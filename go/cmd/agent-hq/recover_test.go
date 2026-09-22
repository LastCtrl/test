package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"agent-hq/internal/store"
)

func seedStaleAttemptForCmd(t *testing.T, handle *store.Store) {
	t.Helper()
	if err := handle.SaveRun(store.Run{TaskID: "run-rec", Agent: "dev-2", Executor: "fake",
		Payload: "do work", Status: store.RunRunning, StartedAt: "2026-09-18T10:00:00Z"}); err != nil {
		t.Fatalf("SaveRun: %v", err)
	}
	if _, err := handle.StartAttempt(store.RunAttempt{TaskID: "run-rec", Agent: "dev-2",
		Executor: "fake", AttemptID: "attempt-1", Status: store.RunRunning,
		StartedAt: "2026-09-18T10:00:00Z"}); err != nil {
		t.Fatalf("StartAttempt: %v", err)
	}
	acquired, err := handle.AcquireClaim(store.ClaimRequest{TaskID: "run-rec", Owner: "owner-old",
		Agent: "dev-2", LeaseSeconds: 60, Now: time.Now().Add(-2 * time.Hour)})
	if err != nil || !acquired {
		t.Fatalf("AcquireClaim = %v, %v; want true, nil", acquired, err)
	}
}

func TestRecoverCommandMarksStaleAndIsIdempotent(t *testing.T) {
	root := newCmdRoot(t)
	handle := openCmdStore(t, root)
	seedStaleAttemptForCmd(t, handle)

	var stdout, stderr bytes.Buffer
	code := runRecover(globalOptions{root: root, json: true}, []string{"-Requeue"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("recover exit = %d, stderr = %s", code, stderr.String())
	}
	var output recoverOutput
	if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
		t.Fatalf("decode recover output: %v (%s)", err, stdout.String())
	}
	if output.Stale != 1 || output.Recovered != 1 || len(output.Attempts) != 1 {
		t.Fatalf("output = %+v, want one recovered attempt", output)
	}
	if !output.Attempts[0].Recovered || output.Attempts[0].Reason != "heartbeat-expired" {
		t.Errorf("attempt = %+v, want a recovered heartbeat-expired record", output.Attempts[0])
	}

	run, found, err := handle.RunByTask("run-rec")
	if err != nil || !found || run.Status != store.RunQueued || run.Payload != "do work" {
		t.Errorf("run = %+v (found=%v, err=%v), want queued with the payload kept", run, found, err)
	}
	claims, err := handle.RunClaims()
	if err != nil || len(claims) != 0 {
		t.Errorf("claims = %+v, %v; want the stale lease released", claims, err)
	}
	attempts, err := handle.RunAttempts("run-rec")
	if err != nil || len(attempts) != 1 || attempts[0].Status != store.RunStale {
		t.Errorf("attempts = %+v, %v; want one stale record", attempts, err)
	}

	stdout.Reset()
	stderr.Reset()
	code = runRecover(globalOptions{root: root, json: true}, []string{"-requeue"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("second recover exit = %d, stderr = %s", code, stderr.String())
	}
	var second recoverOutput
	if err := json.Unmarshal(stdout.Bytes(), &second); err != nil {
		t.Fatalf("decode second recover output: %v", err)
	}
	if second.Stale != 0 || second.Recovered != 0 {
		t.Errorf("second sweep = %+v, want a no-op", second)
	}
}

func TestRecoverCommandUsage(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := runRecover(globalOptions{}, []string{"unexpected"}, &stdout, &stderr); code != 2 {
		t.Errorf("unexpected positional exit = %d, want 2", code)
	}
}

// A rejected -ttl must not be a silent no-op: the command warns on stderr and
// falls back to the per-attempt lease (ttl 0) instead of pretending an override
// was applied.
func TestRecoverCommandWarnsOnInvalidTTL(t *testing.T) {
	root := newCmdRoot(t)
	_ = openCmdStore(t, root)

	var stdout, stderr bytes.Buffer
	code := runRecover(globalOptions{root: root, json: true}, []string{"-ttl", "abc"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("recover exit = %d, want 0 (fallback to default), stderr = %s", code, stderr.String())
	}
	if warning := stderr.String(); !strings.Contains(warning, "abc") || !strings.Contains(strings.ToLower(warning), "ttl") {
		t.Errorf("stderr = %q, want a warning naming the rejected -ttl value", warning)
	}

	var output recoverOutput
	if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
		t.Fatalf("decode recover output: %v (%s)", err, stdout.String())
	}
	if output.TTLSeconds != 0 {
		t.Errorf("ttl_seconds = %d, want 0 so the per-attempt lease is used", output.TTLSeconds)
	}
}

func TestRecoverCommandWarnsOnNonPositiveAndMissingTTL(t *testing.T) {
	root := newCmdRoot(t)
	_ = openCmdStore(t, root)

	for _, args := range [][]string{{"-ttl", "0"}, {"-ttl=-5"}, {"-ttl"}} {
		var stdout, stderr bytes.Buffer
		code := runRecover(globalOptions{root: root, json: true}, args, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("runRecover(%v) exit = %d, want 0, stderr = %s", args, code, stderr.String())
		}
		if !strings.Contains(strings.ToLower(stderr.String()), "ttl") {
			t.Errorf("runRecover(%v) stderr = %q, want a -ttl warning", args, stderr.String())
		}
	}
}

func TestExtractRecoverOptions(t *testing.T) {
	options, rest := extractRecoverOptions([]string{"-Requeue", "-ttl=120"})
	if !options.requeue || options.ttl != 120 || len(rest) != 0 {
		t.Errorf("options = %+v, rest = %v; want requeue with ttl 120", options, rest)
	}
	options, rest = extractRecoverOptions([]string{"-requeue", "-ttl", "30"})
	if !options.requeue || options.ttl != 30 || len(rest) != 0 {
		t.Errorf("options = %+v, rest = %v; want requeue with ttl 30", options, rest)
	}
	options, rest = extractRecoverOptions([]string{"-ttl", "abc"})
	if options.ttl != 0 || len(options.warnings) != 1 || !strings.Contains(options.warnings[0], "abc") {
		t.Errorf("options = %+v, rest = %v; want a warning and no ttl override", options, rest)
	}
}
