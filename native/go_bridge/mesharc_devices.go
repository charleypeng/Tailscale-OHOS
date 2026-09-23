package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
)

const (
	meshArcDeviceEndpointHTTPS   = "https://127.0.0.1:53317/api/mesharc/devices"
	meshArcDeviceEndpointHTTP    = "http://127.0.0.1:53317/api/mesharc/devices"
	meshArcDeviceSyncPeriod      = 30 * time.Second
	meshArcDeviceTimeout         = 3 * time.Second
	meshArcDeviceRefreshTimeout  = 15 * time.Second
	meshArcLocalSendPort         = 53317
	meshArcLocalSendProtocol     = "https"
	meshArcLocalSendVersion      = "2.1"
	meshArcLocalSendRegisterPath = "/api/localsend/v2/register"
	// LocalSend is probed through Tailscale. Over DERP, the TCP, TLS/mTLS and
	// HTTP round trips can exceed 1.5s even when the receiver
	// is healthy. Bound each protocol attempt and the whole manual refresh
	// separately; a LAN-sized deadline makes cellular DERP peers look absent.
	meshArcLocalSendProbeTimeout = 5 * time.Second
	meshArcLocalSendProbeWorkers = 8
	meshArcLocalSendDeviceType   = "mobile"
)

// meshArcDeviceItem is the array item defined by the MeshArc device API
// contract. alias remains the peer's human-readable name; deviceModel
// identifies the source in the receiving device list.
type meshArcDeviceItem struct {
	Alias       string `json:"alias"`
	IP          string `json:"ip"`
	Port        int    `json:"port"`
	Protocol    string `json:"protocol"`
	Fingerprint string `json:"fingerprint"`
	DeviceType  string `json:"deviceType"`
	DeviceModel string `json:"deviceModel"`
	Version     string `json:"version"`
	Download    bool   `json:"download"`
}

// meshArcLocalSendInfo is the LocalSend v2 register payload. The response
// omits port and protocol in the documented contract, so those fields remain
// optional when decoding a peer's response.
type meshArcLocalSendInfo struct {
	Alias       string `json:"alias"`
	Version     string `json:"version"`
	DeviceModel string `json:"deviceModel"`
	DeviceType  string `json:"deviceType"`
	Fingerprint string `json:"fingerprint"`
	Port        int    `json:"port,omitempty"`
	Protocol    string `json:"protocol,omitempty"`
	Download    bool   `json:"download"`
}

type meshArcPeerCandidate struct {
	peer    *ipnstate.PeerStatus
	address string
}

type meshArcDeviceStatus struct {
	State       string `json:"state"`
	Protocol    string `json:"protocol,omitempty"`
	Port        int    `json:"port,omitempty"`
	Version     string `json:"version,omitempty"`
	CheckedAtMS int64  `json:"checkedAtMs,omitempty"`
}

type meshArcDeviceProbeResult struct {
	Key    string
	Item   meshArcDeviceItem
	Status meshArcDeviceStatus
}

// meshArcReceiverStatus is intentionally limited to protocol-level counters
// and fixed failure categories. It is persisted with the peer snapshot for
// support diagnostics without retaining peer addresses, fingerprints, or
// certificate material.
type meshArcReceiverStatus struct {
	State       string `json:"state"`
	Protocol    string `json:"protocol,omitempty"`
	HTTPStatus  int    `json:"httpStatus,omitempty"`
	Sent        int    `json:"sent"`
	Registered  int    `json:"registered"`
	HTTPSReason string `json:"httpsReason,omitempty"`
	HTTPReason  string `json:"httpReason,omitempty"`
	CheckedAtMS int64  `json:"checkedAtMs,omitempty"`
}

type meshArcDevicePostResult struct {
	Protocol   string
	HTTPStatus int
	Registered int
}

type meshArcDevicePostResponse struct {
	OK         bool `json:"ok"`
	Registered int  `json:"registered"`
}

type meshArcDevicePostError struct {
	reason string
}

func (e *meshArcDevicePostError) Error() string {
	return e.reason
}

type meshArcProbeClient struct {
	HTTPClient  *http.Client
	Fingerprint string
}

