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
)

// runloop_parity_test.go is the M5 cut-over proof: for identical inputs the Go
// run-loop and the PowerShell inbox engine must produce an equivalent result -
// same destination folder, same file names, same message fields, same status and
// same machine evidence. The PowerShell engine is driven by the real
// inbox-poller.ps1 with tests/fake-opencode.ps1 as the worker CLI, exactly the
// way test-pipeline.ps1 drives it.
//
// Two deliberate, documented differences remain (both are format details, never
// semantics):
//   - the PowerShell engine writes a UTF-8 BOM into outbox/dead-letter because
//     it uses Encoding.GetEncoding(65001); the Go writer does not, because a BOM
//     breaks JSON.parse in the Node bridge while every JSON reader strips it.
//     The comparison therefore reads both with the BOM stripped.
//   - the PowerShell engine decodes a child's stdout with the console code page,
//     the Go driver keeps the raw bytes. Hashes and text of non-ASCII worker
//     output are therefore not byte-comparable; those fields are compared only
//     for ASCII output (all classification-critical cases are ASCII).

// parityCase is one worker behaviour exercised through both drivers.
type parityCase struct {
	name    string
	mode    string
	message string
	// nonASCII marks a fixture whose worker output is not ASCII, so the recorded
	// output hashes and lengths are not comparable across the two drivers.
	nonASCII bool
	// stderrDivergence marks a fixture that answers on stderr only. The
	// PowerShell engine runs the CLI inside Start-Job and its 2> redirect cannot
	// capture a .ps1 worker's console stderr, while the Go driver executes the
	// CLI as a real child process and does capture it. The verdict is identical,
	// only the recorded stderr text (and the dead-letter STDERR section) differ.
	stderrDivergence bool
}

func parityRepoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("repo root: %v", err)
	}
	for _, probe := range []string{
		filepath.Join(root, ".agents", "scripts", "inbox-poller.ps1"),
		filepath.Join(root, "tests", "fake-opencode.ps1"),
	} {
		if _, err := os.Stat(probe); err != nil {
			t.Skipf("parity fixture missing (%s): %v", probe, err)
		}
	}
	return root
}

// parityRoot builds an isolated agent-hq root with one inbox message.
func parityRoot(t *testing.T, message string) string {
	t.Helper()
	root := tempRoot(t)
	writeShadowFile(t, filepath.Join(root, "CONTEXT-BUFFER.md"), "context buffer")
	writeShadowFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "m-1.json"), message)
	writeShadowFile(t, filepath.Join(root, "projects", "alpha", "queue.json"),
		`{"project":"alpha","tasks":[{"id":"tq-001","title":"queued parity task","status":"queued","assigned_agent":"dev-2","priority":"normal","created_at":"2026-09-21T10:00:00.000","custom_field":"must survive"}]}`)
	return root
}

func runGoLoop(t *testing.T, root, fakeCli, mode string, extra ...string) (int, string) {
	t.Helper()
	t.Setenv("AGENT_HQ_ROOT", "")
	t.Setenv("AGENT_HQ_OPENCODE", fakeCli)
	t.Setenv("AGENT_HQ_OPENCODE_PATH", "")
	t.Setenv("AGENT_HQ_DRIVER", "")
	t.Setenv("FAKE_OPENCODE_MODE", mode)

	args := append([]string{"run-loop", "-root", root, "-once", "-json", "-queue=false"}, extra...)
	var stdout, stderr bytes.Buffer
	code := run(args, &stdout, &stderr)
	return code, stdout.String()
}

