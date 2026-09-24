package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"agent-hq/internal/shadow"
)

func writeShadowFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// newShadowFixture builds a minimal read-only state tree for the CLI tests.
func newShadowFixture(t *testing.T) string {
	t.Helper()
	root := tempRoot(t)
	writeShadowFile(t, filepath.Join(root, "opencode.json"),
		`{"agent":{"dev-2":{"model":"opencode-go/deepseek-v4.1-flash"}}}`)
	writeShadowFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "m-100.json"),
		`{"id":"m-100","from":"team-lead","to":"dev-2","priority":"high","payload":"summary please"}`)
	writeShadowFile(t, filepath.Join(root, ".memory", "outbox", "m-101.json"),
		`{"id":"m-101","to":"dev-2","status":"done","response":"ok"}`)
	writeShadowFile(t, filepath.Join(root, "projects", "alpha", "queue.json"),
		`{"project":"alpha","tasks":[{"id":"q-100","title":"queued item","status":"queued","assigned_agent":"dev-2"}]}`)
	return root
}

func shadowDigest(t *testing.T, root string) map[string]string {
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
			if rel == filepath.Join(".memory", "shadow") {
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

func runShadowCLI(t *testing.T, root string, extra ...string) (int, string, string) {
	t.Helper()
	t.Setenv("AGENT_HQ_ROOT", "")
	args := append([]string{"shadow", "-root", root}, extra...)
	var stdout, stderr bytes.Buffer
	code := run(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestRunShadowJSON(t *testing.T) {
	root := newShadowFixture(t)
	before := shadowDigest(t, root)

	code, stdout, stderr := runShadowCLI(t, root, "-json")
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr)
	}

	var report shadow.Report
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("stdout is not valid json: %v\n%s", err, stdout)
	}
	if report.Mode != shadow.Mode || !report.ReadOnly {
		t.Errorf("report = %+v, want shadow and read-only", report)
	}
	if report.Summary.Inbox != 1 || report.Summary.Queue != 1 {
		t.Errorf("summary = %+v, want one inbox and one queue step", report.Summary)
	}

	foundInbox := false
	for _, step := range report.Steps {
		if step.TaskID == "m-100" {
			foundInbox = true
			if step.Agent != "dev-2" || step.Model != "opencode-go/deepseek-v4.1-flash" ||
				step.Executor != shadow.DefaultExecutor || step.Action != shadow.ActionRun {
				t.Errorf("m-100 = %+v, want a run step for dev-2", step)
			}
		}
	}
	if !foundInbox {
		t.Errorf("steps = %+v, want the inbox item planned", report.Steps)
	}

	if report.Path == "" {
		t.Fatal("report path is empty")
	}
	if _, err := os.Stat(report.Path); err != nil {
		t.Fatalf("report file missing: %v", err)
	}

	after := shadowDigest(t, root)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("state changed:\nbefore=%v\nafter=%v", before, after)
	}
}

func TestRunShadowSummaryText(t *testing.T) {
	root := newShadowFixture(t)
	code, stdout, stderr := runShadowCLI(t, root, "-once", "-summary")
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr)
	}
	if !strings.Contains(stdout, "summary") || !strings.Contains(stdout, "total") {
		t.Errorf("stdout = %q, want the summary block", stdout)
	}
	if strings.Contains(stdout, "SOURCE") {
		t.Errorf("stdout = %q, want no step table in summary mode", stdout)
	}
}

func TestRunShadowTextListsSteps(t *testing.T) {
	root := newShadowFixture(t)
	code, stdout, stderr := runShadowCLI(t, root)
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr)
	}
	if !strings.Contains(stdout, "SOURCE") || !strings.Contains(stdout, "m-100") {
		t.Errorf("stdout = %q, want the step table", stdout)
	}
	if !strings.Contains(stdout, "report:") {
		t.Errorf("stdout = %q, want the report path", stdout)
	}
}

func TestRunShadowRejectsUnknownFlag(t *testing.T) {
	root := newShadowFixture(t)
	code, _, _ := runShadowCLI(t, root, "-bogus")
	if code != 2 {
		t.Errorf("exit = %d, want 2 for a usage error", code)
	}
}

func TestRunShadowHelp(t *testing.T) {
	root := newShadowFixture(t)
	code, _, _ := runShadowCLI(t, root, "-h")
	if code != 0 {
		t.Errorf("exit = %d, want 0 for -h", code)
	}
}

func TestRunShadowRejectsMissingRoot(t *testing.T) {
	// A typo in -root must fail loudly and must not create a stray
	// <root>/.memory/shadow tree.
	missing := filepath.Join(tempRoot(t), "does-not-exist")

	code, _, stderr := runShadowCLI(t, missing, "-json")
	if code == 0 {
		t.Fatalf("exit = 0, want a non-zero exit for a missing root")
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatalf("missing root %s was created (stat err = %v), want it left absent", missing, err)
	}
	if !strings.Contains(stderr, "root") {
		t.Errorf("stderr = %q, want a diagnostic naming the root", stderr)
	}
}

func TestRunShadowRejectsRootWithoutMemory(t *testing.T) {
	// An existing directory that is not an agent-hq checkout (no .memory) is
	// rejected and .memory must not be created by the shadow pass.
	root := tempRoot(t)

	code, _, stderr := runShadowCLI(t, root)
	if code == 0 {
		t.Fatalf("exit = 0, want a non-zero exit for a root without .memory")
	}
	if _, err := os.Stat(filepath.Join(root, ".memory")); !os.IsNotExist(err) {
		t.Fatalf(".memory was created under %s, want it left absent", root)
	}
	if !strings.Contains(stderr, ".memory") {
		t.Errorf("stderr = %q, want a diagnostic about the missing .memory", stderr)
	}
}
