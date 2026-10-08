package gateway

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func candidate(baseURL, model string) Candidate {
	return Candidate{Provider: "test", BaseURL: baseURL, Model: model, APIKeyEnv: "TEST_KEY"}
}

func TestNormalizeAcceptsLoopback(t *testing.T) {
	cfg := Config{
		Listen: "127.0.0.1:8899",
		Aliases: map[string]Alias{
			"strong": {Candidates: []Candidate{candidate("https://example.com/v1/", "m1")}},
		},
	}
	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if got := cfg.Aliases["strong"].Candidates[0].BaseURL; got != "https://example.com/v1" {
		t.Fatalf("baseURL not trimmed: %q", got)
	}
}

func TestNormalizeRejectsNonLoopback(t *testing.T) {
	for _, listen := range []string{"0.0.0.0:8899", "localhost:8899", ":8899", "192.168.1.5:8899"} {
		cfg := Config{
			Listen: listen,
			Aliases: map[string]Alias{
				"strong": {Candidates: []Candidate{candidate("https://example.com/v1", "m1")}},
			},
		}
		if err := cfg.normalize(); err == nil {
			t.Fatalf("normalize(%q): expected error", listen)
		}
	}
}

func TestNormalizeRejectsEmptyAliases(t *testing.T) {
	cfg := Config{Listen: "127.0.0.1:8899", Aliases: nil}
	if err := cfg.normalize(); err == nil {
		t.Fatal("expected error for empty aliases")
	}
}

func TestNormalizeRejectsCandidateProblems(t *testing.T) {
	cases := map[string]Candidate{
		"no model":   {Provider: "p", BaseURL: "https://example.com", APIKeyEnv: "K"},
		"no env":     {Provider: "p", BaseURL: "https://example.com", Model: "m"},
		"no baseURL": {Provider: "p", Model: "m", APIKeyEnv: "K"},
		"bad scheme": {Provider: "p", BaseURL: "ftp://example.com", Model: "m", APIKeyEnv: "K"},
	}
	for name, cand := range cases {
		cfg := Config{Listen: "127.0.0.1:8899", Aliases: map[string]Alias{"a": {Candidates: []Candidate{cand}}}}
		if err := cfg.normalize(); err == nil {
			t.Fatalf("%s: expected error", name)
		}
	}
}

func TestAliasNamesSorted(t *testing.T) {
	cfg := Config{Aliases: map[string]Alias{"strong": {}, "fast": {}, "free": {}}}
	want := []string{"fast", "free", "strong"}
	if got := cfg.AliasNames(); !reflect.DeepEqual(got, want) {
		t.Fatalf("AliasNames = %v, want %v", got, want)
	}
}

func TestNormalizeAppliesStreamIdleTimeoutDefault(t *testing.T) {
	cfg := Config{
		Listen:  "127.0.0.1:8899",
		Aliases: map[string]Alias{"a": {Candidates: []Candidate{candidate("https://example.com/v1", "m")}}},
	}
	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if cfg.StreamIdleTimeoutSec != defaultStreamIdleTimeoutSec {
		t.Fatalf("StreamIdleTimeoutSec = %d, want %d", cfg.StreamIdleTimeoutSec, defaultStreamIdleTimeoutSec)
	}
	server, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if got, want := server.streamIdleTimeout, time.Duration(defaultStreamIdleTimeoutSec)*time.Second; got != want {
		t.Fatalf("server.streamIdleTimeout = %s, want %s", got, want)
	}
}

func TestNormalizeKeepsExplicitStreamIdleTimeout(t *testing.T) {
	cfg := Config{
		Listen:               "127.0.0.1:8899",
		Aliases:              map[string]Alias{"a": {Candidates: []Candidate{candidate("https://example.com/v1", "m")}}},
		StreamIdleTimeoutSec: 45,
	}
	if err := cfg.normalize(); err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if cfg.StreamIdleTimeoutSec != 45 {
		t.Fatalf("StreamIdleTimeoutSec = %d, want 45", cfg.StreamIdleTimeoutSec)
	}
}

func TestNormalizeRejectsNegativeStreamIdleTimeout(t *testing.T) {
	cfg := Config{
		Listen:               "127.0.0.1:8899",
		Aliases:              map[string]Alias{"a": {Candidates: []Candidate{candidate("https://example.com/v1", "m")}}},
		StreamIdleTimeoutSec: -1,
	}
	if err := cfg.normalize(); err == nil {
		t.Fatal("expected error for negative streamIdleTimeoutSec")
	}
}

func TestLoadConfigFromFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gateway.json")
	content := `{
	  "listen": "127.0.0.1:8899",
	  "aliases": {
	    "strong": {"candidates": [{"provider":"p","baseURL":"https://x/v1","model":"m","apiKeyEnv":"K"}]}
	  }
	}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if len(cfg.Aliases) != 1 || cfg.Listen != "127.0.0.1:8899" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestLoadConfigStreamIdleTimeout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gateway.json")
	content := `{"listen":"127.0.0.1:8899","streamIdleTimeoutSec":30,"aliases":{"strong":{"candidates":[{"provider":"p","baseURL":"https://x/v1","model":"m","apiKeyEnv":"K"}]}}}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.StreamIdleTimeoutSec != 30 {
		t.Fatalf("StreamIdleTimeoutSec = %d, want 30", cfg.StreamIdleTimeoutSec)
	}
}

func TestLoadConfigRejectsUnknownField(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gateway.json")
	content := `{"listen":"127.0.0.1:8899","aliases":{},"bogus":true}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadConfig(path); err == nil {
		t.Fatal("expected error for unknown field")
	} else if !strings.Contains(err.Error(), "config") {
		t.Fatalf("error should name config: %v", err)
	}
}

func TestLoadConfigMissingFile(t *testing.T) {
	if _, err := LoadConfig(filepath.Join(t.TempDir(), "absent.json")); err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestNormalizeRejectsEmptyHeaderName(t *testing.T) {
	cand := candidate("https://example.com/v1", "m")
	cand.Headers = map[string]string{"": "v"}
	cfg := Config{Listen: "127.0.0.1:8899", Aliases: map[string]Alias{"a": {Candidates: []Candidate{cand}}}}
	if err := cfg.normalize(); err == nil {
		t.Fatal("expected error for empty header name")
	}
}

func TestLoadConfigAcceptsHeaders(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gateway.json")
	content := `{"listen":"127.0.0.1:8899","aliases":{"strong":{"candidates":[{"provider":"p","baseURL":"https://x/v1","model":"m","apiKeyEnv":"K","headers":{"x-opencode-session":"sess-1"}}]}}}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	got := cfg.Aliases["strong"].Candidates[0].Headers
	if got["x-opencode-session"] != "sess-1" {
		t.Fatalf("headers not loaded: %v", got)
	}
}
