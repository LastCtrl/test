package store

import (
	"database/sql"
	"testing"
	"time"
)

func TestSessionMarkRoundTrip(t *testing.T) {
	handle, err := Open(newRoot(t))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = handle.Close() }()

	mark := SessionMark{TaskID: "t-1", Agent: "dev-2", Status: SessionInvalid,
		Reason: "session expired", MarkedAt: "2026-09-18T12:00:00Z"}
	if err := handle.MarkSessionInvalid(mark); err != nil {
		t.Fatalf("MarkSessionInvalid: %v", err)
	}
	if err := handle.MarkSessionInvalid(SessionMark{TaskID: "t-2", Agent: "dev-3",
		Status: SessionInvalid, Reason: "401 unauthorized"}); err != nil {
		t.Fatalf("MarkSessionInvalid second: %v", err)
	}

	count, err := handle.InvalidSessionCount()
	if err != nil || count != 2 {
		t.Fatalf("InvalidSessionCount = %d, %v; want 2", count, err)
	}

	// Re-marking the same task refreshes the reason instead of duplicating it.
	if err := handle.MarkSessionInvalid(SessionMark{TaskID: "t-1", Status: SessionInvalid,
		Reason: "session revoked", MarkedAt: "2026-09-18T13:00:00Z"}); err != nil {
		t.Fatalf("re-mark: %v", err)
	}
	stored, found, err := handle.SessionMarkByTask("t-1")
	if err != nil || !found {
		t.Fatalf("SessionMarkByTask = %+v (found=%v, err=%v)", stored, found, err)
	}
	if stored.Reason != "session revoked" || stored.MarkedAt != "2026-09-18T13:00:00Z" {
		t.Errorf("re-marked record = %+v, want the newer reason and timestamp", stored)
	}

	cleared, err := handle.ClearSession("t-1", time.Date(2026, 9, 18, 14, 0, 0, 0, time.UTC))
	if err != nil || !cleared {
		t.Fatalf("ClearSession = %v, %v; want true", cleared, err)
	}
	if again, err := handle.ClearSession("t-1", time.Now()); err != nil || again {
		t.Errorf("second ClearSession = %v, %v; want idempotent false", again, err)
	}
	count, err = handle.InvalidSessionCount()
	if err != nil || count != 1 {
		t.Fatalf("InvalidSessionCount after clear = %d, %v; want 1", count, err)
	}
	stored, _, _ = handle.SessionMarkByTask("t-1")
	if stored.Status != SessionCleared || stored.ClearedAt == "" {
		t.Errorf("cleared record = %+v, want status cleared with a timestamp", stored)
	}
}

func TestMarkSessionRejectsEmptyID(t *testing.T) {
	handle, err := Open(newRoot(t))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer func() { _ = handle.Close() }()

	if err := handle.MarkSessionInvalid(SessionMark{Reason: "no id"}); err == nil {
		t.Error("MarkSessionInvalid with an empty id must fail")
	}
	if _, err := handle.ClearSession("", time.Now()); err == nil {
		t.Error("ClearSession with an empty id must fail")
	}
}

// TestMigrationV3ToV4PreservesRuns builds a v3 database by hand, seeds a run and
// a checkpoint, then lets Open upgrade it: M2 history must survive and the new
// session table must be usable.
func TestMigrationV3ToV4PreservesRuns(t *testing.T) {
	root := newRoot(t)

	raw, err := sql.Open(DriverName, Path(root))
	if err != nil {
		t.Fatalf("raw open: %v", err)
	}
	for version, statements := range map[int][]string{1: schemaV1, 2: schemaV2, 3: schemaV3} {
		if err := apply(raw, statements); err != nil {
			t.Fatalf("apply v%d: %v", version, err)
		}
	}
	if _, err := raw.Exec(`INSERT INTO runs
			(task_id, agent, executor, payload, status, attempt, started_at, created_at, updated_at)
		VALUES ('run-m3', 'dev-2', 'fake', 'do work', 'running', 1,
			'2026-09-18T10:00:00Z', '2026-09-18T10:00:00Z', '2026-09-18T10:00:00Z')`); err != nil {
		t.Fatalf("seed v3 run: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO run_checkpoints (run_id, seq, path, state, created_at)
		VALUES ('run-m3', 1, 'src/app.go', 'step 1', '2026-09-18T10:05:00Z')`); err != nil {
		t.Fatalf("seed v3 checkpoint: %v", err)
	}
	if _, err := raw.Exec("PRAGMA user_version = 3"); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("raw close: %v", err)
	}

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open v3 database: %v", err)
	}
	defer func() { _ = handle.Close() }()

	version, err := handle.SchemaVersion()
	if err != nil || version != SchemaVersion {
		t.Fatalf("schema version = %d, %v; want %d", version, err, SchemaVersion)
	}
	run, found, err := handle.RunByTask("run-m3")
	if err != nil || !found || run.Payload != "do work" {
		t.Fatalf("run after migration = %+v (found=%v, err=%v)", run, found, err)
	}
	if _, found, err := handle.LatestCheckpoint("run-m3"); err != nil || !found {
		t.Fatalf("checkpoint after migration: found=%v err=%v", found, err)
	}
	if err := handle.MarkSessionInvalid(SessionMark{TaskID: "run-m3", Status: SessionInvalid}); err != nil {
		t.Errorf("MarkSessionInvalid after migration: %v", err)
	}
}
