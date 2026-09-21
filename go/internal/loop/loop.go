// Package loop implements the Go control plane of the agent-hq bus: it scans the
// same inbox the PowerShell engine owns (plus the project queues), takes an
// atomic lease per task, executes the worker through an Executor and publishes
// the result into the same bus folders, in the same format.
//
// The package is deliberately small and single-threaded: bounded work, one task
// at a time, everything durable before and after the worker runs. It never
// invents a second format and never writes anywhere the PowerShell engine does
// not already write.
package loop

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"agent-hq/internal/bus"
	"agent-hq/internal/driver"
	"agent-hq/internal/executor"
	"agent-hq/internal/store"
)

// Item statuses reported per processed unit of work.
const (
	StatusDone       = "done"
	StatusDeadLetter = "dead-letter"
	StatusDead       = "dead"
	StatusSkipped    = "skipped"
	StatusError      = "error"
)

// Sources of a unit of work.
const (
	SourceInbox = "inbox"
	SourceQueue = "queue"
)

// DefaultInterval is the pause between two passes of the daemon loop.
const DefaultInterval = 30 * time.Second

// DefaultStaleTTL matches the sweep TTL of Process-Inbox in inbox-engine.ps1.
const DefaultStaleTTL = 900 * time.Second

// heartbeatSlice is how often a long-running attempt refreshes its leases; the
// PowerShell engine waits in 30-second slices for exactly the same reason.
const heartbeatSlice = 30 * time.Second

// Options configures a Runner.
type Options struct {
	Root         string
	Executor     executor.Executor
	Max          int
	Once         bool
	Interval     time.Duration
	LeaseSeconds int
	StaleTTL     time.Duration
	Owner        string
	DriverMode   string
	Queue        bool
	// Logger receives human progress lines; the CLI sends them to stderr so a
	// -json report on stdout stays parseable.
	Logger func(format string, args ...any)
	Now    func() time.Time
}

// Item is the outcome of one unit of work.
type Item struct {
	Source      string `json:"source"`
	Project     string `json:"project,omitempty"`
	TaskID      string `json:"task_id"`
	Agent       string `json:"agent,omitempty"`
	Status      string `json:"status"`
	Reason      string `json:"reason,omitempty"`
	Destination string `json:"destination,omitempty"`
	Evidence    string `json:"evidence,omitempty"`
	Attempts    int    `json:"attempts"`
}

// Report is the machine-readable result of a run.
type Report struct {
	Root       string   `json:"root"`
	DriverMode string   `json:"driver_mode"`
	Executor   string   `json:"executor"`
	StartedAt  string   `json:"started_at"`
	FinishedAt string   `json:"finished_at,omitempty"`
	Passes     int      `json:"passes"`
	Processed  int      `json:"processed"`
	Done       int      `json:"done"`
	DeadLetter int      `json:"dead_letter"`
	Skipped    int      `json:"skipped"`
	Errors     int      `json:"errors"`
	Recovered  []string `json:"recovered"`
	Items      []Item   `json:"items"`
	Warnings   []string `json:"warnings"`
}

// Runner drives the loop for one root.
type Runner struct {
	options  Options
	store    *store.Store
	logf     func(format string, args ...any)
	started  time.Time
	lockMu   sync.Mutex
	lock     driver.Lock
	hasLock  bool
	warnings []string
}

// New opens the durable store and prepares the bus directories. It refuses a
// root that does not look like an agent-hq checkout.
func New(options Options) (*Runner, error) {
	if strings.TrimSpace(options.Root) == "" {
		return nil, fmt.Errorf("run loop: empty root")
	}
	if options.Executor == nil {
		return nil, fmt.Errorf("run loop: no executor")
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Interval <= 0 {
		options.Interval = DefaultInterval
	}
	if options.LeaseSeconds <= 0 {
		options.LeaseSeconds = defaultLeaseSeconds(options.Executor)
	}
	if options.StaleTTL <= 0 {
		options.StaleTTL = DefaultStaleTTL
	}
	if strings.TrimSpace(options.Owner) == "" {
		options.Owner = defaultOwner()
	}

	memory := bus.MemoryDir(options.Root)
	if info, err := os.Stat(memory); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("run loop: %s is missing; not an agent-hq root", memory)
	}
	for _, dir := range []string{
		bus.InboxDir(options.Root), bus.OutboxDir(options.Root), bus.ArchiveDir(options.Root),
		bus.DeadLetterDir(options.Root), bus.ClaimsDir(options.Root), bus.TracesDir(options.Root),
		bus.EvidenceDir(options.Root),
	} {
		if err := bus.EnsureDir(dir); err != nil {
			return nil, err
		}
	}

	handle, err := store.Open(options.Root)
	if err != nil {
		return nil, err
	}

	runner := &Runner{options: options, store: handle, started: options.Now()}
	runner.logf = runner.buildLogger()
	return runner, nil
}

