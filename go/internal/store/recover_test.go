package store

import (
	"testing"
	"time"
)

// seedRunningAttempt writes a running run and attempt, plus a claim with the
// given heartbeat when a lease is requested (leaseSeconds > 0).
func seedRunningAttempt(t *testing.T, handle *Store, taskID, owner string, heartbeat time.Time, leaseSeconds int) int {
	t.Helper()
	if err := handle.SaveRun(Run{TaskID: taskID, Agent: "dev-2", Executor: "fake",
		Payload: "do work", Status: RunRunning, StartedAt: runStart.Format(time.RFC3339Nano)}); err != nil {
		t.Fatalf("SaveRun: %v", err)
	}
	seq, err := handle.StartAttempt(RunAttempt{TaskID: taskID, Agent: "dev-2", Executor: "fake",
		AttemptID: "attempt-1", Command: "fake executor", Status: RunRunning,
		StartedAt: runStart.Format(time.RFC3339Nano)})
	if err != nil {
		t.Fatalf("StartAttempt: %v", err)
	}
	if leaseSeconds > 0 {
		acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: taskID, Owner: owner,
			Agent: "dev-2", LeaseSeconds: leaseSeconds, Now: heartbeat})
		if err != nil || !acquired {
			t.Fatalf("AcquireClaim: %v, %v; want true, nil", acquired, err)
		}
	}
	return seq
}

func hasStoreEvent(events []RunEvent, kind string) bool {
	for _, event := range events {
		if event.Kind == kind {
			return true
		}
	}
	return false
}

// TestHeartbeatClaimExtendsLease covers the mechanism the M2 ticker relies on:
// only the owner may refresh, and a refresh moves the expiry beyond the
// original lease.
func TestHeartbeatClaimExtendsLease(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	if acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: "run-1", Owner: "a",
		LeaseSeconds: 60, Now: runStart}); err != nil || !acquired {
		t.Fatalf("claim = %v, %v; want true, nil", acquired, err)
	}

	if refreshed, err := handle.HeartbeatClaim("run-1", "b", runStart.Add(30*time.Second)); err != nil || refreshed {
		t.Errorf("foreign heartbeat = %v, %v; want false, nil", refreshed, err)
	}
	if refreshed, err := handle.HeartbeatClaim("run-1", "a", runStart.Add(30*time.Second)); err != nil || !refreshed {
		t.Fatalf("owner heartbeat = %v, %v; want true, nil", refreshed, err)
	}

	// Without the refresh the lease would expire at +60; it now expires at +90.
	if acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: "run-1", Owner: "c",
		LeaseSeconds: 60, Now: runStart.Add(61 * time.Second)}); err != nil || acquired {
		t.Errorf("heartbeat did not extend the lease: %v, %v; want false, nil", acquired, err)
	}
	if acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: "run-1", Owner: "c",
		LeaseSeconds: 60, Now: runStart.Add(91 * time.Second)}); err != nil || !acquired {
		t.Errorf("expired lease not taken: %v, %v; want true, nil", acquired, err)
	}
}

func TestStaleAttemptsFindsExpiredAttempt(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	seedRunningAttempt(t, handle, "run-1", "owner-old", runStart, 60)

	fresh, err := handle.StaleAttempts(runStart.Add(30*time.Second), 0)
	if err != nil {
		t.Fatalf("StaleAttempts (fresh): %v", err)
	}
	if len(fresh) != 0 {
		t.Fatalf("a live lease was reported stale: %+v", fresh)
	}

	stale, err := handle.StaleAttempts(runStart.Add(61*time.Second), 0)
	if err != nil {
		t.Fatalf("StaleAttempts (expired): %v", err)
	}
	if len(stale) != 1 {
		t.Fatalf("stale = %+v, want exactly one expired attempt", stale)
	}
	got := stale[0]
	if got.TaskID != "run-1" || got.Owner != "owner-old" || got.Reason != "heartbeat-expired" {
		t.Errorf("stale = %+v, want run-1/owner-old/heartbeat-expired", got)
	}
	if got.LeaseSeconds != 60 || got.AgeSeconds != 61 {
		t.Errorf("stale = %+v, want lease 60s and age 61s", got)
	}
}

// TestStaleAttemptsTTLOverride pins the -ttl behaviour: the override replaces
// the stored lease without rewriting the claim row.
func TestStaleAttemptsTTLOverride(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	seedRunningAttempt(t, handle, "run-1", "owner", runStart, 60)

	stale, err := handle.StaleAttempts(runStart.Add(61*time.Second), 120*time.Second)
	if err != nil {
		t.Fatalf("StaleAttempts: %v", err)
	}
	if len(stale) != 0 {
		t.Errorf("ttl override kept the attempt live; got %+v", stale)
	}

	stale, err = handle.StaleAttempts(runStart.Add(61*time.Second), 30*time.Second)
	if err != nil {
		t.Fatalf("StaleAttempts: %v", err)
	}
	if len(stale) != 1 || stale[0].LeaseSeconds != 30 {
		t.Errorf("stale = %+v, want one attempt with the 30s override", stale)
	}
}

