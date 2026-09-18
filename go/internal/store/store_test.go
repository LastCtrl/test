package store

import (
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"agent-hq/internal/state"
)

// newRoot returns a temporary directory that looks like an agent-hq checkout:
// the .memory directory exists, everything else is created by the fixtures.
func newRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, state.MemoryDirName), 0o755); err != nil {
		t.Fatalf("mkdir .memory: %v", err)
	}
	return root
}

func writeFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// seedState writes one artifact of every kind the index covers.
func seedState(t *testing.T, root string) {
	t.Helper()
	writeFixture(t, filepath.Join(state.EvidenceDir(root), "run-1.json"), `{
		"task_id": "run-1",
		"attempts": [
			{
				"attempt_id": "a1", "agent": "dev-1", "command": "go test ./...",
				"exit_code": 0, "stdout_sha256": "aa", "stdout_length": 10,
				"stderr_sha256": "bb", "stderr_length": 2,
				"started_at": "2026-09-18T09:00:00.000", "finished_at": "2026-09-18T09:00:05.000",
				"duration_ms": 5000, "status": "success", "reason": "",
				"git_head": "abc", "git_diff_sha256": "dd", "host": "host-1", "pid": 123
			},
			{
				"attempt_id": "a2", "agent": "dev-2",
				"exit_code": 1, "status": "failed", "finished_at": "2026-09-18T09:01:00.000"
			}
		]
	}`)

	writeFixture(t, filepath.Join(state.ClaimsDir(root), "run-1.claim.json"),
		`{"task_id":"run-1","agent":"dev-1","claimed_at":"2026-09-18T09:00:00.000","heartbeat_at":"2026-09-18T09:10:00.000","lease_seconds":900,"attempt":1}`)
	writeFixture(t, filepath.Join(state.ClaimsDir(root), "run-9.claim.json"),
		`{"task_id":"run-9","agent":"dev-9","heartbeat_at":"2026-09-18T08:00:00.000"}`)

	writeFixture(t, filepath.Join(state.ProjectsDir(root), "alpha", state.QueueFileName), `{
		"tasks": [
			{"id":"t-1","title":"first","priority":"high","status":"queued","assigned_agent":"dev-1","created_at":"2026-09-18T08:00:00Z"},
			{"id":"t-2","title":"second","priority":"low","status":"done","retries":2,"created_at":"2026-09-18T08:05:00Z","started_at":"2026-09-18T08:06:00Z","completed_at":"2026-09-18T08:10:00Z"}
		]
	}`)
	writeFixture(t, filepath.Join(state.ProjectsDir(root), "beta", state.QueueFileName), `{"tasks":[]}`)

	writeFixture(t, filepath.Join(state.InboxDir(root), "dev-1", "msg-1.json"),
		`{"id":"msg-1","from":"team-lead","to":"dev-1","type":"task","priority":"high","payload":"do work","status":"pending","created_at":"2026-09-18T07:00:00Z"}`)
	writeFixture(t, filepath.Join(state.OutboxDir(root), "msg-2.json"),
		`{"id":"msg-2","from":"dev-1","to":"team-lead","type":"result","payload":{"files":["a"]},"status":"done","finishedAt":"2026-09-18T09:05:00Z"}`)
}

var fixtureNow = time.Date(2026, 9, 18, 10, 0, 0, 0, time.UTC)

func indexOnce(t *testing.T, handle *Store, root string, now time.Time) Counts {
	t.Helper()
	snapshot := state.Load(root, "test", 0, now)
	fingerprint, err := Fingerprint(root)
	if err != nil {
		t.Fatalf("Fingerprint: %v", err)
	}
	counts, err := handle.Index(snapshot, fingerprint, now)
	if err != nil {
		t.Fatalf("Index: %v", err)
	}
	return counts
}

func TestOpenCreatesSchemaAndRequiresMemory(t *testing.T) {
	root := newRoot(t)
	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer handle.Close()

	version, err := handle.SchemaVersion()
	if err != nil {
		t.Fatalf("SchemaVersion: %v", err)
	}
	if version != SchemaVersion {
		t.Errorf("schema version = %d, want %d", version, SchemaVersion)
	}

	for _, table := range []string{"meta", "projects", "tasks", "evidence", "evidence_attempts", "claims", "messages"} {
		var name string
		err := handle.db.QueryRow("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", table).Scan(&name)
		if err != nil {
			t.Errorf("table %s missing: %v", table, err)
		}
	}

	if _, err := Open(t.TempDir()); err == nil {
		t.Error("Open succeeded for a root without .memory, want an error")
	}
}

