package loop

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agent-hq/internal/bus"
	"agent-hq/internal/driver"
	"agent-hq/internal/executor"
)

// newLoopRoot builds a minimal agent-hq root the runner accepts.
func newLoopRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, dir := range []string{
		filepath.Join(root, ".memory", "inbox", "dev-2"),
		filepath.Join(root, ".memory", "outbox"),
		filepath.Join(root, ".memory", "dead-letter"),
		filepath.Join(root, ".memory", "archive"),
		filepath.Join(root, ".memory", "claims"),
		filepath.Join(root, ".memory", "evidence"),
		filepath.Join(root, "projects", "alpha"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "CONTEXT-BUFFER.md"), []byte("ctx\n"), 0o644); err != nil {
		t.Fatalf("context buffer: %v", err)
	}
	return root
}

func writeLoopFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func newRunner(t *testing.T, root string, worker executor.Executor, options Options) *Runner {
	t.Helper()
	options.Root = root
	options.Executor = worker
	options.Once = true
	runner, err := New(options)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = runner.Close() })
	return runner
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatalf("%s is not valid json: %v", path, err)
	}
	return document
}

func TestPassPublishesSuccessLikePowerShell(t *testing.T) {
	root := newLoopRoot(t)
	t.Setenv("USERPROFILE", t.TempDir()) // keep the real vault out of the plan
	writeLoopFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "m-1.json"),
		`{"id":"m-1","from":"team-lead","to":"dev-2","priority":"high","payload":"do the thing"}`)

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{})
	report := runner.Run(context.Background())

	if report.Processed != 1 || report.Done != 1 {
		t.Fatalf("report = %+v, want one done item", report)
	}
	item := report.Items[0]
	if item.Source != SourceInbox || item.TaskID != "m-1" || item.Agent != "dev-2" || item.Attempts != 1 {
		t.Fatalf("item = %+v", item)
	}

	outbox := readJSON(t, filepath.Join(root, ".memory", "outbox", "m-1.json"))
	if outbox["status"] != "done" || outbox["id"] != "m-1" || outbox["to"] != "dev-2" {
		t.Errorf("outbox = %+v", outbox)
	}
	if outbox["evidence"] != ".memory/evidence/m-1.json" {
		t.Errorf("evidence field = %v", outbox["evidence"])
	}
	if response, _ := outbox["response"].(string); !strings.Contains(response, "STATUS: resolved") {
		t.Errorf("response = %v", outbox["response"])
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "archive", "dev-2-m-1.json")); err != nil {
		t.Errorf("inbox file was not archived: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "inbox", "dev-2", "m-1.json")); !os.IsNotExist(err) {
		t.Errorf("inbox file survived")
	}
	evidence := readJSON(t, filepath.Join(root, ".memory", "evidence", "m-1.json"))
	if attempts, _ := evidence["attempts"].([]any); len(attempts) != 1 {
		t.Errorf("evidence attempts = %v", evidence["attempts"])
	}
	// Both leases are released on the terminal path.
	if _, err := os.Stat(filepath.Join(root, ".memory", "claims", "m-1.claim.json")); !os.IsNotExist(err) {
		t.Errorf("file lease was not released")
	}
	claims, err := runner.store.RunClaims()
	if err != nil {
		t.Fatalf("RunClaims: %v", err)
	}
	if len(claims) != 0 {
		t.Errorf("sqlite leases = %+v, want none", claims)
	}
	// A scheduled `-once` pass must leave a fresh heartbeat behind: that is what
	// keeps the PowerShell poller standing down between two scheduled passes.
	lock, ok := driver.ReadLock(root)
	if !ok {
		t.Fatal("driver.lock is missing after an -once pass: the PS guard sees no heartbeat")
	}
	if lock.Mode != driver.ModeGo || !driver.Alive(root, driver.DefaultLockTTL) {
		t.Errorf("driver.lock is not a fresh go heartbeat: %+v", lock)
	}
}

