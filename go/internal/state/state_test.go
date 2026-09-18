package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeFixture(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestParseTimeLayouts(t *testing.T) {
	cases := []struct {
		value string
		ok    bool
	}{
		{"2026-09-18T10:00:00.123", true}, // claim style
		{"2026-09-18T10:00:00", true},     // evidence style
		{"2026-09-18T10:00:00Z", true},    // RFC3339
		{"2026-09-18T10:00:00+03:00", true},
		{"2026-09-18 10:00:00", true},
		{"2026-09-18", true},
		{"", false},
		{"not-a-time", false},
	}

	for _, testCase := range cases {
		_, ok := ParseTime(testCase.value)
		if ok != testCase.ok {
			t.Errorf("ParseTime(%q) ok = %v, want %v", testCase.value, ok, testCase.ok)
		}
	}
}

func TestFormatAge(t *testing.T) {
	cases := []struct {
		duration time.Duration
		want     string
	}{
		{5 * time.Second, "5s"},
		{90 * time.Second, "1m30s"},
		{2*time.Hour + 3*time.Minute, "2h3m"},
		{50 * time.Hour, "2d2h"},
		{-time.Second, "0s"},
	}

	for _, testCase := range cases {
		if got := FormatAge(testCase.duration); got != testCase.want {
			t.Errorf("FormatAge(%s) = %q, want %q", testCase.duration, got, testCase.want)
		}
	}
}

func TestResolveRootPrecedence(t *testing.T) {
	t.Setenv("AGENT_HQ_ROOT", "")
	root, err := ResolveRoot("/flag/root")
	if err != nil {
		t.Fatalf("ResolveRoot: %v", err)
	}
	if root != filepath.Clean("/flag/root") {
		t.Errorf("flag root = %q, want %q", root, filepath.Clean("/flag/root"))
	}

	t.Setenv("AGENT_HQ_ROOT", "/env/root")
	root, err = ResolveRoot("/flag/root")
	if err != nil {
		t.Fatalf("ResolveRoot: %v", err)
	}
	if root != filepath.Clean("/env/root") {
		t.Errorf("env root = %q, want %q", root, filepath.Clean("/env/root"))
	}
}

func TestLoadEvidenceSkipsBrokenFiles(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(EvidenceDir(root), "run-1.json"), `{
		"task_id": "run-1",
		"attempts": [
			{"attempt_id": "attempt-1", "agent": "dev-1", "exit_code": 0, "status": "success", "finished_at": "2026-09-18T10:00:05.000", "stdout_length": 12, "duration_ms": 5000}
		]
	}`)
	writeFixture(t, filepath.Join(EvidenceDir(root), "broken.json"), `{not json`)
	writeFixture(t, filepath.Join(EvidenceDir(root), "ignore.txt"), `plain text`)

	docs, warnings := LoadEvidence(root)
	if len(docs) != 1 {
		t.Fatalf("docs = %d, want 1 (%+v)", len(docs), docs)
	}
	if len(warnings) != 1 {
		t.Fatalf("warnings = %d, want 1 (%v)", len(warnings), warnings)
	}

	doc := docs[0]
	if doc.TaskID != "run-1" {
		t.Errorf("TaskID = %q, want %q", doc.TaskID, "run-1")
	}
	if doc.AttemptCount() != 1 {
		t.Fatalf("attempts = %d, want 1", doc.AttemptCount())
	}
	attempt := doc.Attempts[0]
	if attempt.ExitCodeValue() != 0 {
		t.Errorf("exit code = %d, want 0", attempt.ExitCodeValue())
	}
	if attempt.StdoutBytes() != 12 {
		t.Errorf("stdout bytes = %d, want 12", attempt.StdoutBytes())
	}
	if attempt.DurationMillis() != 5000 {
		t.Errorf("duration = %d, want 5000", attempt.DurationMillis())
	}
	if agents := doc.Agents(); len(agents) != 1 || agents[0] != "dev-1" {
		t.Errorf("agents = %v, want [dev-1]", agents)
	}
	if _, ok := doc.LastFinished(); !ok {
		t.Error("LastFinished() found no timestamp")
	}
}

func TestLoadEvidenceFallsBackToFileName(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(EvidenceDir(root), "fallback-id.json"), `{"attempts": []}`)

	docs, warnings := LoadEvidence(root)
	if len(warnings) != 0 {
		t.Fatalf("warnings = %v, want none", warnings)
	}
	if len(docs) != 1 || docs[0].TaskID != "fallback-id" {
		t.Fatalf("docs = %+v, want one document with TaskID fallback-id", docs)
	}
}

