package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agent-hq/internal/executor"
	"agent-hq/internal/store"
)

func newCmdRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".memory"), 0o755); err != nil {
		t.Fatalf("mkdir .memory: %v", err)
	}
	return root
}

func openCmdStore(t *testing.T, root string) *store.Store {
	t.Helper()
	handle, err := store.Open(root)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = handle.Close() })
	return handle
}

func TestExecuteRunFakeSuccess(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	spec := executor.TaskSpec{ID: "run-1", Agent: "dev-2", Payload: "do work"}

	outcome := executeRun(context.Background(), handle,
		executor.NewFakeExecutor(executor.FakeSuccess), spec, "owner-1", 60)

	if !outcome.Claimed || outcome.Status != string(executor.StatusSuccess) || outcome.ExitCode != 0 {
		t.Fatalf("outcome = %+v, want claimed success exit 0", outcome)
	}
	if outcome.Attempt != 1 {
		t.Errorf("attempt = %d, want 1", outcome.Attempt)
	}
	if !strings.Contains(outcome.Stdout, "STATUS: resolved") {
		t.Errorf("stdout = %q, want the success marker", outcome.Stdout)
	}

	run, found, err := handle.RunByTask("run-1")
	if err != nil || !found {
		t.Fatalf("RunByTask: %v, %v", found, err)
	}
	if run.Status != store.RunSuccess || run.Attempt != 1 || run.ExitCode == nil || *run.ExitCode != 0 {
		t.Errorf("run = %+v, want success attempt 1 exit 0", run)
	}

	attempts, err := handle.RunAttempts("run-1")
	if err != nil {
		t.Fatalf("RunAttempts: %v", err)
	}
	if len(attempts) != 1 || attempts[0].Status != store.RunSuccess ||
		attempts[0].StdoutSHA256 == "" || attempts[0].StdoutLength == nil || *attempts[0].StdoutLength == 0 {
		t.Errorf("attempts = %+v, want one finished success record with a hash and length", attempts)
	}
	if attempts[0].AttemptID != "attempt-1" {
		t.Errorf("attempt_id = %q, want %q persisted in the database", attempts[0].AttemptID, "attempt-1")
	}

	claims, err := handle.RunClaims()
	if err != nil {
		t.Fatalf("RunClaims: %v", err)
	}
	if len(claims) != 0 {
		t.Errorf("claims = %+v, want the lease released", claims)
	}

	events, err := handle.RunEvents("run-1")
	if err != nil {
		t.Fatalf("RunEvents: %v", err)
	}
	for _, kind := range []string{store.EventClaimAcquired, store.EventAttemptStarted,
		store.EventAttemptFinished, store.EventRunFinished, store.EventClaimReleased} {
		if !hasEvent(events, kind) {
			t.Errorf("missing event %s in %+v", kind, events)
		}
	}
}

func TestExecuteRunFakeFail(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	spec := executor.TaskSpec{ID: "run-2", Agent: "dev-2", Payload: "do work"}

	outcome := executeRun(context.Background(), handle,
		executor.NewFakeExecutor(executor.FakeFail), spec, "owner-1", 60)

	if outcome.Status != string(executor.StatusFailed) || outcome.ExitCode != 1 {
		t.Fatalf("outcome = %+v, want failed exit 1", outcome)
	}
	run, found, _ := handle.RunByTask("run-2")
	if !found || run.Status != store.RunFailed {
		t.Errorf("run = %+v (found=%v), want failed", run, found)
	}
	attempts, _ := handle.RunAttempts("run-2")
	if len(attempts) != 1 || attempts[0].Status != store.RunFailed || attempts[0].Error == "" {
		t.Errorf("attempts = %+v, want one failed record with a reason", attempts)
	}
}

