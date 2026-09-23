package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

const (
	taildriveHTTPURL           = "http://100.100.100.100:8080"
	taildriveListTimeout       = 20 * time.Second
	taildriveMutationTimeout   = 30 * time.Second
	taildriveTransferTimeout   = 30 * time.Minute
	taildriveMaxListResponse   = 8 << 20
	taildriveProgressBufferLen = 32 << 10
	taildrivePeerWarmupTimeout = 5 * time.Second
	taildrivePeerWarmupTTL     = 2 * time.Minute
	taildriveColdProbeTimeout  = 3 * time.Second
)

var taildrivePropfindBody = []byte(`<?xml version="1.0" encoding="utf-8" ?>
<propfind xmlns="DAV:">
  <prop>
    <resourcetype/>
    <displayname/>
    <getcontentlength/>
    <getlastmodified/>
    <getetag/>
    <getcontenttype/>
  </prop>
</propfind>`)

type taildriveSnapshot struct {
	State    string                    `json:"state"`
	Reason   string                    `json:"reason"`
	Transfer taildriveTransferSnapshot `json:"transfer"`
}

type taildriveEntry struct {
	Name        string `json:"name"`
	Path        string `json:"path"`
	Kind        string `json:"kind"`
	Size        int64  `json:"size"`
	ModifiedAt  int64  `json:"modifiedAtMs"`
	ContentType string `json:"contentType,omitempty"`
	ETag        string `json:"etag,omitempty"`
}

type taildriveListRequest struct {
	Path string `json:"path"`
}

type taildriveListResult struct {
	State   string           `json:"state"`
	Path    string           `json:"path"`
	Entries []taildriveEntry `json:"entries"`
	Reason  string           `json:"reason,omitempty"`
}

type taildriveStatRequest struct {
	Path string `json:"path"`
}

type taildriveStatResult struct {
	State  string         `json:"state"`
	Entry  taildriveEntry `json:"entry"`
	Reason string         `json:"reason,omitempty"`
}

type taildriveMutationRequest struct {
	Operation string `json:"operation"`
	Path      string `json:"path"`
	NewPath   string `json:"newPath,omitempty"`
	Overwrite bool   `json:"overwrite,omitempty"`
}

