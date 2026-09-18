package main

import (
	"context"
	stdnet "net"
	"testing"
	"time"

	"agent-hq/internal/executor"
	"agent-hq/internal/net"
	"agent-hq/internal/store"
)

// scriptedExecutor returns a fixed result per attempt and records every spec it
// was given, so a test can assert both what the healing loop did and which
// environment (proxy/model) each attempt carried.
type scriptedExecutor struct {
	results []executor.Result
	specs   []executor.TaskSpec
}

func (s *scriptedExecutor) Version() int { return executor.InterfaceVersion }
func (s *scriptedExecutor) Name() string { return "scripted" }

func (s *scriptedExecutor) Execute(_ context.Context, spec executor.TaskSpec) (executor.Result, error) {
	s.specs = append(s.specs, spec)
	if len(s.specs) <= len(s.results) {
		return s.results[len(s.specs)-1], nil
	}
	return executor.Result{Status: executor.StatusError, ExitCode: -1, Error: "scripted results exhausted"}, nil
}

func failedResult(stdout, stderr string) executor.Result {
	return executor.Result{Status: executor.StatusFailed, ExitCode: 1, Stdout: stdout, Stderr: stderr,
		Duration: time.Millisecond}
}

func successResult() executor.Result {
	return executor.Result{Status: executor.StatusSuccess, ExitCode: 0,
		Stdout: "done\nSTATUS: resolved", Duration: time.Millisecond}
}

// healFor builds production-shaped heal options whose health/passport files do
// not exist yet (so the packaged ladder decides) and whose proxy probe is
// scripted by the caller.
func healFor(root string, dial net.DialFunc) healOptions {
	options := defaultHealOptions(root)
	options.now = time.Now
	options.prober = net.Prober{Timeout: time.Second, Dial: dial}
	return options
}

func alwaysReachable(t *testing.T) net.DialFunc {
	t.Helper()
	return func(context.Context, string, string) (stdnet.Conn, error) {
		client, server := stdnet.Pipe()
		t.Cleanup(func() { _ = server.Close() })
		return client, nil
	}
}

func TestHealRetriesThroughProxyOnRateLimit(t *testing.T) {
	root := newCmdRoot(t)
	handle := openCmdStore(t, root)
	worker := &scriptedExecutor{results: []executor.Result{
		failedResult("", "Free usage exceeded, subscribe to Go"),
		successResult(),
	}}
	heal := healFor(root, alwaysReachable(t))
	heal.proxyURL = "http://127.0.0.1:3128"

	outcome := executeRunWithHealing(context.Background(), handle, worker,
		executor.TaskSpec{ID: "heal-1", Agent: "dev-2", Payload: "work"}, "owner-1", 60, heal)

	if outcome.Status != string(executor.StatusSuccess) || outcome.Attempt != 2 {
		t.Fatalf("outcome = %+v, want a success on attempt 2", outcome)
	}
	if len(worker.specs) != 2 || worker.specs[1].Proxy != heal.proxyURL {
		t.Fatalf("specs = %+v, want a second attempt carrying the proxy", worker.specs)
	}
	if len(outcome.Healing) == 0 {
		t.Fatal("outcome must report what was healed")
	}
	events, _ := handle.RunEvents("heal-1")
	if !hasEvent(events, store.EventProviderRetry) {
		t.Errorf("events = %+v, want provider.retry", events)
	}
	if hasEvent(events, store.EventModelFallback) {
		t.Errorf("events = %+v, want no fallback when the retry succeeded", events)
	}
}

func TestHealFallsBackToAnotherModel(t *testing.T) {
	root := newCmdRoot(t)
	handle := openCmdStore(t, root)
	worker := &scriptedExecutor{results: []executor.Result{
		failedResult("", "No available channel"),
		failedResult("", "No available channel"),
		successResult(),
	}}
	heal := healFor(root, alwaysReachable(t))
	heal.proxyURL = "http://127.0.0.1:3128"
	heal.ladder = []string{"fallback/model"}

	outcome := executeRunWithHealing(context.Background(), handle, worker,
		executor.TaskSpec{ID: "heal-2", Agent: "dev-2", Payload: "work", Model: "primary/model"},
		"owner-1", 60, heal)

	if outcome.Status != string(executor.StatusSuccess) || outcome.Attempt != 3 {
		t.Fatalf("outcome = %+v, want a success on the third (fallback) attempt", outcome)
	}
	if worker.specs[2].Model != "fallback/model" {
		t.Errorf("third spec model = %q, want the fallback", worker.specs[2].Model)
	}
	events, _ := handle.RunEvents("heal-2")
	if !hasEvent(events, store.EventProviderRetry) || !hasEvent(events, store.EventModelFallback) {
		t.Errorf("events = %+v, want provider.retry and model.fallback", events)
	}
	for _, event := range events {
		t.Logf("durable event: %s attempt=%d detail=%s", event.Kind, event.Attempt, event.Detail)
	}
	attempts, _ := handle.RunAttempts("heal-2")
	if len(attempts) != 3 {
		t.Fatalf("attempts = %d, want one durable row per attempt", len(attempts))
	}
	if attempts[0].Error == "" || attempts[0].Status != store.RunFailed {
		t.Errorf("first attempt = %+v, want the provider fault persisted", attempts[0])
	}
}