func TestOpenReadOnlyReportsMissingDatabase(t *testing.T) {
	root := newRoot(t)
	if _, err := OpenReadOnly(root); !errors.Is(err, ErrNotIndexed) {
		t.Fatalf("OpenReadOnly on a fresh root: err = %v, want ErrNotIndexed", err)
	}
	if _, err := os.Stat(Path(root)); !os.IsNotExist(err) {
		t.Errorf("read-only open created %s", Path(root))
	}
}

func TestIndexCountsAndIdempotency(t *testing.T) {
	root := newRoot(t)
	seedState(t, root)

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer handle.Close()

	first := indexOnce(t, handle, root, fixtureNow)
	want := Counts{Projects: 2, Tasks: 2, Evidence: 1, EvidenceAttempts: 2, Claims: 2, Messages: 2}
	if first != want {
		t.Fatalf("first index counts = %+v, want %+v", first, want)
	}

	second := indexOnce(t, handle, root, fixtureNow)
	if second != first {
		t.Errorf("second index counts = %+v, want the same as the first %+v", second, first)
	}

	stored, found, err := handle.FingerprintValue()
	if err != nil || !found {
		t.Fatalf("FingerprintValue: %v (found=%v)", err, found)
	}
	fresh, err := handle.IsFresh()
	if err != nil {
		t.Fatalf("IsFresh: %v", err)
	}
	if !fresh {
		t.Errorf("index not fresh right after indexing (%s)", stored)
	}
}

func TestIndexRemovesStaleRows(t *testing.T) {
	root := newRoot(t)
	seedState(t, root)

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer handle.Close()

	indexOnce(t, handle, root, fixtureNow)

	if err := os.Remove(filepath.Join(state.EvidenceDir(root), "run-1.json")); err != nil {
		t.Fatalf("remove evidence: %v", err)
	}
	counts := indexOnce(t, handle, root, fixtureNow)
	if counts.Evidence != 0 || counts.EvidenceAttempts != 0 {
		t.Errorf("after deleting the only evidence document counts = %+v, want no evidence rows", counts)
	}
}

// TestSnapshotMatchesFileLoad is the core compatibility guarantee: a snapshot
// read from a fresh index must equal one parsed straight from the files.
func TestSnapshotMatchesFileLoad(t *testing.T) {
	root := newRoot(t)
	seedState(t, root)

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer handle.Close()
	indexOnce(t, handle, root, fixtureNow)

	fromFiles := state.Load(root, "test", 0, fixtureNow)
	fromIndex, err := handle.Snapshot("test", 0, fixtureNow)
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}

	if got, want := fromIndex.Tasks(), fromFiles.Tasks(); !reflect.DeepEqual(got, want) {
		t.Errorf("tasks differ\n index: %+v\n files: %+v", got, want)
	}
	if !reflect.DeepEqual(fromIndex.Claims, fromFiles.Claims) {
		t.Errorf("claims differ\n index: %+v\n files: %+v", fromIndex.Claims, fromFiles.Claims)
	}
	if !reflect.DeepEqual(fromIndex.Evidence, fromFiles.Evidence) {
		t.Errorf("evidence differ\n index: %+v\n files: %+v", fromIndex.Evidence, fromFiles.Evidence)
	}
	if !reflect.DeepEqual(fromIndex.Inbox, fromFiles.Inbox) {
		t.Errorf("inbox differ\n index: %+v\n files: %+v", fromIndex.Inbox, fromFiles.Inbox)
	}
	if !reflect.DeepEqual(fromIndex.Outbox, fromFiles.Outbox) {
		t.Errorf("outbox differ\n index: %+v\n files: %+v", fromIndex.Outbox, fromFiles.Outbox)
	}
	if !reflect.DeepEqual(fromIndex.DeadLetter, fromFiles.DeadLetter) {
		t.Errorf("dead-letter differ\n index: %+v\n files: %+v", fromIndex.DeadLetter, fromFiles.DeadLetter)
	}

	// The payload may be a string or an object; the index must preserve both.
	if len(fromIndex.Outbox) != 1 {
		t.Fatalf("outbox = %d, want 1", len(fromIndex.Outbox))
	}
	if payload := fromIndex.Outbox[0].PayloadText(); !strings.Contains(payload, `"files"`) {
		t.Errorf("object payload did not survive the index: %q", payload)
	}
}

