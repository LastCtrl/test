package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"text/tabwriter"
	"time"

	"agent-hq/internal/executor"
	"agent-hq/internal/store"
)

// runOptions carries the run-specific flags. They are extracted by hand so
// `agent-hq run <agent> <text> -executor fake` (flags after positionals) works
// the same as flags before them.
type runOptions struct {
	executor string
	taskID   string
	model    string
	lease    int
}

type runOutcome struct {
	TaskID     string `json:"task_id"`
	Agent      string `json:"agent"`
	Executor   string `json:"executor"`
	Attempt    int    `json:"attempt"`
	Status     string `json:"status"`
	ExitCode   int    `json:"exit_code"`
	DurationMS int64  `json:"duration_ms"`
	Error      string `json:"error,omitempty"`
	Reason     string `json:"reason,omitempty"`
	Claimed    bool   `json:"claimed"`
	Stdout     string `json:"stdout,omitempty"`
	Stderr     string `json:"stderr,omitempty"`
}

func runRun(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	options, rest := extractRunOptions(args)
	if len(rest) != 2 {
		fmt.Fprintf(stderr, "usage: %s run <agent> <text> [-executor opencode|fake] [-id <run-id>] [-model <name>] [-lease <seconds>]\n", cliName)
		return 2
	}
	agent := strings.TrimSpace(rest[0])
	promptText := rest[1]
	if agent == "" || strings.TrimSpace(promptText) == "" {
		fmt.Fprintln(stderr, cliName+": run needs a non-empty agent and text")
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	worker, err := buildExecutor(options.executor, root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 2
	}

	handle, err := store.Open(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot open state: %v\n", cliName, err)
		return 1
	}
	defer func() { _ = handle.Close() }()

	taskID := strings.TrimSpace(options.taskID)
	if taskID == "" {
		taskID = newRunID()
	}
	spec := executor.TaskSpec{
		ID:      taskID,
		Agent:   agent,
		Payload: buildPrompt(root, promptText),
		Model:   strings.TrimSpace(options.model),
	}

	outcome := executeRun(context.Background(), handle, worker, spec, newOwner(), options.lease)
	return reportRun(outcome, globals.json, stdout, stderr)
}

// buildExecutor selects the worker implementation.
func buildExecutor(name, root string) (executor.Executor, error) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "", "opencode":
		return executor.NewOpenCodeExecutor(root), nil
	case "fake":
		return executor.NewFakeExecutorFromEnv(), nil
	default:
		return nil, fmt.Errorf("unknown executor %q (want opencode or fake)", name)
	}
}

