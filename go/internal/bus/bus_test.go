package bus

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeBusFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// TestRedactMirrorsRedactPs1 asserts the exact output of Redact-Secrets from
// .agents/scripts/redact.ps1 for the same inputs (captured by running the
// PowerShell helper directly), so a drift in the Go copy is a test failure.
func TestRedactMirrorsRedactPs1(t *testing.T) {
	tokVal := "abc" + "123" + "secret"
	awsVal := "AK" + "IAIOSFODNN7EXAMPLE"
	cases := map[string]string{
		"password=hunter" + "2 and token=" + tokVal: "password=[REDACTED] and token=[REDACTED]",
		"apiKey = getApiKey()":                    "apiKey = getApiKey()",
		"Bearer abcdefghijklmnopqrstuvwx":         "Bearer [REDACTED]",
		"secret: verysecret value here":           "secret: [REDACTED] value here",
		"api" + "_key=" + awsVal:                   "api_key=[REDACTED]",
		"PWD:x":                                   "PWD:[REDACTED]",
		"token = plainWord":                       "token = [REDACTED]",
		"":                                        "",
	}
	for input, want := range cases {
		if got := Redact(input); got != want {
			t.Errorf("Redact(%q) = %q, want %q", input, got, want)
		}
		if got := Redact(Redact(input)); got != want {
			t.Errorf("Redact is not idempotent for %q: %q", input, got)
		}
	}
}

func TestRedactMasksKnownKeyShapes(t *testing.T) {
	// Assembled at runtime so this source file holds no literal key pattern.
	openAI := "s" + "k-" + "ABCDEFGHIJKLMNOPQRSTUV"
	jwt := "eyJ" + "hbGciOiJIUzI1NiJ9" + "." + "eyJ" + "zdWIiOiIxMjM0NTY3ODkwIn0" + "." + "abcdef"
	input := "key=" + openAI + " jwt=" + jwt
	redacted := Redact(input)
	if strings.Contains(redacted, openAI) {
		t.Errorf("openai-style key survived redaction: %q", redacted)
	}
	if strings.Contains(redacted, "eyJ"+"hbGciOiJIUzI1NiJ9") {
		t.Errorf("jwt survived redaction: %q", redacted)
	}
}

func TestClassificationMirrorsInboxEngine(t *testing.T) {
	cases := []struct {
		name           string
		exitCode       int
		stdout         string
		stderr         string
		requireMarker  bool
		wantSuccess    bool
		wantReasonPart string
	}{
		{"marker present", 0, "work done\nSTATUS: resolved", "", true, true, ""},
		{"non-zero exit", 1, "STATUS: resolved", "", true, false, "exit code 1"},
		{"empty stdout", 0, "  \n ", "", true, false, "empty stdout"},
		{"missing marker", 0, "all good", "", true, false, "missing success marker"},
		{"error marker", 0, "Error: boom\nSTATUS: resolved", "", true, false, "error marker in output"},
		{"benign warning ignored", 0, "answer", "agent \"dev-1\" not found. Falling back to default agent", false, true, ""},
		{"benign warning with marker", 0, "answer\nSTATUS: done", "agent \"x\" not found. Falling back to default agent", true, true, ""},
		{"interactive without marker", 0, "answer", "", false, true, ""},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got := AttemptSucceeded(testCase.exitCode, testCase.stdout, testCase.stderr, testCase.requireMarker)
			if got != testCase.wantSuccess {
				t.Fatalf("AttemptSucceeded = %v, want %v", got, testCase.wantSuccess)
			}
			if testCase.wantSuccess {
				// The engine only asks for a reason when the attempt failed; the
				// success path stores an empty reason.
				return
			}
			reason := FailureReason(testCase.exitCode, testCase.stdout, testCase.stderr, testCase.requireMarker)
			if !strings.Contains(reason, testCase.wantReasonPart) {
				t.Errorf("reason = %q, want it to contain %q", reason, testCase.wantReasonPart)
			}
		})
	}
}

