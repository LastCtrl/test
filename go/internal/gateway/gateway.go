package gateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

const (
	modelsPath = "/v1/models"
	chatPath   = "/v1/chat/completions"
	// chatEndpoint is appended to a candidate base URL (which already carries
	// the provider's version prefix, e.g. https://host/v1).
	chatEndpoint = "/chat/completions"
	// maxErrorDrain bounds how much of a failed upstream body is read so the
	// connection can be reused; the body is never logged or forwarded.
	maxErrorDrain = 4096
	// copyBufferSize is the streaming copy buffer.
	copyBufferSize = 32 * 1024
	// defaultMaxRequestBody bounds the incoming chat request body. Larger
	// requests are rejected with 413 before parsing.
	defaultMaxRequestBody = 32 << 20 // 32 MiB
)

// hopByHopHeaders are connection-scoped and must not be forwarded.
var hopByHopHeaders = map[string]bool{
	"Connection":          true,
	"Keep-Alive":          true,
	"Proxy-Authenticate":  true,
	"Proxy-Authorization": true,
	"Te":                  true,
	"Trailer":             true,
	"Transfer-Encoding":   true,
	"Upgrade":             true,
}

// Server is the gateway HTTP handler. The zero value is not usable; build it
// with New.
type Server struct {
	cfg    Config
	client *http.Client
	getenv func(string) string
	logger *log.Logger
	now    func() time.Time

	// maxRequestBody bounds the incoming request body (413 beyond it).
	maxRequestBody int64
	// streamIdleTimeout bounds the gap between upstream stream chunks.
	streamIdleTimeout time.Duration
}

// New validates cfg and returns a ready server. The client dials the configured
// upstreams; the env lookup is os.Getenv.
func New(cfg Config) (*Server, error) {
	if err := cfg.normalize(); err != nil {
		return nil, err
	}
	return &Server{
		cfg:               cfg,
		client:            defaultClient(),
		getenv:            os.Getenv,
		logger:            log.New(os.Stderr, "gateway ", log.LstdFlags),
		now:               time.Now,
		maxRequestBody:    defaultMaxRequestBody,
		streamIdleTimeout: time.Duration(cfg.StreamIdleTimeoutSec) * time.Second,
	}, nil
}

// SetLogger replaces the access logger. Passing nil silences it.
func (s *Server) SetLogger(logger *log.Logger) { s.logger = logger }

// Handler returns the gateway routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc(modelsPath, s.handleModels)
	mux.HandleFunc(chatPath, s.handleChat)
	return mux
}

// handleModels returns the configured aliases in the OpenAI list shape. opencode
// requires that the returned ids match provider.models entries, so ids are alias
// names, not upstream model names.
func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	names := s.cfg.AliasNames()
	data := make([]modelInfo, 0, len(names))
	created := s.now().Unix()
	for _, name := range names {
		data = append(data, modelInfo{ID: name, Object: "model", Created: created, OwnedBy: "agent-hq"})
	}
	writeJSON(w, http.StatusOK, modelList{Object: "list", Data: data})
}

// handleChat proxies one chat completion. The response is forwarded
// byte-for-byte (status, headers and streamed SSE frames); the request body is
// re-encoded so that only the model field changes, only the required headers are
// sent upstream, and the client query string is not forwarded.
func (s *Server) handleChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	started := time.Now()

	r.Body = http.MaxBytesReader(w, r.Body, s.maxRequestBody)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
			s.logf("%s %s -> 413 latency=%s", r.Method, r.URL.Path, time.Since(started))
			return
		}
		writeError(w, http.StatusBadRequest, "cannot read request body")
		return
	}
	payload, alias, err := s.preparePayload(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		s.logf("%s %s -> 400 latency=%s", r.Method, r.URL.Path, time.Since(started))
		return
	}
	stream := wantsStream(payload)

	tracked := &trackedWriter{ResponseWriter: w}
	candidate, err := s.forwardChat(tracked, r, payload, alias.Candidates)
	if err != nil {
		if tracked.written {
			// The stream already started; the client saw a valid HTTP status.
			// Never mask it with a different candidate or error body.
			s.logf("%s %s -> %d candidate=%s/%s latency=%s stream=%t error=%v",
				r.Method, r.URL.Path, tracked.status, candidate.Provider, candidate.Model, time.Since(started), stream, err)
			return
		}
		var cfgErr *configError
		status := http.StatusBadGateway
		if errors.As(err, &cfgErr) {
			status = http.StatusInternalServerError
		}
		writeError(w, status, err.Error())
		s.logf("%s %s -> %d latency=%s stream=%t error=%v",
			r.Method, r.URL.Path, status, time.Since(started), stream, err)
		return
	}
	s.logf("%s %s -> %d candidate=%s/%s latency=%s stream=%t",
		r.Method, r.URL.Path, tracked.status, candidate.Provider, candidate.Model, time.Since(started), stream)
}

