package store

import (
	"database/sql"
	"testing"
	"time"
)

func TestCheckpointRoundTrip(t *testing.T) {
	handle := openRunStore(t, newRoot(t))

	first, err := handle.SaveCheckpoint(RunCheckpoint{RunID: "run-1", State: "step 1"})
	if err != nil || first != 1 {
		t.Fatalf("first SaveCheckpoint = %d, %v; want 1, nil", first, err)
	}
	second, err := handle.SaveCheckpoint(RunCheckpoint{RunID: "run-1", Path: "src/app.go",
		State: "step 2", CreatedAt: runStart.Format(time.RFC3339Nano)})
	if err != nil || second != 2 {
		t.Fatalf("second SaveCheckpoint = %d, %v; want 2, nil", second, err)
	}

	// An identical retry of the latest state is a no-op, not a duplicate.
	retry, err := handle.SaveCheckpoint(RunCheckpoint{RunID: "run-1", Path: "src/app.go", State: "step 2"})
	if err != nil || retry != 2 {
		t.Errorf("identical retry = %d, %v; want the existing sequence 2", retry, err)
	}

	checkpoints, err := handle.Checkpoints("run-1")
	if err != nil {
		t.Fatalf("Checkpoints: %v", err)
	}
	if len(checkpoints) != 2 {
		t.Fatalf("checkpoints = %+v, want 2 (identical retry must not append)", checkpoints)
	}
	if checkpoints[0].Seq != 1 || checkpoints[0].State != "step 1" || checkpoints[0].CreatedAt == "" {
		t.Errorf("checkpoint 1 = %+v, want step 1 with a timestamp", checkpoints[0])
	}
	if checkpoints[1].Seq != 2 || checkpoints[1].Path != "src/app.go" || checkpoints[1].State != "step 2" {
		t.Errorf("checkpoint 2 = %+v, want the second handoff", checkpoints[1])
	}
	if checkpoints[1].CreatedAt != runStart.Format(time.RFC3339Nano) {
		t.Errorf("explicit created_at was not preserved: %q", checkpoints[1].CreatedAt)
	}

	latest, found, err := handle.LatestCheckpoint("run-1")
	if err != nil || !found || latest.Seq != 2 {
		t.Errorf("LatestCheckpoint = %+v (found=%v, err=%v), want seq 2", latest, found, err)
	}

	if _, found, err := handle.LatestCheckpoint("missing"); err != nil || found {
		t.Errorf("LatestCheckpoint(missing) found=%v err=%v; want false, nil", found, err)
	}
	empty, err := handle.Checkpoints("missing")
	if err != nil || len(empty) != 0 {
		t.Errorf("Checkpoints(missing) = %+v, %v; want empty", empty, err)
	}
}

func TestCheckpointRejectsBrokenInputs(t *testing.T) {
	handle := openRunStore(t, newRoot(t))

	if _, err := handle.SaveCheckpoint(RunCheckpoint{}); err == nil {
		t.Error("SaveCheckpoint with an empty run id returned no error")
	}
	if _, err := handle.Checkpoints(""); err == nil {
		t.Error("Checkpoints with an empty run id returned no error")
	}
	if _, _, err := handle.LatestCheckpoint(""); err == nil {
		t.Error("LatestCheckpoint with an empty run id returned no error")
	}
}

// TestMigrationV2ToV3PreservesRuns builds a real v2 database by hand, writes a
// run into it, then lets Open upgrade it. The M1 history must survive and the
// new checkpoint table must be usable.
func TestMigrationV2ToV3PreservesRuns(t *testing.T) {
	root := newRoot(t)

	raw, err := sql.Open(DriverName, Path(root))
	if err != nil {
		t.Fatalf("raw open: %v", err)
	}
	if err := apply(raw, schemaV1); err != nil {
		t.Fatalf("apply v1: %v", err)
	}
	if err := apply(raw, schemaV2); err != nil {
		t.Fatalf("apply v2: %v", err)
	}
	if _, err := raw.Exec(`INSERT INTO runs
			(task_id, agent, executor, payload, status, attempt, started_at, created_at, updated_at)
		VALUES ('run-1', 'dev-2', 'fake', 'do work', 'running', 1,
			'2026-09-18T10:00:00Z', '2026-09-18T10:00:00Z', '2026-09-18T10:00:00Z')`); err != nil {
		t.Fatalf("seed v2 run: %v", err)
	}
	if _, err := raw.Exec("PRAGMA user_version = 2"); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("raw close: %v", err)
	}

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open v2 database: %v", err)
	}
	defer func() { _ = handle.Close() }()

	version, err := handle.SchemaVersion()
	if err != nil || version != SchemaVersion {
		t.Fatalf("schema version = %d, %v; want %d", version, err, SchemaVersion)
	}

	run, found, err := handle.RunByTask("run-1")
	if err != nil || !found || run.Payload != "do work" {
		t.Fatalf("run after migration = %+v (found=%v, err=%v); want the seeded run", run, found, err)
	}

	if _, err := handle.SaveCheckpoint(RunCheckpoint{RunID: "run-1", State: "after migration"}); err != nil {
		t.Errorf("SaveCheckpoint after migration: %v", err)
	}
}
