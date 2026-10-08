package gateway

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testAPIKey = "unit-test-key-do-not-log"

// newTestServer builds a server with a deterministic API key and silent logging.
func newTestServer(t *testing.T, cfg Config) *Server {
	t.Helper()
	server, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	server.logger = log.New(io.Discard, "", 0)
	server.getenv = func(string) string { return testAPIKey }
	return server
}

// singleAlias builds a config with one alias "strong" pointing at baseURL.
func singleAlias(baseURL, model string) Config {
	return Config{
		Listen: "127.0.0.1:0",
		Aliases: map[string]Alias{
			"strong": {Candidates: []Candidate{candidate(baseURL, model)}},
		},
	}
}

func doChat(t *testing.T, handler http.Handler, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, chatPath, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

// (a) GET /v1/models lists the alias names in the OpenAI list shape.
func TestModelsListsAliases(t *testing.T) {
	server := newTestServer(t, Config{
		Listen: "127.0.0.1:0",
		Aliases: map[string]Alias{
			"strong": {Candidates: []Candidate{candidate("https://a/v1", "m1")}},
			"free":   {Candidates: []Candidate{candidate("https://b/v1", "m2")}},
			"fast":   {Candidates: []Candidate{candidate("https://c/v1", "m3")}},
		},
	})
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, modelsPath, nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var got struct {
		Object string `json:"object"`
		Data   []struct {
			ID     string `json:"id"`
			Object string `json:"object"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Object != "list" {
		t.Fatalf("object = %q, want list", got.Object)
	}
	ids := make([]string, 0, len(got.Data))
	for _, model := range got.Data {
		ids = append(ids, model.ID)
	}
	want := []string{"fast", "free", "strong"}
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Fatalf("ids = %v, want %v", ids, want)
	}
}

// (b) Non-stream passthrough: the model field is rewritten, everything else and
// the upstream response reach the client.
func TestChatNonStreamRewritesModel(t *testing.T) {
	var gotModel, gotAuth, gotCT, gotPath string
	var gotRaw []byte
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		gotCT = r.Header.Get("Content-Type")
		gotRaw, _ = io.ReadAll(r.Body)
		var payload map[string]json.RawMessage
		_ = json.Unmarshal(gotRaw, &payload)
		_ = json.Unmarshal(payload["model"], &gotModel)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"c1","object":"chat.completion","model":"`+gotModel+`","choices":[{"index":0,"message":{"role":"assistant","content":"pong"}}]}`)
	}))
	defer upstream.Close()

	server := newTestServer(t, singleAlias(upstream.URL, "real-model-1"))
	rec := doChat(t, server.Handler(), `{"model":"strong","messages":[{"role":"user","content":"ping"}]}`)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if gotModel != "real-model-1" {
		t.Fatalf("upstream model = %q, want real-model-1", gotModel)
	}
	if gotPath != chatEndpoint {
		t.Fatalf("upstream path = %q, want %q", gotPath, chatEndpoint)
	}
	if gotAuth != "Bearer "+testAPIKey {
		t.Fatalf("upstream Authorization = %q", gotAuth)
	}
	if gotCT != "application/json" {
		t.Fatalf("upstream Content-Type = %q", gotCT)
	}
	if !strings.Contains(string(gotRaw), `"content":"ping"`) {
		t.Fatalf("messages not forwarded: %s", gotRaw)
	}
	if !strings.Contains(rec.Body.String(), `"content":"pong"`) {
		t.Fatalf("response body not forwarded: %s", rec.Body.String())
	}
}

