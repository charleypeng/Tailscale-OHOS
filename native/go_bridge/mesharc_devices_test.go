package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"

	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/types/key"
)

func TestCollectAndBuildMeshArcDeviceItemsFiltersOfflinePeers(t *testing.T) {
	firstKey := key.NewNode().Public()
	secondKey := key.NewNode().Public()
	status := &ipnstate.Status{
		BackendState: "Running",
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			firstKey: {
				ID:           tailcfg.StableNodeID("office-pc"),
				DNSName:      "office-pc.example.ts.net.",
				OS:           "windows",
				DeviceModel:  "ThinkPad X1",
				Online:       true,
				TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.11")},
			},
			secondKey: {
				ID:           tailcfg.StableNodeID("phone"),
				HostName:     "phone",
				OS:           "android",
				Online:       false,
				TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.12")},
			},
		},
	}

	candidates := collectMeshArcPeerCandidates(status)
	if len(candidates) != 1 {
		t.Fatalf("MeshArc candidates = %#v, want one online peer", candidates)
	}
	item := buildMeshArcDeviceItem(candidates[0], meshArcLocalSendInfo{
		Alias:       "office-pc.example.ts.net.",
		Version:     "2.2",
		DeviceType:  "desktop",
		DeviceModel: "ThinkPad X1",
		Fingerprint: "localsend-cert-fingerprint",
		Download:    true,
	}, "https")
	if item.Alias != "office-pc.example.ts.net" || item.IP != "100.64.0.11" {
		t.Fatalf("unexpected peer identity: %#v", item)
	}
	if item.Port != meshArcLocalSendPort || item.Protocol != "https" || item.Version != "2.2" || !item.Download {
		t.Fatalf("unexpected LocalSend metadata: %#v", item)
	}
	if item.DeviceType != "desktop" || item.DeviceModel != "ThinkPad X1" ||
		item.Fingerprint != "localsend-cert-fingerprint" {
		t.Fatalf("unexpected device metadata: %#v", item)
	}

	status.BackendState = "Stopped"
	if candidates := collectMeshArcPeerCandidates(status); len(candidates) != 0 {
		t.Fatalf("stopped backend still produced MeshArc candidates: %#v", candidates)
	}
}

func TestBuildMeshArcDeviceItemUsesMobileAndFallbackMetadata(t *testing.T) {
	peerKey := key.NewNode().Public()
	candidates := collectMeshArcPeerCandidates(&ipnstate.Status{
		BackendState: "Running",
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			peerKey: {
				ID:           tailcfg.StableNodeID("phone"),
				HostName:     "phone",
				OS:           "HarmonyOS",
				Online:       true,
				TailscaleIPs: []netip.Addr{netip.MustParseAddr("fd7a:115c:a1e0::10"), netip.MustParseAddr("100.64.0.10")},
			},
		},
	})
	if len(candidates) != 1 {
		t.Fatalf("candidates = %#v, want one peer", candidates)
	}

	item := buildMeshArcDeviceItem(candidates[0], meshArcLocalSendInfo{
		Alias:   "phone",
		Version: "2.1",
	}, "https")
	if item.IP != "100.64.0.10" || item.DeviceType != "mobile" ||
		item.DeviceModel != "MeshArc" || item.Alias != "phone" {
		t.Fatalf("unexpected fallback/mobile mapping: %#v", item)
	}
}