var meshArcDeviceHTTPClient = newMeshArcDeviceHTTPClient(nil)

var (
	meshArcDeviceHTTPSClientOnce  sync.Once
	meshArcDeviceHTTPSClientValue *http.Client
	meshArcDeviceHTTPSClientErr   error
)

func newMeshArcDeviceHTTPClient(tlsConfig *tls.Config) *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:             nil,
			DisableKeepAlives: true,
			TLSClientConfig:   tlsConfig,
		},
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// meshArcDeviceHTTPSClient keeps the receiver's client identity in memory for
// this MeshArc process. The current 捷传 build serves the MeshArc endpoint on
// its LocalSend TLS listener and requires a client certificate, although the
// published API contract still documents plain HTTP on loopback.
func meshArcDeviceHTTPSClient() (*http.Client, error) {
	meshArcDeviceHTTPSClientOnce.Do(func() {
		certificate, err := newMeshArcDeviceClientCertificate()
		if err != nil {
			meshArcDeviceHTTPSClientErr = err
			return
		}
		meshArcDeviceHTTPSClientValue = newMeshArcDeviceHTTPClient(&tls.Config{
			MinVersion:         tls.VersionTLS12,
			InsecureSkipVerify: true, // #nosec G402 -- 捷传 uses a self-signed LocalSend certificate.
			Certificates:       []tls.Certificate{certificate},
			// The receiver advertises an acceptable CA name for its client
			// certificate request. This ephemeral MeshArc certificate is
			// intentionally self-signed, so default selection may decline to
			// send it and the receiver reports "certificate required".
			GetClientCertificate: func(_ *tls.CertificateRequestInfo) (*tls.Certificate, error) {
				return &certificate, nil
			},
		})
	})
	return meshArcDeviceHTTPSClientValue, meshArcDeviceHTTPSClientErr
}

func newMeshArcDeviceClientCertificate() (tls.Certificate, error) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          serialNumber,
		Subject:               pkix.Name{CommonName: "MeshArc"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
	}
	derCertificate, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return tls.Certificate{}, err
	}
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derCertificate})
	privateKeyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return tls.Certificate{}, err
	}
	privateKeyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKeyDER})
	return tls.X509KeyPair(certificatePEM, privateKeyPEM)
}

func meshArcDeviceClientTLSConfig(certificate tls.Certificate) *tls.Config {
	return &tls.Config{
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: true, // #nosec G402 -- LocalSend uses per-device self-signed certificates.
		Certificates:       []tls.Certificate{certificate},
		// Always select the ephemeral certificate when the peer requests one.
		// Its self-signed issuer may not appear in the advertised CA list.
		GetClientCertificate: func(_ *tls.CertificateRequestInfo) (*tls.Certificate, error) {
			return &certificate, nil
		},
	}
}

func meshArcCertificateFingerprint(certificate tls.Certificate) string {
	if len(certificate.Certificate) == 0 {
		return ""
	}
	digest := sha256.Sum256(certificate.Certificate[0])
	return fmt.Sprintf("%X", digest)
}

func (b *backendController) startMeshArcDeviceSync(
	server *tsnet.Server, generation uint64, client *local.Client,
) {
	syncContext, cancel := context.WithCancel(context.Background())
	b.mu.Lock()
	if b.server != server || b.generation != generation {
		b.mu.Unlock()
		cancel()
		return
	}
	previousCancel := b.meshArcDeviceSyncStop
	b.meshArcDeviceSyncStop = cancel
	// The first probe is asynchronous. Treat the status channel as initialized
	// immediately so an empty result cannot keep an online peer in checking
	// forever if the first LocalSend request fails.
	b.meshArcDeviceSyncReady = true
	b.mu.Unlock()
	if previousCancel != nil {
		previousCancel()
	}

	go b.meshArcDeviceSyncLoop(syncContext, server, generation, client)
}