// preparePayload parses the body, resolves the alias and keeps every other field
// as raw JSON so tools and unknown fields survive round-tripping verbatim.
func (s *Server) preparePayload(body []byte) (map[string]json.RawMessage, Alias, error) {
	if len(bytes.TrimSpace(body)) == 0 {
		return nil, Alias{}, errors.New("empty request body")
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(body, &payload); err != nil {
		return nil, Alias{}, fmt.Errorf("invalid JSON body: %v", err)
	}
	rawModel, ok := payload["model"]
	if !ok {
		return nil, Alias{}, errors.New("model field is required")
	}
	var aliasName string
	if err := json.Unmarshal(rawModel, &aliasName); err != nil || strings.TrimSpace(aliasName) == "" {
		return nil, Alias{}, errors.New("model must be a non-empty string")
	}
	alias, ok := s.cfg.Aliases[aliasName]
	if !ok {
		return nil, Alias{}, fmt.Errorf("unknown model alias %q", aliasName)
	}
	return payload, alias, nil
}

// forwardChat tries candidates in order and streams the first 2xx response.
// Fallback happens only before any response byte is written; an upstream that
// fails after the stream started is returned as-is.
func (s *Server) forwardChat(w http.ResponseWriter, r *http.Request, payload map[string]json.RawMessage, candidates []Candidate) (Candidate, error) {
	var lastErr error
	keyed := false
	for _, candidate := range candidates {
		key := s.getenv(candidate.APIKeyEnv)
		if key == "" {
			lastErr = fmt.Errorf("candidate %s/%s: environment variable %s is not set", candidate.Provider, candidate.Model, candidate.APIKeyEnv)
			continue
		}
		keyed = true

		body, err := encodeWithModel(payload, candidate.Model)
		if err != nil {
			lastErr = fmt.Errorf("candidate %s/%s: %v", candidate.Provider, candidate.Model, err)
			continue
		}
		req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, candidate.BaseURL+chatEndpoint, bytes.NewReader(body))
		if err != nil {
			lastErr = fmt.Errorf("candidate %s/%s: %v", candidate.Provider, candidate.Model, err)
			continue
		}
		// Apply per-candidate headers first so the gateway's own required
		// headers (below) always win on a name conflict.
		for name, value := range candidate.Headers {
			req.Header.Set(name, value)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set("Accept", "application/json")
		if wantsStream(payload) {
			req.Header.Set("Accept", "text/event-stream")
		} else if accept := r.Header.Get("Accept"); accept != "" {
			req.Header.Set("Accept", accept)
		}

		resp, err := s.client.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("candidate %s/%s: %v", candidate.Provider, candidate.Model, err)
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			lastErr = fmt.Errorf("candidate %s/%s: upstream status %d", candidate.Provider, candidate.Model, resp.StatusCode)
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxErrorDrain))
			_ = resp.Body.Close()
			continue
		}

		copyErr := copyUpstream(w, resp, s.streamIdleTimeout)
		_ = resp.Body.Close()
		if copyErr != nil {
			return candidate, fmt.Errorf("stream interrupted: %v", copyErr)
		}
		return candidate, nil
	}

	if lastErr == nil {
		lastErr = errors.New("no upstream candidates configured")
	}
	if !keyed {
		return Candidate{}, &configError{err: lastErr}
	}
	return Candidate{}, lastErr
}

// encodeWithModel returns the payload with the model field replaced. Raw
// messages are re-emitted verbatim, so tools and unknown fields are untouched.
func encodeWithModel(payload map[string]json.RawMessage, model string) ([]byte, error) {
	raw, err := json.Marshal(model)
	if err != nil {
		return nil, err
	}
	payload["model"] = raw
	return json.Marshal(payload)
}

// wantsStream reports whether the request asks for an SSE stream.
func wantsStream(payload map[string]json.RawMessage) bool {
	raw, ok := payload["stream"]
	if !ok {
		return false
	}
	var stream bool
	if err := json.Unmarshal(raw, &stream); err != nil {
		return false
	}
	return stream
}