func TestLoadEvidenceMissingDirectory(t *testing.T) {
	docs, warnings := LoadEvidence(t.TempDir())
	if len(docs) != 0 || len(warnings) != 0 {
		t.Fatalf("docs = %v, warnings = %v; want empty and no warnings", docs, warnings)
	}
}

func TestEvaluateClaims(t *testing.T) {
	now, _ := ParseTime("2026-09-18T10:20:00Z")
	leaseSeconds := 900

	claims := []Claim{
		{TaskID: "fresh", Agent: "dev-1", HeartbeatAt: "2026-09-18T10:19:00.000", LeaseSeconds: &leaseSeconds, Attempt: intPointer(2)},
		{TaskID: "expired", Agent: "dev-2", HeartbeatAt: "2026-09-18T10:00:00.000", LeaseSeconds: &leaseSeconds},
		{TaskID: "unparsable", Agent: "dev-3", HeartbeatAt: "garbage"},
		{TaskID: "default-ttl", Agent: "dev-4", HeartbeatAt: "2026-09-18T10:00:00.000"},
	}

	statuses := EvaluateClaims(claims, 0, now)
	if len(statuses) != 4 {
		t.Fatalf("statuses = %d, want 4", len(statuses))
	}

	byID := make(map[string]ClaimStatus)
	for _, status := range statuses {
		byID[status.TaskID] = status
	}

	if byID["fresh"].Stale {
		t.Errorf("fresh lease marked stale: %+v", byID["fresh"])
	}
	if byID["fresh"].Attempt != 2 {
		t.Errorf("fresh attempt = %d, want 2", byID["fresh"].Attempt)
	}
	if !byID["expired"].Stale || byID["expired"].Reason != "heartbeat-expired" {
		t.Errorf("expired lease = %+v, want stale heartbeat-expired", byID["expired"])
	}
	if byID["expired"].HeartbeatAgeSeconds != 1200 {
		t.Errorf("expired age = %d, want 1200", byID["expired"].HeartbeatAgeSeconds)
	}
	if !byID["unparsable"].Stale || byID["unparsable"].Reason != "unparsable-heartbeat" {
		t.Errorf("unparsable lease = %+v, want stale unparsable-heartbeat", byID["unparsable"])
	}
	if !byID["default-ttl"].Stale || byID["default-ttl"].TTLSeconds != DefaultLeaseSeconds {
		t.Errorf("default ttl lease = %+v, want stale with TTL %d", byID["default-ttl"], DefaultLeaseSeconds)
	}
}

func TestEvaluateClaimsTTLOverride(t *testing.T) {
	now, _ := ParseTime("2026-09-18T10:20:00Z")
	leaseSeconds := 900
	claims := []Claim{{TaskID: "expired", HeartbeatAt: "2026-09-18T10:00:00.000", LeaseSeconds: &leaseSeconds}}

	statuses := EvaluateClaims(claims, time.Hour, now)
	if statuses[0].Stale {
		t.Errorf("override to 1h should keep the lease active: %+v", statuses[0])
	}
	if statuses[0].TTLSeconds != 3600 {
		t.Errorf("TTL = %d, want 3600", statuses[0].TTLSeconds)
	}
}

func TestLoadClaimsIgnoresMarkers(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(ClaimsDir(root), "run-1.claim.json"),
		`{"task_id":"run-1","agent":"dev-1","claimed_at":"2026-09-18T10:00:00.000","heartbeat_at":"2026-09-18T10:05:00.000","lease_seconds":900,"attempt":1}`)
	writeFixture(t, filepath.Join(ClaimsDir(root), "run-1.attempt"), `1`)
	writeFixture(t, filepath.Join(ClaimsDir(root), "run-2.json"), `{"task_id":"run-2"}`)

	claims, warnings := LoadClaims(root)
	if len(warnings) != 0 {
		t.Fatalf("warnings = %v, want none", warnings)
	}
	if len(claims) != 1 {
		t.Fatalf("claims = %d, want 1 (%+v)", len(claims), claims)
	}
	if claims[0].TaskID != "run-1" || claims[0].AttemptValue() != 1 {
		t.Errorf("claim = %+v, want run-1 attempt 1", claims[0])
	}
}