func TestHealSkipsRetryWhenProxyIsDown(t *testing.T) {
	root := newCmdRoot(t)
	handle := openCmdStore(t, root)
	worker := &scriptedExecutor{results: []executor.Result{
		failedResult("", "insufficient credit"),
		successResult(),
	}}
	heal := healFor(root, dialRefused())
	heal.proxyURL = "http://127.0.0.1:3128"
	heal.ladder = []string{"fallback/model"}

	outcome := executeRunWithHealing(context.Background(), handle, worker,
		executor.TaskSpec{ID: "heal-3", Agent: "dev-2", Payload: "work"}, "owner-1", 60, heal)

	if outcome.Status != string(executor.StatusSuccess) || outcome.Attempt != 2 {
		t.Fatalf("outcome = %+v, want a success on the fallback attempt", outcome)
	}
	if worker.specs[1].Proxy != "" {
		t.Errorf("second spec proxy = %q, want none: the proxy was down", worker.specs[1].Proxy)
	}
	if worker.specs[1].Model != "fallback/model" {
		t.Errorf("second spec model = %q, want the fallback", worker.specs[1].Model)
	}
	events, _ := handle.RunEvents("heal-3")
	if hasEvent(events, store.EventProviderRetry) {
		t.Errorf("events = %+v, want no proxy retry when the proxy is down", events)
	}
	if !hasEvent(events, store.EventModelFallback) {
		t.Errorf("events = %+v, want model.fallback", events)
	}
}

func TestHealMarksInvalidSessionWithoutRetrying(t *testing.T) {
	root := newCmdRoot(t)
	handle := openCmdStore(t, root)
	worker := &scriptedExecutor{results: []executor.Result{
		failedResult("", "your session has expired, please log in again"),
	}}
	heal := healFor(root, alwaysReachable(t))

	outcome := executeRunWithHealing(context.Background(), handle, worker,
		executor.TaskSpec{ID: "heal-4", Agent: "dev-2", Payload: "work"}, "owner-1", 60, heal)

	if outcome.Fault != string(net.StatusSessionInvalid) {
		t.Fatalf("fault = %q, want SESSION_INVALID", outcome.Fault)
	}
	if len(worker.specs) != 1 {
		t.Fatalf("attempts = %d, want exactly one: a session fault is not retried", len(worker.specs))
	}
	mark, found, err := handle.SessionMarkByTask("heal-4")
	if err != nil || !found || mark.Status != store.SessionInvalid {
		t.Fatalf("session mark = %+v (found=%v, err=%v), want a durable invalid mark", mark, found, err)
	}
	events, _ := handle.RunEvents("heal-4")
	if !hasEvent(events, store.EventSessionInvalid) {
		t.Errorf("events = %+v, want session.invalid", events)
	}
	if hasEvent(events, store.EventProviderRetry) || hasEvent(events, store.EventModelFallback) {
		t.Errorf("events = %+v, want no retry/fallback for a session fault", events)
	}
}

func TestHealLeavesUnknownFailureAlone(t *testing.T) {
	root := newCmdRoot(t)
	handle := openCmdStore(t, root)
	worker := &scriptedExecutor{results: []executor.Result{
		failedResult("fake executor failure", "Error: fake failure"),
	}}
	heal := healFor(root, alwaysReachable(t))

	outcome := executeRunWithHealing(context.Background(), handle, worker,
		executor.TaskSpec{ID: "heal-5", Agent: "dev-2", Payload: "work"}, "owner-1", 60, heal)

	if outcome.Status != string(executor.StatusFailed) || outcome.Attempt != 1 || outcome.Fault != string(net.StatusUnknown) {
		t.Fatalf("outcome = %+v, want a single failed attempt marked UNKNOWN", outcome)
	}
	if len(worker.specs) != 1 {
		t.Fatalf("attempts = %d, want no healing for an unknown failure", len(worker.specs))
	}
	events, _ := handle.RunEvents("heal-5")
	for _, kind := range []string{store.EventProviderRetry, store.EventModelFallback, store.EventSessionInvalid} {
		if hasEvent(events, kind) {
			t.Errorf("events = %+v, want no %s for an unknown failure", events, kind)
		}
	}
}

// TestExecuteRunDefaultHealKeepsPlainFailuresSingleAttempt guards the existing
// contract: executeRun (the production entry point) must not turn a generic
// task failure into a retry storm.
func TestExecuteRunDefaultHealKeepsPlainFailuresSingleAttempt(t *testing.T) {
	root := newCmdRoot(t)
	handle := openCmdStore(t, root)

	outcome := executeRun(context.Background(), handle,
		executor.NewFakeExecutor(executor.FakeFail),
		executor.TaskSpec{ID: "heal-6", Agent: "dev-2", Payload: "work"}, "owner-1", 60)

	if outcome.Status != string(executor.StatusFailed) || outcome.Attempt != 1 {
		t.Fatalf("outcome = %+v, want one failed attempt", outcome)
	}
}
