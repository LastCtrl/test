package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"agent-hq/internal/shadow"
)

// shadow_rich_test.go is the enhanced M5 shadow re-verification: a rich fixture
// (several agents, mixed queue statuses, already processed work, broken and empty
// inbox files, an unknown target agent) is planned by `agent-hq shadow` and the
// plan is then compared with the FACTS - what the PowerShell engine actually
// processes on a copy of the same fixture, and what the Go run-loop actually does
// with the queue. The read-only invariant is asserted with a whole-tree digest.

func richShadowFixture(t *testing.T) string {
	t.Helper()
	root := tempRoot(t)
	files := map[string]string{
		"opencode.json":                        `{"agent":{"dev-2":{"model":"opencode-go/deepseek-v4.1-flash"},"qa-engineer":{"model":"opencode-go/qwen3.8-flash"}}}`,
		"CONTEXT-BUFFER.md":                    "context\n",
		".memory/inbox/dev-2/m-200.json":       `{"id":"m-200","from":"team-lead","to":"dev-2","priority":"high","payload":"task A"}`,
		".memory/inbox/qa-engineer/m-201.json": `{"id":"m-201","from":"team-lead","payload":"task B"}`,
		".memory/inbox/dev-2/m-202.json":       `{"id":"m-202","from":"team-lead","to":"ghost-agent","payload":"task C"}`,
		".memory/inbox/dev-2/broken.json":      `{"id": "broken", `,
		".memory/inbox/dev-2/empty.json":       "",
		".memory/outbox/m-100.json":            `{"id":"m-100","to":"dev-2","status":"done","response":"already delivered"}`,
		".memory/dead-letter/m-101.json":       `{"id":"m-101","to":"dev-2","status":"failed","response":"already parked"}`,
		".memory/evidence/q-100.json":          `{"task_id":"q-100","attempts":[{"attempt_id":"attempt-1","agent":"dev-2","status":"success","exit_code":0}]}`,
		"projects/alpha/queue.json": `{"project":"alpha","tasks":[
			{"id":"q-100","title":"has evidence","status":"queued","priority":"high","assigned_agent":"dev-2"},
			{"id":"q-101","title":"finished","status":"done","priority":"normal","assigned_agent":"dev-2"},
			{"id":"q-102","title":"given up","status":"dead","priority":"low","assigned_agent":"dev-2"},
			{"id":"q-103","title":"ready to run","status":"queued","priority":"critical","assigned_agent":"dev-2"},
			{"id":"q-104","title":"nobody assigned","status":"assigned","priority":"normal","assigned_agent":""},
			{"id":"q-105","title":"assigned to qa","status":"assigned","priority":"high","assigned_agent":"qa-engineer"}
		]}`,
	}
	for name, content := range files {
		writeShadowFile(t, filepath.Join(root, filepath.FromSlash(name)), content)
	}
	return root
}

func copyTree(t *testing.T, source, target string) {
	t.Helper()
	err := filepath.Walk(source, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, relErr := filepath.Rel(source, path)
		if relErr != nil {
			return relErr
		}
		destination := filepath.Join(target, relative)
		if info.IsDir() {
			return os.MkdirAll(destination, 0o755)
		}
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		if mkErr := os.MkdirAll(filepath.Dir(destination), 0o755); mkErr != nil {
			return mkErr
		}
		return os.WriteFile(destination, raw, 0o644)
	})
	if err != nil {
		t.Fatalf("copy tree: %v", err)
	}
}