func TestLoadQueues(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(ProjectsDir(root), "alpha", QueueFileName), `{
		"tasks": [
			{"id": "a-1", "title": "first", "priority": "high", "status": "queued", "created_at": "2026-09-18T09:00:00Z"},
			{"id": "a-2", "title": "second", "status": "assigned", "assigned_agent": "dev-2", "project": "explicit"}
		]
	}`)
	writeFixture(t, filepath.Join(ProjectsDir(root), "broken", QueueFileName), `{oops`)
	writeFixture(t, filepath.Join(ProjectsDir(root), "empty", QueueFileName), `{"tasks": []}`)

	queues, warnings := LoadQueues(root)
	if len(warnings) != 1 {
		t.Fatalf("warnings = %d, want 1 (%v)", len(warnings), warnings)
	}
	if len(queues) != 2 {
		t.Fatalf("queues = %d, want 2 (%+v)", len(queues), queues)
	}

	alpha := queues[0]
	if alpha.Project != "alpha" {
		t.Fatalf("first project = %q, want alpha", alpha.Project)
	}
	if len(alpha.Tasks) != 2 {
		t.Fatalf("alpha tasks = %d, want 2", len(alpha.Tasks))
	}
	if alpha.Tasks[0].Project != "alpha" {
		t.Errorf("implicit project = %q, want alpha", alpha.Tasks[0].Project)
	}
	if alpha.Tasks[1].Project != "explicit" {
		t.Errorf("explicit project = %q, want explicit", alpha.Tasks[1].Project)
	}
	if alpha.Tasks[0].Source != "queue" {
		t.Errorf("task source = %q, want queue", alpha.Tasks[0].Source)
	}
	if TaskCount(queues) != 2 {
		t.Errorf("TaskCount = %d, want 2", TaskCount(queues))
	}
}

func TestLoadMessagesFlatAndNested(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(InboxDir(root), "dev-1", "msg-1.json"),
		`{"id":"msg-1","from":"team-lead","to":"dev-1","type":"task","priority":"high","payload":"do work","status":"pending","created_at":"2026-09-18T09:00:00Z"}`)
	writeFixture(t, filepath.Join(OutboxDir(root), "msg-2.json"),
		`{"id":"msg-2","from":"dev-1","to":"team-lead","type":"result","payload":{"files":["a.txt"]},"status":"done","startedAt":"2026-09-18T09:01:00","finishedAt":"2026-09-18T09:02:00"}`)
	writeFixture(t, filepath.Join(DeadLetterDir(root), "msg-3.json"), `{broken`)

	inbox, inboxWarnings := LoadMessages(InboxDir(root))
	if len(inboxWarnings) != 0 {
		t.Fatalf("inbox warnings = %v, want none", inboxWarnings)
	}
	if len(inbox) != 1 {
		t.Fatalf("inbox = %d, want 1", len(inbox))
	}
	if inbox[0].Agent != "dev-1" {
		t.Errorf("inbox agent = %q, want dev-1", inbox[0].Agent)
	}
	if inbox[0].PayloadText() != "do work" {
		t.Errorf("payload text = %q, want %q", inbox[0].PayloadText(), "do work")
	}

	outbox, _ := LoadMessages(OutboxDir(root))
	if len(outbox) != 1 {
		t.Fatalf("outbox = %d, want 1", len(outbox))
	}
	var objectPayload map[string][]string
	if err := json.Unmarshal([]byte(outbox[0].PayloadText()), &objectPayload); err != nil {
		t.Fatalf("object payload is not valid json: %v (%q)", err, outbox[0].PayloadText())
	}
	if len(objectPayload["files"]) != 1 || objectPayload["files"][0] != "a.txt" {
		t.Errorf("object payload = %v", objectPayload)
	}

	dead, deadWarnings := LoadMessages(DeadLetterDir(root))
	if len(dead) != 0 {
		t.Errorf("dead-letter = %d, want 0", len(dead))
	}
	if len(deadWarnings) != 1 {
		t.Errorf("dead-letter warnings = %v, want 1", deadWarnings)
	}
}

func TestLoadMessagesHandlesBOM(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(OutboxDir(root), "bom.json"),
		"\ufeff{\"id\":\"bom\",\"status\":\"done\",\"payload\":\"ok\"}")

	messages, warnings := LoadMessages(OutboxDir(root))
	if len(warnings) != 0 {
		t.Fatalf("warnings = %v, want none", warnings)
	}
	if len(messages) != 1 || messages[0].ID != "bom" {
		t.Fatalf("messages = %+v, want one message with ID bom", messages)
	}
}

func TestSnapshotEmptyRoot(t *testing.T) {
	root := t.TempDir()
	now, _ := ParseTime("2026-09-18T10:00:00Z")

	snapshot := Load(root, "test", 0, now)
	counts := snapshot.Counts()
	if counts.Evidence != 0 || counts.Claims != 0 || counts.Inbox != 0 || counts.Outbox != 0 {
		t.Errorf("counts on empty root = %+v, want all zero", counts)
	}
	if counts.QueueTasks != 0 || counts.Projects != 0 {
		t.Errorf("queue counts on empty root = %+v, want all zero", counts)
	}
	if len(snapshot.Warnings) != 0 {
		t.Errorf("warnings on empty root = %v, want none", snapshot.Warnings)
	}
	if len(snapshot.RecentActivity(5)) != 0 {
		t.Errorf("recent activity on empty root should be empty")
	}
}