// (c) Stream passthrough: SSE chunks arrive in the same order and content.
func TestChatStreamPassthrough(t *testing.T) {
	chunks := []string{
		"data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\n",
		"data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\n",
		"data: [DONE]\n\n",
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		for _, chunk := range chunks {
			_, _ = io.WriteString(w, chunk)
			if flusher != nil {
				flusher.Flush()
			}
		}
	}))
	defer upstream.Close()

	server := newTestServer(t, singleAlias(upstream.URL, "real-model-1"))
	gatewaySrv := httptest.NewServer(server.Handler())
	defer gatewaySrv.Close()

	resp, err := http.Post(gatewaySrv.URL+chatPath, "application/json",
		strings.NewReader(`{"model":"strong","stream":true,"messages":[]}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "text/event-stream") {
		t.Fatalf("Content-Type = %q, want text/event-stream", ct)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read stream: %v", err)
	}
	if string(body) != strings.Join(chunks, "") {
		t.Fatalf("stream mismatch\n got: %q\nwant: %q", string(body), strings.Join(chunks, ""))
	}
}

// (d) tools in the request and tool_calls in the response are untouched.
func TestChatToolsUntouched(t *testing.T) {
	requestBody := `{"model":"strong","messages":[{"role":"user","content":"call f"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}],"tool_choice":"auto"}`
	var gotRaw []byte
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotRaw, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"f","arguments":"{}"}}]}}]}`)
	}))
	defer upstream.Close()

	server := newTestServer(t, singleAlias(upstream.URL, "real-model-1"))
	rec := doChat(t, server.Handler(), requestBody)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	for _, needle := range []string{`"tools"`, `"tool_choice":"auto"`, `"name":"f"`, `"parameters"`} {
		if !strings.Contains(string(gotRaw), needle) {
			t.Fatalf("request lost %s: %s", needle, gotRaw)
		}
	}
	if !strings.Contains(rec.Body.String(), `"tool_calls"`) || !strings.Contains(rec.Body.String(), `"call_1"`) {
		t.Fatalf("response tool_calls not forwarded: %s", rec.Body.String())
	}
}

// (e) Fallback: a dead first candidate (connection refused) and a 500 first
// candidate both fall through to the second.
func TestChatFallback(t *testing.T) {
	t.Run("connection refused then second answers", func(t *testing.T) {
		dead := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		deadURL := dead.URL
		dead.Close()

		live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"second"}}]}`)
		}))
		defer live.Close()

		cfg := Config{Listen: "127.0.0.1:0", Aliases: map[string]Alias{
			"strong": {Candidates: []Candidate{
				candidate(deadURL, "dead-model"),
				candidate(live.URL, "live-model"),
			}},
		}}
		server := newTestServer(t, cfg)
		rec := doChat(t, server.Handler(), `{"model":"strong","messages":[]}`)

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), `"second"`) {
			t.Fatalf("expected second candidate response, got %s", rec.Body.String())
		}
	})

	t.Run("http 500 then second answers", func(t *testing.T) {
		first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = io.WriteString(w, `{"error":"upstream boom"}`)
		}))
		defer first.Close()

		live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, `{"choices":[{"message":{"content":"second"}}]}`)
		}))
		defer live.Close()

		cfg := Config{Listen: "127.0.0.1:0", Aliases: map[string]Alias{
			"strong": {Candidates: []Candidate{
				candidate(first.URL, "flaky-model"),
				candidate(live.URL, "live-model"),
			}},
		}}
		server := newTestServer(t, cfg)
		rec := doChat(t, server.Handler(), `{"model":"strong","messages":[]}`)

		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), `"second"`) {
			t.Fatalf("expected second candidate response, got %s", rec.Body.String())
		}
	})
}

// (f) An upstream failure after the stream started is not masked: the gateway
// must not switch to the next candidate.
func TestChatErrorAfterStreamStartNotMasked(t *testing.T) {
	var secondHit atomic.Bool

	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		_, _ = io.WriteString(w, "data: first\n\n")
		if flusher != nil {
			flusher.Flush()
		}
		panic(http.ErrAbortHandler)
	}))
	defer first.Close()

	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secondHit.Store(true)
		_, _ = io.WriteString(w, "SECOND-ANSWER")
	}))
	defer second.Close()

	cfg := Config{Listen: "127.0.0.1:0", Aliases: map[string]Alias{
		"strong": {Candidates: []Candidate{
			candidate(first.URL, "first-model"),
			candidate(second.URL, "second-model"),
		}},
	}}
	server := newTestServer(t, cfg)
	gatewaySrv := httptest.NewServer(server.Handler())
	defer gatewaySrv.Close()

	resp, err := http.Post(gatewaySrv.URL+chatPath, "application/json",
		strings.NewReader(`{"model":"strong","stream":true,"messages":[]}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	if !strings.Contains(string(body), "first") {
		t.Fatalf("expected first candidate bytes, got %q", string(body))
	}
	if strings.Contains(string(body), "SECOND-ANSWER") {
		t.Fatalf("gateway masked a post-stream error with the second candidate: %q", string(body))
	}
	if secondHit.Load() {
		t.Fatal("second candidate was contacted after the stream started")
	}
}