// TestStaleAttemptWithoutClaim covers the LEFT JOIN fallback: an attempt whose
// claim row is already gone is still recoverable.
func TestStaleAttemptWithoutClaim(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	seq := seedRunningAttempt(t, handle, "run-1", "", runStart, 0)

	stale, err := handle.StaleAttempts(runStart.Add(2*time.Hour), 0)
	if err != nil {
		t.Fatalf("StaleAttempts: %v", err)
	}
	if len(stale) != 1 || stale[0].Owner != "" || stale[0].LeaseSeconds != DefaultRunLeaseSeconds {
		t.Fatalf("stale = %+v, want one ownerless attempt with the default lease", stale)
	}

	done, err := handle.RecoverAttempt(RecoverRequest{TaskID: "run-1", Seq: seq, Now: runStart.Add(2 * time.Hour)})
	if err != nil || !done {
		t.Fatalf("RecoverAttempt = %v, %v; want true, nil", done, err)
	}
}

func TestRecoverAttemptReleasesLeaseAndIsIdempotent(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	seq := seedRunningAttempt(t, handle, "run-1", "owner-old", runStart, 60)
	now := runStart.Add(61 * time.Second)

	done, err := handle.RecoverAttempt(RecoverRequest{TaskID: "run-1", Seq: seq,
		Owner: "owner-old", Reason: "heartbeat-expired", Now: now})
	if err != nil || !done {
		t.Fatalf("RecoverAttempt = %v, %v; want true, nil", done, err)
	}

	attempts, err := handle.RunAttempts("run-1")
	if err != nil {
		t.Fatalf("RunAttempts: %v", err)
	}
	if len(attempts) != 1 || attempts[0].Status != RunStale ||
		attempts[0].FinishedAt == "" || attempts[0].Error != "heartbeat-expired" {
		t.Errorf("attempts = %+v, want one finished stale record", attempts)
	}

	claims, err := handle.RunClaims()
	if err != nil {
		t.Fatalf("RunClaims: %v", err)
	}
	if len(claims) != 0 {
		t.Errorf("claims = %+v, want the stale lease released", claims)
	}

	run, found, err := handle.RunByTask("run-1")
	if err != nil || !found || run.Status != RunStale {
		t.Errorf("run = %+v (found=%v, err=%v), want stale", run, found, err)
	}

	events, err := handle.RunEvents("run-1")
	if err != nil {
		t.Fatalf("RunEvents: %v", err)
	}
	if !hasStoreEvent(events, EventAttemptStale) || !hasStoreEvent(events, EventRunStale) {
		t.Errorf("events = %+v, want attempt and run recovery events", events)
	}

	stale, err := handle.StaleAttempts(now, 0)
	if err != nil {
		t.Fatalf("StaleAttempts after recovery: %v", err)
	}
	if len(stale) != 0 {
		t.Errorf("stale after recovery = %+v, want none", stale)
	}

	again, err := handle.RecoverAttempt(RecoverRequest{TaskID: "run-1", Seq: seq,
		Owner: "owner-old", Reason: "heartbeat-expired", Now: now})
	if err != nil || again {
		t.Errorf("second RecoverAttempt = %v, %v; want false, nil", again, err)
	}
	after, err := handle.RunEvents("run-1")
	if err != nil {
		t.Fatalf("RunEvents after second recovery: %v", err)
	}
	if len(after) != len(events) {
		t.Errorf("second recovery appended events: %d then %d", len(events), len(after))
	}
}

func TestRecoverAttemptRequeueKeepsPayload(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	seq := seedRunningAttempt(t, handle, "run-1", "owner", runStart, 60)

	done, err := handle.RecoverAttempt(RecoverRequest{TaskID: "run-1", Seq: seq,
		Owner: "owner", Reason: "heartbeat-expired", Requeue: true, Now: runStart.Add(61 * time.Second)})
	if err != nil || !done {
		t.Fatalf("RecoverAttempt = %v, %v; want true, nil", done, err)
	}

	run, found, err := handle.RunByTask("run-1")
	if err != nil || !found {
		t.Fatalf("RunByTask: %v, %v", found, err)
	}
	if run.Status != RunQueued || run.Payload != "do work" {
		t.Errorf("run = %+v, want queued with the payload preserved", run)
	}

	events, err := handle.RunEvents("run-1")
	if err != nil {
		t.Fatalf("RunEvents: %v", err)
	}
	if !hasStoreEvent(events, EventRecoverRequeued) {
		t.Errorf("events = %+v, want a requeue event", events)
	}
}

func TestRecoverRejectsBrokenInputs(t *testing.T) {
	handle := openRunStore(t, newRoot(t))

	if _, err := handle.RecoverAttempt(RecoverRequest{}); err == nil {
		t.Error("RecoverAttempt with an empty id returned no error")
	}
	if _, err := handle.RecoverAttempt(RecoverRequest{TaskID: "run-1"}); err == nil {
		t.Error("RecoverAttempt with a zero sequence returned no error")
	}
	if _, err := handle.StaleAttempts(runStart, -time.Second); err != nil {
		t.Errorf("StaleAttempts with a negative ttl: %v", err)
	}
	if done, err := handle.RecoverAttempt(RecoverRequest{TaskID: "missing", Seq: 1, Now: runStart}); err != nil || done {
		t.Errorf("RecoverAttempt on an unknown attempt = %v, %v; want false, nil", done, err)
	}
}