// Close releases the durable store.
func (r *Runner) Close() error {
	if r.store == nil {
		return nil
	}
	return r.store.Close()
}

// Run executes one pass (Once) or loops until the context is cancelled. The
// returned report collects every pass.
func (r *Runner) Run(ctx context.Context) *Report {
	report := &Report{
		Root:       r.options.Root,
		DriverMode: r.options.DriverMode,
		Executor:   r.options.Executor.Name(),
		StartedAt:  r.options.Now().Format(time.RFC3339),
		Items:      []Item{},
		Recovered:  []string{},
		Warnings:   []string{},
	}
	r.startLock()
	defer r.stopLock()

	for {
		r.refreshLock()
		items, warnings, recovered := r.pass(ctx)
		report.Passes++
		report.Warnings = append(report.Warnings, warnings...)
		report.Recovered = append(report.Recovered, recovered...)
		for _, item := range items {
			report.Items = append(report.Items, item)
			report.Processed++
			switch item.Status {
			case StatusDone:
				report.Done++
			case StatusDeadLetter, StatusDead:
				report.DeadLetter++
			case StatusSkipped:
				report.Skipped++
			case StatusError:
				report.Errors++
			}
		}
		if r.options.Once || ctx.Err() != nil {
			break
		}
		select {
		case <-ctx.Done():
		case <-time.After(r.options.Interval):
		}
	}
	report.FinishedAt = r.options.Now().Format(time.RFC3339)
	return report
}

// pass performs one bounded pass: recover stale leases, then process pending
// inbox messages followed by pending queue tasks.
func (r *Runner) pass(ctx context.Context) (items []Item, warnings []string, recovered []string) {
	items = []Item{}
	warnings = []string{}
	recovered = r.recoverStale()

	for _, message := range r.pendingInbox(&warnings) {
		if ctx.Err() != nil || r.limitReached(items) {
			break
		}
		items = append(items, r.processInbox(ctx, message))
	}

	if r.options.Queue {
		for _, queued := range r.pendingQueue(&warnings) {
			if ctx.Err() != nil || r.limitReached(items) {
				break
			}
			items = append(items, r.processQueueTask(ctx, queued.queue, queued.task))
		}
	}
	return items, warnings, recovered
}

func (r *Runner) limitReached(items []Item) bool {
	return r.options.Max > 0 && len(items) >= r.options.Max
}

// recoverStale reconciles leases whose owner is gone: running attempts in the
// durable store become stale (M2 recovery) and file leases are revoked like the
// PowerShell stale sweep does.
func (r *Runner) recoverStale() []string {
	recovered := []string{}

	stale, err := r.store.StaleAttempts(r.options.Now(), 0)
	if err != nil {
		r.logf("recover: cannot list stale attempts: %v", err)
	} else {
		for _, attempt := range stale {
			done, recoverErr := r.store.RecoverAttempt(store.RecoverRequest{
				TaskID: attempt.TaskID, Seq: attempt.Seq, Owner: attempt.Owner,
				Reason: attempt.Reason, Now: r.options.Now(),
			})
			if recoverErr != nil {
				r.logf("recover: %s/%d failed: %v", attempt.TaskID, attempt.Seq, recoverErr)
				continue
			}
			if done {
				recovered = append(recovered, attempt.TaskID)
				r.logf("recover: task '%s' attempt %d marked stale (%s)", attempt.TaskID, attempt.Seq, attempt.Reason)
			}
		}
	}

	revoked, err := bus.RevokeStaleClaims(bus.ClaimsDir(r.options.Root), r.options.StaleTTL, r.options.Now())
	if err != nil {
		r.logf("recover: cannot sweep file claims: %v", err)
	}
	for _, taskID := range revoked {
		recovered = append(recovered, taskID)
		r.logf("recover: revoked stale file claim '%s'", taskID)
	}
	return recovered
}