// Missing API key is a configuration error: 500 with the env var name, never the
// key value.
func TestChatMissingKeyReturns500(t *testing.T) {
	cfg := Config{Listen: "127.0.0.1:0", Aliases: map[string]Alias{
		"strong": {Candidates: []Candidate{
			{Provider: "p", BaseURL: "https://example.com/v1", Model: "m", APIKeyEnv: "MISSING_ENV_NAME"},
		}},
	}}
	server := newTestServer(t, cfg)
	server.getenv = func(string) string { return "" }

	rec := doChat(t, server.Handler(), `{"model":"strong","messages":[]}`)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "MISSING_ENV_NAME") {
		t.Fatalf("error should name the env var: %s", rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), testAPIKey) {
		t.Fatalf("error leaked a key: %s", rec.Body.String())
	}
}

// Unknown alias is a client error.
func TestChatUnknownAliasReturns400(t *testing.T) {
	server := newTestServer(t, singleAlias("https://example.com/v1", "m"))
	rec := doChat(t, server.Handler(), `{"model":"nope","messages":[]}`)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "unknown model alias") {
		t.Fatalf("unexpected body: %s", rec.Body.String())
	}
}

// (g) Wrong method on either endpoint is rejected with 405.
func TestMethodsRejectedWith405(t *testing.T) {
	server := newTestServer(t, singleAlias("https://example.com/v1", "m"))
	handler := server.Handler()

	t.Run("GET chat completions", func(t *testing.T) {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, chatPath, nil))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want 405", rec.Code)
		}
	})

	t.Run("POST models", func(t *testing.T) {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, modelsPath, strings.NewReader("{}")))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want 405", rec.Code)
		}
	})
}