type taildriveMutationResult struct {
	State     string `json:"state"`
	Operation string `json:"operation"`
	Path      string `json:"path"`
	NewPath   string `json:"newPath,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

type taildriveTransferRequest struct {
	RequestID          int64  `json:"requestId"`
	RemotePath         string `json:"remotePath"`
	LocalRoot          string `json:"localRoot"`
	LocalPath          string `json:"localPath"`
	SourceModifiedAtMs int64  `json:"sourceModifiedAtMs,omitempty"`
	Overwrite          bool   `json:"overwrite,omitempty"`
}

type taildriveTransferSnapshot struct {
	RequestID   int64  `json:"requestId"`
	Direction   string `json:"direction"`
	State       string `json:"state"`
	Reason      string `json:"reason"`
	RemotePath  string `json:"remotePath"`
	LocalPath   string `json:"localPath"`
	FileName    string `json:"fileName"`
	Bytes       int64  `json:"bytes"`
	TotalBytes  int64  `json:"totalBytes"`
	StartedAt   int64  `json:"startedAtMs"`
	CompletedAt int64  `json:"completedAtMs"`
}

type taildriveDAVMultistatus struct {
	XMLName  xml.Name               `xml:"multistatus"`
	Response []taildriveDAVResponse `xml:"response"`
}

type taildriveDAVResponse struct {
	Href     string                 `xml:"href"`
	Propstat []taildriveDAVPropstat `xml:"propstat"`
}

type taildriveDAVPropstat struct {
	Prop   taildriveDAVProp `xml:"prop"`
	Status string           `xml:"status"`
}

type taildriveDAVProp struct {
	ResourceType  taildriveDAVResourceType `xml:"resourcetype"`
	DisplayName   string                   `xml:"displayname"`
	ContentLength string                   `xml:"getcontentlength"`
	LastModified  string                   `xml:"getlastmodified"`
	ETag          string                   `xml:"getetag"`
	ContentType   string                   `xml:"getcontenttype"`
}

type taildriveDAVResourceType struct {
	Collection *struct{} `xml:"collection"`
}

type taildriveHTTPStatusError struct {
	StatusCode int
}

func (e *taildriveHTTPStatusError) Error() string {
	return fmt.Sprintf("taildrive HTTP status %d", e.StatusCode)
}

type taildriveWebDAVClient struct {
	httpClient *http.Client
}

func newTaildriveWebDAVClient(server *tsnet.Server) (*taildriveWebDAVClient, error) {
	if server == nil {
		return nil, errors.New("backend unavailable")
	}
	httpClient, err := server.TaildriveHTTPClient()
	if err != nil {
		return nil, err
	}
	httpClient.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return &taildriveWebDAVClient{httpClient: httpClient}, nil
}

func (c *taildriveWebDAVClient) close() {
	if transport, ok := c.httpClient.Transport.(*http.Transport); ok {
		transport.CloseIdleConnections()
	}
}

func normalizeTaildrivePath(raw string) (string, error) {
	if raw == "" {
		return "/", nil
	}
	if strings.ContainsRune(raw, '\x00') || strings.ContainsRune(raw, '\\') {
		return "", errors.New("invalid taildrive path")
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "" || parsed.Host != "" || parsed.User != nil ||
		parsed.RawQuery != "" || parsed.Fragment != "" || parsed.Opaque != "" {
		return "", errors.New("invalid taildrive path")
	}
	decoded := parsed.Path
	if decoded == "" {
		decoded = "/"
	}
	if !strings.HasPrefix(decoded, "/") || strings.ContainsRune(decoded, '\x00') ||
		strings.ContainsRune(decoded, '\\') {
		return "", errors.New("invalid taildrive path")
	}
	if strings.Contains(strings.ToLower(parsed.EscapedPath()), "%2f") ||
		strings.Contains(strings.ToLower(parsed.EscapedPath()), "%5c") {
		return "", errors.New("invalid taildrive path")
	}
	parts := strings.Split(decoded, "/")
	for index, part := range parts {
		if index == 0 || part == "" {
			continue
		}
		if part == "." || part == ".." {
			return "", errors.New("invalid taildrive path")
		}
	}
	if decoded != "/" {
		decoded = strings.TrimRight(decoded, "/")
	}
	canonical := (&url.URL{Path: decoded}).EscapedPath()
	if canonical == "" {
		return "/", nil
	}
	return canonical, nil
}

func taildriveURL(remotePath string) (*url.URL, error) {
	normalized, err := normalizeTaildrivePath(remotePath)
	if err != nil {
		return nil, err
	}
	decoded, err := url.PathUnescape(normalized)
	if err != nil {
		return nil, errors.New("invalid taildrive path")
	}
	return &url.URL{
		Scheme:  "http",
		Host:    "100.100.100.100:8080",
		Path:    decoded,
		RawPath: normalized,
	}, nil
}

func taildriveHrefPath(href string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(href))
	if err != nil || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", errors.New("invalid WebDAV href")
	}
	if parsed.Scheme != "" && parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", errors.New("invalid WebDAV href")
	}
	if parsed.Path == "" {
		return "/", nil
	}
	return normalizeTaildrivePath(parsed.EscapedPath())
}

func taildriveChildName(parentPath, childPath string) (string, bool) {
	parentPath, err := normalizeTaildrivePath(parentPath)
	if err != nil {
		return "", false
	}
	childPath, err = normalizeTaildrivePath(childPath)
	if err != nil || parentPath == childPath {
		return "", false
	}
	prefix := parentPath
	if prefix != "/" {
		prefix += "/"
	}
	if !strings.HasPrefix(childPath, prefix) {
		return "", false
	}
	remaining := strings.TrimPrefix(childPath, prefix)
	if remaining == "" || strings.Contains(remaining, "/") {
		return "", false
	}
	name, err := url.PathUnescape(remaining)
	if err != nil || name == "" || name == "." || name == ".." ||
		strings.ContainsAny(name, "/\\") || strings.ContainsRune(name, '\x00') {
		return "", false
	}
	return name, true
}

func (c *taildriveWebDAVClient) propfind(
	ctx context.Context, remotePath, depth string,
) (string, []taildriveDAVResponse, error) {
	requestURL, err := taildriveURL(remotePath)
	if err != nil {
		return "", nil, err
	}
	request, err := http.NewRequestWithContext(ctx, "PROPFIND", requestURL.String(), bytes.NewReader(taildrivePropfindBody))
	if err != nil {
		return "", nil, err
	}
	request.Header.Set("Depth", depth)
	request.Header.Set("Content-Type", "application/xml; charset=utf-8")
	response, err := c.httpClient.Do(request)
	if err != nil {
		return "", nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusMultiStatus {
		return "", nil, &taildriveHTTPStatusError{StatusCode: response.StatusCode}
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, taildriveMaxListResponse+1))
	if err != nil {
		return "", nil, err
	}
	if len(body) > taildriveMaxListResponse {
		return "", nil, errors.New("WebDAV response too large")
	}
	var multistatus taildriveDAVMultistatus
	if err := xml.Unmarshal(body, &multistatus); err != nil {
		return "", nil, err
	}
	requestedPath, err := normalizeTaildrivePath(remotePath)
	if err != nil {
		return "", nil, err
	}
	return requestedPath, multistatus.Response, nil
}

func (c *taildriveWebDAVClient) list(ctx context.Context, remotePath string) ([]taildriveEntry, error) {
	requestedPath, responses, err := c.propfind(ctx, remotePath, "1")
	if err != nil {
		return nil, err
	}
	entries := make([]taildriveEntry, 0, len(responses))
	for _, response := range responses {
		responsePath, err := taildriveHrefPath(response.Href)
		if err != nil {
			continue
		}
		name, ok := taildriveChildName(requestedPath, responsePath)
		if !ok {
			continue
		}
		prop, ok := taildriveDAVResponseProp(response.Propstat)
		if !ok {
			continue
		}
		entries = append(entries, taildriveEntryFromDAV(name, responsePath, prop))
	}
	sort.Slice(entries, func(left, right int) bool {
		if entries[left].Kind != entries[right].Kind {
			return entries[left].Kind == "directory"
		}
		return strings.ToLower(entries[left].Name) < strings.ToLower(entries[right].Name)
	})
	return entries, nil
}

func (c *taildriveWebDAVClient) stat(ctx context.Context, remotePath string) (taildriveEntry, error) {
	requestedPath, responses, err := c.propfind(ctx, remotePath, "0")
	if err != nil {
		return taildriveEntry{}, err
	}
	for _, response := range responses {
		responsePath, pathErr := taildriveHrefPath(response.Href)
		if pathErr != nil || responsePath != requestedPath {
			continue
		}
		prop, ok := taildriveDAVResponseProp(response.Propstat)
		if !ok {
			continue
		}
		name := taildriveRemoteBaseName(responsePath)
		if responsePath == "/" {
			name = "/"
		}
		return taildriveEntryFromDAV(name, responsePath, prop), nil
	}
	return taildriveEntry{}, &taildriveHTTPStatusError{StatusCode: http.StatusNotFound}
}

func taildriveEntryFromDAV(name, remotePath string, prop taildriveDAVProp) taildriveEntry {
	entry := taildriveEntry{
		Name: name, Path: remotePath, Kind: "file", Size: 0,
		ContentType: strings.TrimSpace(prop.ContentType), ETag: strings.TrimSpace(prop.ETag),
	}
	if prop.ResourceType.Collection != nil {
		entry.Kind = "directory"
	} else if size, err := strconv.ParseInt(strings.TrimSpace(prop.ContentLength), 10, 64); err == nil && size >= 0 {
		entry.Size = size
	}
	if modified, err := http.ParseTime(strings.TrimSpace(prop.LastModified)); err == nil {
		entry.ModifiedAt = modified.UnixMilli()
	}
	return entry
}

func taildriveDAVResponseProp(propstats []taildriveDAVPropstat) (taildriveDAVProp, bool) {
	for _, propstat := range propstats {
		status := strings.TrimSpace(propstat.Status)
		if status == "" || strings.Contains(status, " 200 ") || strings.Contains(status, " 2") {
			return propstat.Prop, true
		}
	}
	return taildriveDAVProp{}, false
}

func (c *taildriveWebDAVClient) mutate(ctx context.Context, request taildriveMutationRequest) error {
	remoteURL, err := taildriveURL(request.Path)
	if err != nil {
		return err
	}
	method := ""
	switch request.Operation {
	case "mkdir":
		method = "MKCOL"
	case "delete":
		method = http.MethodDelete
	case "rename", "move":
		method = "MOVE"
	default:
		return errors.New("invalid mutation operation")
	}
	httpRequest, err := http.NewRequestWithContext(ctx, method, remoteURL.String(), nil)
	if err != nil {
		return err
	}
	if request.Operation == "rename" || request.Operation == "move" {
		destination, err := taildriveURL(request.NewPath)
		if err != nil {
			return err
		}
		httpRequest.Header.Set("Destination", destination.String())
		if request.Overwrite {
			httpRequest.Header.Set("Overwrite", "T")
		} else {
			httpRequest.Header.Set("Overwrite", "F")
		}
	}
	response, err := c.httpClient.Do(httpRequest)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return &taildriveHTTPStatusError{StatusCode: response.StatusCode}
	}
	return nil
}

func (b *backendController) taildriveList(requestText string) string {
	var request taildriveListRequest
	if err := json.Unmarshal([]byte(requestText), &request); err != nil {
		return marshalTaildriveList(taildriveListResult{State: "failed", Path: "/", Reason: "invalid_request"})
	}
	remotePath, err := normalizeTaildrivePath(request.Path)
	if err != nil {
		return marshalTaildriveList(taildriveListResult{State: "failed", Path: "/", Reason: "invalid_request"})
	}
	result := taildriveListResult{State: "failed", Path: remotePath, Entries: []taildriveEntry{}}
	b.warmTaildrivePeer(remotePath)
	server, available := b.taildriveServer()
	if !available {
		result.Reason = "backend_unavailable"
		return marshalTaildriveList(result)
	}
	machine, hasMachine := taildriveTargetMachine(remotePath)
	if hasMachine && !b.taildriveDAVReady(machine) {
		probeClient, probeClientErr := newTaildriveWebDAVClient(server)
		if probeClientErr != nil {
			result.Reason = classifyTaildriveError(probeClientErr)
			return marshalTaildriveList(result)
		}
		probeCtx, probeCancel := context.WithTimeout(context.Background(), taildriveColdProbeTimeout)
		result.Entries, err = probeClient.list(probeCtx, remotePath)
		probeTimedOut := errors.Is(probeCtx.Err(), context.DeadlineExceeded)
		probeCancel()
		probeClient.close()
		if err == nil {
			b.markTaildriveDAVReady(machine)
			result.State = "ready"
			return marshalTaildriveList(result)
		}
		if !probeTimedOut && !taildriveColdProbeRetryable(err) {
			result.Reason = classifyTaildriveError(err)
			return marshalTaildriveList(result)
		}
	}
	client, err := newTaildriveWebDAVClient(server)
	if err != nil {
		result.Reason = classifyTaildriveError(err)
		return marshalTaildriveList(result)
	}
	defer client.close()
	ctx, cancel := context.WithTimeout(context.Background(), taildriveListTimeout)
	defer cancel()
	result.Entries, err = client.list(ctx, remotePath)
	if err != nil {
		result.Reason = classifyTaildriveError(err)
		return marshalTaildriveList(result)
	}
	result.State = "ready"
	if hasMachine {
		b.markTaildriveDAVReady(machine)
	}
	return marshalTaildriveList(result)
}

func (b *backendController) taildriveStat(requestText string) string {
	var request taildriveStatRequest
	if err := json.Unmarshal([]byte(requestText), &request); err != nil {
		return marshalTaildriveStat(taildriveStatResult{State: "failed", Reason: "invalid_request"})
	}
	remotePath, err := normalizeTaildrivePath(request.Path)
	if err != nil {
		return marshalTaildriveStat(taildriveStatResult{State: "failed", Reason: "invalid_request"})
	}
	result := taildriveStatResult{State: "failed", Entry: taildriveEntry{Path: remotePath}}
	server, available := b.taildriveServer()
	if !available {
		result.Reason = "backend_unavailable"
		return marshalTaildriveStat(result)
	}
	client, err := newTaildriveWebDAVClient(server)
	if err != nil {
		result.Reason = classifyTaildriveError(err)
		return marshalTaildriveStat(result)
	}
	defer client.close()
	ctx, cancel := context.WithTimeout(context.Background(), taildriveListTimeout)
	defer cancel()
	result.Entry, err = client.stat(ctx, remotePath)
	if err != nil {
		result.Reason = classifyTaildriveError(err)
		return marshalTaildriveStat(result)
	}
	result.State = "ready"
	return marshalTaildriveStat(result)
}

func (b *backendController) taildriveMutate(requestText string) string {
	var request taildriveMutationRequest
	if err := json.Unmarshal([]byte(requestText), &request); err != nil {
		return marshalTaildriveMutation(taildriveMutationResult{State: "failed", Reason: "invalid_request"})
	}
	path, err := normalizeTaildrivePath(request.Path)
	if err != nil || path == "/" {
		return marshalTaildriveMutation(taildriveMutationResult{State: "failed", Operation: request.Operation, Reason: "invalid_request"})
	}
	request.Path = path
	if request.Operation == "rename" || request.Operation == "move" {
		newPath, normalizeErr := normalizeTaildrivePath(request.NewPath)
		if normalizeErr != nil || newPath == "/" || strings.HasPrefix(newPath, request.Path+"/") {
			return marshalTaildriveMutation(taildriveMutationResult{State: "failed", Operation: request.Operation, Path: request.Path, Reason: "invalid_request"})
		}
		request.NewPath = newPath
	}
	if (request.Operation != "mkdir" && request.Operation != "delete" && request.Operation != "rename" && request.Operation != "move") ||
		((request.Operation == "rename" || request.Operation == "move") && (request.NewPath == "" || request.NewPath == request.Path)) {
		return marshalTaildriveMutation(taildriveMutationResult{State: "failed", Operation: request.Operation, Path: request.Path, Reason: "invalid_request"})
	}
	result := taildriveMutationResult{State: "failed", Operation: request.Operation, Path: request.Path, NewPath: request.NewPath}
	server, available := b.taildriveServer()
	if !available {
		result.Reason = "backend_unavailable"
		return marshalTaildriveMutation(result)
	}
	client, err := newTaildriveWebDAVClient(server)
	if err == nil {
		defer client.close()
		ctx, cancel := context.WithTimeout(context.Background(), taildriveMutationTimeout)
		err = client.mutate(ctx, request)
		cancel()
	}
	if err != nil {
		result.Reason = classifyTaildriveError(err)
		return marshalTaildriveMutation(result)
	}
	result.State = "completed"
	return marshalTaildriveMutation(result)
}

func (b *backendController) taildriveServer() (*tsnet.Server, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.server, b.server != nil && b.client != nil && !b.starting
}

func validateTaildriveTransferRequest(request taildriveTransferRequest) (string, string, error) {
	if request.RequestID <= 0 || request.RemotePath == "" || !filepath.IsAbs(request.LocalRoot) ||
		!filepath.IsAbs(request.LocalPath) || strings.ContainsRune(request.LocalRoot, '\x00') ||
		strings.ContainsRune(request.LocalPath, '\x00') {
		return "", "", errors.New("invalid transfer request")
	}
	remotePath, err := normalizeTaildrivePath(request.RemotePath)
	if err != nil {
		return "", "", err
	}
	root := filepath.Clean(request.LocalRoot)
	localPath := filepath.Clean(request.LocalPath)
	relative, err := filepath.Rel(root, localPath)
	if err != nil || relative == "." || relative == ".." ||
		strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", "", errors.New("local path outside staging root")
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", "", err
	}
	rootResolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", "", err
	}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o700); err != nil {
		return "", "", err
	}
	parentResolved, err := filepath.EvalSymlinks(filepath.Dir(localPath))
	if err != nil {
		return "", "", err
	}
	resolvedRelative, err := filepath.Rel(rootResolved, parentResolved)
	if err != nil || (resolvedRelative != "." && (resolvedRelative == ".." ||
		strings.HasPrefix(resolvedRelative, ".."+string(filepath.Separator)))) {
		return "", "", errors.New("local path outside staging root")
	}
	return remotePath, localPath, nil
}

func (b *backendController) taildriveDownload(requestText string) string {
	return b.taildriveDownloadWithTracking(requestText, true)
}

func taildriveTargetMachine(remotePath string) (string, bool) {
	normalized, err := normalizeTaildrivePath(remotePath)
	if err != nil {
		return "", false
	}
	decoded, err := url.PathUnescape(normalized)
	if err != nil {
		return "", false
	}
	parts := strings.Split(strings.Trim(decoded, "/"), "/")
	if len(parts) < 2 {
		return "", false
	}
	machine := normalizedTaildriveMachineName(parts[1])
	return machine, machine != ""
}

func normalizedTaildriveMachineName(value string) string {
	name := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(value)), ".")
	if dot := strings.IndexByte(name, '.'); dot >= 0 {
		name = name[:dot]
	}
	return name
}

func taildriveColdProbeRetryable(err error) bool {
	if err == nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var statusErr *taildriveHTTPStatusError
	return !errors.As(err, &statusErr)
}

// warmTaildrivePeer establishes a real Tailscale data-plane path before the
// first remote WebDAV request. A Disco ping alone can discover a route without
// completing the encrypted data path that PeerAPI needs, which made the first
// two PROPFIND requests hit their full timeout on a cold VPN session.
func (b *backendController) warmTaildrivePeer(remotePath string) {
	machine, ok := taildriveTargetMachine(remotePath)
	if !ok {
		return
	}
	now := time.Now()
	b.taildriveWarmMu.Lock()
	lastWarm := b.taildriveWarmAt[machine]
	b.taildriveWarmMu.Unlock()
	if !lastWarm.IsZero() && now.Sub(lastWarm) < taildrivePeerWarmupTTL {
		return
	}

	b.mu.Lock()
	client := b.client
	b.mu.Unlock()
	if client == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), taildrivePeerWarmupTimeout)
	defer cancel()
	status, err := client.Status(ctx)
	if err != nil {
		return
	}
	var target netip.Addr
	for _, peer := range status.Peer {
		if normalizedTaildriveMachineName(peer.DNSName) != machine &&
			normalizedTaildriveMachineName(peer.HostName) != machine {
			continue
		}
		for _, address := range peer.TailscaleIPs {
			if address.Is4() {
				target = address
				break
			}
			if !target.IsValid() {
				target = address
			}
		}
		break
	}
	if !target.IsValid() {
		return
	}
	result, err := client.Ping(ctx, target, tailcfg.PingTSMP)
	if err != nil || result == nil || result.Err != "" {
		return
	}
	b.taildriveWarmMu.Lock()
	if b.taildriveWarmAt == nil {
		b.taildriveWarmAt = make(map[string]time.Time)
	}
	b.taildriveWarmAt[machine] = time.Now()
	b.taildriveWarmMu.Unlock()
}

func (b *backendController) taildriveDAVReady(machine string) bool {
	b.taildriveWarmMu.Lock()
	readyAt := b.taildriveDAVReadyAt[machine]
	b.taildriveWarmMu.Unlock()
	return !readyAt.IsZero() && time.Since(readyAt) < taildrivePeerWarmupTTL
}

func (b *backendController) markTaildriveDAVReady(machine string) {
	b.taildriveWarmMu.Lock()
	if b.taildriveDAVReadyAt == nil {
		b.taildriveDAVReadyAt = make(map[string]time.Time)
	}
	b.taildriveDAVReadyAt[machine] = time.Now()
	b.taildriveWarmMu.Unlock()
}

// Manual downloads use a separate request channel and an independent context.
// They must not occupy the preview transfer slot, because a user can start a
// preview while a manually requested export is still downloading.
func (b *backendController) taildriveManualDownload(requestText string) string {
	return b.taildriveDownloadWithTracking(requestText, false)
}

func (b *backendController) taildriveDownloadWithTracking(requestText string, tracked bool) string {
	var request taildriveTransferRequest
	if err := json.Unmarshal([]byte(requestText), &request); err != nil {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{State: "failed", Reason: "invalid_request"})
	}
	remotePath, localPath, err := validateTaildriveTransferRequest(request)
	if err != nil {
		failed := taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "download", State: "failed", Reason: "invalid_request"}
		return marshalTaildriveTransfer(failed)
	}
	server, available := b.taildriveServer()
	if !available {
		failed := taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "download", State: "failed", Reason: "backend_unavailable"}
		return marshalTaildriveTransfer(failed)
	}
	client, err := newTaildriveWebDAVClient(server)
	if err != nil {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "download", State: "failed", Reason: classifyTaildriveError(err)})
	}
	defer client.close()
	fileName := taildriveRemoteBaseName(remotePath)
	startedAt := time.Now().UnixMilli()
	totalBytes := int64(0)
	writtenBytes := int64(0)
	var ctx context.Context
	var cancel context.CancelFunc
	if tracked {
		var queued bool
		ctx, cancel, queued = b.beginTaildriveTransfer(request.RequestID, "download", remotePath, localPath, fileName, 0)
		if !queued {
			return marshalTaildriveTransfer(taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "download", State: "failed", Reason: "busy"})
		}
	} else {
		ctx, cancel = context.WithTimeout(context.Background(), taildriveTransferTimeout)
	}
	defer cancel()
	finish := func(state, reason string) taildriveTransferSnapshot {
		if tracked {
			return b.finishTaildriveTransfer(request.RequestID, state, reason)
		}
		return taildriveTransferSnapshot{
			RequestID: request.RequestID, Direction: "download", State: state, Reason: reason,
			RemotePath: remotePath, LocalPath: localPath, FileName: fileName,
			Bytes: writtenBytes, TotalBytes: totalBytes, StartedAt: startedAt,
			CompletedAt: time.Now().UnixMilli(),
		}
	}
	update := func(change func(*taildriveTransferSnapshot)) {
		if tracked {
			b.updateTaildriveTransfer(request.RequestID, change)
		}
	}
	requestURL, err := taildriveURL(remotePath)
	if err != nil {
		return marshalTaildriveTransfer(finish("failed", "invalid_request"))
	}
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return marshalTaildriveTransfer(finish("failed", "invalid_request"))
	}
	response, err := client.httpClient.Do(httpRequest)
	if err != nil {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(err)))
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(&taildriveHTTPStatusError{StatusCode: response.StatusCode})))
	}
	totalBytes = response.ContentLength
	knownLength := totalBytes >= 0
	if totalBytes < 0 {
		totalBytes = 0
	}
	update(func(snapshot *taildriveTransferSnapshot) {
		snapshot.State = "transferring"
		snapshot.TotalBytes = totalBytes
	})
	partPath := localPath + ".part"
	if _, statErr := os.Lstat(localPath); statErr == nil {
		return marshalTaildriveTransfer(finish("failed", "file_exists"))
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(statErr)))
	}
	if _, statErr := os.Lstat(partPath); statErr == nil {
		return marshalTaildriveTransfer(finish("failed", "file_exists"))
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(statErr)))
	}
	file, err := os.OpenFile(partPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(err)))
	}
	completed := false
	defer func() {
		if !completed {
			_ = file.Close()
			_ = os.Remove(partPath)
		}
	}()
	progressWriter := &taildriveProgressWriter{writer: file, onWrite: func(written int) {
		writtenBytes += int64(written)
		update(func(snapshot *taildriveTransferSnapshot) {
			snapshot.Bytes += int64(written)
		})
	}}
	if _, err := io.CopyBuffer(progressWriter, response.Body, make([]byte, taildriveProgressBufferLen)); err != nil {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(err)))
	}
	if knownLength && writtenBytes != totalBytes {
		return marshalTaildriveTransfer(finish("failed", "network_interrupted"))
	}
	if err := file.Sync(); err != nil {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(err)))
	}
	if err := file.Close(); err != nil {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(err)))
	}
	if err := os.Rename(partPath, localPath); err != nil {
		return marshalTaildriveTransfer(finish("failed", classifyTaildriveError(err)))
	}
	completed = true
	return marshalTaildriveTransfer(finish("completed", ""))
}

func (b *backendController) taildriveUpload(requestText string) string {
	var request taildriveTransferRequest
	if err := json.Unmarshal([]byte(requestText), &request); err != nil {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{State: "failed", Reason: "invalid_request"})
	}
	remotePath, localPath, err := validateTaildriveTransferRequest(request)
	if err != nil {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "upload", State: "failed", Reason: "invalid_request"})
	}
	info, err := os.Stat(localPath)
	if err != nil || !info.Mode().IsRegular() {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "upload", State: "failed", Reason: "file_unavailable"})
	}
	server, available := b.taildriveServer()
	if !available {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "upload", State: "failed", Reason: "backend_unavailable"})
	}
	client, err := newTaildriveWebDAVClient(server)
	if err != nil {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "upload", State: "failed", Reason: classifyTaildriveError(err)})
	}
	defer client.close()
	fileName := taildriveRemoteBaseName(remotePath)
	ctx, cancel, queued := b.beginTaildriveTransfer(request.RequestID, "upload", remotePath, localPath, fileName, info.Size())
	if !queued {
		return marshalTaildriveTransfer(taildriveTransferSnapshot{RequestID: request.RequestID, Direction: "upload", State: "failed", Reason: "busy"})
	}
	defer cancel()
	file, err := os.Open(localPath)
	if err != nil {
		return marshalTaildriveTransfer(b.finishTaildriveTransfer(request.RequestID, "failed", classifyTaildriveError(err)))
	}
	defer file.Close()
	requestURL, err := taildriveURL(remotePath)
	if err != nil {
		return marshalTaildriveTransfer(b.finishTaildriveTransfer(request.RequestID, "failed", "invalid_request"))
	}
	progressReader := &taildriveProgressReader{reader: file, onRead: func(read int) {
		b.updateTaildriveTransfer(request.RequestID, func(snapshot *taildriveTransferSnapshot) {
			snapshot.State = "transferring"
			snapshot.Bytes += int64(read)
		})
	}}
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPut, requestURL.String(), progressReader)
	if err != nil {
		return marshalTaildriveTransfer(b.finishTaildriveTransfer(request.RequestID, "failed", "invalid_request"))
	}
	httpRequest.ContentLength = info.Size()
	httpRequest.Header.Set("Content-Type", "application/octet-stream")
	if request.SourceModifiedAtMs > 0 {
		modifiedAt := time.UnixMilli(request.SourceModifiedAtMs).UTC()
		// Last-Modified is the standard HTTP representation. X-OC-Mtime is also
		// understood by WebDAV servers that explicitly support preserving source
		// timestamps; unsupported Taildrive hosts safely ignore both headers.
		httpRequest.Header.Set("Last-Modified", modifiedAt.Format(http.TimeFormat))
		httpRequest.Header.Set("X-OC-Mtime", strconv.FormatInt(modifiedAt.Unix(), 10))
	}
	if !request.Overwrite {
		httpRequest.Header.Set("If-None-Match", "*")
	}
	response, err := client.httpClient.Do(httpRequest)
	if err != nil {
		return marshalTaildriveTransfer(b.finishTaildriveTransfer(request.RequestID, "failed", classifyTaildriveError(err)))
	}
	defer response.Body.Close()
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return marshalTaildriveTransfer(b.finishTaildriveTransfer(request.RequestID, "failed", classifyTaildriveError(&taildriveHTTPStatusError{StatusCode: response.StatusCode})))
	}
	return marshalTaildriveTransfer(b.finishTaildriveTransfer(request.RequestID, "completed", ""))
}

func (b *backendController) taildriveTransferSnapshot() taildriveTransferSnapshot {
	b.taildriveMu.Lock()
	defer b.taildriveMu.Unlock()
	snapshot := b.taildriveTask
	if snapshot.State == "" {
		snapshot.State = "idle"
	}
	return snapshot
}

func (b *backendController) beginTaildriveTransfer(
	requestID int64, direction, remotePath, localPath, fileName string, totalBytes int64,
) (context.Context, context.CancelFunc, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), taildriveTransferTimeout)
	b.taildriveMu.Lock()
	defer b.taildriveMu.Unlock()
	if b.taildriveTask.State == "queued" || b.taildriveTask.State == "transferring" {
		cancel()
		return nil, nil, false
	}
	b.taildriveTask = taildriveTransferSnapshot{
		RequestID: requestID, Direction: direction, State: "queued", RemotePath: remotePath,
		LocalPath: localPath, FileName: fileName, TotalBytes: totalBytes,
		StartedAt: time.Now().UnixMilli(),
	}
	b.taildriveStop = cancel
	return ctx, cancel, true
}

func (b *backendController) updateTaildriveTransfer(
	requestID int64, update func(*taildriveTransferSnapshot),
) {
	b.taildriveMu.Lock()
	defer b.taildriveMu.Unlock()
	if b.taildriveTask.RequestID != requestID ||
		(b.taildriveTask.State != "queued" && b.taildriveTask.State != "transferring") {
		return
	}
	update(&b.taildriveTask)
}

func (b *backendController) finishTaildriveTransfer(
	requestID int64, state, reason string,
) taildriveTransferSnapshot {
	b.taildriveMu.Lock()
	defer b.taildriveMu.Unlock()
	if b.taildriveTask.RequestID != requestID ||
		(b.taildriveTask.State != "queued" && b.taildriveTask.State != "transferring") {
		return b.taildriveTask
	}
	b.taildriveTask.State = state
	b.taildriveTask.Reason = reason
	b.taildriveTask.CompletedAt = time.Now().UnixMilli()
	b.taildriveStop = nil
	return b.taildriveTask
}

func (b *backendController) cancelTaildriveTransfer(reason string) {
	b.taildriveMu.Lock()
	cancel := b.taildriveStop
	if b.taildriveTask.State == "queued" || b.taildriveTask.State == "transferring" {
		b.taildriveTask.State = "failed"
		b.taildriveTask.Reason = reason
		b.taildriveTask.CompletedAt = time.Now().UnixMilli()
	}
	b.taildriveStop = nil
	b.taildriveMu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func taildriveRemoteBaseName(remotePath string) string {
	decoded, err := url.PathUnescape(remotePath)
	if err != nil {
		return "download"
	}
	name := path.Base(decoded)
	if name == "." || name == "/" || name == "" {
		return "download"
	}
	return name
}

type taildriveProgressReader struct {
	reader io.Reader
	onRead func(int)
}

func (r *taildriveProgressReader) Read(buffer []byte) (int, error) {
	read, err := r.reader.Read(buffer)
	if read > 0 && r.onRead != nil {
		r.onRead(read)
	}
	return read, err
}

type taildriveProgressWriter struct {
	writer  io.Writer
	onWrite func(int)
}

func (w *taildriveProgressWriter) Write(buffer []byte) (int, error) {
	written, err := w.writer.Write(buffer)
	if written > 0 && w.onWrite != nil {
		w.onWrite(written)
	}
	return written, err
}

func classifyTaildriveError(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.Canceled) {
		return "cancelled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var statusErr *taildriveHTTPStatusError
	if errors.As(err, &statusErr) {
		switch statusErr.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden:
			return "permission_denied"
		case http.StatusNotFound:
			return "not_found"
		case http.StatusConflict, http.StatusPreconditionFailed:
			return "already_exists"
		case http.StatusInsufficientStorage:
			return "no_space"
		case http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return "remote_unavailable"
		default:
			return fmt.Sprintf("http_%d", statusErr.StatusCode)
		}
	}
	if errors.Is(err, os.ErrPermission) {
		return "permission_denied"
	}
	if errors.Is(err, os.ErrNotExist) {
		return "file_unavailable"
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "no space"):
		return "no_space"
	case strings.Contains(message, "broken pipe"), strings.Contains(message, "connection reset"),
		strings.Contains(message, "connection closed"), strings.Contains(message, "unexpected eof"):
		return "network_interrupted"
	default:
		return "transfer_failed"
	}
}

func marshalTaildriveList(result taildriveListResult) string {
	if result.Entries == nil {
		result.Entries = []taildriveEntry{}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return `{"state":"failed","path":"/","entries":[],"reason":"invalid_result"}`
	}
	return string(encoded)
}

func marshalTaildriveStat(result taildriveStatResult) string {
	encoded, err := json.Marshal(result)
	if err != nil {
		return `{"state":"failed","reason":"invalid_result"}`
	}
	return string(encoded)
}

func marshalTaildriveMutation(result taildriveMutationResult) string {
	encoded, err := json.Marshal(result)
	if err != nil {
		return `{"state":"failed","reason":"invalid_result"}`
	}
	return string(encoded)
}

func marshalTaildriveTransfer(snapshot taildriveTransferSnapshot) string {
	encoded, err := json.Marshal(snapshot)
	if err != nil {
		return `{"state":"failed","reason":"invalid_result"}`
	}
	return string(encoded)
}