func TestPassDeadLettersAfterRetry(t *testing.T) {
	root := newLoopRoot(t)
	writeLoopFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "m-2.json"),
		`{"id":"m-2","from":"team-lead","to":"dev-2","payload":"broken worker"}`)

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeFail), Options{})
	report := runner.Run(context.Background())

	if report.DeadLetter != 1 {
		t.Fatalf("report = %+v, want one dead-letter item", report)
	}
	deadLetter := readJSON(t, filepath.Join(root, ".memory", "dead-letter", "m-2.json"))
	if deadLetter["status"] != "failed" || deadLetter["type"] != "failed" {
		t.Errorf("dead-letter = %+v", deadLetter)
	}
	response, _ := deadLetter["response"].(string)
	for _, want := range []string{"First attempt failed:", "Retry failed:", "--- STDOUT ---"} {
		if !strings.Contains(response, want) {
			t.Errorf("dead-letter response missing %q: %s", want, response)
		}
	}
	evidence := readJSON(t, filepath.Join(root, ".memory", "evidence", "m-2.json"))
	if attempts, _ := evidence["attempts"].([]any); len(attempts) != 2 {
		t.Errorf("evidence attempts = %v, want 2", evidence["attempts"])
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "inbox", "dev-2", "m-2.json")); !os.IsNotExist(err) {
		t.Errorf("inbox file survived the dead-letter path")
	}
}

func TestPassMovesUnparsedFileToDeadLetter(t *testing.T) {
	root := newLoopRoot(t)
	broken := filepath.Join(root, ".memory", "inbox", "dev-2", "m-broken.json")
	writeLoopFile(t, broken, `{"id": "m-broken", `)

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{})
	report := runner.Run(context.Background())

	item := report.Items[0]
	if item.Status != StatusDeadLetter || item.Reason != "parse-error" {
		t.Fatalf("item = %+v, want dead-letter/parse-error", item)
	}
	// The raw bytes are preserved, exactly like the PowerShell parse-error branch.
	moved := readFileString(t, filepath.Join(root, ".memory", "dead-letter", "m-broken.json"))
	if moved != `{"id": "m-broken", ` {
		t.Errorf("dead-letter content = %q", moved)
	}
	if _, err := os.Stat(broken); !os.IsNotExist(err) {
		t.Errorf("broken inbox file survived")
	}
}

func TestPassDeadLettersEmptyPayload(t *testing.T) {
	root := newLoopRoot(t)
	writeLoopFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "m-empty.json"),
		`{"id":"m-empty","to":"dev-2","payload":""}`)

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{})
	report := runner.Run(context.Background())

	item := report.Items[0]
	if item.Status != StatusDeadLetter || item.Reason != "empty-payload" {
		t.Fatalf("item = %+v, want dead-letter/empty-payload", item)
	}
	deadLetter := readJSON(t, filepath.Join(root, ".memory", "dead-letter", "m-empty.json"))
	if !strings.Contains(deadLetter["response"].(string), "Empty payload") {
		t.Errorf("response = %v", deadLetter["response"])
	}
}

func TestPassSkipsAlreadyClaimedMessage(t *testing.T) {
	root := newLoopRoot(t)
	writeLoopFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "m-3.json"),
		`{"id":"m-3","to":"dev-2","payload":"pick me"}`)
	// Another driver owns the file lease.
	owned, err := bus.ClaimFile(bus.ClaimsDir(root), "m-3", "dev-9", 900, 1)
	if err != nil || !owned {
		t.Fatalf("pre-claim = %v, %v", owned, err)
	}

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{})
	report := runner.Run(context.Background())

	if report.Skipped != 1 {
		t.Fatalf("report = %+v, want one skipped item", report)
	}
	if report.Items[0].Reason != "already-claimed" {
		t.Errorf("reason = %q", report.Items[0].Reason)
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "outbox", "m-3.json")); !os.IsNotExist(err) {
		t.Errorf("a claimed message was processed anyway")
	}
}

func TestPassHonoursMax(t *testing.T) {
	root := newLoopRoot(t)
	for _, id := range []string{"m-10", "m-11", "m-12"} {
		writeLoopFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", id+".json"),
			`{"id":"`+id+`","to":"dev-2","payload":"work"}`)
	}

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{Max: 2})
	report := runner.Run(context.Background())

	if report.Processed != 2 {
		t.Fatalf("processed = %d, want 2 (-max)", report.Processed)
	}
}

