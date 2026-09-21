package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
	"text/tabwriter"
	"time"

	"agent-hq/internal/bus"
	"agent-hq/internal/executor"
	"agent-hq/internal/net"
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
	TaskID     string   `json:"task_id"`
	Agent      string   `json:"agent"`
	Executor   string   `json:"executor"`
	Attempt    int      `json:"attempt"`
	Status     string   `json:"status"`
	ExitCode   int      `json:"exit_code"`
	DurationMS int64    `json:"duration_ms"`
	Error      string   `json:"error,omitempty"`
	Reason     string   `json:"reason,omitempty"`
	Claimed    bool     `json:"claimed"`
	Fault      string   `json:"fault,omitempty"`
	Healing    []string `json:"healing,omitempty"`
	Stdout     string   `json:"stdout,omitempty"`
	Stderr     string   `json:"stderr,omitempty"`
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
// write-after, release, and (from M3) the network self-healing loop. It never
// panics on store errors; a failed bookkeeping step is reported in the outcome.
func executeRun(ctx context.Context, handle *store.Store, worker executor.Executor, spec executor.TaskSpec, owner string, leaseSeconds int) runOutcome {
	return executeRunWithHealing(ctx, handle, worker, spec, owner, leaseSeconds, defaultHealOptions(handle.Root()))
}

// healOptions configures the M3 self-healing loop. Tests build it by hand; the
// zero value disables healing entirely.
type healOptions struct {
	enabled      bool
	proxyURL     string
	prober       net.Prober
	healthPath   string
	passportPath string
	ladder       []string
	now          func() time.Time
}

// defaultHealOptions is the production configuration for root: proxy from the
// environment (CNTLM default), model-health and passport from the root, ladder
// from the packaged fallback list. No secret ever passes through here: only the
// proxy URL is read, and the model ids are public names.
func defaultHealOptions(root string) healOptions {
	return healOptions{
		enabled:      true,
		proxyURL:     resolveProxyURL(),
		prober:       net.DefaultProber(),
		healthPath:   net.ModelHealthPath(root),
		passportPath: net.PassportPath(root),
		ladder:       net.DefaultLadder,
		now:          time.Now,
	}
}

// resolveProxyURL returns the proxy the retry runs through, following the same
// precedence the rest of the fleet uses (AGENTS.md section 10).
func resolveProxyURL() string {
	for _, name := range []string{"AGENT_HQ_PROXY", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"} {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			return value
		}
	}
	return "http://" + net.DefaultProxyAddress
}

// attemptResult is what the healing loop needs to know about one attempt.
type attemptResult struct {
	seq    int
	result executor.Result
	fault  net.Status
	reason string
}

// runAttempt performs one crash-safe attempt: write-before (running row), run
// the worker, write-after (outcome row) and both lifecycle events. The fault
// classification is persisted in the attempt's error column, so even a provider
// outage leaves an auditable reason on disk.
func runAttempt(ctx context.Context, handle *store.Store, worker executor.Executor, spec executor.TaskSpec) (attemptResult, error) {
	seq, err := handle.StartAttempt(store.RunAttempt{
		TaskID: spec.ID, Agent: spec.Agent, Executor: worker.Name(),
		Command: commandDescription(worker, spec), StartedAt: stamp(time.Now()), Status: store.RunRunning,
	})
	if err != nil {
		return attemptResult{}, err
	}
	spec.AttemptID = fmt.Sprintf("attempt-%d", seq)
	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: seq,
		Kind: store.EventAttemptStarted, Detail: spec.AttemptID, CreatedAt: stamp(time.Now())})

	started := time.Now()
	result, execErr := worker.Execute(ctx, spec)
	finished := time.Now()
	if execErr != nil {
		result = executor.Result{Status: executor.StatusError, ExitCode: -1, Error: execErr.Error()}
	}
	if result.Duration <= 0 {
		result.Duration = finished.Sub(started)
	}

	fault, reason := classifyFault(result)
	if fault.Unhealthy() {
		result.Error = string(fault) + ": " + reason
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
	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: seq,
		Kind: store.EventAttemptFinished, Detail: string(result.Status), CreatedAt: stamp(time.Now())})

	return attemptResult{seq: seq, result: result, fault: fault, reason: reason}, nil
}