func planShadow(t *testing.T, root string) *shadow.Report {
	t.Helper()
	t.Setenv("AGENT_HQ_ROOT", "")
	var stdout, stderr bytes.Buffer
	code := run([]string{"shadow", "-root", root, "-json"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("shadow exit = %d, stderr = %s", code, stderr.String())
	}
	var report shadow.Report
	if err := json.Unmarshal(stdout.Bytes(), &report); err != nil {
		t.Fatalf("shadow output is not json: %v\n%s", err, stdout.String())
	}
	return &report
}

func TestRunShadowPlanMatchesEngineFacts(t *testing.T) {
	root := richShadowFixture(t)
	before := shadowDigest(t, root)

	report := planShadow(t, root)
	if !report.ReadOnly || report.Mode != shadow.Mode {
		t.Fatalf("report = mode %q read_only %v", report.Mode, report.ReadOnly)
	}
	if !reflect.DeepEqual(before, shadowDigest(t, root)) {
		t.Fatalf("the shadow pass mutated the state tree")
	}

	plan := classifyPlan(report)
	// Planned actions on the rich fixture.
	wantInboxRun := []string{"m-200", "m-201", "m-202"}
	wantQueueRun := []string{"q-103", "q-105"}
	wantQueueSkip := []string{"q-100", "q-101", "q-102", "q-104"}
	if !reflect.DeepEqual(plan[shadow.ActionRun][shadow.SourceInbox], wantInboxRun) {
		t.Errorf("planned inbox runs = %v, want %v", plan[shadow.ActionRun][shadow.SourceInbox], wantInboxRun)
	}
	if !reflect.DeepEqual(plan[shadow.ActionRun][shadow.SourceQueue], wantQueueRun) {
		t.Errorf("planned queue runs = %v, want %v", plan[shadow.ActionRun][shadow.SourceQueue], wantQueueRun)
	}
	if !reflect.DeepEqual(plan[shadow.ActionSkip][shadow.SourceQueue], wantQueueSkip) {
		t.Errorf("planned queue skips = %v, want %v", plan[shadow.ActionSkip][shadow.SourceQueue], wantQueueSkip)
	}

	// Routing and model resolution.
	for _, step := range report.Steps {
		switch step.TaskID {
		case "m-200":
			if step.Route != shadow.RouteDirect || step.Model == "" {
				t.Errorf("m-200 = %+v, want direct route and a resolved model", step)
			}
		case "m-201":
			if step.Agent != "qa-engineer" || step.Route != shadow.RouteFolder {
				t.Errorf("m-201 = %+v, want folder routing to qa-engineer", step)
			}
		case "m-202":
			if step.Agent != "ghost-agent" || step.Action != shadow.ActionRun || step.Model != "" {
				t.Errorf("m-202 = %+v, want a run for the unknown agent without a model", step)
			}
		case "q-104":
			if step.Reason != shadow.ReasonNoAgent {
				t.Errorf("q-104 = %+v, want no-target-agent", step)
			}
		case "q-100":
			if !step.ProcessedByPS || step.Reason != shadow.ReasonProcessed {
				t.Errorf("q-100 = %+v, want processed-by-ps (successful evidence)", step)
			}
		}
	}

	// Broken and empty inbox files are reported as warnings, never as steps and
	// never as a crash.
	joined := strings.Join(report.Warnings, "\n")
	for _, want := range []string{"broken.json", "empty.json"} {
		if !strings.Contains(joined, want) {
			t.Errorf("warnings do not mention %s: %v", want, report.Warnings)
		}
	}
	for _, step := range report.Steps {
		if step.TaskID == "broken" || step.TaskID == "empty" {
			t.Errorf("a malformed inbox file became a step: %+v", step)
		}
	}

	// FACT 1: the PowerShell engine on a copy of the same fixture archives exactly
	// the messages the plan called would-run - nothing more, nothing less.
	psRoot := filepath.Join(tempRoot(t), "ps-copy")
	copyTree(t, root, psRoot)
	runPowerShellEngineOnRoot(t, psRoot, "success")
	archived := archivedMessageIDs(t, psRoot)
	if !reflect.DeepEqual(archived, wantInboxRun) {
		t.Errorf("engine archived %v, plan predicted %v", archived, wantInboxRun)
	}
	for _, untouched := range []string{
		filepath.Join(".memory", "outbox", "m-100.json"),
		filepath.Join(".memory", "dead-letter", "m-101.json"),
	} {
		if _, err := os.Stat(filepath.Join(psRoot, untouched)); err != nil {
			t.Errorf("pre-existing artifact %s disappeared: %v", untouched, err)
		}
	}

	// FACT 2: the Go run-loop on another copy performs exactly the planned queue
	// transitions (the queue has no PowerShell executor to compare against).
	goRoot := filepath.Join(tempRoot(t), "go-copy")
	copyTree(t, root, goRoot)
	t.Setenv("AGENT_HQ_ROOT", "")
	t.Setenv("AGENT_HQ_DRIVER", "")
	t.Setenv("AGENT_HQ_OPENCODE", "")
	t.Setenv("AGENT_HQ_FAKE_MODE", "success")
	var stdout, stderr bytes.Buffer
	if code := run([]string{"run-loop", "-root", goRoot, "-once", "-json", "-executor", "fake"}, &stdout, &stderr); code != 0 {
		t.Fatalf("run-loop exit = %d, stderr = %s", code, stderr.String())
	}
	if !hasQueueStatus(t, goRoot, "q-103", "done") || !hasQueueStatus(t, goRoot, "q-105", "done") {
		t.Errorf("run-loop did not complete the planned queue tasks")
	}
	// q-100 has success evidence but was still pending: the driver must reconcile
	// it to done instead of running it again, exactly as the plan predicted.
	if !hasQueueStatus(t, goRoot, "q-100", "done") {
		t.Errorf("run-loop did not reconcile the already-completed task q-100")
	}
	for _, id := range []string{"q-101", "q-102", "q-104"} {
		if !queueStatusUnchanged(t, goRoot, id) {
			t.Errorf("run-loop touched a task the plan said to skip: %s", id)
		}
	}
}

// runPowerShellEngineOnRoot drives the real poller against a prepared root.
func runPowerShellEngineOnRoot(t *testing.T, root, mode string) {
	t.Helper()
	repoRoot := parityRepoRoot(t)
	fakeCli := filepath.Join(repoRoot, "tests", "fake-opencode.ps1")
	if _, err := exec.LookPath("powershell"); err != nil {
		t.Skip("powershell is not available")
	}
	poller := filepath.Join(repoRoot, ".agents", "scripts", "inbox-poller.ps1")
	command := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-File", poller, "-Once")
	command.Dir = repoRoot
	command.Env = append(os.Environ(),
		"AGENT_HQ_ROOT="+root,
		"AGENT_HQ_OPENCODE="+fakeCli,
		"FAKE_OPENCODE_MODE="+mode,
		"AGENT_HQ_DRIVER=",
	)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("powershell inbox-poller failed: %v\n%s", err, output)
	}
}