func TestBuildPeerSummariesExposeLocalSendStatus(t *testing.T) {
	availableKey := key.NewNode().Public()
	checkingKey := key.NewNode().Public()
	offlineKey := key.NewNode().Public()
	availableID := tailcfg.StableNodeID("available")
	checkingID := tailcfg.StableNodeID("checking")
	offlineID := tailcfg.StableNodeID("offline")
	status := &ipnstate.Status{
		BackendState: "Running",
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			availableKey: {ID: availableID, HostName: "available", Online: true},
			checkingKey:  {ID: checkingID, HostName: "checking", Online: true},
			offlineKey:   {ID: offlineID, HostName: "offline", Online: false},
		},
	}
	peers := buildPeerSummariesWithLocalSend(context.Background(), nil, status,
		map[string]meshArcDeviceStatus{
			peerStableKey(availableID): {
				State: "available", Protocol: "https", Port: 53317, Version: "2.2",
			},
		}, false)
	if len(peers) != 3 {
		t.Fatalf("peer summaries = %#v, want three peers", peers)
	}
	for _, peer := range peers {
		switch peer.Name {
		case "available":
			if peer.LocalSend.State != "available" || peer.LocalSend.Protocol != "https" {
				t.Fatalf("available LocalSend status = %#v", peer.LocalSend)
			}
		case "checking":
			if peer.LocalSend.State != "checking" {
				t.Fatalf("checking LocalSend status = %#v", peer.LocalSend)
			}
		case "offline":
			if peer.LocalSend.State != "offline" {
				t.Fatalf("offline LocalSend status = %#v", peer.LocalSend)
			}
		}
	}
}

func TestBuildPeerSummariesMarkLocalSendUnavailableAfterInitialProbe(t *testing.T) {
	peerKey := key.NewNode().Public()
	peerID := tailcfg.StableNodeID("office-pc")
	peers := buildPeerSummariesWithLocalSend(context.Background(), nil, &ipnstate.Status{
		BackendState: "Running",
		Peer: map[key.NodePublic]*ipnstate.PeerStatus{
			peerKey: {ID: peerID, HostName: "office-pc", Online: true},
		},
	}, map[string]meshArcDeviceStatus{}, true)
	if len(peers) != 1 || peers[0].LocalSend.State != "unavailable" {
		t.Fatalf("peer LocalSend status = %#v, want unavailable after initial probe", peers)
	}
}

func TestUpdateMeshArcDeviceStatusesRequiresTwoFailuresToDropAvailable(t *testing.T) {
	server := &tsnet.Server{}
	client := &local.Client{}
	controller := &backendController{
		server:     server,
		client:     client,
		generation: 7,
		meshArcDeviceStatuses: map[string]meshArcDeviceStatus{
			"peer-workstation": {State: "available", Protocol: "https", Port: 53317},
		},
	}
	unavailable := map[string]meshArcDeviceStatus{
		"peer-workstation": {State: "unavailable", CheckedAtMS: 100},
	}
	if !controller.updateMeshArcDeviceStatuses(server, 7, unavailable) {
		t.Fatal("first status update was rejected")
	}
	if got := controller.meshArcDeviceStatuses["peer-workstation"].State; got != "available" {
		t.Fatalf("first transient failure changed state to %q, want available", got)
	}
	if !controller.hasPendingMeshArcDeviceFailure(server, 7) {
		t.Fatal("first transient failure was not marked for retry")
	}
	if !controller.updateMeshArcDeviceStatuses(server, 7, unavailable) {
		t.Fatal("second status update was rejected")
	}
	if got := controller.meshArcDeviceStatuses["peer-workstation"].State; got != "unavailable" {
		t.Fatalf("second consecutive failure kept state %q, want unavailable", got)
	}
}

func TestUpdateMeshArcDeviceStatusesDoesNotPublishInitialSingleFailure(t *testing.T) {
	server := &tsnet.Server{}
	controller := backendController{
		server:     server,
		client:     &local.Client{},
		generation: 9,
	}
	unavailable := map[string]meshArcDeviceStatus{
		"peer-workstation": {State: "unavailable", CheckedAtMS: 100},
	}
	if !controller.updateMeshArcDeviceStatuses(server, 9, unavailable) {
		t.Fatal("initial status update was rejected")
	}
	if got := controller.meshArcDeviceStatuses["peer-workstation"].State; got != "checking" {
		t.Fatalf("initial transient failure changed state to %q, want checking", got)
	}
	if !controller.hasPendingMeshArcDeviceFailure(server, 9) {
		t.Fatal("initial transient failure was not marked for retry")
	}
	if !controller.updateMeshArcDeviceStatuses(server, 9, unavailable) {
		t.Fatal("second status update was rejected")
	}
	if got := controller.meshArcDeviceStatuses["peer-workstation"].State; got != "unavailable" {
		t.Fatalf("second consecutive failure kept state %q, want unavailable", got)
	}
}