func (b *backendController) meshArcDeviceSyncLoop(
	ctx context.Context, server *tsnet.Server, generation uint64, client *local.Client,
) {
	defer func() {
		b.mu.Lock()
		if b.server == server && b.generation == generation {
			b.meshArcDeviceSyncStop = nil
		}
		b.mu.Unlock()
	}()

	b.syncMeshArcDevicesOnce(ctx, server, generation, client)
	ticker := time.NewTicker(meshArcDeviceSyncPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			b.syncMeshArcDevicesOnce(ctx, server, generation, client)
		}
	}
}

func (b *backendController) syncMeshArcDevicesOnce(
	ctx context.Context, server *tsnet.Server, generation uint64, client *local.Client,
) {
	// A UI refresh can arrive during the periodic sweep. Waiting for its lock
	// must respect the same deadline as the network requests.
	for !b.meshArcDeviceRefreshMu.TryLock() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(50 * time.Millisecond):
		}
	}
	defer b.meshArcDeviceRefreshMu.Unlock()
	if ctx.Err() != nil || !b.isCurrentBackend(server, generation) {
		return
	}
	statusContext, cancel := context.WithTimeout(ctx, meshArcDeviceTimeout)
	status, err := client.Status(statusContext)
	cancel()
	if err != nil || !b.isCurrentBackend(server, generation) {
		// Keep the last successful list alive. The receiver expires devices that
		// stop arriving, while a transient status failure should not immediately
		// hide every device from the user's transfer list.
		if err != nil {
			b.updateMeshArcReceiverStatus(server, generation, meshArcReceiverStatus{
				State: "failed", Sent: 0, Registered: 0,
				HTTPSReason: "tailscale_status", CheckedAtMS: time.Now().UnixMilli(),
			})
		}
		return
	}

	// Tailscale's peer list is only the candidate set. A peer is added to the
	// MeshArc array after its LocalSend /register endpoint answers successfully.
	devices, localSendStatuses := probeMeshArcDeviceItems(ctx, server, status)
	// An exhausted caller budget is not evidence that any receiver stopped.
	// In particular, never count a cancelled second sample as another failure.
	if ctx.Err() != nil {
		return
	}
	if !b.updateMeshArcDeviceStatuses(server, generation, localSendStatuses) {
		return
	}
	receiverStatus := postMeshArcDevicesToReceiver(ctx, devices)
	b.updateMeshArcReceiverStatus(server, generation, receiverStatus)
}

func (b *backendController) refreshMeshArcDevices() string {
	b.mu.Lock()
	server := b.server
	generation := b.generation
	client := b.client
	b.mu.Unlock()
	if server == nil || client == nil {
		return "FAILED | LocalSend refresh | backend not ready"
	}
	ctx, cancel := context.WithTimeout(context.Background(), meshArcDeviceRefreshTimeout)
	defer cancel()
	b.syncMeshArcDevicesOnce(ctx, server, generation, client)
	// A receiver that was available may occasionally lose one mTLS/register
	// request while the service is still running. The first miss is held by
	// updateMeshArcDeviceStatuses; an explicit user refresh immediately takes a
	// second sample when enough budget remains. A stopped receiver that rejects
	// connections promptly can still become unavailable in one tap.
	deadline, _ := ctx.Deadline()
	if b.hasPendingMeshArcDeviceFailure(server, generation) &&
		time.Until(deadline) >= 2*meshArcLocalSendProbeTimeout {
		b.syncMeshArcDevicesOnce(ctx, server, generation, client)
	}
	if !b.isCurrentBackend(server, generation) {
		return "FAILED | LocalSend refresh | backend changed"
	}
	if ctx.Err() != nil {
		return "FAILED | LocalSend refresh | timeout"
	}
	return "OK | LocalSend refresh"
}

func (b *backendController) isCurrentBackend(server *tsnet.Server, generation uint64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.server == server && b.generation == generation && b.client != nil
}

