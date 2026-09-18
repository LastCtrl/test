package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// EvidenceAttempt mirrors one record written by New-EvidenceRecord in
// inbox-engine.ps1. The runtime (poller/daemon), never the agent under test,
// fills these fields: exit code, output hashes and lengths, timing, git state.
type EvidenceAttempt struct {
	TaskID        string `json:"task_id"`
	AttemptID     string `json:"attempt_id"`
	Agent         string `json:"agent"`
	Command       string `json:"command"`
	ExitCode      *int   `json:"exit_code"`
	StdoutSHA256  string `json:"stdout_sha256"`
	StdoutLength  *int   `json:"stdout_length"`
	StderrSHA256  string `json:"stderr_sha256"`
	StderrLength  *int   `json:"stderr_length"`
	StartedAt     string `json:"started_at"`
	FinishedAt    string `json:"finished_at"`
	DurationMS    *int64 `json:"duration_ms"`
	Status        string `json:"status"`
	Reason        string `json:"reason"`
	GitHead       string `json:"git_head"`
	GitDiffSHA256 string `json:"git_diff_sha256"`
	Host          string `json:"host"`
	PID           *int   `json:"pid"`
}

// ExitCodeValue returns the recorded exit code, or -1 when the record has none.
func (a EvidenceAttempt) ExitCodeValue() int {
	if a.ExitCode == nil {
		return -1
	}
	return *a.ExitCode
}

// DurationMillis returns the recorded duration in milliseconds, or 0.
func (a EvidenceAttempt) DurationMillis() int64 {
	if a.DurationMS == nil {
		return 0
	}
	return *a.DurationMS
}

// StdoutBytes returns the recorded stdout length in bytes, or 0.
func (a EvidenceAttempt) StdoutBytes() int {
	if a.StdoutLength == nil {
		return 0
	}
	return *a.StdoutLength
}

// StderrBytes returns the recorded stderr length in bytes, or 0.
func (a EvidenceAttempt) StderrBytes() int {
	if a.StderrLength == nil {
		return 0
	}
	return *a.StderrLength
}

// EvidenceDoc is the content of .memory/evidence/<identifier>.json.
type EvidenceDoc struct {
	TaskID   string            `json:"task_id"`
	Attempts []EvidenceAttempt `json:"attempts"`
	Path     string            `json:"-"`
	Warnings []string          `json:"-"`
}

// AttemptCount is the number of recorded attempts.
func (d EvidenceDoc) AttemptCount() int {
	return len(d.Attempts)
}

// LastFinished returns the newest parseable finished_at timestamp among the
// attempts.
func (d EvidenceDoc) LastFinished() (time.Time, bool) {
	var newest time.Time
	found := false
	for _, attempt := range d.Attempts {
		parsed, ok := ParseTime(attempt.FinishedAt)
		if !ok {
			continue
		}
		if !found || parsed.After(newest) {
			newest = parsed
			found = true
		}
	}
	return newest, found
}

// Agents returns the distinct agent names recorded in the document, sorted.
func (d EvidenceDoc) Agents() []string {
	seen := make(map[string]struct{})
	for _, attempt := range d.Attempts {
		if name := strings.TrimSpace(attempt.Agent); name != "" {
			seen[name] = struct{}{}
		}
	}
	agents := make([]string, 0, len(seen))
	for name := range seen {
		agents = append(agents, name)
	}
	sort.Strings(agents)
	return agents
}

// LoadEvidence reads every evidence document under <root>/.memory/evidence.
// Unreadable or malformed files become warnings and are skipped.
func LoadEvidence(root string) ([]EvidenceDoc, []string) {
	files, warnings := jsonFiles(EvidenceDir(root))
	docs := make([]EvidenceDoc, 0, len(files))

	for _, file := range files {
		raw, err := os.ReadFile(file)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("evidence: cannot read %s: %v", file, err))
			continue
		}
		var doc EvidenceDoc
		if err := json.Unmarshal(trimBOM(raw), &doc); err != nil {
			warnings = append(warnings, fmt.Sprintf("evidence: broken json %s: %v", file, err))
			continue
		}
		doc.Path = file
		if strings.TrimSpace(doc.TaskID) == "" {
			doc.TaskID = strings.TrimSuffix(filepath.Base(file), filepath.Ext(file))
		}
		docs = append(docs, doc)
	}

	sort.Slice(docs, func(i, j int) bool { return docs[i].TaskID < docs[j].TaskID })
	return docs, warnings
}