// pendingInbox lists the pending inbox files.
func (r *Runner) pendingInbox(warnings *[]string) []bus.InboxMessage {
	messages, scanWarnings := bus.ScanInbox(r.options.Root)
	*warnings = append(*warnings, scanWarnings...)
	return messages
}

type queuedTask struct {
	queue *bus.Queue
	task  map[string]any
}

// pendingQueue lists the pending tasks of every project queue, highest priority
// first. Like the inbox scan, one pass drains everything pending and the caller
// bounds the work with Max.
func (r *Runner) pendingQueue(warnings *[]string) []queuedTask {
	projects, err := bus.DiscoverQueueProjects(r.options.Root)
	if err != nil {
		*warnings = append(*warnings, "queue: cannot list projects: "+err.Error())
		return nil
	}
	pending := make([]queuedTask, 0, len(projects))
	for _, project := range projects {
		queue, loadErr := bus.LoadQueue(r.options.Root, project)
		if loadErr != nil {
			*warnings = append(*warnings, "queue: broken "+project+"/queue.json: "+loadErr.Error())
			continue
		}
		if queue == nil {
			continue
		}
		for _, task := range queue.PendingSorted() {
			pending = append(pending, queuedTask{queue: queue, task: task})
		}
	}
	return pending
}

// processInbox handles one inbox message with the exact lifecycle of
// Process-InboxFile: parse, claim, payload guard, up to two attempts, then
// outbox+archive or dead-letter.
func (r *Runner) processInbox(ctx context.Context, message bus.InboxMessage) Item {
	root := r.options.Root
	item := Item{Source: SourceInbox, TaskID: bus.BaseName(message.FilePath), Attempts: 0}

	parsed, err := bus.ParseInboxFile(message)
	if err != nil {
		target, moveErr := bus.MoveToDeadLetterUnparsed(root, message.FilePath)
		if moveErr != nil {
			item.Status = StatusError
			item.Reason = "parse-error: " + moveErr.Error()
			return item
		}
		item.Status = StatusDeadLetter
		item.Reason = "parse-error"
		item.Destination = target
		r.logf("dead-letter: %s is not valid json", item.TaskID)
		return item
	}

	item.TaskID = parsed.ID
	agent := parsed.TargetAgent()
	item.Agent = agent
	if agent == "" {
		target, moveErr := bus.MoveToDeadLetterUnparsed(root, message.FilePath)
		if moveErr != nil {
			item.Status = StatusError
			item.Reason = "no-target-agent: " + moveErr.Error()
			return item
		}
		item.Status = StatusDeadLetter
		item.Reason = "no-target-agent"
		item.Destination = target
		return item
	}

	claimsDir := bus.ClaimsDir(root)
	if owned, claimErr := bus.ClaimFile(claimsDir, parsed.ID, agent, r.options.LeaseSeconds, 1); claimErr != nil {
		item.Status = StatusError
		item.Reason = "claim-error: " + claimErr.Error()
		return item
	} else if !owned {
		item.Status = StatusSkipped
		item.Reason = "already-claimed"
		return item
	}
	claimed, acquireErr := r.store.AcquireClaim(store.ClaimRequest{
		TaskID: parsed.ID, Owner: r.options.Owner, Agent: agent,
		LeaseSeconds: r.options.LeaseSeconds, Now: r.options.Now(),
	})
	if acquireErr != nil {
		_, _ = bus.ReleaseFile(claimsDir, parsed.ID, agent)
		item.Status = StatusError
		item.Reason = "claim-error: " + acquireErr.Error()
		return item
	}
	if !claimed {
		_, _ = bus.ReleaseFile(claimsDir, parsed.ID, agent)
		item.Status = StatusSkipped
		item.Reason = "already-claimed"
		return item
	}
	defer func() {
		_, _ = r.store.ReleaseClaim(parsed.ID, r.options.Owner)
		_, _ = bus.ReleaseFile(claimsDir, parsed.ID, agent)
	}()

	startedAt := bus.FormatDateTime(r.options.Now())
	payload := parsed.PayloadText()
	priority := strings.TrimSpace(parsed.Priority)
	if priority == "" {
		priority = "normal"
	}
	envelope := bus.Envelope{
		ID:        parsed.ID,
		From:      parsed.From,
		To:        agent,
		Type:      "result",
		Priority:  priority,
		Payload:   bus.NormalizePayload(parsed.Payload),
		Status:    StatusDone,
		StartedAt: startedAt,
		Evidence:  "",
	}

	if len(parsed.Payload) == 0 || payload == "" {
		envelope.Type = "failed"
		envelope.Status = "failed"
		envelope.FinishedAt = bus.FormatDateTime(r.options.Now())
		envelope.Response = "Empty payload \u2014 no task to process"
		target, writeErr := bus.WriteDeadLetter(root, message.FilePath, envelope)
		if writeErr != nil {
			item.Status = StatusError
			item.Reason = "dead-letter-write: " + writeErr.Error()
			return item
		}
		item.Status = StatusDeadLetter
		item.Reason = "empty-payload"
		item.Destination = target
		r.logf("dead-letter: %s has an empty payload", item.TaskID)
		return item
	}

	requireMarker := !parsed.IsInteractive()
	prompt := bus.BuildPrompt(root, payload)

	first := r.runAttempt(ctx, parsed.ID, agent, prompt, 1, requireMarker, claimsDir)
	item.Attempts = 1
	item.Evidence = first.evidence
	if first.success {
		envelope.Response = bus.Truncate(bus.Redact(first.stdout), bus.MaxResponseLength)
		envelope.Evidence = first.evidence
		envelope.FinishedAt = bus.FormatDateTime(r.options.Now())
		_, writeErr := bus.WriteOutbox(root, agent, bus.FileName(message.FilePath), envelope)
		if writeErr != nil {
			item.Status = StatusError
			item.Reason = "outbox-write: " + writeErr.Error()
			return item
		}
		archivePath, archiveErr := bus.ArchiveInbox(root, message.FilePath, agent)
		if archiveErr != nil {
			r.logf("archive: %s: %v", item.TaskID, archiveErr)
			item.Reason = "archive-failed"
		}
		item.Status = StatusDone
		item.Destination = archivePath
		r.logf("done: %s -> outbox (%s)", item.TaskID, agent)
		return item
	}

	r.logf("retry: %s attempt-1 failed (%s)", item.TaskID, first.reason)
	second := r.runAttempt(ctx, parsed.ID, agent, prompt, 2, requireMarker, claimsDir)
	item.Attempts = 2
	item.Evidence = second.evidence
	if second.success {
		envelope.Response = bus.Truncate(bus.Redact(second.stdout), bus.MaxResponseLength)
		envelope.Evidence = second.evidence
		envelope.FinishedAt = bus.FormatDateTime(r.options.Now())
		if _, writeErr := bus.WriteOutbox(root, agent, bus.FileName(message.FilePath), envelope); writeErr != nil {
			item.Status = StatusError
			item.Reason = "outbox-write: " + writeErr.Error()
			return item
		}
		archivePath, archiveErr := bus.ArchiveInbox(root, message.FilePath, agent)
		if archiveErr != nil {
			item.Reason = "archive-failed"
		}
		item.Status = StatusDone
		item.Destination = archivePath
		r.logf("done: %s -> outbox after retry (%s)", item.TaskID, agent)
		return item
	}

	envelope.Type = "failed"
	envelope.Status = "failed"
	envelope.FinishedAt = bus.FormatDateTime(r.options.Now())
	envelope.Response = bus.Redact(bus.FormatAttemptReport("First attempt failed: "+first.reason, first.exitCode, first.stdout, first.stderr) +
		"\n\n" +
		bus.FormatAttemptReport("Retry failed: "+second.reason, second.exitCode, second.stdout, second.stderr))
	envelope.Evidence = second.evidence
	target, writeErr := bus.WriteDeadLetter(root, message.FilePath, envelope)
	if writeErr != nil {
		item.Status = StatusError
		item.Reason = "dead-letter-write: " + writeErr.Error()
		return item
	}
	item.Status = StatusDeadLetter
	item.Reason = "failed-after-retry"
	item.Destination = target
	r.logf("dead-letter: %s failed after 2 attempts", item.TaskID)
	return item
}