func (b *backendController) updateMeshArcDeviceStatuses(
	server *tsnet.Server, generation uint64, statuses map[string]meshArcDeviceStatus,
) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.server != server || b.generation != generation || b.client == nil {
		return false
	}
	if b.meshArcDeviceFailures == nil {
		b.meshArcDeviceFailures = make(map[string]int)
	}
	merged := cloneMeshArcDeviceStatuses(statuses)
	for peerKey, status := range statuses {
		if status.State == "available" {
			delete(b.meshArcDeviceFailures, peerKey)
			continue
		}
		previous, hadPrevious := b.meshArcDeviceStatuses[peerKey]
		if hadPrevious && previous.State != "available" && previous.State != "checking" {
			delete(b.meshArcDeviceFailures, peerKey)
			continue
		}
		failures := b.meshArcDeviceFailures[peerKey] + 1
		b.meshArcDeviceFailures[peerKey] = failures
		if failures < 2 {
			if hadPrevious {
				merged[peerKey] = previous
			} else {
				merged[peerKey] = meshArcDeviceStatus{
					State:       "checking",
					CheckedAtMS: status.CheckedAtMS,
				}
			}
		}
	}
	for peerKey := range b.meshArcDeviceFailures {
		if _, stillOnline := statuses[peerKey]; !stillOnline {
			delete(b.meshArcDeviceFailures, peerKey)
		}
	}
	b.meshArcDeviceStatuses = merged
	return true
}

func (b *backendController) hasPendingMeshArcDeviceFailure(
	server *tsnet.Server, generation uint64,
) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.server != server || b.generation != generation || b.client == nil {
		return false
	}
	for _, failures := range b.meshArcDeviceFailures {
		if failures == 1 {
			return true
		}
	}
	return false
}

func (b *backendController) updateMeshArcReceiverStatus(
	server *tsnet.Server, generation uint64, status meshArcReceiverStatus,
) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.server != server || b.generation != generation || b.client == nil {
		return false
	}
	b.meshArcReceiverStatus = status
	return true
}

// meshArcDeviceStatusesSnapshotLocked must be called while b.mu is held.
func (b *backendController) meshArcDeviceStatusesSnapshotLocked() map[string]meshArcDeviceStatus {
	return cloneMeshArcDeviceStatuses(b.meshArcDeviceStatuses)
}

func cloneMeshArcDeviceStatuses(
	statuses map[string]meshArcDeviceStatus,
) map[string]meshArcDeviceStatus {
	if len(statuses) == 0 {
		return map[string]meshArcDeviceStatus{}
	}
	copyStatuses := make(map[string]meshArcDeviceStatus, len(statuses))
	for key, status := range statuses {
		copyStatuses[key] = status
	}
	return copyStatuses
}

func postMeshArcDevices(
	ctx context.Context, endpoint string, devices []meshArcDeviceItem,
) (meshArcDevicePostResult, error) {
	result := meshArcDevicePostResult{Protocol: "http"}
	if strings.HasPrefix(strings.ToLower(strings.TrimSpace(endpoint)), "https://") {
		result.Protocol = "https"
	}
	if devices == nil {
		devices = []meshArcDeviceItem{}
	}
	body, err := json.Marshal(devices)
	if err != nil {
		return result, &meshArcDevicePostError{reason: "encoding"}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return result, &meshArcDevicePostError{reason: "request"}
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "MeshArc-Tailscale/1")
	client := meshArcDeviceHTTPClient
	if strings.HasPrefix(strings.ToLower(strings.TrimSpace(endpoint)), "https://") {
		client, err = meshArcDeviceHTTPSClient()
		if err != nil {
			return result, &meshArcDevicePostError{reason: "client_certificate"}
		}
	}
	response, err := client.Do(request)
	if err != nil {
		return result, &meshArcDevicePostError{reason: meshArcTransportFailureReason(ctx, err)}
	}
	defer response.Body.Close()
	result.HTTPStatus = response.StatusCode
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, 8<<10))
	if readErr != nil {
		return result, &meshArcDevicePostError{reason: "response_read"}
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return result, &meshArcDevicePostError{reason: "http_status"}
	}
	var decoded meshArcDevicePostResponse
	if err := json.Unmarshal(responseBody, &decoded); err != nil {
		return result, &meshArcDevicePostError{reason: "invalid_response"}
	}
	result.Registered = decoded.Registered
	if !decoded.OK {
		return result, &meshArcDevicePostError{reason: "rejected"}
	}
	return result, nil
}