// classifyFault maps an executor result onto the network vocabulary. A
// successful run is always OK; an unrecognised failure stays UNKNOWN so a plain
// task failure never triggers a provider retry.
func classifyFault(result executor.Result) (net.Status, string) {
	if result.Status == executor.StatusSuccess {
		return net.StatusOK, ""
	}
	return net.Classify(result.ExitCode, result.Stdout, result.Stderr, result.Status == executor.StatusTimeout)
}

func executeRunWithHealing(ctx context.Context, handle *store.Store, worker executor.Executor, spec executor.TaskSpec, owner string, leaseSeconds int, heal healOptions) runOutcome {
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

	// The lease is refreshed for as long as the whole healing sequence runs, not
	// just the first attempt, so a retry cannot silently orphan the claim.
	var heartbeatAttempt int
	stopHeartbeat := startHeartbeat(handle, spec.ID, owner, leaseSeconds, func(err error) {
		_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: heartbeatAttempt,
			Kind: store.EventHeartbeatError, Detail: err.Error(), CreatedAt: stamp(time.Now())})
	})
	defer stopHeartbeat()

	attempt, err := runAttempt(ctx, handle, worker, spec)
	if err != nil {
		outcome.Status = store.RunError
		outcome.Error = err.Error()
		return outcome
	}
	heartbeatAttempt = attempt.seq
	outcome.Attempt = attempt.seq
	result := attempt.result
	outcome.Fault = string(attempt.fault)

	healing := make([]string, 0, 2)
	if heal.enabled && attempt.fault.Unhealthy() {
		result, attempt, healing = healRun(ctx, handle, worker, spec, attempt, heal, healing)
		outcome.Attempt = attempt.seq
		outcome.Fault = string(attempt.fault)
	}
	outcome.Healing = healing

	finishedAt := time.Now().UTC().Format(time.RFC3339Nano)
	run.Status = string(result.Status)
	run.Attempt = outcome.Attempt
	run.FinishedAt = finishedAt
	run.ExitCode = &result.ExitCode
	run.DurationMS = durationPtr(result.Duration)
	run.Error = result.Error
	run.UpdatedAt = finishedAt
	_ = handle.SaveRun(run)

	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: outcome.Attempt,
		Kind: store.EventRunFinished, Detail: string(result.Status), CreatedAt: stamp(time.Now())})

	outcome.Status = string(result.Status)
	outcome.ExitCode = result.ExitCode
	outcome.DurationMS = result.Duration.Milliseconds()
	outcome.Error = result.Error
	outcome.Stdout = result.Stdout
	outcome.Stderr = result.Stderr
	return outcome
}

// healRun applies the M3 recovery ladder to an unhealthy attempt: mark an
// invalid session, otherwise retry once through the proxy and then fall back to
// another model. Each action is an append-only event, so the recovery is
// auditable and replayable.
func healRun(ctx context.Context, handle *store.Store, worker executor.Executor, spec executor.TaskSpec, attempt attemptResult, heal healOptions, healing []string) (executor.Result, attemptResult, []string) {
	if attempt.fault.SessionFault() {
		return markSessionInvalid(handle, spec, attempt, healing)
	}

	// (a) one retry through the proxy, and only when the proxy actually answers.
	proxy := net.ProxyResult{Address: heal.proxyURL}
	if heal.proxyURL != "" {
		proxy = heal.prober.ProbeProxy(ctx, proxyAddress(heal.proxyURL))
	}
	if proxy.Status == net.StatusOK {
		_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: attempt.seq,
			Kind: store.EventProviderRetry, Detail: fmt.Sprintf("%s; retrying through %s", attempt.reason, proxy.Address),
			CreatedAt: stamp(time.Now())})
		healing = append(healing, "provider.retry via "+proxy.Address)
		retrySpec := spec
		retrySpec.Proxy = heal.proxyURL
		next, err := runAttempt(ctx, handle, worker, retrySpec)
		if err == nil {
			attempt = next
			healing = append(healing, "retry -> "+string(attempt.fault))
			// A retry can surface a session fault the first attempt did not
			// (e.g. the provider invalidated the session mid-run). It is never
			// retried again, but it must still leave a durable mark.
			if attempt.fault.SessionFault() {
				return markSessionInvalid(handle, spec, attempt, healing)
			}
		}
	}

	// (b) fall back to another healthy model when the provider is still down.
	if attempt.fault.ProviderFault() {
		fallback, why := selectFallback(heal, spec.Model)
		if fallback != "" {
			_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: attempt.seq,
				Kind: store.EventModelFallback, Detail: spec.Model + " -> " + fallback + " (" + why + ")",
				CreatedAt: stamp(time.Now())})
			healing = append(healing, "model.fallback -> "+fallback)
			fallbackSpec := spec
			fallbackSpec.Model = fallback
			next, err := runAttempt(ctx, handle, worker, fallbackSpec)
			if err == nil {
				attempt = next
				healing = append(healing, "fallback -> "+string(attempt.fault))
				if attempt.fault.SessionFault() {
					return markSessionInvalid(handle, spec, attempt, healing)
				}
			}
		} else {
			healing = append(healing, "no fallback: "+why)
		}
	}
	return attempt.result, attempt, healing
}

