package net

import "testing"

func TestClassifyProviderSignatures(t *testing.T) {
	cases := []struct {
		name     string
		exitCode int
		stdout   string
		stderr   string
		timedOut bool
		want     Status
	}{
		{"rate limit from PS wording", 1, "Free usage exceeded, subscribe to Go", "", false, StatusRateLimit},
		{"rate limit 429", 1, "", "HTTP 429 Too Many Requests", false, StatusRateLimit},
		{"no available channel", 1, "No available channel", "", false, StatusProviderDead},
		{"credit exhausted", 1, "", "insufficient credit", false, StatusProviderDead},
		{"connection refused", 1, "", "dial tcp 127.0.0.1:443: connect: connection refused", false, StatusProviderDead},
		{"session expired", 0, "your session has expired", "", false, StatusSessionInvalid},
		{"session invalid 401", 1, "", "401 unauthorized", false, StatusSessionInvalid},
		{"proxy error", 1, "", "proxyconnect tcp: dial tcp 127.0.0.1:3128: connection refused", false, StatusProxyDown},
		{"timeout wins over text", 1, "rate limit", "", true, StatusTimeout},
		{"generic failure is unknown", 1, "fake executor failure", "Error: fake failure", false, StatusUnknown},
		{"success-looking text is unknown to the fault classifier", 0, "all good", "", false, StatusUnknown},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, reason := Classify(tc.exitCode, tc.stdout, tc.stderr, tc.timedOut)
			if got != tc.want {
				t.Fatalf("Classify = %s (%s), want %s", got, reason, tc.want)
			}
			if tc.want != StatusUnknown && reason == "" {
				t.Errorf("Classify returned no reason for %s", got)
			}
		})
	}
}

func TestStatusPredicates(t *testing.T) {
	if !StatusRateLimit.ProviderFault() || !StatusTimeout.ProviderFault() ||
		!StatusProviderDead.ProviderFault() || !StatusProxyDown.ProviderFault() {
		t.Error("provider faults must report ProviderFault")
	}
	if StatusSessionInvalid.ProviderFault() {
		t.Error("a session fault is not a provider transport fault")
	}
	if !StatusSessionInvalid.SessionFault() || !StatusSessionInvalid.Unhealthy() {
		t.Error("session invalid must be a session fault and unhealthy")
	}
	if StatusOK.Unhealthy() || StatusUnknown.Unhealthy() {
		t.Error("OK and UNKNOWN must not be unhealthy (no retry for unknown failures)")
	}
}

func TestParseHealthStatus(t *testing.T) {
	cases := map[string]Status{
		"OK":         StatusOK,
		" ok ":       StatusOK,
		"RATE_LIMIT": StatusRateLimit,
		"DEAD":       StatusProviderDead,
		"TIMEOUT":    StatusTimeout,
		"":           StatusUnknown,
		"something":  StatusUnknown,
	}
	for input, want := range cases {
		if got := ParseHealthStatus(input); got != want {
			t.Errorf("ParseHealthStatus(%q) = %s, want %s", input, got, want)
		}
	}
}