// archivedMessageIDs lists the inbox messages the engine archived, sorted.
func archivedMessageIDs(t *testing.T, root string) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(root, ".memory", "archive"))
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}
		}
		t.Fatalf("read archive: %v", err)
	}
	ids := make([]string, 0, len(entries))
	for _, entry := range entries {
		name := strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))
		if index := strings.Index(name, "-m-"); index >= 0 {
			name = name[index+1:]
		}
		ids = append(ids, name)
	}
	sort.Strings(ids)
	return ids
}

func queueStatusOf(t *testing.T, root, taskID string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(root, "projects", "alpha", "queue.json"))
	if err != nil {
		t.Fatalf("read queue: %v", err)
	}
	var document struct {
		Tasks []map[string]any `json:"tasks"`
	}
	if err := json.Unmarshal(raw, &document); err != nil {
		t.Fatalf("queue json: %v", err)
	}
	for _, task := range document.Tasks {
		if id, _ := task["id"].(string); id == taskID {
			status, _ := task["status"].(string)
			return status
		}
	}
	t.Fatalf("task %s not found", taskID)
	return ""
}

func hasQueueStatus(t *testing.T, root, taskID, status string) bool {
	t.Helper()
	return queueStatusOf(t, root, taskID) == status
}

func queueStatusUnchanged(t *testing.T, root, taskID string) bool {
	t.Helper()
	switch taskID {
	case "q-100":
		return queueStatusOf(t, root, taskID) == "queued"
	case "q-101":
		return queueStatusOf(t, root, taskID) == "done"
	case "q-102":
		return queueStatusOf(t, root, taskID) == "dead"
	case "q-104":
		return queueStatusOf(t, root, taskID) == "assigned"
	}
	return true
}

// classifyPlan groups planned task ids by action and source.
func classifyPlan(report *shadow.Report) map[string]map[string][]string {
	grouped := map[string]map[string][]string{}
	for _, step := range report.Steps {
		if grouped[step.Action] == nil {
			grouped[step.Action] = map[string][]string{}
		}
		grouped[step.Action][step.Source] = append(grouped[step.Action][step.Source], step.TaskID)
	}
	for action := range grouped {
		for source := range grouped[action] {
			sort.Strings(grouped[action][source])
		}
	}
	return grouped
}
