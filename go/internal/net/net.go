// Package net is the G3-M3 network self-healing layer of the agent-hq control
// plane: it probes the CNTLM proxy, reads the model-router health state,
// classifies provider/session failures and suggests a fallback model, so the Go
// control plane can repair a network or provider outage without a human.
//
// The package never calls a provider CLI and never touches another owner's
// files: the only reads are .memory/model-health.json and
// .agents/config/capability-passport.json (both read-only) and the only sockets
// are a short TCP connect to the proxy plus an optional provider endpoint.
package net

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

// ProxyModeEnv selects the proxy strategy for the process. "off" means the
// fleet works directly (the default in .agents/config/proxy.json), so a missing
// cntlm listener must not be treated as a fault.
const ProxyModeEnv = "AGENT_HQ_PROXY_MODE"

// ProxyModeFromEnv returns the lower-cased AGENT_HQ_PROXY_MODE value ("" when unset).
func ProxyModeFromEnv() string { return strings.ToLower(strings.TrimSpace(os.Getenv(ProxyModeEnv))) }

// DirectMode reports whether the proxy is switched off for this process.
func DirectMode() bool { return ProxyModeFromEnv() == "off" }

// Status classifies one observed network/provider outcome. It is the shared
// vocabulary of `agent-hq net-check`, the doctor net section and the run
// self-healing loop.
type Status string

const (
	// StatusOK means the proxy or provider answered as expected.
	StatusOK Status = "OK"
	// StatusProxyDown means the CNTLM proxy did not accept a TCP connection.
	StatusProxyDown Status = "PROXY_DOWN"
	// StatusRateLimit means the provider refused the request for quota reasons.
	StatusRateLimit Status = "PROVIDER_RATE_LIMIT"
	// StatusProviderDead means the provider is unreachable or has no channel.
	StatusProviderDead Status = "PROVIDER_DEAD"
	// StatusSessionInvalid means the provider session/credentials are invalid.
	StatusSessionInvalid Status = "SESSION_INVALID"
	// StatusTimeout means the attempt exceeded its time budget.
	StatusTimeout Status = "TIMEOUT"
	// StatusUnknown means the failure matched no known signature, so it is not a
	// provider-class failure and must not trigger self-healing.
	StatusUnknown Status = "UNKNOWN"
)

// ProviderFault reports whether the status is a provider/proxy fault that the
// self-healing loop may repair (retry through the proxy, then fall back).
func (s Status) ProviderFault() bool {
	switch s {
	case StatusProxyDown, StatusRateLimit, StatusProviderDead, StatusTimeout:
		return true
	default:
		return false
	}
}

// SessionFault reports whether the status is a broken provider session.
func (s Status) SessionFault() bool { return s == StatusSessionInvalid }

// Unhealthy reports whether the status is anything other than OK/UNKNOWN.
func (s Status) Unhealthy() bool { return s.ProviderFault() || s.SessionFault() }

// Failure signatures. They mirror .agents/scripts/model-router.ps1
// (Get-ProbeStatus) and add the session and proxy cases the Go control plane
// must distinguish; the patterns are deliberately conservative, because a
// false positive would retry a run that simply failed on its own merits.
var (
	rateLimitPattern = regexp.MustCompile(`(?i)free usage exceeded|rate limit|rate_limit|too many requests|quota exceeded|\b429\b`)
	proxyPattern     = regexp.MustCompile(`(?i)proxyconnect|proxy connect|cntlm|127\.0\.0\.1:3128|proxy error|\b407\b`)
	sessionPattern   = regexp.MustCompile(`(?i)session\s+(?:is\s+|has\s+|was\s+)?(?:invalid|expired|not found|revoked)|invalid session|no such session|unauthorized|\b401\b|authentication failed`)
	deadPattern      = regexp.MustCompile(`(?i)no available channel|credit insufficient|insufficient credit|unknownerror|connection refused|could not connect|dial tcp|no such host|network is unreachable`)
)

// Classify turns one finished attempt or probe into a Status plus a
// human-readable reason. timedOut wins over every textual signature. An output
// that matches nothing is statusUnknown with the exit code as the reason: the
// caller can still treat the attempt as failed, but it is not a provider fault.
func Classify(exitCode int, stdout, stderr string, timedOut bool) (Status, string) {
	if timedOut {
		return StatusTimeout, "attempt timed out"
	}
	text := stdout + "\n" + stderr
	switch {
	case rateLimitPattern.MatchString(text):
		return StatusRateLimit, "provider rate limit: " + firstMatch(rateLimitPattern, text)
	case proxyPattern.MatchString(text):
		return StatusProxyDown, "proxy error: " + firstMatch(proxyPattern, text)
	case sessionPattern.MatchString(text):
		return StatusSessionInvalid, "session rejected: " + firstMatch(sessionPattern, text)
	case deadPattern.MatchString(text):
		return StatusProviderDead, "provider unreachable: " + firstMatch(deadPattern, text)
	}
	return StatusUnknown, fmt.Sprintf("no provider signature in output (exit %d)", exitCode)
}

// firstMatch returns the literal match so the reason explains itself without
// echoing whole provider responses (which may carry account data).
func firstMatch(pattern *regexp.Regexp, text string) string {
	return pattern.FindString(text)
}

// ParseHealthStatus maps the status strings written by model-router.ps1
// (OK / RATE_LIMIT / DEAD / TIMEOUT) onto this package's vocabulary. Anything
// else, including an empty string, is statusUnknown.
func ParseHealthStatus(value string) Status {
	switch strings.ToUpper(strings.TrimSpace(value)) {
	case "OK":
		return StatusOK
	case "RATE_LIMIT":
		return StatusRateLimit
	case "DEAD":
		return StatusProviderDead
	case "TIMEOUT":
		return StatusTimeout
	default:
		return StatusUnknown
	}
}
