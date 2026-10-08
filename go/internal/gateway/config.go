// Package gateway implements a local OpenAI-compatible gateway: an
// OpenAI-compatible HTTP proxy for opencode that rewrites only the "model"
// field of /v1/chat/completions requests according to aliases.
//
// Responses are forwarded byte-for-byte (status, headers, streaming SSE frames
// and tool calls are passed through unchanged). Requests are NOT forwarded
// verbatim: the JSON body is re-encoded and only the "model" field is
// substituted (all other fields survive as raw JSON), only the required headers
// are sent upstream, and the client query string is not forwarded.
package gateway

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"sort"
	"strings"
)

// loopbackHost is the only host the gateway is allowed to bind to. Binding to
// 0.0.0.0 (or a routable address) would expose an unauthenticated proxy.
const loopbackHost = "127.0.0.1"

// defaultStreamIdleTimeoutSec is the default upstream inter-chunk timeout. It
// protects against an upstream that sends response headers and then stalls
// without ever closing the stream. A non-positive configured value is rejected;
// 0 means "use the default".
const defaultStreamIdleTimeoutSec = 120

// Candidate is one upstream provider endpoint behind an alias.
type Candidate struct {
	Provider  string `json:"provider"`
	BaseURL   string `json:"baseURL"`
	Model     string `json:"model"`
	APIKeyEnv string `json:"apiKeyEnv"`
	// Headers are extra request headers sent to this upstream (for example
	// x-opencode-session required by the opencode-go endpoint). They never
	// override the gateway's own Content-Type/Accept/Authorization headers.
	Headers map[string]string `json:"headers"`
}

// Alias maps an opencode model id to an ordered list of upstream candidates.
// Candidates are tried in order; the first one that answers before the stream
// starts wins.
type Alias struct {
	Candidates []Candidate `json:"candidates"`
}

// Config is the on-disk gateway configuration.
type Config struct {
	Listen  string           `json:"listen"`
	Aliases map[string]Alias `json:"aliases"`
	// StreamIdleTimeoutSec bounds the gap between two upstream stream chunks.
	// Zero selects defaultStreamIdleTimeoutSec.
	StreamIdleTimeoutSec int `json:"streamIdleTimeoutSec"`
}

// LoadConfig reads and validates the configuration. It fails fast with a
// message that names the offending field; secret values are never included.
func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config %s: %w", path, err)
	}
	var cfg Config
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("parse config %s: %w", path, err)
	}
	if err := cfg.normalize(); err != nil {
		return Config{}, fmt.Errorf("config %s: %w", path, err)
	}
	return cfg, nil
}

// AliasNames returns the alias names in lexical order so listings are stable.
func (c Config) AliasNames() []string {
	names := make([]string, 0, len(c.Aliases))
	for name := range c.Aliases {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// normalize validates the config and applies defaults in place.
func (c *Config) normalize() error {
	if strings.TrimSpace(c.Listen) == "" {
		return errors.New("listen is empty")
	}
	host, _, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return fmt.Errorf("listen %q: %v", c.Listen, err)
	}
	if host != loopbackHost {
		return fmt.Errorf("listen %q: only %s is allowed", c.Listen, loopbackHost)
	}
	if len(c.Aliases) == 0 {
		return errors.New("aliases is empty")
	}
	if c.StreamIdleTimeoutSec < 0 {
		return errors.New("streamIdleTimeoutSec must not be negative")
	}
	if c.StreamIdleTimeoutSec == 0 {
		c.StreamIdleTimeoutSec = defaultStreamIdleTimeoutSec
	}
	for name, alias := range c.Aliases {
		if strings.TrimSpace(name) == "" {
			return errors.New("alias name is empty")
		}
		if len(alias.Candidates) == 0 {
			return fmt.Errorf("alias %q has no candidates", name)
		}
		for i := range alias.Candidates {
			if err := alias.Candidates[i].normalize(); err != nil {
				return fmt.Errorf("alias %q candidate %d: %w", name, i, err)
			}
		}
		c.Aliases[name] = alias
	}
	return nil
}

// normalize validates one candidate and trims its base URL.
func (c *Candidate) normalize() error {
	if strings.TrimSpace(c.Model) == "" {
		return errors.New("model is empty")
	}
	if strings.TrimSpace(c.APIKeyEnv) == "" {
		return errors.New("apiKeyEnv is empty")
	}
	for name := range c.Headers {
		if strings.TrimSpace(name) == "" {
			return errors.New("header name is empty")
		}
	}
	if c.Provider == "" {
		c.Provider = "unknown"
	}
	raw := strings.TrimRight(strings.TrimSpace(c.BaseURL), "/")
	if raw == "" {
		return errors.New("baseURL is empty")
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("baseURL %q: %v", raw, err)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return fmt.Errorf("baseURL %q: scheme must be http or https", raw)
	}
	if parsed.Host == "" {
		return fmt.Errorf("baseURL %q: host is empty", raw)
	}
	c.BaseURL = raw
	return nil
}