func postMeshArcDevicesToReceiver(ctx context.Context, devices []meshArcDeviceItem) meshArcReceiverStatus {
	status := meshArcReceiverStatus{
		State: "failed", Sent: len(devices), Registered: 0, CheckedAtMS: time.Now().UnixMilli(),
	}
	for _, endpoint := range []string{meshArcDeviceEndpointHTTPS, meshArcDeviceEndpointHTTP} {
		attemptContext, cancel := context.WithTimeout(ctx, meshArcDeviceTimeout)
		result, err := postMeshArcDevices(attemptContext, endpoint, devices)
		cancel()
		if err == nil {
			status.Protocol = result.Protocol
			status.HTTPStatus = result.HTTPStatus
			status.Registered = result.Registered
			if result.Registered == len(devices) {
				status.State = "ok"
			} else if result.Protocol == "https" {
				status.HTTPSReason = "registration_mismatch"
			} else {
				status.HTTPReason = "registration_mismatch"
			}
			return status
		}
		status.Protocol = result.Protocol
		status.HTTPStatus = result.HTTPStatus
		reason := meshArcPostFailureReason(err)
		if result.Protocol == "https" {
			status.HTTPSReason = reason
		} else {
			status.HTTPReason = reason
		}
	}
	return status
}

func meshArcPostFailureReason(err error) string {
	var postError *meshArcDevicePostError
	if errors.As(err, &postError) {
		return postError.reason
	}
	return "unknown"
}

func meshArcTransportFailureReason(ctx context.Context, err error) string {
	if ctx.Err() != nil {
		return "timeout"
	}
	detail := strings.ToLower(err.Error())
	switch {
	case strings.Contains(detail, "certificate required"):
		return "tls_certificate_required"
	case strings.Contains(detail, "remote error: tls"),
		strings.Contains(detail, "tls handshake"),
		strings.Contains(detail, "tls:"):
		return "tls_handshake"
	case strings.Contains(detail, "connection refused"):
		return "connection_refused"
	case strings.Contains(detail, "connection reset"):
		return "connection_reset"
	case strings.Contains(detail, "no route to host"),
		strings.Contains(detail, "network is unreachable"):
		return "network_unreachable"
	case strings.Contains(detail, "malformed http response"):
		return "malformed_http"
	case strings.Contains(detail, "eof"):
		return "eof"
	default:
		return "transport"
	}
}

func probeMeshArcDeviceItems(
	ctx context.Context, server *tsnet.Server, status *ipnstate.Status,
) ([]meshArcDeviceItem, map[string]meshArcDeviceStatus) {
	items := make([]meshArcDeviceItem, 0)
	statuses := make(map[string]meshArcDeviceStatus)
	checkedAtMS := time.Now().UnixMilli()
	if status != nil && status.BackendState == "Running" {
		for _, peer := range status.Peer {
			if peer == nil || !peer.Online || peer.Expired {
				continue
			}
			statuses[peerStableKey(peer.ID)] = meshArcDeviceStatus{
				State:       "unavailable",
				CheckedAtMS: checkedAtMS,
			}
		}
	}
	candidates := collectMeshArcPeerCandidates(status)
	if server == nil || len(candidates) == 0 {
		return items, statuses
	}

	probeClient := newMeshArcProbeHTTPClient(server)
	if probeClient == nil {
		return items, statuses
	}
	defer closeMeshArcProbeHTTPClient(probeClient.HTTPClient)

	workerCount := meshArcLocalSendProbeWorkers
	if len(candidates) < workerCount {
		workerCount = len(candidates)
	}
	jobs := make(chan meshArcPeerCandidate, len(candidates))
	results := make(chan meshArcDeviceProbeResult, len(candidates))
	for _, candidate := range candidates {
		jobs <- candidate
	}
	close(jobs)

	var workers sync.WaitGroup
	workers.Add(workerCount)
	for index := 0; index < workerCount; index++ {
		go func() {
			defer workers.Done()
			for candidate := range jobs {
				info, protocol, ok := probeMeshArcLocalSend(
					ctx, probeClient.HTTPClient, candidate.address, probeClient.Fingerprint)
				if !ok {
					continue
				}
				results <- meshArcDeviceProbeResult{
					Key:  peerStableKey(candidate.peer.ID),
					Item: buildMeshArcDeviceItem(candidate, info, protocol),
					Status: meshArcDeviceStatus{
						State:       "available",
						Protocol:    protocol,
						Port:        meshArcLocalSendPort,
						Version:     strings.TrimSpace(info.Version),
						CheckedAtMS: checkedAtMS,
					},
				}
			}
		}()
	}
	workers.Wait()
	close(results)
	seenKeys := make(map[string]struct{}, len(candidates))
	for result := range results {
		if _, ok := seenKeys[result.Key]; ok {
			continue
		}
		seenKeys[result.Key] = struct{}{}
		items = append(items, result.Item)
		statuses[result.Key] = result.Status
	}
	sortMeshArcDeviceItems(items)
	return items, statuses
}