func TestProbeMeshArcLocalSendUsesRegisterAndReturnsHTTPSInfo(t *testing.T) {
	probeFingerprint := strings.Repeat("A", sha256.Size*2)
	client := &http.Client{Transport: meshArcRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method != http.MethodPost || request.URL.Scheme != "https" ||
			request.URL.Host != "100.64.0.11:53317" || request.URL.Path != meshArcLocalSendRegisterPath {
			t.Errorf("probe request = %s %s", request.Method, request.URL.String())
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("read probe request: %v", err)
		} else {
			var payload meshArcLocalSendInfo
			if err := json.Unmarshal(body, &payload); err != nil {
				t.Errorf("probe request is not JSON: %v", err)
			} else if payload.Protocol != "https" || payload.Port != meshArcLocalSendPort ||
				payload.DeviceModel != "MeshArc" || payload.Fingerprint != probeFingerprint {
				t.Errorf("probe payload = %#v", payload)
			}
		}
		return meshArcProbeResponse(`{"alias":"Office LocalSend","version":"2.2","deviceModel":"Windows","deviceType":"desktop","fingerprint":"cert-fingerprint","download":true}`), nil
	})}

	info, protocol, ok := probeMeshArcLocalSend(
		context.Background(), client, "100.64.0.11", probeFingerprint)
	if !ok || protocol != "https" || info.Alias != "Office LocalSend" || info.Fingerprint != "cert-fingerprint" || !info.Download {
		t.Fatalf("probe result = %#v, %q, %t", info, protocol, ok)
	}
}

func TestProbeMeshArcLocalSendFallsBackToHTTPAndRejectsInvalidResponses(t *testing.T) {
	probeFingerprint := strings.Repeat("B", sha256.Size*2)
	var protocols []string
	client := &http.Client{Transport: meshArcRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		protocols = append(protocols, request.URL.Scheme)
		if request.URL.Scheme == "https" {
			return nil, errors.New("TLS unavailable")
		}
		return meshArcProbeResponse(`{"alias":"HTTP LocalSend","version":"2.1","fingerprint":"http-fingerprint"}`), nil
	})}

	info, protocol, ok := probeMeshArcLocalSend(
		context.Background(), client, "100.64.0.12", probeFingerprint)
	if !ok || protocol != "http" || info.Alias != "HTTP LocalSend" || strings.Join(protocols, ",") != "https,http" {
		t.Fatalf("HTTP fallback result = %#v, %q, %t; protocols=%v", info, protocol, ok, protocols)
	}

	invalidClient := &http.Client{Transport: meshArcRoundTripFunc(func(*http.Request) (*http.Response, error) {
		return meshArcProbeResponse(`{"service":"unrelated"}`), nil
	})}
	if _, _, ok := probeMeshArcLocalSend(
		context.Background(), invalidClient, "100.64.0.13", probeFingerprint); ok {
		t.Fatal("unrelated JSON service was accepted as LocalSend")
	}
}

func TestMeshArcCertificateFingerprintMatchesLocalSendFormat(t *testing.T) {
	certificate, err := newMeshArcDeviceClientCertificate()
	if err != nil {
		t.Fatalf("newMeshArcDeviceClientCertificate() error = %v", err)
	}
	fingerprint := meshArcCertificateFingerprint(certificate)
	if len(fingerprint) != sha256.Size*2 || strings.ToUpper(fingerprint) != fingerprint {
		t.Fatalf("certificate fingerprint = %q, want 64 uppercase hex characters", fingerprint)
	}
	if _, err := hex.DecodeString(fingerprint); err != nil {
		t.Fatalf("certificate fingerprint is not hexadecimal: %v", err)
	}
}

