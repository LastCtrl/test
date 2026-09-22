// Package executor defines the versioned execution boundary of the agent-hq
// control plane (G3-M1).
//
// An Executor turns one TaskSpec into one Result. The control plane
// (agent-hq run) owns claims, durability and lifecycle events; the executor
// only launches a worker and classifies its output. Two implementations ship
// here: OpenCodeExecutor (the real CLI, optionally through the DPAPI vault
// wrapper) and FakeExecutor (deterministic tests).
package executor

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// InterfaceVersion is the revision of the Executor contract. Results can be
// tagged with the version that produced them, so a future control plane can
// tell which semantics were applied to a persisted attempt.
const InterfaceVersion = 1

// Status is the terminal state of one execution attempt.
type Status string

const (
	StatusSuccess Status = "success"
	StatusFailed  Status = "failed"
	StatusTimeout Status = "timeout"
	StatusError   Status = "error"
)

// TaskSpec is the immutable input of one execution attempt. Model is optional
// and is recorded only; it is not forwarded to the CLI (no verified flag).
// Proxy is the optional http(s) proxy URL the M3 self-healing retry runs
// through; it carries no credentials and is applied as HTTPS_PROXY/HTTP_PROXY
// for this attempt only.
type TaskSpec struct {
	ID        string
	Agent     string
	Payload   string
	Model     string
	AttemptID string
	Proxy     string
}

// Result is the outcome of one execution attempt. Stdout and Stderr are kept
// in memory only; the durable store records their hashes and lengths instead.
type Result struct {
	Status   Status
	ExitCode int
	Stdout   string
	Stderr   string
	Duration time.Duration
	Error    string
}

// Executor is the versioned execution boundary.
type Executor interface {
	Version() int
	Name() string
	Execute(ctx context.Context, spec TaskSpec) (Result, error)
}

// SuccessMarker and ErrorMarker mirror inbox-engine.ps1 exactly: a run is a
// success only when the exit code is 0, stdout is non-empty, stdout carries an
// explicit success marker and neither stream carries an error marker.
var (
	SuccessMarker = regexp.MustCompile(`(?i)STATUS:\s*(resolved|done|completed)`)
	ErrorMarker   = regexp.MustCompile(`(?i)(not found|permission denied|auto-rejecting|rejected permission|Error:)`)
)

// Classify applies the shared success rule to a finished process. The returned
// string is a human-readable failure reason, empty on success.
func Classify(exitCode int, stdout, stderr string) (Status, string) {
	if exitCode != 0 {
		return StatusFailed, fmt.Sprintf("exit code %d", exitCode)
	}
	if strings.TrimSpace(stdout) == "" {
		return StatusFailed, "empty stdout"
	}
	if marker := ErrorMarker.FindString(stdout + "\n" + stderr); marker != "" {
		return StatusFailed, "error marker in output: " + marker
	}
	if !SuccessMarker.MatchString(stdout) {
		return StatusFailed, "missing success marker " + SuccessMarker.String()
	}
	return StatusSuccess, ""
}