// executeRun owns the durable lifecycle: claim, write-before, execute,
// write-after, release. It never panics on store errors; a failed bookkeeping
// step is reported in the outcome.
func executeRun(ctx context.Context, handle *store.Store, worker executor.Executor, spec executor.TaskSpec, owner string, leaseSeconds int) runOutcome {
	outcome := runOutcome{TaskID: spec.ID, Agent: spec.Agent, Executor: worker.Name(), ExitCode: -1}
	now := time.Now().UTC()

	acquired, err := handle.AcquireClaim(store.ClaimRequest{
		TaskID: spec.ID, Owner: owner, Agent: spec.Agent, LeaseSeconds: leaseSeconds, Now: now,
	})
	if err != nil {
		outcome.Status = store.RunError
		outcome.Reason = "claim-error"
		outcome.Error = err.Error()
		return outcome
	}
	if !acquired {
		_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Kind: store.EventClaimConflict,
			Detail: "lease held by " + owner, CreatedAt: stamp(now)})
		outcome.Status = "skipped"
		outcome.Reason = "already-claimed"
		outcome.Error = "task is already claimed by another run"
		return outcome
	}

	outcome.Claimed = true
	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Kind: store.EventClaimAcquired,
		Detail: owner, CreatedAt: stamp(now)})
	defer func() {
		released, releaseErr := handle.ReleaseClaim(spec.ID, owner)
		if releaseErr == nil && released {
			_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Kind: store.EventClaimReleased,
				Detail: owner, CreatedAt: stamp(time.Now())})
		}
	}()

	startedAt := now.Format(time.RFC3339Nano)
	run := store.Run{TaskID: spec.ID, Agent: spec.Agent, Executor: worker.Name(), Model: spec.Model,
		Payload: spec.Payload, Status: store.RunRunning, StartedAt: startedAt}
	if err := handle.SaveRun(run); err != nil {
		outcome.Status = store.RunError
		outcome.Error = err.Error()
		return outcome
	}

	seq, err := handle.StartAttempt(store.RunAttempt{
		TaskID: spec.ID, Agent: spec.Agent, Executor: worker.Name(),
		Command: commandDescription(worker, spec), StartedAt: startedAt, Status: store.RunRunning,
	})
	if err != nil {
		outcome.Status = store.RunError
		outcome.Error = err.Error()
		return outcome
	}
	outcome.Attempt = seq
	spec.AttemptID = fmt.Sprintf("attempt-%d", seq)
	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: seq,
		Kind: store.EventAttemptStarted, Detail: spec.AttemptID, CreatedAt: stamp(time.Now())})

	// A worker may outlive its lease, so the lease is refreshed from a ticker
	// for as long as Execute runs. stopHeartbeat is deferred: it runs before
	// the claim release registered above, so the lease is never refreshed
	// after it was released.
	stopHeartbeat := startHeartbeat(handle, spec.ID, owner, leaseSeconds, func(err error) {
		_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: seq,
			Kind: store.EventHeartbeatError, Detail: err.Error(), CreatedAt: stamp(time.Now())})
	})
	defer stopHeartbeat()

	started := time.Now()
	result, execErr := worker.Execute(ctx, spec)
	finished := time.Now()
	if execErr != nil {
		result = executor.Result{Status: executor.StatusError, ExitCode: -1, Error: execErr.Error()}
	}
	if result.Duration <= 0 {
		result.Duration = finished.Sub(started)
	}

	finishedAt := finished.UTC().Format(time.RFC3339Nano)
	stdoutLength := len(result.Stdout)
	stderrLength := len(result.Stderr)
	_, _ = handle.FinishAttempt(store.RunAttempt{
		TaskID: spec.ID, Seq: seq, AttemptID: spec.AttemptID, ExitCode: &result.ExitCode,
		StdoutSHA256: sumHex(result.Stdout), StdoutLength: &stdoutLength,
		StderrSHA256: sumHex(result.Stderr), StderrLength: &stderrLength,
		FinishedAt: finishedAt, DurationMS: durationPtr(result.Duration),
		Status: string(result.Status), Error: result.Error,
	})

	run.Status = string(result.Status)
	run.Attempt = seq
	run.FinishedAt = finishedAt
	run.ExitCode = &result.ExitCode
	run.DurationMS = durationPtr(result.Duration)
	run.Error = result.Error
	run.UpdatedAt = finishedAt
	_ = handle.SaveRun(run)

	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: seq,
		Kind: store.EventAttemptFinished, Detail: string(result.Status), CreatedAt: stamp(time.Now())})
	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: seq,
		Kind: store.EventRunFinished, Detail: string(result.Status), CreatedAt: stamp(time.Now())})

	outcome.Status = string(result.Status)
	outcome.ExitCode = result.ExitCode
	outcome.DurationMS = result.Duration.Milliseconds()
	outcome.Error = result.Error
	outcome.Stdout = result.Stdout
	outcome.Stderr = result.Stderr
	return outcome
}

// reportRun prints the outcome and returns the process exit code: 0 only when
// the worker succeeded, 1 for a failed run or a lost claim, 2 for usage.
func reportRun(outcome runOutcome, asJSON bool, stdout, stderr io.Writer) int {
	if asJSON {
		if !writeJSON(stdout, outcome) {
			return 1
		}
		if outcome.Status == string(executor.StatusSuccess) {
			return 0
		}
		return 1
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "task:\t%s\n", outcome.TaskID)
	fmt.Fprintf(writer, "agent:\t%s\n", outcome.Agent)
	fmt.Fprintf(writer, "executor:\t%s\n", outcome.Executor)
	if outcome.Claimed {
		fmt.Fprintf(writer, "claim:\tacquired\n")
		fmt.Fprintf(writer, "attempt:\t%d\n", outcome.Attempt)
	} else {
		fmt.Fprintf(writer, "claim:\t%s\n", outcome.Reason)
	}
	fmt.Fprintf(writer, "status:\t%s\n", outcome.Status)
	if outcome.Claimed {
		fmt.Fprintf(writer, "exit:\t%d\n", outcome.ExitCode)
		fmt.Fprintf(writer, "duration:\t%dms\n", outcome.DurationMS)
	}
	if outcome.Error != "" {
		fmt.Fprintf(writer, "error:\t%s\n", outcome.Error)
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}

	if outcome.Stdout != "" {
		fmt.Fprintln(stdout, "--- stdout ---")
		fmt.Fprintln(stdout, strings.TrimRight(outcome.Stdout, "\r\n"))
	}
	if outcome.Stderr != "" {
		fmt.Fprintln(stdout, "--- stderr ---")
		fmt.Fprintln(stdout, strings.TrimRight(outcome.Stderr, "\r\n"))
	}

	if outcome.Status == string(executor.StatusSuccess) {
		return 0
	}
	return 1
}

// commandDescription mirrors the informational command string of the
// PowerShell evidence writer (the real argv is deliberately not logged).
func commandDescription(worker executor.Executor, spec executor.TaskSpec) string {
	if described, ok := worker.(interface {
		Command(executor.TaskSpec) string
	}); ok {
		return described.Command(spec)
	}
	return worker.Name() + " executor"
}