func TestNormalizeWorkerStdout(t *testing.T) {
	cases := map[string]string{
		"a\r\nb\r\n": "a\nb",
		"a\nb\n":     "a\nb",
		"a\r\n":      "a",
		"":           "",
		"a":          "a",
	}
	for input, want := range cases {
		if got := NormalizeWorkerStdout(input); got != want {
			t.Errorf("NormalizeWorkerStdout(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestLimitTextAddsOmissionNote(t *testing.T) {
	if got := LimitText("short", 10); got != "short" {
		t.Errorf("LimitText(short) = %q", got)
	}
	got := LimitText(strings.Repeat("x", 12), 10)
	if !strings.Contains(got, "[truncated 2 chars]") {
		t.Errorf("LimitText = %q, want an omission note", got)
	}
	if strings.Contains(LimitText(strings.Repeat("x", 12), 10), "\u2026") == false {
		t.Errorf("LimitText = %q, want the ellipsis marker", got)
	}
}

func TestFileClaimLifecycle(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "claims")

	owned, err := ClaimFile(dir, "m-1", "dev-2", 60, 1)
	if err != nil || !owned {
		t.Fatalf("first claim = %v, %v; want true, nil", owned, err)
	}
	again, err := ClaimFile(dir, "m-1", "dev-3", 60, 1)
	if err != nil {
		t.Fatalf("second claim error: %v", err)
	}
	if again {
		t.Error("second claim won the lease; the file claim is not exclusive")
	}
	if _, err := os.Stat(ClaimFilePath(dir, "m-1")); err != nil {
		t.Fatalf("lease file missing: %v", err)
	}

	// A different owner must not release or refresh the lease.
	if released, _ := ReleaseFile(dir, "m-1", "dev-3"); released {
		t.Error("a foreign agent released the lease")
	}
	if refreshed, _ := HeartbeatFile(dir, "m-1", "dev-3"); refreshed {
		t.Error("a foreign agent refreshed the lease")
	}
	if refreshed, _ := HeartbeatFile(dir, "m-1", "dev-2"); !refreshed {
		t.Error("the owner could not refresh the lease")
	}
	if released, _ := ReleaseFile(dir, "m-1", "dev-2"); !released {
		t.Error("the owner could not release the lease")
	}
	if _, err := os.Stat(ClaimFilePath(dir, "m-1")); !os.IsNotExist(err) {
		t.Error("lease file survived the release")
	}
}

func TestClaimFileNameHashesHostileIDs(t *testing.T) {
	if got := ClaimFileName("tq-001"); got != "tq-001.claim.json" {
		t.Errorf("ClaimFileName(tq-001) = %q", got)
	}
	hostile := ClaimFileName("../../evil")
	if strings.Contains(hostile, "/") || strings.Contains(hostile, "\\") || strings.Contains(hostile, "..") {
		t.Errorf("hostile id produced an unsafe name: %q", hostile)
	}
}

func TestRevokeStaleClaims(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "claims")
	stale := FileClaim{TaskID: "m-old", Agent: "dev-2", LeaseSeconds: 60,
		ClaimedAt: FormatClaimTime(time.Now().Add(-2 * time.Hour)), HeartbeatAt: FormatClaimTime(time.Now().Add(-2 * time.Hour))}
	fresh := FileClaim{TaskID: "m-new", Agent: "dev-2", LeaseSeconds: 60,
		ClaimedAt: FormatClaimTime(time.Now()), HeartbeatAt: FormatClaimTime(time.Now())}
	for _, claim := range []FileClaim{stale, fresh} {
		encoded, err := json.Marshal(claim)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		writeBusFile(t, ClaimFilePath(dir, claim.TaskID), string(encoded))
	}

	revoked, err := RevokeStaleClaims(dir, time.Minute, time.Now())
	if err != nil {
		t.Fatalf("RevokeStaleClaims: %v", err)
	}
	if len(revoked) != 1 || revoked[0] != "m-old" {
		t.Fatalf("revoked = %v, want [m-old]", revoked)
	}
	if _, err := os.Stat(ClaimFilePath(dir, "m-new")); err != nil {
		t.Errorf("a fresh lease was revoked: %v", err)
	}
}

func TestLoadQueueAndNextPending(t *testing.T) {
	root := t.TempDir()
	writeBusFile(t, filepath.Join(root, "projects", "alpha", "queue.json"),
		`{"project":"alpha","tasks":[
			{"id":"tq-003","title":"low first","status":"queued","priority":"low","assigned_agent":"dev-2","created_at":"2026-01-01T00:00:00.000"},
			{"id":"tq-001","title":"normal","status":"queued","priority":"normal","assigned_agent":"dev-2","created_at":"2026-01-02T00:00:00.000"},
			{"id":"tq-002","title":"critical","status":"assigned","priority":"critical","assigned_agent":"dev-3","created_at":"2026-01-03T00:00:00.000","custom_field":"keep me","retries":2},
			{"id":"tq-004","title":"done already","status":"done","priority":"critical","assigned_agent":"dev-2"}
		]}`)

	queue, err := LoadQueue(root, "alpha")
	if err != nil || queue == nil {
		t.Fatalf("LoadQueue = %v, %v", queue, err)
	}
	next, ok := queue.NextPending()
	if !ok {
		t.Fatal("NextPending found nothing")
	}
	if id := TaskString(next, "id"); id != "tq-002" {
		t.Fatalf("NextPending = %s, want tq-002 (critical runs first)", id)
	}

	SetTaskField(next, "status", "done")
	SetTaskField(next, "completed_at", "2026-09-21T10:00:00.000")
	if err := queue.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}

	raw, err := os.ReadFile(filepath.Join(root, "projects", "alpha", "queue.json"))
	if err != nil {
		t.Fatalf("read queue: %v", err)
	}
	persisted := string(raw)
	for _, want := range []string{"custom_field", "keep me", "\"retries\":2", "tq-004"} {
		if !strings.Contains(persisted, want) {
			t.Errorf("saved queue lost %s: %s", want, persisted)
		}
	}
	if !strings.HasPrefix(persisted, "{") {
		t.Errorf("saved queue is not compact json: %s", persisted)
	}
}