func TestExecuteRunClaimConflict(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	// Another worker already holds a live lease.
	if acquired, err := handle.AcquireClaim(store.ClaimRequest{TaskID: "run-3", Owner: "holder",
		LeaseSeconds: 900, Now: time.Now()}); err != nil || !acquired {
		t.Fatalf("seed claim = %v, %v", acquired, err)
	}

	outcome := executeRun(context.Background(), handle,
		executor.NewFakeExecutor(executor.FakeSuccess),
		executor.TaskSpec{ID: "run-3", Agent: "dev-2", Payload: "do work"}, "owner-2", 60)

	if outcome.Claimed || outcome.Reason != "already-claimed" || outcome.Status != "skipped" {
		t.Fatalf("outcome = %+v, want an already-claimed skip", outcome)
	}
	attempts, _ := handle.RunAttempts("run-3")
	if len(attempts) != 0 {
		t.Errorf("attempts = %+v, want no attempt for a lost claim", attempts)
	}
	claims, _ := handle.RunClaims()
	if len(claims) != 1 || claims[0].Owner != "holder" {
		t.Errorf("claims = %+v, want the holder lease intact", claims)
	}
	events, _ := handle.RunEvents("run-3")
	if !hasEvent(events, store.EventClaimConflict) {
		t.Errorf("missing claim conflict event in %+v", events)
	}
}

func TestExecuteRunDurableAcrossRuns(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	spec := executor.TaskSpec{ID: "run-4", Agent: "dev-2", Payload: "do work"}

	executeRun(context.Background(), handle, executor.NewFakeExecutor(executor.FakeSuccess), spec, "owner-1", 60)
	second := executeRun(context.Background(), handle, executor.NewFakeExecutor(executor.FakeFail), spec, "owner-2", 60)
	if second.Attempt != 2 {
		t.Fatalf("second attempt = %d, want 2", second.Attempt)
	}

	attempts, _ := handle.RunAttempts("run-4")
	if len(attempts) != 2 {
		t.Fatalf("attempts = %d, want 2 preserved records", len(attempts))
	}
	if attempts[0].Status != store.RunSuccess || attempts[1].Status != store.RunFailed {
		t.Errorf("attempts = %+v, want success then failed", attempts)
	}
	run, found, _ := handle.RunByTask("run-4")
	if !found || run.Status != store.RunFailed || run.Attempt != 2 {
		t.Errorf("run = %+v (found=%v), want the latest failed attempt 2", run, found)
	}
}

// TestExecuteRunPersistsAttemptID guards BUG-029: the attempt_id column must be
// populated for every attempt, including the first, and survive the finish
// write.
func TestExecuteRunPersistsAttemptID(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	spec := executor.TaskSpec{ID: "run-attempt-id", Agent: "dev-2", Payload: "do work"}

	executeRun(context.Background(), handle,
		executor.NewFakeExecutor(executor.FakeSuccess), spec, "owner-1", 60)
	executeRun(context.Background(), handle,
		executor.NewFakeExecutor(executor.FakeFail), spec, "owner-2", 60)

	attempts, err := handle.RunAttempts("run-attempt-id")
	if err != nil {
		t.Fatalf("RunAttempts: %v", err)
	}
	if len(attempts) != 2 {
		t.Fatalf("attempts = %d, want 2", len(attempts))
	}
	for index, want := range []string{"attempt-1", "attempt-2"} {
		if attempts[index].AttemptID != want {
			t.Errorf("attempt %d attempt_id = %q, want %q", index+1, attempts[index].AttemptID, want)
		}
	}
}

func TestExecuteRunExecutorError(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	outcome := executeRun(context.Background(), handle, executor.NewFakeExecutor(executor.FakeMode("bogus")),
		executor.TaskSpec{ID: "run-5", Agent: "dev-2", Payload: "do work"}, "owner-1", 60)
	if outcome.Status != string(executor.StatusError) || outcome.Error == "" {
		t.Fatalf("outcome = %+v, want an error status with a message", outcome)
	}
	attempts, _ := handle.RunAttempts("run-5")
	if len(attempts) != 1 || attempts[0].Status != store.RunError {
		t.Errorf("attempts = %+v, want one error record (write-before guarantees it)", attempts)
	}
}

func TestReportRunExitCodes(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := reportRun(runOutcome{Status: string(executor.StatusSuccess), Claimed: true}, false, &stdout, &stderr); code != 0 {
		t.Errorf("success exit = %d, want 0", code)
	}
	stdout.Reset()
	if code := reportRun(runOutcome{Status: string(executor.StatusFailed), Claimed: true}, false, &stdout, &stderr); code != 1 {
		t.Errorf("failure exit = %d, want 1", code)
	}
	stdout.Reset()
	if code := reportRun(runOutcome{Status: "skipped", Reason: "already-claimed"}, false, &stdout, &stderr); code != 1 {
		t.Errorf("conflict exit = %d, want 1", code)
	}
	if !strings.Contains(stdout.String(), "already-claimed") {
		t.Errorf("conflict output = %q, want the reason", stdout.String())
	}
}

