package bus

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// EvidenceAttempt is one machine-generated record, field for field identical to
// New-EvidenceRecord in inbox-engine.ps1. The runtime, never the agent under
// test, fills these values.
type EvidenceAttempt struct {
	TaskID        string `json:"task_id"`
	AttemptID     string `json:"attempt_id"`
	Agent         string `json:"agent"`
	Command       string `json:"command"`
	ExitCode      int    `json:"exit_code"`
	StdoutSHA256  string `json:"stdout_sha256"`
	StdoutLength  int    `json:"stdout_length"`
	StderrSHA256  string `json:"stderr_sha256"`
	StderrLength  int    `json:"stderr_length"`
	StartedAt     string `json:"started_at"`
	FinishedAt    string `json:"finished_at"`
	DurationMS    int64  `json:"duration_ms"`
	Status        string `json:"status"`
	Reason        string `json:"reason"`
	GitHead       string `json:"git_head"`
	GitDiffSHA256 string `json:"git_diff_sha256"`
	Host          string `json:"host"`
	PID           int    `json:"pid"`
}

// EvidenceDoc is the document stored as .memory/evidence/<task_id>.json.
type EvidenceDoc struct {
	TaskID   string            `json:"task_id"`
	Attempts []EvidenceAttempt `json:"attempts"`
}

// BuildEvidenceRecord builds the record for one finished attempt. reason is
// redacted (it may quote agent output); the hashes stay computed over the raw
// streams so tamper-evidence is preserved.
func BuildEvidenceRecord(root, taskID, attemptID, agent, command string, exitCode int, stdout, stderr string, startedAt, finishedAt time.Time, status, reason string) EvidenceAttempt {
	git := gitState(root)
	return EvidenceAttempt{
		TaskID:        taskID,
		AttemptID:     attemptID,
		Agent:         agent,
		Command:       command,
		ExitCode:      exitCode,
		StdoutSHA256:  SHA256Hex(stdout),
		StdoutLength:  len(stdout),
		StderrSHA256:  SHA256Hex(stderr),
		StderrLength:  len(stderr),
		StartedAt:     startedAt.Format(time.RFC3339Nano),
		FinishedAt:    finishedAt.Format(time.RFC3339Nano),
		DurationMS:    finishedAt.Sub(startedAt).Milliseconds(),
		Status:        status,
		Reason:        Redact(reason),
		GitHead:       git.head,
		GitDiffSHA256: git.diffSHA,
		Host:          hostName(),
		PID:           os.Getpid(),
	}
}

// AppendEvidence appends one record to .memory/evidence/<taskID>.json and
// returns the repo-relative path embedded into outbox/dead-letter messages. The
// document is rewritten atomically, like Write-EvidenceRecord.
func AppendEvidence(root string, record EvidenceAttempt) (string, error) {
	path := filepath.Join(EvidenceDir(root), record.TaskID+".json")
	doc := EvidenceDoc{TaskID: record.TaskID, Attempts: []EvidenceAttempt{}}
	if raw, err := os.ReadFile(path); err == nil {
		var existing EvidenceDoc
		if jsonErr := json.Unmarshal(raw, &existing); jsonErr == nil && len(existing.Attempts) > 0 {
			doc.Attempts = existing.Attempts
		}
	}
	doc.Attempts = append(doc.Attempts, record)

	encoded, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return "", err
	}
	if err := WriteFileAtomic(path, append(encoded, '\n')); err != nil {
		return "", err
	}
	return EvidenceRelativePath(record.TaskID), nil
}

// EvidenceRelativePath is the path stored in the message evidence field.
func EvidenceRelativePath(taskID string) string {
	return ".memory/evidence/" + taskID + ".json"
}

// HasSuccessfulAttempt reports whether the evidence document of a task already
// records a successful attempt. It is the reconciliation signal of the queue:
// a task with success evidence must never be executed twice, even when its queue
// status was left in a pending state (for example by a crash between the
// evidence write and the status update).
func HasSuccessfulAttempt(root, taskID string) bool {
	if strings.TrimSpace(taskID) == "" {
		return false
	}
	raw, err := os.ReadFile(filepath.Join(EvidenceDir(root), taskID+".json"))
	if err != nil {
		return false
	}
	var doc EvidenceDoc
	if err := json.Unmarshal(trimBOM(raw), &doc); err != nil {
		return false
	}
	for _, attempt := range doc.Attempts {
		if strings.EqualFold(strings.TrimSpace(attempt.Status), "success") {
			return true
		}
	}
	return false
}

// gitSnapshot is the cached git state of one root: a batch of attempts must not
// shell out once per record. The driver loop is single-threaded by design.
type gitSnapshot struct {
	root    string
	loaded  bool
	head    string
	diffSHA string
}

var gitCache gitSnapshot

// gitState returns the cached git state of root, reading it on first use.
func gitState(root string) gitSnapshot {
	if gitCache.loaded && gitCache.root == root {
		return gitCache
	}
	snapshot := readGitSnapshot(root)
	gitCache = snapshot
	return snapshot
}

func readGitSnapshot(root string) gitSnapshot {
	snapshot := gitSnapshot{root: root, loaded: true}
	if !isGitRepo(root) {
		// Not a repository: git would report an empty diff, which hashes to the
		// SHA-256 of the empty string. Skip the process spawn, keep the value.
		snapshot.diffSHA = SHA256Hex("")
		return snapshot
	}
	if head, started, code := gitOutput(root, "rev-parse", "HEAD"); started && code == 0 {
		snapshot.head = strings.TrimSpace(head)
	}
	if diff, started, _ := gitOutput(root, "diff"); started {
		snapshot.diffSHA = SHA256Hex(normalizeGitText(diff))
	}
	return snapshot
}

// isGitRepo reports whether root holds a git directory, without spawning git.
func isGitRepo(root string) bool {
	info, err := os.Stat(filepath.Join(root, ".git"))
	return err == nil && info != nil
}

// gitOutput runs git -C root <args> with a short timeout. started is false only
// when git itself is unavailable.
func gitOutput(root string, args ...string) (output string, started bool, exitCode int) {
	if _, err := exec.LookPath("git"); err != nil {
		return "", false, -1
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	full := append([]string{"-C", root}, args...)
	command := exec.CommandContext(ctx, "git", full...)
	raw, err := command.Output()
	if err == nil {
		return string(raw), true, 0
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		return string(raw), true, exitErr.ExitCode()
	}
	return string(raw), true, -1
}

// normalizeGitText reproduces the PowerShell line join: the capture is split on
// newlines and rejoined with a single newline, so a trailing newline is dropped
// and CRLF is normalised.
func normalizeGitText(text string) string {
	trimmed := strings.TrimRight(text, "\r\n")
	if trimmed == "" {
		return ""
	}
	return strings.Join(strings.Split(strings.ReplaceAll(trimmed, "\r\n", "\n"), "\n"), "\n")
}

// hostName mirrors $env:COMPUTERNAME in the evidence record.
func hostName() string {
	if name := strings.TrimSpace(os.Getenv("COMPUTERNAME")); name != "" {
		return name
	}
	name, err := os.Hostname()
	if err != nil {
		return ""
	}
	return name
}
