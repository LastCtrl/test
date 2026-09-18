package main

import (
	"bytes"
	"context"
	"encoding/json"
	stdnet "net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agent-hq/internal/net"
)

// withProber swaps the package prober for one test and restores it afterwards,
// so no test leaves a fake dialer active for another.
func withProber(t *testing.T, dialer net.DialFunc) {
	t.Helper()
	previous := netProber
	netProber = net.Prober{Timeout: time.Second, Dial: dialer}
	t.Cleanup(func() { netProber = previous })
}

func dialOK(t *testing.T) net.DialFunc {
	t.Helper()
	return func(context.Context, string, string) (stdnet.Conn, error) {
		client, server := stdnet.Pipe()
		t.Cleanup(func() { _ = server.Close() })
		return client, nil
	}
}

func dialRefused() net.DialFunc {
	return func(context.Context, string, string) (stdnet.Conn, error) {
		return nil, &stdnet.OpError{Op: "dial", Net: "tcp", Err: errDial{}}
	}
}

type errDial struct{}

func (errDial) Error() string { return "connection refused" }

func writeHealthForRoot(t *testing.T, root, content string) {
	t.Helper()
	path := net.ModelHealthPath(root)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write health: %v", err)
	}
}

func TestNetCheckReportsHealthyProxyAndHealth(t *testing.T) {
	root := newCmdRoot(t)
	writeHealthForRoot(t, root, `{"opencode/mimo-v2.5-free": {"model": "opencode/mimo-v2.5-free",
		"status": "OK", "fail_count": 0, "open_until": ""}}`)
	withProber(t, dialOK(t))

	var stdout, stderr bytes.Buffer
	code := runNetCheck(globalOptions{root: root, json: true}, nil, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("net-check exit = %d, want 0; stderr = %s", code, stderr.String())
	}

	var output netCheckOutput
	if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
		t.Fatalf("decode net-check output: %v (%s)", err, stdout.String())
	}
	if !output.OK || output.Proxy.Status != net.StatusOK {
		t.Errorf("output = %+v, want a healthy proxy", output)
	}
	if !output.Health.Available || len(output.Health.Models) != 1 || output.Health.Open != 0 {
		t.Errorf("health = %+v, want one available closed record", output.Health)
	}
	if len(output.Recommendations) == 0 {
		t.Error("net-check must always explain itself")
	}
}

func TestNetCheckReportsDownProxyAndFallback(t *testing.T) {
	root := newCmdRoot(t)
	writeHealthForRoot(t, root, `{"opencode/mimo-v2.5-free": {"model": "opencode/mimo-v2.5-free",
		"status": "TIMEOUT", "fail_count": 2, "open_until": "2099-01-01T00:00:00"}}`)
	withProber(t, dialRefused())

	var stdout, stderr bytes.Buffer
	code := runNetCheck(globalOptions{root: root, json: true},
		[]string{"-model", "opencode/mimo-v2.5-free"}, &stdout, &stderr)
	if code != 1 {
		t.Fatalf("net-check exit = %d, want 1 for a down proxy; stderr = %s", code, stderr.String())
	}

	var output netCheckOutput
	if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
		t.Fatalf("decode: %v (%s)", err, stdout.String())
	}
	if output.OK || output.Proxy.Status != net.StatusProxyDown {
		t.Errorf("output = %+v, want PROXY_DOWN", output)
	}
	if output.Health.Open != 1 {
		t.Errorf("open = %d, want the parked model counted", output.Health.Open)
	}
	if output.Fallback == nil || output.Fallback.Model == "" {
		t.Fatalf("fallback = %+v, want a candidate that is not the parked current model", output.Fallback)
	}
	if output.Fallback.Model == "opencode/mimo-v2.5-free" {
		t.Error("the fallback must not be the current (parked) model")
	}
	if !strings.Contains(strings.Join(output.Recommendations, " "), "DOWN") {
		t.Errorf("recommendations = %v, want the proxy failure named", output.Recommendations)
	}
}

func TestNetCheckMissingHealthIsWarnNotFail(t *testing.T) {
	root := newCmdRoot(t)
	withProber(t, dialOK(t))

	var stdout, stderr bytes.Buffer
	if code := runNetCheck(globalOptions{root: root, json: true}, nil, &stdout, &stderr); code != 0 {
		t.Fatalf("net-check exit = %d, want 0 when only the health state is missing", code)
	}
	var output netCheckOutput
	if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if output.Health.Available || output.Health.Error == "" {
		t.Errorf("health = %+v, want an unavailable state with an explanation", output.Health)
	}
}

func TestNetCheckRejectsUnknownArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := runNetCheck(globalOptions{}, []string{"surprise"}, &stdout, &stderr); code != 2 {
		t.Fatalf("net-check exit = %d, want 2 for an unknown argument", code)
	}
}

func TestExtractNetCheckOptions(t *testing.T) {
	options, rest := extractNetCheckOptions([]string{"-proxy", "10.0.0.1:8080", "-timeout=3", "-model", "m1"})
	if options.proxy != "10.0.0.1:8080" || options.timeout != 3 || options.model != "m1" {
		t.Errorf("options = %+v, want the parsed proxy/timeout/model", options)
	}
	if len(rest) != 0 {
		t.Errorf("rest = %v, want none", rest)
	}
	if _, rest := extractNetCheckOptions([]string{"-timeout", "abc"}); len(rest) != 0 {
		t.Errorf("rest = %v, want a rejected timeout to be ignored, not passed through", rest)
	}
}

func TestDoctorNetChecksAreWarnOnly(t *testing.T) {
	root := newCmdRoot(t)
	withProber(t, dialRefused())

	checks := netChecks(root)
	byName := make(map[string]string, len(checks))
	for _, check := range checks {
		byName[check.Name] = check.Status
	}
	if byName["net-proxy"] != "warn" {
		t.Errorf("net-proxy status = %q, want warn for a down proxy", byName["net-proxy"])
	}
	if byName["model-health"] != "warn" {
		t.Errorf("model-health status = %q, want warn for a missing state", byName["model-health"])
	}

	var stdout, stderr bytes.Buffer
	if code := runDoctor(globalOptions{root: root, json: true}, nil, &stdout, &stderr); code != 0 {
		t.Fatalf("doctor exit = %d, want 0 (net findings must never fail the doctor)", code)
	}
}

func TestProxyAddressParsing(t *testing.T) {
	cases := map[string]string{
		"http://127.0.0.1:3128":      "127.0.0.1:3128",
		"http://127.0.0.1:3128/":     "127.0.0.1:3128",
		"https://proxy.local:8443/x": "proxy.local:8443",
		"127.0.0.1:3128":             "127.0.0.1:3128",
		"":                           net.DefaultProxyAddress,
	}
	for input, want := range cases {
		if got := proxyAddress(input); got != want {
			t.Errorf("proxyAddress(%q) = %q, want %q", input, got, want)
		}
	}
}