// processQueueTask executes one project queue task and moves it to its terminal
// status. project-queue.ps1 defines the status transitions (in_progress -> done
// or dead); there is no bus envelope for a queue task, its result is the queue
// entry plus machine evidence, exactly like the PowerShell queue tooling.
func (r *Runner) processQueueTask(ctx context.Context, queue *bus.Queue, task map[string]any) Item {
	root := r.options.Root
	taskID := bus.TaskString(task, "id")
	agent := bus.TaskString(task, "assigned_agent")
	item := Item{Source: SourceQueue, Project: queue.Project, TaskID: taskID, Agent: agent}

	if strings.TrimSpace(agent) == "" {
		item.Status = StatusSkipped
		item.Reason = "no-target-agent"
		return item
	}

	// A pending task whose evidence already records a successful attempt is a
	// leftover (the engine wrote evidence but crashed before the status update).
	// Reconcile it instead of running it twice; the shadow plan announces exactly
	// this decision with processed-by-ps.
	if bus.HasSuccessfulAttempt(root, taskID) {
		bus.SetTaskField(task, "status", "done")
		bus.SetTaskField(task, "completed_at", bus.NowStampFormatted(r.options.Now()))
		item.Status = StatusDone
		item.Reason = "already-completed"
		item.Destination = "queue"
		item.Evidence = bus.EvidenceRelativePath(taskID)
		if err := queue.Save(); err != nil {
			item.Status = StatusError
			item.Reason = "queue-save: " + err.Error()
			return item
		}
		r.logf("reconciled: queue task %s (%s) already has success evidence", taskID, queue.Project)
		return item
	}

	claimsDir := bus.ProjectClaimsDir(root, queue.Project)
	if owned, claimErr := bus.ClaimFile(claimsDir, taskID, agent, r.options.LeaseSeconds, 1); claimErr != nil {
		item.Status = StatusError
		item.Reason = "claim-error: " + claimErr.Error()
		return item
	} else if !owned {
		item.Status = StatusSkipped
		item.Reason = "already-claimed"
		return item
	}
	claimed, acquireErr := r.store.AcquireClaim(store.ClaimRequest{
		TaskID: taskID, Owner: r.options.Owner, Agent: agent,
		LeaseSeconds: r.options.LeaseSeconds, Now: r.options.Now(),
	})
	if acquireErr != nil || !claimed {
		_, _ = bus.ReleaseFile(claimsDir, taskID, agent)
		item.Status = StatusSkipped
		item.Reason = "already-claimed"
		if acquireErr != nil {
			item.Status = StatusError
			item.Reason = "claim-error: " + acquireErr.Error()
		}
		return item
	}
	defer func() {
		_, _ = r.store.ReleaseClaim(taskID, r.options.Owner)
		_, _ = bus.ReleaseFile(claimsDir, taskID, agent)
	}()

	bus.SetTaskField(task, "status", "in_progress")
	bus.SetTaskField(task, "started_at", bus.NowStampFormatted(r.options.Now()))
	if err := queue.Save(); err != nil {
		item.Status = StatusError
		item.Reason = "queue-save: " + err.Error()
		return item
	}

	prompt := bus.BuildPrompt(root, queueTaskPayload(task))
	first := r.runAttempt(ctx, taskID, agent, prompt, 1, true, claimsDir)
	item.Attempts = 1
	item.Evidence = first.evidence
	success, reason, evidence := first.success, first.reason, first.evidence
	if !success {
		r.logf("retry: %s (queue %s) attempt-1 failed (%s)", taskID, queue.Project, first.reason)
		second := r.runAttempt(ctx, taskID, agent, prompt, 2, true, claimsDir)
		item.Attempts = 2
		item.Evidence = second.evidence
		success, reason, evidence = second.success, second.reason, second.evidence
	}

	if success {
		bus.SetTaskField(task, "status", "done")
		bus.SetTaskField(task, "completed_at", bus.NowStampFormatted(r.options.Now()))
		item.Status = StatusDone
		item.Destination = "queue"
		item.Evidence = evidence
	} else {
		bus.SetTaskField(task, "status", "dead")
		bus.SetTaskField(task, "dead_reason", reason)
		bus.SetTaskField(task, "dead_at", bus.NowStampFormatted(r.options.Now()))
		item.Status = StatusDead
		item.Reason = reason
		item.Destination = "queue"
	}
	if err := queue.Save(); err != nil {
		item.Status = StatusError
		item.Reason = "queue-save: " + err.Error()
		return item
	}
	r.logf("queue task %s (%s) -> %s", taskID, queue.Project, item.Status)
	return item
}

