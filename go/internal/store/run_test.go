package store

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

var runStart = time.Date(2026, 9, 18, 10, 0, 0, 0, time.UTC)

func openRunStore(t *testing.T, root string) *Store {
	t.Helper()
	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = handle.Close() })
	return handle
}

func TestOpenCreatesRunSchema(t *testing.T) {
	root := newRoot(t)
	handle := openRunStore(t, root)

	for _, table := range []string{"run_claims", "runs", "run_attempts", "run_events"} {
		var name string
		if err := handle.db.QueryRow("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", table).Scan(&name); err != nil {
			t.Errorf("table %s missing: %v", table, err)
		}
	}
	version, err := handle.SchemaVersion()
	if err != nil {
		t.Fatalf("SchemaVersion: %v", err)
	}
	if version != SchemaVersion {
		t.Errorf("schema version = %d, want %d", version, SchemaVersion)
	}
}

func TestAcquireClaimPicksOneWinner(t *testing.T) {
	root := newRoot(t)
	first := openRunStore(t, root)
	second, err := Open(root)
	if err != nil {
		t.Fatalf("second Open: %v", err)
	}
	defer func() { _ = second.Close() }()

	handles := []*Store{first, second}
	results := make([]bool, len(handles))
	errs := make([]error, len(handles))
	start := make(chan struct{})
	var wait sync.WaitGroup

	for index := range handles {
		wait.Add(1)
		go func(position int) {
			defer wait.Done()
			<-start
			results[position], errs[position] = handles[position].AcquireClaim(ClaimRequest{
				TaskID: "run-1", Owner: fmt.Sprintf("owner-%d", position),
				Agent: "dev-2", LeaseSeconds: 900,
			})
		}(index)
	}
	close(start)
	wait.Wait()

	winners := 0
	for position, acquired := range results {
		if errs[position] != nil {
			t.Errorf("owner %d: AcquireClaim: %v", position, errs[position])
		}
		if acquired {
			winners++
		}
	}
	if winners != 1 {
		t.Errorf("winners = %d, want exactly 1 (results=%v)", winners, results)
	}
}

func TestAcquireClaimExpires(t *testing.T) {
	handle := openRunStore(t, newRoot(t))

	if acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: "run-1", Owner: "a",
		LeaseSeconds: 60, Now: runStart}); err != nil || !acquired {
		t.Fatalf("first claim = %v, %v; want true, nil", acquired, err)
	}
	if acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: "run-1", Owner: "b",
		LeaseSeconds: 60, Now: runStart.Add(30 * time.Second)}); err != nil || acquired {
		t.Errorf("live lease stolen: %v, %v; want false, nil", acquired, err)
	}
	if acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: "run-1", Owner: "c",
		LeaseSeconds: 60, Now: runStart.Add(61 * time.Second)}); err != nil || !acquired {
		t.Errorf("expired lease not taken: %v, %v; want true, nil", acquired, err)
	}
}

func TestReleaseClaimIsOwnerGuarded(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	if acquired, err := handle.AcquireClaim(ClaimRequest{TaskID: "run-1", Owner: "a",
		LeaseSeconds: 900, Now: runStart}); err != nil || !acquired {
		t.Fatalf("claim: %v, %v", acquired, err)
	}

	if released, err := handle.ReleaseClaim("run-1", "b"); err != nil || released {
		t.Errorf("foreign release = %v, %v; want false, nil", released, err)
	}
	if released, err := handle.ReleaseClaim("run-1", "a"); err != nil || !released {
		t.Errorf("owner release = %v, %v; want true, nil", released, err)
	}
	if released, err := handle.ReleaseClaim("run-1", "a"); err != nil || released {
		t.Errorf("double release = %v, %v; want false, nil", released, err)
	}
}

func TestDurableAttemptsArePreserved(t *testing.T) {
	handle := openRunStore(t, newRoot(t))

	if err := handle.SaveRun(Run{TaskID: "run-1", Agent: "dev-2", Executor: "fake",
		Status: RunRunning, StartedAt: runStart.Format(time.RFC3339Nano)}); err != nil {
		t.Fatalf("SaveRun: %v", err)
	}
	sequence, err := handle.StartAttempt(RunAttempt{TaskID: "run-1", Agent: "dev-2",
		Executor: "fake", AttemptID: "attempt-1", Status: RunRunning,
		StartedAt: runStart.Format(time.RFC3339Nano)})
	if err != nil {
		t.Fatalf("StartAttempt: %v", err)
	}
	if sequence != 1 {
		t.Fatalf("first sequence = %d, want 1", sequence)
	}

	exit := 0
	length := 20
	finished, status := handle.FinishAttempt(RunAttempt{TaskID: "run-1", Seq: sequence,
		ExitCode: &exit, StdoutSHA256: "aa", StdoutLength: &length,
		Status: RunSuccess, FinishedAt: runStart.Add(time.Second).Format(time.RFC3339Nano)})
	if err := status; err != nil || !finished {
		t.Fatalf("FinishAttempt = %v, %v; want true, nil", finished, err)
	}

	second, err := handle.StartAttempt(RunAttempt{TaskID: "run-1", Agent: "dev-2",
		Executor: "fake", AttemptID: "attempt-2", Status: RunRunning})
	if err != nil {
		t.Fatalf("second StartAttempt: %v", err)
	}
	if second != 2 {
		t.Fatalf("second sequence = %d, want 2", second)
	}

	attempts, err := handle.RunAttempts("run-1")
	if err != nil {
		t.Fatalf("RunAttempts: %v", err)
	}
	if len(attempts) != 2 {
		t.Fatalf("attempts = %d, want 2 (past attempts must survive)", len(attempts))
	}
	if attempts[0].Seq != 1 || attempts[0].Status != RunSuccess || attempts[0].StdoutSHA256 != "aa" {
		t.Errorf("attempt 1 = %+v, want finished success record", attempts[0])
	}
	if attempts[1].Seq != 2 || attempts[1].Status != RunRunning {
		t.Errorf("attempt 2 = %+v, want running record", attempts[1])
	}

	if err := handle.SaveRun(Run{TaskID: "run-1", Status: RunSuccess, Attempt: 1,
		ExitCode: &exit, UpdatedAt: runStart.Add(time.Second).Format(time.RFC3339Nano)}); err != nil {
		t.Fatalf("final SaveRun: %v", err)
	}
	run, found, err := handle.RunByTask("run-1")
	if err != nil || !found {
		t.Fatalf("RunByTask = %v, %v", found, err)
	}
	if run.Status != RunSuccess || run.Attempt != 1 || run.ExitCode == nil || *run.ExitCode != 0 {
		t.Errorf("run = %+v, want success attempt 1 exit 0", run)
	}
	if run.CreatedAt == "" {
		t.Error("created_at was not stamped")
	}
}

