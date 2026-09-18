package net

import (
	"context"
	stdnet "net"
	"testing"
	"time"
)

func TestProbeProxyReportsReachableListener(t *testing.T) {
	client, server := stdnet.Pipe()
	defer func() { _ = server.Close() }()

	prober := Prober{
		Timeout: time.Second,
		Dial: func(context.Context, string, string) (stdnet.Conn, error) {
			return client, nil
		},
	}
	result := prober.ProbeProxy(context.Background(), "127.0.0.1:3128")
	if result.Status != StatusOK {
		t.Fatalf("status = %s (%s), want OK", result.Status, result.Error)
	}
	if result.Address != "127.0.0.1:3128" {
		t.Errorf("address = %q, want the probed address", result.Address)
	}
}

func TestProbeProxyReportsRefusedConnection(t *testing.T) {
	prober := Prober{
		Timeout: time.Second,
		Dial: func(context.Context, string, string) (stdnet.Conn, error) {
			return nil, &stdnet.OpError{Op: "dial", Net: "tcp", Err: errRefused{}}
		},
	}
	result := prober.ProbeProxy(context.Background(), "")
	if result.Status != StatusProxyDown {
		t.Fatalf("status = %s, want PROXY_DOWN", result.Status)
	}
	if result.Address != DefaultProxyAddress {
		t.Errorf("address = %q, want the default %s", result.Address, DefaultProxyAddress)
	}
	if result.Error == "" {
		t.Error("a down proxy must carry the dial error")
	}
}

func TestProbeProxyReportsTimeout(t *testing.T) {
	prober := Prober{
		Timeout: 20 * time.Millisecond,
		Dial: func(ctx context.Context, _, _ string) (stdnet.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		},
	}
	result := prober.ProbeProxy(context.Background(), DefaultProxyAddress)
	if result.Status != StatusTimeout {
		t.Fatalf("status = %s, want TIMEOUT", result.Status)
	}
}

func TestProbeProxyUsesDefaultTimeoutWhenUnset(t *testing.T) {
	dialed := false
	prober := Prober{Dial: func(ctx context.Context, _, _ string) (stdnet.Conn, error) {
		dialed = true
		if _, ok := ctx.Deadline(); !ok {
			t.Error("the probe context must carry a deadline")
		}
		return nil, errRefused{}
	}}
	if result := prober.ProbeProxy(context.Background(), DefaultProxyAddress); result.Status != StatusProxyDown {
		t.Fatalf("status = %s, want PROXY_DOWN", result.Status)
	}
	if !dialed {
		t.Error("the injected dialer was not used")
	}
}

type errRefused struct{}

func (errRefused) Error() string { return "connection refused" }