func TestRunRunRejectsBadUsage(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := runRun(globalOptions{}, []string{"only-one"}, &stdout, &stderr); code != 2 {
		t.Errorf("one positional exit = %d, want 2", code)
	}
	stdout.Reset()
	stderr.Reset()
	if code := runRun(globalOptions{}, []string{"", "text"}, &stdout, &stderr); code != 2 {
		t.Errorf("empty agent exit = %d, want 2", code)
	}
	stdout.Reset()
	stderr.Reset()
	if code := runRun(globalOptions{}, []string{"dev-2", "text", "-executor", "bogus"}, &stdout, &stderr); code != 2 {
		t.Errorf("unknown executor exit = %d, want 2", code)
	}
}

func TestExtractRunOptionsAllowsFlagsAfterText(t *testing.T) {
	options, rest := extractRunOptions([]string{"dev-2", "some text", "-executor", "fake", "-id=run-9", "-model", "m1"})
	if options.executor != "fake" || options.taskID != "run-9" || options.model != "m1" {
		t.Errorf("options = %+v, want fake/run-9/m1", options)
	}
	if len(rest) != 2 || rest[0] != "dev-2" || rest[1] != "some text" {
		t.Errorf("rest = %v, want the agent and the text", rest)
	}
}

func hasEvent(events []store.RunEvent, kind string) bool {
	for _, event := range events {
		if event.Kind == kind {
			return true
		}
	}
	return false
}

// TestStartHeartbeatRefreshesLease exercises the M2 ticker: while it runs, the
// lease heartbeat advances, and stop is idempotent.
func TestStartHeartbeatRefreshesLease(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	if acquired, err := handle.AcquireClaim(store.ClaimRequest{TaskID: "run-hb", Owner: "beat",
		LeaseSeconds: 60, Now: time.Now()}); err != nil || !acquired {
		t.Fatalf("seed claim = %v, %v", acquired, err)
	}
	claims, err := handle.RunClaims()
	if err != nil || len(claims) != 1 {
		t.Fatalf("RunClaims = %+v, %v; want one claim", claims, err)
	}
	before := claims[0].HeartbeatAt

	heartbeatIntervalOverride = 20 * time.Millisecond
	t.Cleanup(func() { heartbeatIntervalOverride = 0 })

	stop := startHeartbeat(handle, "run-hb", "beat", 60, nil)
	time.Sleep(120 * time.Millisecond)
	stop()
	stop() // must be idempotent and must not panic

	claims, err = handle.RunClaims()
	if err != nil || len(claims) != 1 {
		t.Fatalf("RunClaims after heartbeat = %+v, %v", claims, err)
	}
	if claims[0].HeartbeatAt == before {
		t.Errorf("heartbeat was not refreshed: still %q", before)
	}
}

// TestExecuteRunHeartbeatsAndReleases checks that a slow fake worker finishes
// cleanly with the ticker running: the lease is released and no heartbeat error
// is recorded.
func TestExecuteRunHeartbeatsAndReleases(t *testing.T) {
	handle := openCmdStore(t, newCmdRoot(t))
	heartbeatIntervalOverride = 20 * time.Millisecond
	t.Cleanup(func() { heartbeatIntervalOverride = 0 })

	worker := executor.NewFakeExecutor(executor.FakeSuccess)
	worker.Delay = 150 * time.Millisecond
	outcome := executeRun(context.Background(), handle, worker,
		executor.TaskSpec{ID: "run-hblong", Agent: "dev-2", Payload: "do work"}, "owner-1", 60)

	if outcome.Status != string(executor.StatusSuccess) {
		t.Fatalf("outcome = %+v, want success", outcome)
	}
	claims, err := handle.RunClaims()
	if err != nil || len(claims) != 0 {
		t.Errorf("claims = %+v, %v; want the lease released", claims, err)
	}
	events, err := handle.RunEvents("run-hblong")
	if err != nil {
		t.Fatalf("RunEvents: %v", err)
	}
	if hasEvent(events, store.EventHeartbeatError) {
		t.Errorf("heartbeat errors recorded: %+v", events)
	}
}