// TestAttemptIDDefaultsAndFinishDoesNotBlank guards BUG-029 at the store layer:
// a blank AttemptID is filled from the assigned sequence, and finishing with an
// empty id must not erase the stored one.
func TestAttemptIDDefaultsAndFinishDoesNotBlank(t *testing.T) {
	handle := openRunStore(t, newRoot(t))

	sequence, err := handle.StartAttempt(RunAttempt{TaskID: "run-id", Agent: "dev-2",
		Executor: "fake", Status: RunRunning})
	if err != nil {
		t.Fatalf("StartAttempt: %v", err)
	}
	attempts, err := handle.RunAttempts("run-id")
	if err != nil || len(attempts) != 1 {
		t.Fatalf("RunAttempts = %+v, %v; want one attempt", attempts, err)
	}
	if attempts[0].AttemptID != "attempt-1" {
		t.Fatalf("default attempt_id = %q, want attempt-1", attempts[0].AttemptID)
	}

	if finished, err := handle.FinishAttempt(RunAttempt{TaskID: "run-id", Seq: sequence,
		Status: RunSuccess}); err != nil || !finished {
		t.Fatalf("FinishAttempt = %v, %v; want true, nil", finished, err)
	}
	attempts, _ = handle.RunAttempts("run-id")
	if attempts[0].AttemptID != "attempt-1" {
		t.Errorf("attempt_id after empty finish = %q, want the stored attempt-1", attempts[0].AttemptID)
	}
	if attempts[0].Status != RunSuccess {
		t.Errorf("attempt status = %q, want %q", attempts[0].Status, RunSuccess)
	}
}

func TestRunEventsAreAppendOnly(t *testing.T) {
	handle := openRunStore(t, newRoot(t))
	for _, kind := range []string{EventClaimAcquired, EventAttemptStarted, EventRunFinished} {
		if _, err := handle.AppendEvent(RunEvent{TaskID: "run-1", Attempt: 1, Kind: kind}); err != nil {
			t.Fatalf("AppendEvent(%s): %v", kind, err)
		}
	}
	events, err := handle.RunEvents("run-1")
	if err != nil {
		t.Fatalf("RunEvents: %v", err)
	}
	if len(events) != 3 {
		t.Fatalf("events = %d, want 3", len(events))
	}
	for index, kind := range []string{EventClaimAcquired, EventAttemptStarted, EventRunFinished} {
		if events[index].Kind != kind || events[index].CreatedAt == "" {
			t.Errorf("event %d = %+v, want %s", index, events[index], kind)
		}
	}
	if events[2].ID <= events[0].ID {
		t.Errorf("event ids are not increasing: %d then %d", events[0].ID, events[2].ID)
	}
}

func TestRunStoreRejectsBrokenInputs(t *testing.T) {
	handle := openRunStore(t, newRoot(t))

	if _, err := handle.AcquireClaim(ClaimRequest{}); err == nil {
		t.Error("AcquireClaim with an empty id returned no error")
	}
	if _, err := handle.ReleaseClaim("", ""); err == nil {
		t.Error("ReleaseClaim with an empty id returned no error")
	}
	if err := handle.SaveRun(Run{}); err == nil {
		t.Error("SaveRun with an empty id returned no error")
	}
	if _, err := handle.StartAttempt(RunAttempt{}); err == nil {
		t.Error("StartAttempt with an empty id returned no error")
	}
	if _, err := handle.FinishAttempt(RunAttempt{}); err == nil {
		t.Error("FinishAttempt with an empty id returned no error")
	}

	finished, err := handle.FinishAttempt(RunAttempt{TaskID: "missing", Seq: 9, Status: RunFailed})
	if err != nil || finished {
		t.Errorf("FinishAttempt on an unknown attempt = %v, %v; want false, nil", finished, err)
	}
	run, found, err := handle.RunByTask("missing")
	if err != nil || found {
		t.Errorf("RunByTask(unknown) = %v, %v; want false, nil", found, err)
	}
	if run.TaskID != "" {
		t.Errorf("unknown run returned data: %+v", run)
	}
}