// copyUpstream forwards the upstream status and headers and streams the body
// with an explicit flush per chunk, so SSE reaches the client without buffering.
// When idleTimeout is positive, a gap longer than idleTimeout between chunks
// aborts the stream with a clear error instead of stalling forever.
func copyUpstream(w http.ResponseWriter, resp *http.Response, idleTimeout time.Duration) error {
	dst := w.Header()
	for name, values := range resp.Header {
		if hopByHopHeaders[http.CanonicalHeaderKey(name)] || strings.EqualFold(name, "Content-Length") {
			continue
		}
		dst.Del(name)
		for _, value := range values {
			dst.Add(name, value)
		}
	}
	w.WriteHeader(resp.StatusCode)
	if resp.Body == nil {
		return nil
	}

	idle := newIdleGuard(resp.Body, idleTimeout)
	defer idle.stop()

	buf := make([]byte, copyBufferSize)
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			idle.touch()
			if _, writeErr := w.Write(buf[:n]); writeErr != nil {
				return writeErr
			}
			flush(w)
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			if idle.tripped() {
				return fmt.Errorf("upstream stream idle for more than %s", idleTimeout)
			}
			return readErr
		}
	}
}

// idleGuard aborts an upstream body that stalls between reads. It closes the
// body on idle timeout; the reading goroutine observes the resulting error and
// reports it as an idle timeout via tripped. A non-positive timeout disables it.
type idleGuard struct {
	body        io.Closer
	timeout     time.Duration
	activity    chan struct{}
	done        chan struct{}
	trippedFlag atomic.Bool
}

func newIdleGuard(body io.Closer, timeout time.Duration) *idleGuard {
	guard := &idleGuard{body: body, timeout: timeout}
	if timeout <= 0 {
		return guard
	}
	guard.activity = make(chan struct{}, 1)
	guard.done = make(chan struct{})
	go guard.watch()
	return guard
}

// watch closes the body when no touch signal arrives within timeout.
func (g *idleGuard) watch() {
	timer := time.NewTimer(g.timeout)
	defer timer.Stop()
	for {
		select {
		case <-g.done:
			return
		case <-g.activity:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(g.timeout)
		case <-timer.C:
			g.trippedFlag.Store(true)
			_ = g.body.Close()
			return
		}
	}
}

// touch records activity, resetting the idle timer.
func (g *idleGuard) touch() {
	if g.activity == nil {
		return
	}
	select {
	case g.activity <- struct{}{}:
	default:
	}
}

// tripped reports whether the idle timeout aborted the body.
func (g *idleGuard) tripped() bool { return g.trippedFlag.Load() }

// stop terminates the watchdog.
func (g *idleGuard) stop() {
	if g.done == nil {
		return
	}
	close(g.done)
}

// flush flushes an http.ResponseWriter when the implementation supports it.
func flush(w http.ResponseWriter) {
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
}

// configError marks failures that are the gateway's own configuration problem
// (for example a missing API key env var) rather than an upstream failure.
type configError struct{ err error }

func (e *configError) Error() string {
	if e.err == nil {
		return "gateway is not configured"
	}
	return e.err.Error()
}

func (e *configError) Unwrap() error { return e.err }

// trackedWriter reports whether the response has started, so a post-stream
// failure is never turned into a fresh error status or another candidate.
type trackedWriter struct {
	http.ResponseWriter
	status  int
	written bool
}

func (t *trackedWriter) WriteHeader(code int) {
	if !t.written {
		t.status = code
		t.written = true
	}
	t.ResponseWriter.WriteHeader(code)
}

func (t *trackedWriter) Write(b []byte) (int, error) {
	if !t.written {
		t.status = http.StatusOK
		t.written = true
	}
	return t.ResponseWriter.Write(b)
}

func (t *trackedWriter) Flush() {
	if flusher, ok := t.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// modelInfo and modelList are the OpenAI /v1/models shapes.
type modelInfo struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	OwnedBy string `json:"owned_by"`
}

type modelList struct {
	Object string      `json:"object"`
	Data   []modelInfo `json:"data"`
}

// errorEnvelope is the OpenAI-compatible error shape. Messages never contain
// upstream bodies or secret values.
type errorEnvelope struct {
	Error errorBody `json:"error"`
}

type errorBody struct {
	Message string `json:"message"`
	Type    string `json:"type"`
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorEnvelope{Error: errorBody{Message: message, Type: "gateway_error"}})
}

// defaultClient builds the upstream client. It has no overall timeout (streams
// may be long-lived) but bounds dialing and response headers.
func defaultClient() *http.Client {
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 120 * time.Second,
	}
	return &http.Client{Transport: transport}
}

func (s *Server) logf(format string, args ...any) {
	if s.logger != nil {
		s.logger.Printf(format, args...)
	}
}