func TestPostMeshArcDevicesSendsDocumentedArray(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/api/mesharc/devices" {
			t.Errorf("request = %s %s", request.Method, request.URL.Path)
		}
		if got := request.Header.Get("Content-Type"); !strings.HasPrefix(got, "application/json") {
			t.Errorf("Content-Type = %q", got)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("read request body: %v", err)
			return
		}
		var items []meshArcDeviceItem
		if err := json.Unmarshal(body, &items); err != nil {
			t.Errorf("request body is not an object array: %v; body=%s", err, body)
			return
		}
		if len(items) != 1 || items[0].IP != "100.64.0.10" {
			t.Errorf("request items = %#v", items)
		}
		response.WriteHeader(http.StatusOK)
		_, _ = response.Write([]byte(`{"ok":true,"registered":1}`))
	}))
	defer server.Close()

	result, err := postMeshArcDevices(context.Background(), server.URL+"/api/mesharc/devices", []meshArcDeviceItem{{
		Alias: "家庭 NAS", IP: "100.64.0.10", Port: 53317, Protocol: "https",
	}})
	if err != nil {
		t.Fatalf("postMeshArcDevices() error = %v", err)
	}
	if result.Protocol != "http" || result.HTTPStatus != http.StatusOK || result.Registered != 1 {
		t.Fatalf("postMeshArcDevices() result = %#v", result)
	}
}

func TestPostMeshArcDevicesSendsClientCertificateOverHTTPS(t *testing.T) {
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.TLS == nil || len(request.TLS.PeerCertificates) == 0 {
			t.Error("HTTPS request did not include a MeshArc client certificate")
		}
		response.WriteHeader(http.StatusOK)
		_, _ = response.Write([]byte(`{"ok":true,"registered":0}`))
	}))
	server.TLS.ClientAuth = tls.RequireAnyClientCert
	server.StartTLS()
	defer server.Close()

	if _, err := postMeshArcDevices(context.Background(), server.URL, nil); err != nil {
		t.Fatalf("postMeshArcDevices() HTTPS error = %v", err)
	}
}

func TestPostMeshArcDevicesRejectsNonSuccessResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusForbidden)
	}))
	defer server.Close()

	result, err := postMeshArcDevices(context.Background(), server.URL, nil)
	if err == nil || meshArcPostFailureReason(err) != "http_status" || result.HTTPStatus != http.StatusForbidden {
		t.Fatalf("postMeshArcDevices() result = %#v, error = %v, want HTTP 403", result, err)
	}
}

func TestPostMeshArcDevicesParsesRegistrationCount(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusOK)
		_, _ = response.Write([]byte(`{"ok":true,"registered":0}`))
	}))
	defer server.Close()

	result, err := postMeshArcDevices(context.Background(), server.URL, []meshArcDeviceItem{{Alias: "PC"}})
	if err != nil || result.Registered != 0 {
		t.Fatalf("postMeshArcDevices() result = %#v, error = %v", result, err)
	}
}

func TestMeshArcTransportFailureReasonRedactsDetails(t *testing.T) {
	tests := []struct {
		err  error
		want string
	}{
		{errors.New("remote error: tls: certificate required"), "tls_certificate_required"},
		{errors.New("read tcp 127.0.0.1: connection reset by peer"), "connection_reset"},
		{errors.New("Post request: EOF"), "eof"},
		{errors.New("dial tcp: connection refused"), "connection_refused"},
	}
	for _, test := range tests {
		if got := meshArcTransportFailureReason(context.Background(), test.err); got != test.want {
			t.Errorf("meshArcTransportFailureReason() = %q, want %q", got, test.want)
		}
	}
}

type meshArcRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn meshArcRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func meshArcProbeResponse(body string) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}