// (h) Malformed or empty request bodies are client errors (400).
func TestChatBadBodyReturns400(t *testing.T) {
	server := newTestServer(t, singleAlias("https://example.com/v1", "m"))
	cases := map[string]string{
		"invalid json":  `{"model":"strong",`,
		"empty body":    ``,
		"missing model": `{"messages":[]}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			rec := doChat(t, server.Handler(), body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

// (i) A body above the configured limit is rejected with 413 before parsing.
func TestChatBodyTooLargeReturns413(t *testing.T) {
	server := newTestServer(t, singleAlias("https://example.com/v1", "m"))
	server.maxRequestBody = 64

	oversized := `{"model":"strong","pad":"` + strings.Repeat("x", 256) + `"}`
	rec := doChat(t, server.Handler(), oversized)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413; body=%s", rec.Code, rec.Body.String())
	}
}

// (j) stream:true is really forwarded upstream (body and Accept header), not
// silently downgraded.
func TestChatStreamRequestForwardedUpstream(t *testing.T) {
	var gotBody []byte
	var gotAccept, gotModel string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotBody, _ = io.ReadAll(r.Body)
		gotAccept = r.Header.Get("Accept")
		var payload map[string]json.RawMessage
		_ = json.Unmarshal(gotBody, &payload)
		_ = json.Unmarshal(payload["model"], &gotModel)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
	}))
	defer upstream.Close()

	server := newTestServer(t, singleAlias(upstream.URL, "real-model-1"))
	gatewaySrv := httptest.NewServer(server.Handler())
	defer gatewaySrv.Close()

	resp, err := http.Post(gatewaySrv.URL+chatPath, "application/json",
		strings.NewReader(`{"model":"strong","stream":true,"messages":[]}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if gotAccept != "text/event-stream" {
		t.Fatalf("upstream Accept = %q, want text/event-stream", gotAccept)
	}
	if !strings.Contains(string(gotBody), `"stream":true`) {
		t.Fatalf("stream flag not forwarded upstream: %s", gotBody)
	}
	if gotModel != "real-model-1" {
		t.Fatalf("upstream model = %q, want real-model-1", gotModel)
	}
}

// (k) Stream fallback still works before the first byte: a failing first
// candidate is skipped and the second candidate's SSE stream is used.
func TestChatStreamFallbackBeforeFirstByte(t *testing.T) {
	var firstHit, secondHit atomic.Bool
	chunks := "data: {\"choices\":[{\"delta\":{\"content\":\"second\"}}]}\n\ndata: [DONE]\n\n"

	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		firstHit.Store(true)
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, `{"error":"upstream boom"}`)
	}))
	defer first.Close()

	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secondHit.Store(true)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, chunks)
	}))
	defer second.Close()

	cfg := Config{Listen: "127.0.0.1:0", Aliases: map[string]Alias{
		"strong": {Candidates: []Candidate{
			candidate(first.URL, "flaky-model"),
			candidate(second.URL, "live-model"),
		}},
	}}
	server := newTestServer(t, cfg)
	gatewaySrv := httptest.NewServer(server.Handler())
	defer gatewaySrv.Close()

	resp, err := http.Post(gatewaySrv.URL+chatPath, "application/json",
		strings.NewReader(`{"model":"strong","stream":true,"messages":[]}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", resp.StatusCode, string(body))
	}
	if string(body) != chunks {
		t.Fatalf("stream mismatch\n got: %q\nwant: %q", string(body), chunks)
	}
	if !firstHit.Load() {
		t.Fatal("first candidate was never contacted")
	}
	if !secondHit.Load() {
		t.Fatal("fallback to the second candidate did not happen")
	}
}

// (l) An upstream that sends headers (and one chunk) then stalls is aborted by
// the idle timeout; the gateway must not mask it with another candidate.
func TestChatStreamIdleTimeoutAborts(t *testing.T) {
	first := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		if flusher, ok := w.(http.Flusher); ok {
			_, _ = io.WriteString(w, "data: first\n\n")
			flusher.Flush()
		}
		// Stall: never send another chunk until the client goes away.
		select {
		case <-r.Context().Done():
		case <-time.After(3 * time.Second):
		}
	}))
	defer first.Close()

	var secondHit atomic.Bool
	second := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secondHit.Store(true)
		_, _ = io.WriteString(w, "SECOND-ANSWER")
	}))
	defer second.Close()

	cfg := Config{Listen: "127.0.0.1:0", Aliases: map[string]Alias{
		"strong": {Candidates: []Candidate{
			candidate(first.URL, "slow-model"),
			candidate(second.URL, "live-model"),
		}},
	}}
	server := newTestServer(t, cfg)
	server.streamIdleTimeout = 100 * time.Millisecond

	gatewaySrv := httptest.NewServer(server.Handler())
	defer gatewaySrv.Close()

	started := time.Now()
	resp, err := http.Post(gatewaySrv.URL+chatPath, "application/json",
		strings.NewReader(`{"model":"strong","stream":true,"messages":[]}`))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	elapsed := time.Since(started)

	if !strings.Contains(string(body), "data: first") {
		t.Fatalf("expected the first chunk before the timeout, got %q", string(body))
	}
	if elapsed >= 2*time.Second {
		t.Fatalf("idle timeout did not fire in time, elapsed=%s", elapsed)
	}
	if secondHit.Load() {
		t.Fatal("gateway masked an idle stall with the second candidate")
	}
	if strings.Contains(string(body), "SECOND-ANSWER") {
		t.Fatalf("second candidate body leaked to the client: %q", string(body))
	}
}