func collectMeshArcPeerCandidates(status *ipnstate.Status) []meshArcPeerCandidate {
	candidates := make([]meshArcPeerCandidate, 0)
	if status == nil || status.BackendState != "Running" {
		return candidates
	}
	for _, peer := range status.Peer {
		if peer == nil || !peer.Online || peer.Expired {
			continue
		}
		for _, address := range meshArcPeerAddresses(peer.TailscaleIPs) {
			candidates = append(candidates, meshArcPeerCandidate{peer: peer, address: address})
		}
	}
	return candidates
}

func newMeshArcProbeHTTPClient(server *tsnet.Server) *meshArcProbeClient {
	if server == nil {
		return nil
	}
	certificate, err := newMeshArcDeviceClientCertificate()
	if err != nil {
		return nil
	}
	fingerprint := meshArcCertificateFingerprint(certificate)
	if fingerprint == "" {
		return nil
	}
	transport := &http.Transport{
		Proxy:             nil,
		DialContext:       server.Dial,
		DisableKeepAlives: true,
		TLSClientConfig:   meshArcDeviceClientTLSConfig(certificate),
	}
	return &meshArcProbeClient{
		HTTPClient: &http.Client{
			Transport: transport,
			CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		Fingerprint: fingerprint,
	}
}

func closeMeshArcProbeHTTPClient(client *http.Client) {
	if client == nil {
		return
	}
	if transport, ok := client.Transport.(*http.Transport); ok {
		transport.CloseIdleConnections()
	}
}

func probeMeshArcLocalSend(
	ctx context.Context, httpClient *http.Client, address, fingerprint string,
) (meshArcLocalSendInfo, string, bool) {
	if httpClient == nil || strings.TrimSpace(address) == "" || strings.TrimSpace(fingerprint) == "" {
		return meshArcLocalSendInfo{}, "", false
	}
	for _, protocol := range []string{meshArcLocalSendProtocol, "http"} {
		attemptContext, cancel := context.WithTimeout(ctx, meshArcLocalSendProbeTimeout)
		probeRequest := meshArcLocalSendInfo{
			Alias:       "MeshArc",
			Version:     meshArcLocalSendVersion,
			DeviceModel: "MeshArc",
			DeviceType:  meshArcLocalSendDeviceType,
			Fingerprint: fingerprint,
			Port:        meshArcLocalSendPort,
			Protocol:    protocol,
			Download:    false,
		}
		body, err := json.Marshal(probeRequest)
		if err != nil {
			cancel()
			return meshArcLocalSendInfo{}, "", false
		}
		endpoint := protocol + "://" + net.JoinHostPort(address, strconv.Itoa(meshArcLocalSendPort)) + meshArcLocalSendRegisterPath
		request, err := http.NewRequestWithContext(attemptContext, http.MethodPost, endpoint, bytes.NewReader(body))
		if err != nil {
			cancel()
			continue
		}
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Accept", "application/json")
		request.Header.Set("User-Agent", "MeshArc-LocalSendProbe/1")
		response, err := httpClient.Do(request)
		if err != nil {
			cancel()
			continue
		}
		responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		response.Body.Close()
		cancel()
		if readErr != nil || response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
			continue
		}
		var info meshArcLocalSendInfo
		if err := json.Unmarshal(responseBody, &info); err != nil || !validMeshArcLocalSendInfo(info) {
			continue
		}
		return info, protocol, true
	}
	return meshArcLocalSendInfo{}, "", false
}

