package net

import (
	"context"
	stdnet "net"
	"time"
)

// DefaultProxyAddress is the CNTLM listener from AGENTS.md section 10.
const DefaultProxyAddress = "127.0.0.1:3128"

// DialTimeout is the bounded probe budget: a self-heal must not stall on a
// black-holed proxy.
const DialTimeout = 2 * time.Second

// DialFunc matches net.Dialer.DialContext, so tests can inject a deterministic
// connection or a fixed error without opening a socket.
type DialFunc func(ctx context.Context, network, address string) (stdnet.Conn, error)

// Prober performs bounded probes. The zero value is usable and dials for real.
type Prober struct {
	Dial    DialFunc
	Timeout time.Duration
}

// DefaultProber returns the production prober (real TCP, DialTimeout budget).
func DefaultProber() Prober { return Prober{Timeout: DialTimeout} }

// ProxyResult is the outcome of one proxy probe.
type ProxyResult struct {
	Address   string `json:"address"`
	Status    Status `json:"status"`
	LatencyMS int64  `json:"latency_ms"`
	Error     string `json:"error,omitempty"`
}

// ProbeProxy connects to address and immediately closes the connection. A TCP
// accept is the cheapest honest signal that the proxy is listening; the probe
// deliberately does not send a request, so it cannot leak a target or a token.
func (p Prober) ProbeProxy(ctx context.Context, address string) ProxyResult {
	if address == "" {
		address = DefaultProxyAddress
	}
	timeout := p.Timeout
	if timeout <= 0 {
		timeout = DialTimeout
	}
	dial := p.Dial
	if dial == nil {
		dial = (&stdnet.Dialer{Timeout: timeout}).DialContext
	}

	probeCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	started := time.Now()
	conn, err := dial(probeCtx, "tcp", address)
	latency := time.Since(started)
	result := ProxyResult{Address: address, LatencyMS: latency.Milliseconds()}
	switch {
	case err != nil:
		result.LatencyMS = 0
		result.Error = err.Error()
		if probeCtx.Err() == context.DeadlineExceeded {
			result.Status = StatusTimeout
		} else {
			result.Status = StatusProxyDown
		}
	default:
		_ = conn.Close()
		result.Status = StatusOK
	}
	return result
}