func TestIndexToleratesBrokenInputs(t *testing.T) {
	root := newRoot(t)
	seedState(t, root)
	writeFixture(t, filepath.Join(state.EvidenceDir(root), "broken.json"), `{not json`)
	writeFixture(t, filepath.Join(state.ProjectsDir(root), "broken", state.QueueFileName), `{oops`)

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer handle.Close()

	snapshot := state.Load(root, "test", 0, fixtureNow)
	if len(snapshot.Warnings) != 2 {
		t.Fatalf("warnings = %v, want 2 broken files", snapshot.Warnings)
	}
	fingerprint, err := Fingerprint(root)
	if err != nil {
		t.Fatalf("Fingerprint: %v", err)
	}
	counts, err := handle.Index(snapshot, fingerprint, fixtureNow)
	if err != nil {
		t.Fatalf("Index with broken inputs: %v", err)
	}
	if counts.Evidence != 1 || counts.Projects != 2 {
		t.Errorf("counts = %+v, want only the parseable artifacts", counts)
	}
}

func TestFreshnessDetectsChanges(t *testing.T) {
	root := newRoot(t)
	seedState(t, root)

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer handle.Close()
	indexOnce(t, handle, root, fixtureNow)

	fresh, err := handle.IsFresh()
	if err != nil || !fresh {
		t.Fatalf("IsFresh after index = %v, %v; want true, nil", fresh, err)
	}

	writeFixture(t, filepath.Join(state.EvidenceDir(root), "run-2.json"), `{"task_id":"run-2"}`)

	fresh, err = handle.IsFresh()
	if err != nil {
		t.Fatalf("IsFresh after change: %v", err)
	}
	if fresh {
		t.Error("IsFresh reported fresh after a new evidence document appeared")
	}
}

func TestFingerprintIsOrderIndependentAndDetectsRemoval(t *testing.T) {
	root := newRoot(t)
	seedState(t, root)

	first, err := Fingerprint(root)
	if err != nil {
		t.Fatalf("Fingerprint: %v", err)
	}
	second, err := Fingerprint(root)
	if err != nil {
		t.Fatalf("Fingerprint: %v", err)
	}
	if first != second {
		t.Errorf("fingerprint changed without a state change: %s vs %s", first, second)
	}

	if err := os.Remove(filepath.Join(state.OutboxDir(root), "msg-2.json")); err != nil {
		t.Fatalf("remove outbox message: %v", err)
	}
	third, err := Fingerprint(root)
	if err != nil {
		t.Fatalf("Fingerprint after removal: %v", err)
	}
	if third == first {
		t.Error("fingerprint did not change after a message was removed")
	}
}

func TestMessageCountsByScope(t *testing.T) {
	root := newRoot(t)
	seedState(t, root)

	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer handle.Close()
	indexOnce(t, handle, root, fixtureNow)

	scopes, err := handle.MessageCountsByScope()
	if err != nil {
		t.Fatalf("MessageCountsByScope: %v", err)
	}
	if scopes["inbox"] != 1 || scopes["outbox"] != 1 || scopes["dead-letter"] != 0 {
		t.Errorf("scope counts = %v, want inbox 1 / outbox 1 / dead-letter 0", scopes)
	}
}

func TestMigrationRejectsNewerSchema(t *testing.T) {
	root := newRoot(t)
	handle, err := Open(root)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := handle.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	raw, err := sql.Open(DriverName, Path(root))
	if err != nil {
		t.Fatalf("raw open: %v", err)
	}
	if _, err := raw.Exec("PRAGMA user_version = 99"); err != nil {
		t.Fatalf("set user_version: %v", err)
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("raw close: %v", err)
	}

	if _, err := Open(root); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Errorf("Open on a newer schema: err = %v, want a 'newer' error", err)
	}
}