func validMeshArcLocalSendInfo(info meshArcLocalSendInfo) bool {
	return strings.TrimSpace(info.Alias) != "" &&
		strings.TrimSpace(info.Version) != "" &&
		strings.TrimSpace(info.Fingerprint) != ""
}

func buildMeshArcDeviceItem(
	candidate meshArcPeerCandidate, info meshArcLocalSendInfo, protocol string,
) meshArcDeviceItem {
	alias := strings.TrimSuffix(strings.TrimSpace(info.Alias), ".")
	if alias == "" {
		alias = meshArcPeerName(candidate.peer)
	}
	fingerprint := strings.TrimSpace(info.Fingerprint)
	if fingerprint == "" {
		fingerprint = peerStableKey(candidate.peer.ID)
	}
	if fingerprint == "" {
		fingerprint = "mesharc-" + candidate.address
	}
	model := strings.TrimSpace(info.DeviceModel)
	if model == "" || strings.EqualFold(model, "default") {
		model = strings.TrimSpace(candidate.peer.DeviceModel)
	}
	if model == "" || strings.EqualFold(model, "default") {
		model = "MeshArc"
	}
	version := strings.TrimSpace(info.Version)
	if version == "" {
		version = meshArcLocalSendVersion
	}
	return meshArcDeviceItem{
		Alias:       alias,
		IP:          candidate.address,
		Port:        meshArcLocalSendPort,
		Protocol:    protocol,
		Fingerprint: fingerprint,
		DeviceType:  normalizeMeshArcDeviceType(info.DeviceType, candidate.peer.OS, model),
		DeviceModel: model,
		Version:     version,
		Download:    info.Download,
	}
}

func meshArcPeerName(peer *ipnstate.PeerStatus) string {
	if peer == nil {
		return "Unnamed device"
	}
	name := strings.TrimSuffix(strings.TrimSpace(peer.DNSName), ".")
	if name == "" {
		name = strings.TrimSpace(peer.HostName)
	}
	if name == "" {
		return "Unnamed device"
	}
	return name
}

func normalizeMeshArcDeviceType(deviceType, osName, deviceModel string) string {
	switch strings.ToLower(strings.TrimSpace(deviceType)) {
	case "mobile", "desktop", "web", "headless", "server":
		return strings.ToLower(strings.TrimSpace(deviceType))
	default:
		return meshArcDeviceType(osName, deviceModel)
	}
}

func sortMeshArcDeviceItems(items []meshArcDeviceItem) {
	sort.Slice(items, func(left, right int) bool {
		leftName := strings.ToLower(items[left].Alias)
		rightName := strings.ToLower(items[right].Alias)
		if leftName != rightName {
			return leftName < rightName
		}
		return items[left].IP < items[right].IP
	})
}

func meshArcPeerAddress(addresses []netip.Addr) string {
	values := meshArcPeerAddresses(addresses)
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

func meshArcPeerAddresses(addresses []netip.Addr) []string {
	result := make([]string, 0, len(addresses))
	seen := make(map[string]struct{}, len(addresses))
	for _, address := range addresses {
		if !address.IsValid() || !address.Is4() {
			continue
		}
		value := address.String()
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	if len(result) > 0 {
		return result
	}
	for _, address := range addresses {
		if !address.IsValid() {
			continue
		}
		value := address.String()
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func meshArcDeviceType(osName, deviceModel string) string {
	value := strings.ToLower(strings.TrimSpace(osName) + " " + strings.TrimSpace(deviceModel))
	switch {
	case containsAny(value, "nas", "server"):
		return "server"
	case containsAny(value, "headless"):
		return "headless"
	case containsAny(value, "web browser", "web"):
		return "web"
	case containsAny(value, "android", "ios", "ipados", "harmony", "ohos"):
		return "mobile"
	default:
		return "desktop"
	}
}