// markSessionInvalid records a durable invalid-session mark and its audit event
// for the attempt that carried the session fault. It is shared by the first
// attempt, the proxy retry and the fallback so every session fault is visible
// to `recover`, not just the initial one.
func markSessionInvalid(handle *store.Store, spec executor.TaskSpec, attempt attemptResult, healing []string) (executor.Result, attemptResult, []string) {
	if err := handle.MarkSessionInvalid(store.SessionMark{TaskID: spec.ID, Agent: spec.Agent,
		Status: store.SessionInvalid, Reason: attempt.reason, MarkedAt: stamp(time.Now())}); err != nil {
		_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: attempt.seq,
			Kind: store.EventSessionMarkError, Detail: "session mark failed: " + err.Error(), CreatedAt: stamp(time.Now())})
		return attempt.result, attempt, append(healing, "session mark failed")
	}
	_, _ = handle.AppendEvent(store.RunEvent{TaskID: spec.ID, Attempt: attempt.seq,
		Kind: store.EventSessionInvalid, Detail: attempt.reason, CreatedAt: stamp(time.Now())})
	return attempt.result, attempt, append(healing, "session-invalid marked")
}

// selectFallback prefers the passport's models (cheap tiers first) and fills up
// with the packaged ladder, so a broken or missing passport degrades to the
// same list model-router.ps1 uses.
func selectFallback(heal healOptions, current string) (string, string) {
	health := make([]net.ModelHealth, 0)
	if records, err := net.ReadModelHealthFile(heal.healthPath, heal.now()); err == nil {
		health = records
	}
	return net.SelectFallback(current, net.MergeCandidates(heal.passportPath, heal.ladder), health, heal.now())
}

// proxyAddress extracts host:port from a proxy URL for the TCP probe. A bare
// address is returned unchanged.
func proxyAddress(proxyURL string) string {
	trimmed := strings.TrimSpace(proxyURL)
	if withoutScheme, found := strings.CutPrefix(trimmed, "http://"); found {
		trimmed = withoutScheme
	} else if withoutScheme, found := strings.CutPrefix(trimmed, "https://"); found {
		trimmed = withoutScheme
	}
	if slash := strings.IndexAny(trimmed, "/?#"); slash >= 0 {
		trimmed = trimmed[:slash]
	}
	if strings.TrimSpace(trimmed) == "" {
		return net.DefaultProxyAddress
	}
	return trimmed
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
	if outcome.Fault != "" && outcome.Fault != string(net.StatusOK) {
		fmt.Fprintf(writer, "fault:\t%s\n", outcome.Fault)
	}
	if outcome.Claimed {
		fmt.Fprintf(writer, "exit:\t%d\n", outcome.ExitCode)
		fmt.Fprintf(writer, "duration:\t%dms\n", outcome.DurationMS)
	}
	if outcome.Error != "" {
		fmt.Fprintf(writer, "error:\t%s\n", outcome.Error)
	}
	for _, action := range outcome.Healing {
		fmt.Fprintf(writer, "healing:\t%s\n", action)
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
// engines drive the worker with the same contract. The text itself lives in
// internal/bus, where the bus loop uses the identical function.
func buildPrompt(root, taskText string) string {
	return bus.BuildPrompt(root, taskText)
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