// queueTaskPayload is the task text handed to the worker: the title plus the
// optional description, so a queue entry carries the same information a bus
// message payload would.
func queueTaskPayload(task map[string]any) string {
	payload := strings.TrimSpace(bus.TaskString(task, "title"))
	if description := strings.TrimSpace(bus.TaskString(task, "description")); description != "" {
		payload += "\n" + description
	}
	return payload
}

// attemptResult is one finished worker attempt.
type attemptResult struct {
	index    int
	exitCode int
	stdout   string
	stderr   string
	success  bool
	reason   string
	evidence string
}

// runAttempt executes one attempt and appends its machine evidence. The
// classification is the PowerShell rule (bus.AttemptSucceeded), not the broader
// executor one, so a benign subagent warning can never fail a good run.
func (r *Runner) runAttempt(ctx context.Context, taskID, agent, prompt string, index int, requireMarker bool, claimsDir string) attemptResult {
	spec := executor.TaskSpec{
		ID:        taskID,
		Agent:     agent,
		Payload:   prompt,
		AttemptID: fmt.Sprintf("attempt-%d", index),
	}
	startedAt := r.options.Now()
	stop := r.startHeartbeat(taskID, agent, claimsDir)
	result, execErr := r.options.Executor.Execute(ctx, spec)
	stop()
	finishedAt := r.options.Now()

	exitCode := result.ExitCode
	stdout, stderr := bus.NormalizeWorkerStdout(result.Stdout), result.Stderr
	if execErr != nil {
		exitCode = -1
		if strings.TrimSpace(stderr) == "" {
			stderr = execErr.Error()
		} else {
			stderr = stderr + "\n" + execErr.Error()
		}
	}
	if result.Status == executor.StatusTimeout {
		exitCode = bus.TimeoutExitCode
		stdout = bus.TimeoutMessage(agent, int(r.jobTimeout().Seconds()))
	}

	success := bus.AttemptSucceeded(exitCode, stdout, stderr, requireMarker)
	status, reason := "failed", ""
	if success {
		status = "success"
	} else {
		reason = bus.FailureReason(exitCode, stdout, stderr, requireMarker)
	}

	record := bus.BuildEvidenceRecord(r.options.Root, taskID, spec.AttemptID, agent,
		r.commandDescription(spec), exitCode, stdout, stderr, startedAt, finishedAt, status, reason)
	evidence, err := bus.AppendEvidence(r.options.Root, record)
	if err != nil {
		r.logf("evidence: %s/%s not written: %v", taskID, spec.AttemptID, err)
		evidence = ""
	}
	r.logf("evidence: %s/%s status=%s exit=%d", taskID, spec.AttemptID, status, exitCode)

	return attemptResult{index: index, exitCode: exitCode, stdout: stdout, stderr: stderr,
		success: success, reason: reason, evidence: evidence}
}