func TestPassProcessesQueueTaskToDone(t *testing.T) {
	root := newLoopRoot(t)
	writeLoopFile(t, filepath.Join(root, "projects", "alpha", "queue.json"),
		`{"project":"alpha","tasks":[{"id":"tq-001","title":"queued work","status":"queued","priority":"normal","assigned_agent":"dev-2","custom_field":"keep"}]}`)

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{Queue: true})
	report := runner.Run(context.Background())

	if len(report.Items) != 1 || report.Items[0].Source != SourceQueue {
		t.Fatalf("report = %+v", report)
	}
	if report.Items[0].Status != StatusDone {
		t.Fatalf("queue item = %+v, want done", report.Items[0])
	}
	queue := readJSON(t, filepath.Join(root, "projects", "alpha", "queue.json"))
	tasks, _ := queue["tasks"].([]any)
	task, _ := tasks[0].(map[string]any)
	if task["status"] != "done" || task["completed_at"] == nil {
		t.Errorf("queue task = %+v", task)
	}
	if task["custom_field"] != "keep" {
		t.Errorf("queue task lost its unknown field: %+v", task)
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "evidence", "tq-001.json")); err != nil {
		t.Errorf("no evidence for the queue task: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "outbox", "tq-001.json")); !os.IsNotExist(err) {
		t.Errorf("a queue task must not write a bus envelope")
	}
}

func TestPassMarksFailedQueueTaskDead(t *testing.T) {
	root := newLoopRoot(t)
	writeLoopFile(t, filepath.Join(root, "projects", "alpha", "queue.json"),
		`{"project":"alpha","tasks":[{"id":"tq-002","title":"doomed","status":"assigned","assigned_agent":"dev-2"}]}`)

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeFail), Options{Queue: true})
	report := runner.Run(context.Background())

	if report.Items[0].Status != StatusDead {
		t.Fatalf("queue item = %+v, want dead", report.Items[0])
	}
	queue := readJSON(t, filepath.Join(root, "projects", "alpha", "queue.json"))
	tasks, _ := queue["tasks"].([]any)
	task, _ := tasks[0].(map[string]any)
	if task["status"] != "dead" || task["dead_reason"] == nil || task["dead_at"] == nil {
		t.Errorf("queue task = %+v", task)
	}
}

func TestRecoverStaleReleasesForeignLease(t *testing.T) {
	root := newLoopRoot(t)
	// A file lease that expired two hours ago.
	stale := bus.FileClaim{
		TaskID: "m-stale", Agent: "dev-9", LeaseSeconds: 60,
		ClaimedAt:   bus.FormatClaimTime(time.Now().Add(-2 * time.Hour)),
		HeartbeatAt: bus.FormatClaimTime(time.Now().Add(-2 * time.Hour)),
	}
	encoded, err := json.Marshal(stale)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	writeLoopFile(t, bus.ClaimFilePath(bus.ClaimsDir(root), "m-stale"), string(encoded))

	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{StaleTTL: time.Minute})
	report := runner.Run(context.Background())

	if len(report.Recovered) != 1 || report.Recovered[0] != "m-stale" {
		t.Fatalf("recovered = %v, want [m-stale]", report.Recovered)
	}
	if _, err := os.Stat(bus.ClaimFilePath(bus.ClaimsDir(root), "m-stale")); !os.IsNotExist(err) {
		t.Errorf("stale lease survived the sweep")
	}
}

func TestRunRejectsNonAgentHQRoot(t *testing.T) {
	// A directory without .memory must be refused: the loop writes state.
	empty := t.TempDir()
	if _, err := New(Options{Root: empty, Executor: executor.NewFakeExecutor(executor.FakeSuccess)}); err == nil {
		t.Fatal("New accepted a root without .memory")
	}
}

func TestRunDaemonRemovesLivenessOnShutdown(t *testing.T) {
	root := newLoopRoot(t)
	runner := newRunner(t, root, executor.NewFakeExecutor(executor.FakeSuccess), Options{})
	runner.options.Once = false
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // a cancelled context is the daemon's clean shutdown
	_ = runner.Run(ctx)

	if _, err := os.Stat(filepath.Join(root, ".memory", "driver.lock")); !os.IsNotExist(err) {
		t.Errorf("driver.lock was not cleaned up at daemon shutdown")
	}
}

func readFileString(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(raw)
}