func TestBuildPromptMirrorsEngine(t *testing.T) {
	prompt := BuildPrompt(`C:\root`, "do the thing")
	for _, want := range []string{`C:\root\CONTEXT-BUFFER.md`, "STATUS: resolved", "TASK: do the thing"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt missing %q: %s", want, prompt)
		}
	}
}

func TestAppendEvidenceKeepsEarlierAttempts(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".memory"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	started := time.Now().Add(-time.Second)
	for index, status := range []string{"failed", "success"} {
		record := BuildEvidenceRecord(root, "m-1", "attempt-"+string(rune('1'+index)), "dev-2", "cli run", 0,
			"out", "", started, time.Now(), status, "reason")
		if _, err := AppendEvidence(root, record); err != nil {
			t.Fatalf("AppendEvidence: %v", err)
		}
	}

	raw, err := os.ReadFile(filepath.Join(root, ".memory", "evidence", "m-1.json"))
	if err != nil {
		t.Fatalf("read evidence: %v", err)
	}
	var doc EvidenceDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("evidence is not valid json: %v", err)
	}
	if len(doc.Attempts) != 2 {
		t.Fatalf("attempts = %d, want 2", len(doc.Attempts))
	}
	if doc.Attempts[0].Status != "failed" || doc.Attempts[1].Status != "success" {
		t.Errorf("attempt order/status lost: %+v", doc.Attempts)
	}
	if doc.Attempts[0].StdoutSHA256 != SHA256Hex("out") {
		t.Errorf("stdout hash = %q", doc.Attempts[0].StdoutSHA256)
	}
	if strings.Contains(string(raw), "REDACTED") {
		t.Errorf("evidence should not contain redaction markers: %s", raw)
	}
}

func TestScanInboxReadsAgentFoldersOnly(t *testing.T) {
	root := t.TempDir()
	writeBusFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "b.json"), `{"id":"b","to":"dev-2","payload":"x"}`)
	writeBusFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "a.json"), `{"id":"a","to":"dev-2","payload":"x"}`)
	writeBusFile(t, filepath.Join(root, ".memory", "inbox", "loose.json"), `{"id":"loose","to":"dev-2","payload":"x"}`)
	writeBusFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "notes.txt"), "not json")

	messages, warnings := ScanInbox(root)
	if len(warnings) != 0 {
		t.Errorf("warnings = %v", warnings)
	}
	if len(messages) != 2 {
		t.Fatalf("messages = %d, want 2 (%+v)", len(messages), messages)
	}
	if BaseName(messages[0].FilePath) != "a" || BaseName(messages[1].FilePath) != "b" {
		t.Errorf("inbox order = %s, %s; want a then b", messages[0].FilePath, messages[1].FilePath)
	}
	if messages[0].Agent != "dev-2" {
		t.Errorf("agent = %q", messages[0].Agent)
	}
}