func TestSnapshotRecentActivityOrder(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(ProjectsDir(root), "alpha", QueueFileName),
		`{"tasks":[{"id":"old","status":"queued","created_at":"2026-09-18T08:00:00Z"}]}`)
	writeFixture(t, filepath.Join(EvidenceDir(root), "new.json"),
		`{"task_id":"new","attempts":[{"status":"success","finished_at":"2026-09-18T09:00:00.000"}]}`)

	now, _ := ParseTime("2026-09-18T10:00:00Z")
	snapshot := Load(root, "test", 0, now)
	activity := snapshot.RecentActivity(10)
	if len(activity) != 2 {
		t.Fatalf("activity = %d, want 2 (%+v)", len(activity), activity)
	}
	if activity[0].Source != "evidence" || activity[0].ID != "new" {
		t.Errorf("activity[0] = %+v, want the newest (evidence/new)", activity[0])
	}
	if activity[1].Source != "queue" {
		t.Errorf("activity[1] = %+v, want the queue entry", activity[1])
	}

	limited := snapshot.RecentActivity(1)
	if len(limited) != 1 || limited[0].ID != "new" {
		t.Errorf("limited activity = %+v, want one entry for new", limited)
	}
}

func TestSnapshotCountsAndEvidenceLookup(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(EvidenceDir(root), "run-1.json"),
		`{"task_id":"run-1","attempts":[{"status":"success","finished_at":"2026-09-18T09:00:00.000"},{"status":"failed","finished_at":"2026-09-18T09:01:00.000"}]}`)
	writeFixture(t, filepath.Join(ClaimsDir(root), "run-2.claim.json"),
		`{"task_id":"run-2","agent":"dev-2","heartbeat_at":"2026-09-18T09:00:00.000","lease_seconds":60}`)

	now, _ := ParseTime("2026-09-18T10:00:00Z")
	snapshot := Load(root, "test", 0, now)
	counts := snapshot.Counts()

	if counts.Evidence != 1 || counts.EvidenceAttempts != 2 {
		t.Errorf("evidence counts = %+v, want 1 document / 2 attempts", counts)
	}
	if counts.Claims != 1 || counts.StaleClaims != 1 {
		t.Errorf("claim counts = %+v, want 1 claim / 1 stale", counts)
	}

	doc, found := snapshot.EvidenceByTaskID("run-1")
	if !found || doc.AttemptCount() != 2 {
		t.Errorf("EvidenceByTaskID(run-1) = %+v, %v", doc, found)
	}
	if _, found := snapshot.EvidenceByTaskID("missing"); found {
		t.Error("EvidenceByTaskID(missing) reported found")
	}
}

func TestDoctorOnEmptyRoot(t *testing.T) {
	root := t.TempDir()
	now, _ := ParseTime("2026-09-18T10:00:00Z")
	snapshot := Load(root, "test", 0, now)

	checks := Doctor(root, snapshot)
	if DoctorOK(checks) {
		t.Error("DoctorOK reported healthy for a root without .memory")
	}

	byName := make(map[string]Check)
	for _, check := range checks {
		byName[check.Name] = check
	}
	if byName["root"].Status != CheckOK {
		t.Errorf("root check = %+v, want ok", byName["root"])
	}
	if byName["memory"].Status != CheckFail {
		t.Errorf("memory check = %+v, want fail", byName["memory"])
	}
	if byName["evidence"].Status != CheckWarn {
		t.Errorf("evidence check = %+v, want warn", byName["evidence"])
	}
}

func TestDoctorWarnsOnBrokenConfig(t *testing.T) {
	root := t.TempDir()
	writeFixture(t, filepath.Join(root, OpenCodeConfigName), `{broken`)
	writeFixture(t, filepath.Join(root, MetadataConfigName), `{"memory": {}}`)

	now, _ := ParseTime("2026-09-18T10:00:00Z")
	checks := Doctor(root, Load(root, "test", 0, now))

	byName := make(map[string]Check)
	for _, check := range checks {
		byName[check.Name] = check
	}
	if byName["opencode-config"].Status != CheckFail {
		t.Errorf("opencode-config check = %+v, want fail", byName["opencode-config"])
	}
	if byName["metadata"].Status != CheckOK {
		t.Errorf("metadata check = %+v, want ok", byName["metadata"])
	}
}

func intPointer(value int) *int {
	return &value
}
