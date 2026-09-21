package shadow

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
	"time"
)

var testNow = time.Date(2026, 9, 21, 12, 0, 0, 0, time.UTC)

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// stateDigest maps every file below root (except the shadow report directory)
// to its content hash and size, so a test can prove nothing else moved.
func stateDigest(t *testing.T, root string) map[string]string {
	t.Helper()
	digest := make(map[string]string)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return relErr
		}
		if entry.IsDir() {
			if rel == filepath.Join(stateMemoryDirName, "shadow") {
				return fs.SkipDir
			}
			return nil
		}
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		sum := sha256.Sum256(raw)
		digest[rel] = hex.EncodeToString(sum[:]) + ":" + strconv.Itoa(len(raw))
		return nil
	})
	if err != nil {
		t.Fatalf("digest walk: %v", err)
	}
	return digest
}

const stateMemoryDirName = ".memory"

func seedInbox(t *testing.T, root, agent, name, content string) {
	t.Helper()
	writeTestFile(t, filepath.Join(root, ".memory", "inbox", agent, name), content)
}

func seedOutbox(t *testing.T, root, name, content string) {
	t.Helper()
	writeTestFile(t, filepath.Join(root, ".memory", "outbox", name), content)
}

func findByID(t *testing.T, report *Report, id string) Step {
	t.Helper()
	for _, step := range report.Steps {
		if step.TaskID == id {
			return step
		}
	}
	t.Fatalf("step %q not found in %+v", id, report.Steps)
	return Step{}
}

func TestBuildPlansInboxAndQueue(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, ".opencode", "agents", "dev-2.json"),
		`{"name":"dev-2","model":"opencode-go/deepseek-v4.1-flash"}`)
	writeTestFile(t, filepath.Join(root, "opencode.json"),
		`{"agent":{"backend":{"model":"opencode/big-pickle"}}}`)
	seedInbox(t, root, "dev-2", "m-001.json",
		`{"id":"m-001","from":"team-lead","to":"dev-2","priority":"high","payload":"do work"}`)
	seedInbox(t, root, "backend", "m-002.json",
		`{"id":"m-002","from":"team-lead","payload":"other work"}`)
	writeTestFile(t, filepath.Join(root, "projects", "alpha", "queue.json"),
		`{"project":"alpha","tasks":[`+
			`{"id":"q-001","title":"queued item","priority":"normal","status":"queued","assigned_agent":"dev-2"},`+
			`{"id":"q-002","title":"finished item","status":"done","assigned_agent":"dev-2"}]}`)

	report := Build(root, "test", testNow)

	if report.Mode != Mode || !report.ReadOnly {
		t.Fatalf("report header = %+v, want shadow and read-only", report)
	}
	if report.Executor != DefaultExecutor {
		t.Fatalf("executor = %q, want %q", report.Executor, DefaultExecutor)
	}
	if report.CreatedAt != "2026-09-21T12:00:00Z" {
		t.Errorf("created_at = %q, want the fixed timestamp", report.CreatedAt)
	}

	inboxDirect := findByID(t, report, "m-001")
	if inboxDirect.Source != SourceInbox || inboxDirect.Agent != "dev-2" ||
		inboxDirect.Model != "opencode-go/deepseek-v4.1-flash" ||
		inboxDirect.Route != RouteDirect || inboxDirect.Action != ActionRun {
		t.Errorf("m-001 = %+v, want direct inbox run as dev-2", inboxDirect)
	}

	inboxFolder := findByID(t, report, "m-002")
	if inboxFolder.Agent != "backend" || inboxFolder.Model != "opencode/big-pickle" ||
		inboxFolder.Route != RouteFolder || inboxFolder.Action != ActionRun {
		t.Errorf("m-002 = %+v, want folder-routed inbox run as backend", inboxFolder)
	}

	queued := findByID(t, report, "q-001")
	if queued.Source != SourceQueue || queued.Project != "alpha" || queued.Agent != "dev-2" ||
		queued.Route != RouteAssigned || queued.Action != ActionRun || queued.ProcessedByPS {
		t.Errorf("q-001 = %+v, want an actionable assigned queue item", queued)
	}

	done := findByID(t, report, "q-002")
	if done.Action != ActionSkip || !done.ProcessedByPS || done.Reason != ReasonProcessed {
		t.Errorf("q-002 = %+v, want a processed skip", done)
	}

	want := Summary{Total: 4, WouldRun: 3, WouldSkip: 1, ProcessedByPS: 1, Inbox: 2, Queue: 2}
	if report.Summary != want {
		t.Errorf("summary = %+v, want %+v", report.Summary, want)
	}
}

