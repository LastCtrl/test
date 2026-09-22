package executor

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// FakeMode selects what FakeExecutor simulates.
type FakeMode string

const (
	FakeSuccess FakeMode = "success"
	FakeFail    FakeMode = "fail"
	FakeTimeout FakeMode = "timeout"
	FakeEmpty   FakeMode = "empty"
)

// FakeExecutor is a deterministic Executor for tests and for exercising the
// write path without calling the real CLI.
type FakeExecutor struct {
	Mode    FakeMode
	Delay   time.Duration
	Timeout time.Duration
	Stdout  string
	Stderr  string
}

// NewFakeExecutor builds a fake with the shared success/error markers.
func NewFakeExecutor(mode FakeMode) *FakeExecutor {
	return &FakeExecutor{Mode: mode}
}

// NewFakeExecutorFromEnv reads AGENT_HQ_FAKE_MODE (default success) and the
// optional AGENT_HQ_FAKE_DELAY_MS / AGENT_HQ_FAKE_TIMEOUT_MS values.
func NewFakeExecutorFromEnv() *FakeExecutor {
	fake := &FakeExecutor{Mode: FakeSuccess}
	if raw := strings.TrimSpace(os.Getenv("AGENT_HQ_FAKE_MODE")); raw != "" {
		fake.Mode = FakeMode(strings.ToLower(raw))
	}
	if ms, ok := envMillis("AGENT_HQ_FAKE_DELAY_MS"); ok {
		fake.Delay = ms
	}
	if ms, ok := envMillis("AGENT_HQ_FAKE_TIMEOUT_MS"); ok {
		fake.Timeout = ms
	}
	return fake
}

// Version implements Executor.
func (f *FakeExecutor) Version() int { return InterfaceVersion }

// Name implements Executor.
func (f *FakeExecutor) Name() string { return "fake" }

// Execute implements Executor.
func (f *FakeExecutor) Execute(ctx context.Context, spec TaskSpec) (Result, error) {
	started := time.Now()
	if f.Mode == FakeTimeout {
		return f.executeTimeout(ctx, started)
	}
	if f.Delay > 0 {
		select {
		case <-ctx.Done():
			return Result{Status: StatusTimeout, ExitCode: 124, Duration: time.Since(started),
				Error: "fake timeout"}, nil
		case <-time.After(f.Delay):
		}
	}

	var stdout, stderr string
	exitCode := 0
	switch f.Mode {
	case FakeSuccess:
		stdout = "fake executor ok\nSTATUS: resolved"
	case FakeFail:
		stdout = "fake executor failure"
		stderr = "Error: fake failure"
		exitCode = 1
	case FakeEmpty:
		stdout = ""
	default:
		return Result{}, fmt.Errorf("fake executor: unknown mode %q", f.Mode)
	}
	if f.Stdout != "" {
		stdout = f.Stdout
	}
	if f.Stderr != "" {
		stderr = f.Stderr
	}

	status, reason := Classify(exitCode, stdout, stderr)
	return Result{Status: status, ExitCode: exitCode, Stdout: stdout, Stderr: stderr,
		Duration: time.Since(started), Error: reason}, nil
}

// executeTimeout blocks until the context is cancelled (or a bounded fallback
// when the caller supplied no deadline) and reports a timeout.
func (f *FakeExecutor) executeTimeout(ctx context.Context, started time.Time) (Result, error) {
	fallback := f.Timeout
	if fallback <= 0 {
		fallback = 10 * time.Second
	}
	select {
	case <-ctx.Done():
	case <-time.After(fallback):
	}
	return Result{Status: StatusTimeout, ExitCode: 124, Duration: time.Since(started),
		Error: "fake timeout"}, nil
}

func envMillis(name string) (time.Duration, bool) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return 0, false
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return 0, false
	}
	return time.Duration(value) * time.Millisecond, true
}