// commandDescription mirrors the informational command string recorded in
// machine evidence by the PowerShell engine.
func (r *Runner) commandDescription(spec executor.TaskSpec) string {
	if described, ok := r.options.Executor.(interface {
		Command(executor.TaskSpec) string
	}); ok {
		return described.Command(spec)
	}
	return r.options.Executor.Name() + " executor"
}

// jobTimeout reports the worker timeout the executor uses.
func (r *Runner) jobTimeout() time.Duration {
	if source, ok := r.options.Executor.(interface {
		Timeout() time.Duration
	}); ok {
		if value := source.Timeout(); value > 0 {
			return value
		}
	}
	return executor.JobTimeout()
}

// startHeartbeat refreshes both leases (and the driver lock) while an attempt
// runs, so a long worker never loses its claim or looks dead to the fallback.
func (r *Runner) startHeartbeat(taskID, agent, claimsDir string) func() {
	done := make(chan struct{})
	stopped := make(chan struct{})
	var once sync.Once

	go func() {
		defer close(stopped)
		ticker := time.NewTicker(heartbeatSlice)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if _, err := r.store.HeartbeatClaim(taskID, r.options.Owner, time.Now()); err != nil {
					r.logf("heartbeat: store %s: %v", taskID, err)
				}
				if _, err := bus.HeartbeatFile(claimsDir, taskID, agent); err != nil {
					r.logf("heartbeat: file %s: %v", taskID, err)
				}
				r.refreshLock()
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

// startLock records the liveness document of this driver.
func (r *Runner) startLock() {
	r.lockMu.Lock()
	defer r.lockMu.Unlock()
	r.lock = driver.Lock{
		Mode:        driver.ModeGo,
		PID:         os.Getpid(),
		StartedAt:   r.options.Now().Format(time.RFC3339Nano),
		HeartbeatAt: r.options.Now().Format(time.RFC3339Nano),
		Cycles:      0,
	}
	r.hasLock = true
	if err := driver.WriteLock(r.options.Root, r.lock); err != nil {
		r.logf("lock: cannot write driver.lock: %v", err)
	}
}

// refreshLock bumps the liveness heartbeat.
func (r *Runner) refreshLock() {
	r.lockMu.Lock()
	defer r.lockMu.Unlock()
	if !r.hasLock {
		return
	}
	r.persistLock()
}

// persistLock writes the liveness document with a fresh heartbeat; the caller
// holds lockMu.
func (r *Runner) persistLock() {
	r.lock.HeartbeatAt = r.options.Now().Format(time.RFC3339Nano)
	r.lock.Cycles++
	if err := driver.WriteLock(r.options.Root, r.lock); err != nil {
		r.logf("lock: cannot refresh driver.lock: %v", err)
	}
}

// stopLock ends the liveness of this run. A daemon removes the document on a
// clean shutdown, which immediately hands the loop back to the PowerShell
// fallback. A scheduled `run-loop -once` pass is period-driven instead: it keeps
// the document with a fresh heartbeat, so the PowerShell poller stands down
// between two scheduled passes and the heartbeat expires on its own (see
// driver.DefaultLockTTL) when the schedule stops firing.
func (r *Runner) stopLock() {
	r.lockMu.Lock()
	defer r.lockMu.Unlock()
	if !r.hasLock {
		return
	}
	r.hasLock = false
	if r.options.Once {
		r.persistLock()
		return
	}
	if err := driver.RemoveLock(r.options.Root); err != nil {
		r.logf("lock: cannot remove driver.lock: %v", err)
	}
}

// buildLogger routes log lines to the caller and appends them to
// .memory/traces/run-loop.log, like the PowerShell engine logs to poller.log.
func (r *Runner) buildLogger() func(format string, args ...any) {
	return func(format string, args ...any) {
		line := time.Now().Format("15:04:05") + " " + fmt.Sprintf(format, args...)
		if r.options.Logger != nil {
			r.options.Logger("%s", line)
		}
		logPath := filepath.Join(bus.TracesDir(r.options.Root), "run-loop.log")
		file, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			return
		}
		defer func() { _ = file.Close() }()
		_, _ = file.WriteString(line + "\n")
	}
}

// defaultLeaseSeconds mirrors ClaimLeaseSeconds in inbox-engine.ps1: a lease must
// outlive the worst case (two attempts plus overhead).
func defaultLeaseSeconds(worker executor.Executor) int {
	timeout := executor.JobTimeout()
	if source, ok := worker.(interface {
		Timeout() time.Duration
	}); ok {
		if value := source.Timeout(); value > 0 {
			timeout = value
		}
	}
	return int(timeout.Seconds())*2 + 300
}

// defaultOwner identifies this process in both lease systems.
func defaultOwner() string {
	host, err := os.Hostname()
	if err != nil || strings.TrimSpace(host) == "" {
		host = "host"
	}
	return fmt.Sprintf("%s-%d-%d", host, os.Getpid(), time.Now().UnixNano())
}