func TestBuildMarksProcessedByPS(t *testing.T) {
	root := t.TempDir()
	seedInbox(t, root, "dev-2", "m-003.json",
		`{"id":"m-003","to":"dev-2","payload":"already handled"}`)
	seedOutbox(t, root, "m-003.json",
		`{"id":"m-003","to":"dev-2","status":"done","response":"ok"}`)

	writeTestFile(t, filepath.Join(root, "projects", "beta", "queue.json"),
		`{"project":"beta","tasks":[{"id":"q-010","title":"shipped","status":"queued","assigned_agent":"dev-2"}]}`)
	writeTestFile(t, filepath.Join(root, ".memory", "evidence", "q-010.json"),
		`{"task_id":"q-010","attempts":[{"status":"success","exit_code":0}]}`)

	report := Build(root, "test", testNow)

	message := findByID(t, report, "m-003")
	if message.Action != ActionSkip || !message.ProcessedByPS || message.Reason != ReasonProcessed {
		t.Errorf("m-003 = %+v, want processed-by-ps skip", message)
	}

	queue := findByID(t, report, "q-010")
	if queue.Action != ActionSkip || !queue.ProcessedByPS || queue.Reason != ReasonProcessed {
		t.Errorf("q-010 = %+v, want processed-by-ps skip from evidence", queue)
	}
}

func TestBuildSkipsTaskWithoutAgent(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "projects", "gamma", "queue.json"),
		`{"project":"gamma","tasks":[{"id":"q-020","title":"unrouted","status":"queued"}]}`)

	report := Build(root, "test", testNow)
	step := findByID(t, report, "q-020")
	if step.Action != ActionSkip || step.Reason != ReasonNoAgent || step.ProcessedByPS {
		t.Errorf("q-020 = %+v, want a no-target-agent skip", step)
	}
}

func TestBuildToleratesBrokenInputs(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "opencode.json"), `{"agent":`)
	seedInbox(t, root, "dev-2", "broken.json", `{"id":`)
	seedInbox(t, root, "dev-2", "m-004.json",
		`{"id":"m-004","to":"dev-2","payload":"still planned"}`)

	report := Build(root, "test", testNow)

	if report == nil {
		t.Fatal("report is nil")
	}
	if len(report.Warnings) == 0 {
		t.Error("warnings = 0, want at least one for the broken config and inbox file")
	}
	step := findByID(t, report, "m-004")
	if step.Action != ActionRun || step.Agent != "dev-2" {
		t.Errorf("m-004 = %+v, want a run step despite the broken neighbour", step)
	}
}

func TestWriteLeavesStateUnchanged(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "opencode.json"),
		`{"agent":{"dev-2":{"model":"opencode-go/deepseek-v4.1-flash"}}}`)
	seedInbox(t, root, "dev-2", "m-005.json",
		`{"id":"m-005","to":"dev-2","payload":"plan me"}`)
	seedOutbox(t, root, "m-006.json", `{"id":"m-006","status":"done"}`)
	writeTestFile(t, filepath.Join(root, "projects", "alpha", "queue.json"),
		`{"project":"alpha","tasks":[{"id":"q-030","status":"queued","assigned_agent":"dev-2"}]}`)
	writeTestFile(t, filepath.Join(root, ".memory", "claims", "q-030.claim.json"),
		`{"task_id":"q-030","agent":"dev-2","heartbeat_at":"2026-09-21T11:00:00Z"}`)

	before := stateDigest(t, root)

	report := Build(root, "test", testNow)
	path := ReportPath(root, testNow)
	report.Path = path
	if err := Write(path, report); err != nil {
		t.Fatalf("Write: %v", err)
	}

	after := stateDigest(t, root)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("state changed:\nbefore=%v\nafter=%v", before, after)
	}

	if filepath.Base(path) != "20260921T120000.000000000Z.json" {
		t.Errorf("report name = %q, want the timestamped name", filepath.Base(path))
	}
	if filepath.Base(filepath.Dir(path)) != "shadow" {
		t.Errorf("report dir = %q, want the shadow directory", filepath.Dir(path))
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read report: %v", err)
	}
	var decoded Report
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("report is not valid json: %v", err)
	}
	if decoded.Mode != Mode || !decoded.ReadOnly || decoded.Summary.Total != 2 {
		t.Errorf("decoded report = %+v, want shadow, read-only and two steps", decoded)
	}
}