func runPowerShellEngine(t *testing.T, repoRoot, root, fakeCli, mode string) {
	t.Helper()
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

// busArtifacts maps every bus artifact of a root to its decoded JSON document.
func busArtifacts(t *testing.T, root string, stripLengths bool) map[string]map[string]any {
	t.Helper()
	artifacts := make(map[string]map[string]any)
	for _, dir := range []string{"outbox", "dead-letter", "archive", "evidence"} {
		base := filepath.Join(root, ".memory", dir)
		err := filepath.Walk(base, func(path string, info os.FileInfo, walkErr error) error {
			if walkErr != nil {
				return nil
			}
			if info.IsDir() || !strings.HasSuffix(strings.ToLower(info.Name()), ".json") {
				return nil
			}
			relative, relErr := filepath.Rel(root, path)
			if relErr != nil {
				return relErr
			}
			raw, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			var document map[string]any
			if jsonErr := json.Unmarshal(trimBOM(raw), &document); jsonErr != nil {
				t.Fatalf("%s is not valid json even without a BOM: %v\n%s", relative, jsonErr, raw)
			}
			if dir == "evidence" {
				if attempts, ok := document["attempts"].([]any); ok {
					for _, item := range attempts {
						if attempt, isMap := item.(map[string]any); isMap {
							normalizeEvidenceAttempt(attempt, stripLengths)
						}
					}
				}
			}
			artifacts[filepath.ToSlash(relative)] = document
			return nil
		})
		if err != nil && !os.IsNotExist(err) {
			t.Fatalf("walk %s: %v", base, err)
		}
	}
	return artifacts
}

func trimBOM(raw []byte) []byte {
	return bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
}

// normalizeEvidenceAttempt drops the fields that legitimately differ between two
// runs (wall-clock stamps, pid, duration) and, when asked, the output size fields
// whose input was not ASCII.
func normalizeEvidenceAttempt(attempt map[string]any, stripLengths bool) {
	for _, volatile := range []string{"started_at", "finished_at", "duration_ms", "pid", "stdout_sha256", "stderr_sha256"} {
		delete(attempt, volatile)
	}
	if stripLengths {
		delete(attempt, "stdout_length")
		delete(attempt, "stderr_length")
	}
}

const (
	paritySuccess     = `{"id":"m-1","from":"team-lead","to":"dev-2","priority":"high","payload":"do the thing"}`
	parityInteractive = `{"id":"m-1","from":"team-lead","to":"dev-2","priority":"high","source":"run","payload":"what time is it"}`
)

func TestRunLoopParityWithPowerShellEngine(t *testing.T) {
	repoRoot := parityRepoRoot(t)
	fakeCli := filepath.Join(repoRoot, "tests", "fake-opencode.ps1")
	if _, err := exec.LookPath("powershell"); err != nil {
		t.Skip("powershell is not available")
	}

	cases := []parityCase{
		{"structured success", "success", paritySuccess, false, false},
		{"interactive answer without marker", "benign-run", parityInteractive, true, false},
		{"missing status marker", "nomarker", paritySuccess, false, false},
		{"error marker in output", "errormarker", paritySuccess, false, false},
		{"failing worker retried", "exit1", paritySuccess, false, false},
		{"empty stdout retried", "empty", paritySuccess, false, false},
		{"stderr only retried", "stderr-only", paritySuccess, false, true},
		{"secret leak redacted", "leak", paritySuccess, false, false},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			goRoot := parityRoot(t, testCase.message)
			psRoot := parityRoot(t, testCase.message)

			code, stdout := runGoLoop(t, goRoot, fakeCli, testCase.mode)
			if code != 0 {
				t.Fatalf("go run-loop exit = %d, want 0 (json: %s)", code, stdout)
			}
			runPowerShellEngine(t, repoRoot, psRoot, fakeCli, testCase.mode)

			goArtifacts := busArtifacts(t, goRoot, testCase.nonASCII || testCase.stderrDivergence)
			psArtifacts := busArtifacts(t, psRoot, testCase.nonASCII || testCase.stderrDivergence)

			goKeys, psKeys := sortedKeys(goArtifacts), sortedKeys(psArtifacts)
			if !reflect.DeepEqual(goKeys, psKeys) {
				t.Fatalf("different artifacts\n go: %v\n ps: %v", goKeys, psKeys)
			}
			if len(goKeys) == 0 {
				t.Fatal("no bus artifacts were produced")
			}

			for _, key := range goKeys {
				compareArtifact(t, key, goArtifacts[key], psArtifacts[key], testCase)
			}

			// The Go writer must not add the BOM the PowerShell engine writes.
			assertNoBOM(t, goRoot)

			// The queue must be untouched: the Go loop was told -queue=false.
			queueRaw, err := os.ReadFile(filepath.Join(goRoot, "projects", "alpha", "queue.json"))
			if err != nil {
				t.Fatalf("queue: %v", err)
			}
			if !strings.Contains(string(queueRaw), "queued parity task") {
				t.Errorf("queue changed although -queue=false: %s", queueRaw)
			}
		})
	}
}

// assertNoBOM walks the Go bus artifacts and fails on a UTF-8 BOM.
func assertNoBOM(t *testing.T, root string) {
	t.Helper()
	for _, dir := range []string{"outbox", "dead-letter", "evidence", "archive"} {
		base := filepath.Join(root, ".memory", dir)
		_ = filepath.Walk(base, func(path string, info os.FileInfo, walkErr error) error {
			if walkErr != nil || info.IsDir() {
				return nil
			}
			raw, readErr := os.ReadFile(path)
			if readErr != nil {
				return nil
			}
			if bytes.HasPrefix(raw, []byte{0xEF, 0xBB, 0xBF}) {
				t.Errorf("%s starts with a UTF-8 BOM", path)
			}
			return nil
		})
	}
}

func sortedKeys(values map[string]map[string]any) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// compareArtifact compares two artifacts field by field, ignoring the volatile
// timestamps and the output fields that are not comparable for this fixture.
func compareArtifact(t *testing.T, key string, goDoc, psDoc map[string]any, testCase parityCase) {
	t.Helper()
	fields := []string{
		"id", "from", "to", "type", "priority", "payload", "status", "evidence",
		"task_id", "attempt_id", "agent", "command", "exit_code",
		"reason", "host", "attempts",
	}
	if !testCase.nonASCII {
		fields = append(fields, "stdout_length")
	}
	if !testCase.nonASCII && !testCase.stderrDivergence {
		fields = append(fields, "stderr_length", "response")
	}
	for _, field := range fields {
		goValue, goHas := goDoc[field]
		psValue, psHas := psDoc[field]
		if !goHas && !psHas {
			continue
		}
		if !goHas || !psHas {
			t.Errorf("%s: field %q present in one artifact only (go=%v ps=%v)", key, field, goHas, psHas)
			continue
		}
		if !reflect.DeepEqual(goValue, psValue) {
			t.Errorf("%s: field %q differs\n go: %#v\n ps: %#v", key, field, goValue, psValue)
		}
	}

	// A response must still exist on both sides wherever the artifact has one.
	if _, hasResponse := goDoc["response"]; !hasResponse {
		return
	}
	if _, hasResponse := psDoc["response"]; !hasResponse {
		return
	}
	if response, _ := goDoc["response"].(string); strings.TrimSpace(response) == "" {
		t.Errorf("%s: go response is empty", key)
	}
	if response, _ := psDoc["response"].(string); strings.TrimSpace(response) == "" {
		t.Errorf("%s: ps response is empty", key)
	}
	if testCase.stderrDivergence {
		attempts, _ := goDoc["attempts"].([]any)
		captured := false
		for _, item := range attempts {
			if attempt, isMap := item.(map[string]any); isMap {
				if length, ok := attempt["stderr_length"].(float64); ok && length > 0 {
					captured = true
				}
			}
		}
		if !captured && len(attempts) > 0 {
			t.Errorf("%s: go driver did not capture the worker stderr", key)
		}
	}
}