// buildPrompt mirrors the prompt construction of inbox-engine.ps1 so both
// engines drive the worker with the same contract.
func buildPrompt(root, taskText string) string {
	contextBuffer := filepath.Join(root, "CONTEXT-BUFFER.md")
	return "You received a task from agent-hq bus. Read the last 30 lines of " + contextBuffer +
		" (iron rules protocol), execute the task, result write to CONTEXT-BUFFER.md, answer briefly. " +
		"CRITICAL: end your final answer with a line containing exactly 'STATUS: resolved' " +
		"(or 'STATUS: done' if completed) in stdout, otherwise the run is treated as failed. " +
		"TASK: " + taskText
}

func extractRunOptions(args []string) (runOptions, []string) {
	options := runOptions{executor: "opencode"}
	rest := make([]string, 0, len(args))
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch {
		case arg == "-executor" || arg == "--executor":
			if index+1 < len(args) {
				options.executor = args[index+1]
				index++
			}
		case strings.HasPrefix(arg, "-executor=") || strings.HasPrefix(arg, "--executor="):
			options.executor = arg[strings.Index(arg, "=")+1:]
		case arg == "-id" || arg == "--id":
			if index+1 < len(args) {
				options.taskID = args[index+1]
				index++
			}
		case strings.HasPrefix(arg, "-id=") || strings.HasPrefix(arg, "--id="):
			options.taskID = arg[strings.Index(arg, "=")+1:]
		case arg == "-model" || arg == "--model":
			if index+1 < len(args) {
				options.model = args[index+1]
				index++
			}
		case strings.HasPrefix(arg, "-model=") || strings.HasPrefix(arg, "--model="):
			options.model = arg[strings.Index(arg, "=")+1:]
		case arg == "-lease" || arg == "--lease":
			if index+1 < len(args) {
				if seconds, err := strconv.Atoi(args[index+1]); err == nil && seconds > 0 {
					options.lease = seconds
				}
				index++
			}
		case strings.HasPrefix(arg, "-lease=") || strings.HasPrefix(arg, "--lease="):
			if seconds, err := strconv.Atoi(arg[strings.Index(arg, "=")+1:]); err == nil && seconds > 0 {
				options.lease = seconds
			}
		default:
			rest = append(rest, arg)
		}
	}
	return options, rest
}

// newRunID generates a unique id without a filesystem round trip.
func newRunID() string {
	return "run-" + strconv.FormatInt(time.Now().UnixNano(), 10)
}

// newOwner identifies this process in the lease, so a stale owner can never
// release a lease another process has since taken.
func newOwner() string {
	host, err := os.Hostname()
	if err != nil || strings.TrimSpace(host) == "" {
		host = "host"
	}
	return fmt.Sprintf("%s-%d-%d", host, os.Getpid(), time.Now().UnixNano())
}

func sumHex(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func durationPtr(duration time.Duration) *int64 {
	millis := duration.Milliseconds()
	return &millis
}

// stamp renders a UTC timestamp in the same shape the store uses.
func stamp(value time.Time) string {
	return value.UTC().Format(time.RFC3339Nano)
}

// heartbeat tuning: a lease is refreshed at a third of its lifetime, so a
// worker survives two missed ticks before the watchdog would consider it
// expired. Very short leases (and tests) clamp to the minimum interval.
const (
	heartbeatDivisor     = 3
	minHeartbeatInterval = time.Second
)

// heartbeatIntervalOverride lets tests replace the lease-derived ticker with a
// short interval. Zero means "derive from the lease".
var heartbeatIntervalOverride time.Duration

// heartbeatIntervalFor returns how often a lease of leaseSeconds must be
// refreshed. A non-positive lease uses the store default.
func heartbeatIntervalFor(leaseSeconds int) time.Duration {
	if heartbeatIntervalOverride > 0 {
		return heartbeatIntervalOverride
	}
	if leaseSeconds <= 0 {
		leaseSeconds = store.DefaultRunLeaseSeconds
	}
	interval := time.Duration(leaseSeconds) * time.Second / heartbeatDivisor
	if interval < minHeartbeatInterval {
		interval = minHeartbeatInterval
	}
	return interval
}

// startHeartbeat refreshes the owner's lease on a ticker until the returned
// stop function is called. The stop function is idempotent and waits for the
// goroutine to finish, so no ticker outlives a run. A heartbeat error (for
// example a database that went away) is reported to observe instead of being
// swallowed; a lost lease is not an error here, because the owner-guarded
// UPDATE simply affects no rows.
func startHeartbeat(handle *store.Store, taskID, owner string, leaseSeconds int, observe func(error)) func() {
	interval := heartbeatIntervalFor(leaseSeconds)
	done := make(chan struct{})
	stopped := make(chan struct{})
	var once sync.Once

	go func() {
		defer close(stopped)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if _, err := handle.HeartbeatClaim(taskID, owner, time.Now()); err != nil && observe != nil {
					observe(err)
				}
			}
		}
	}()

	return func() {
		once.Do(func() {
			close(done)
			<-stopped
		})
	}
}
