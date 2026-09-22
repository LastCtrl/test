package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Run lifecycle statuses persisted in the runs table. They mirror the terminal
// statuses of the executor package plus the transient "running" state written
// before the worker starts (crash-safe ordering).
const (
	RunRunning = "running"
	RunSuccess = "success"
	RunFailed  = "failed"
	RunTimeout = "timeout"
	RunError   = "error"
	// RunStale is written by the M2 watchdog when a running attempt stopped
	// refreshing its lease (crash, kill or hang) while the worker may still
	// hold the process. RunQueued is written instead when recovery is asked to
	// requeue the task for another attempt.
	RunStale  = "stale"
	RunQueued = "queued"
)

// Run lifecycle event kinds. Events are append-only and are the substrate the
// M2 watchdog/recovery will read.
const (
	EventClaimAcquired   = "claim.acquired"
	EventClaimConflict   = "claim.conflict"
	EventClaimReleased   = "claim.released"
	EventAttemptStarted  = "attempt.started"
	EventAttemptFinished = "attempt.finished"
	EventRunFinished     = "run.finished"
	// M2 durability events.
	EventHeartbeatError  = "heartbeat.error"
	EventAttemptStale    = "attempt.stale"
	EventRunStale        = "run.stale"
	EventRecoverRequeued = "recover.requeued"
	// M3 self-healing events.
	EventProviderRetry  = "provider.retry"
	EventModelFallback  = "model.fallback"
	EventSessionInvalid = "session.invalid"
	// EventSessionMarkError reports a failure to persist the durable
	// session-invalid mark. It is deliberately distinct from heartbeat.error:
	// the two have different remedies and must not be confused during audit.
	EventSessionMarkError = "session.mark.error"
)

// DefaultRunLeaseSeconds is used when a caller requests no explicit lease.
const DefaultRunLeaseSeconds = 900

// ClaimRequest is one attempt to take the lease of an id.
type ClaimRequest struct {
	TaskID       string
	Owner        string
	Agent        string
	Attempt      int
	LeaseSeconds int
	Now          time.Time
}

// RunClaim is a durable lease row.
type RunClaim struct {
	TaskID       string `json:"task_id"`
	Owner        string `json:"owner"`
	Agent        string `json:"agent"`
	Attempt      int    `json:"attempt"`
	ClaimedAt    string `json:"claimed_at"`
	HeartbeatAt  string `json:"heartbeat_at"`
	LeaseSeconds int    `json:"lease_seconds"`
}

// Run is the durable record of one task and its latest state.
type Run struct {
	TaskID     string `json:"task_id"`
	Agent      string `json:"agent"`
	Executor   string `json:"executor"`
	Model      string `json:"model,omitempty"`
	Payload    string `json:"payload,omitempty"`
	Status     string `json:"status"`
	Attempt    int    `json:"attempt"`
	StartedAt  string `json:"started_at,omitempty"`
	FinishedAt string `json:"finished_at,omitempty"`
	ExitCode   *int   `json:"exit_code,omitempty"`
	DurationMS *int64 `json:"duration_ms,omitempty"`
	Error      string `json:"error,omitempty"`
	CreatedAt  string `json:"created_at,omitempty"`
	UpdatedAt  string `json:"updated_at,omitempty"`
}

// RunAttempt is one durable execution attempt. Raw output is never stored:
// hashes and lengths keep tamper-evidence without persisting credentials.
type RunAttempt struct {
	TaskID       string `json:"task_id"`
	Seq          int    `json:"seq"`
	AttemptID    string `json:"attempt_id"`
	Agent        string `json:"agent"`
	Executor     string `json:"executor"`
	Command      string `json:"command,omitempty"`
	ExitCode     *int   `json:"exit_code,omitempty"`
	StdoutSHA256 string `json:"stdout_sha256,omitempty"`
	StdoutLength *int   `json:"stdout_length,omitempty"`
	StderrSHA256 string `json:"stderr_sha256,omitempty"`
	StderrLength *int   `json:"stderr_length,omitempty"`
	StartedAt    string `json:"started_at,omitempty"`
	FinishedAt   string `json:"finished_at,omitempty"`
	DurationMS   *int64 `json:"duration_ms,omitempty"`
	Status       string `json:"status"`
	Error        string `json:"error,omitempty"`
}

// RunEvent is one append-only lifecycle record.
type RunEvent struct {
	ID        int64  `json:"id"`
	TaskID    string `json:"task_id"`
	Attempt   int    `json:"attempt"`
	Kind      string `json:"kind"`
	Detail    string `json:"detail,omitempty"`
	CreatedAt string `json:"created_at"`
}

// acquireClaimSQL takes a lease atomically in one statement. A live lease for
// the same id (heartbeat within its own lease window) makes the upsert a no-op,
// so RowsAffected reports exactly one winner under concurrency. An empty or
// unparsable heartbeat is treated as expired, matching the PowerShell sweep.
const acquireClaimSQL = `INSERT INTO run_claims
		(task_id, owner, agent, attempt, claimed_at, heartbeat_at, lease_seconds)
	VALUES (?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(task_id) DO UPDATE SET
		owner         = excluded.owner,
		agent         = excluded.agent,
		attempt       = excluded.attempt,
		claimed_at    = excluded.claimed_at,
		heartbeat_at  = excluded.heartbeat_at,
		lease_seconds = excluded.lease_seconds
	WHERE run_claims.heartbeat_at = ''
	   OR datetime(run_claims.heartbeat_at, '+' || run_claims.lease_seconds || ' seconds') IS NULL
	   OR datetime(run_claims.heartbeat_at, '+' || run_claims.lease_seconds || ' seconds') <= datetime(?)`

// AcquireClaim reports whether the caller now owns the lease. It never errors
// on a lost race: a live lease simply yields false.
func (s *Store) AcquireClaim(request ClaimRequest) (bool, error) {
	if strings.TrimSpace(request.TaskID) == "" {
		return false, errors.New("acquire claim: empty id")
	}
	lease := request.LeaseSeconds
	if lease <= 0 {
		lease = DefaultRunLeaseSeconds
	}
	now := formatRunTime(request.Now)
	result, err := s.db.Exec(acquireClaimSQL, request.TaskID, request.Owner, request.Agent,
		request.Attempt, now, now, lease, now)
	if err != nil {
		return false, fmt.Errorf("acquire claim %s: %w", request.TaskID, err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("acquire claim %s: %w", request.TaskID, err)
	}
	return affected > 0, nil
}

// ReleaseClaim deletes the lease only when the caller still owns it, so a
// re-taken (stale-swept) lease is never removed by its former holder.
func (s *Store) ReleaseClaim(taskID, owner string) (bool, error) {
	if strings.TrimSpace(taskID) == "" {
		return false, errors.New("release claim: empty id")
	}
	result, err := s.db.Exec("DELETE FROM run_claims WHERE task_id = ? AND owner = ?", taskID, owner)
	if err != nil {
		return false, fmt.Errorf("release claim %s: %w", taskID, err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("release claim %s: %w", taskID, err)
	}
	return affected > 0, nil
}

// HeartbeatClaim refreshes the lease of the current owner. M2 will call it
// during a long run; M1 records the write path only.
func (s *Store) HeartbeatClaim(taskID, owner string, now time.Time) (bool, error) {
	result, err := s.db.Exec("UPDATE run_claims SET heartbeat_at = ? WHERE task_id = ? AND owner = ?",
		formatRunTime(now), taskID, owner)
	if err != nil {
		return false, fmt.Errorf("heartbeat claim %s: %w", taskID, err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("heartbeat claim %s: %w", taskID, err)
	}
	return affected > 0, nil
}

// RunClaims returns every durable lease, ordered by id.
func (s *Store) RunClaims() ([]RunClaim, error) {
	rows, err := s.db.Query(`SELECT task_id, owner, agent, attempt, claimed_at, heartbeat_at, lease_seconds
		FROM run_claims ORDER BY task_id`)
	if err != nil {
		return nil, fmt.Errorf("query run claims: %w", err)
	}
	defer rows.Close()

	claims := make([]RunClaim, 0)
	for rows.Next() {
		var (
			claim   RunClaim
			attempt sql.NullInt64
			lease   sql.NullInt64
		)
		if err := rows.Scan(&claim.TaskID, &claim.Owner, &claim.Agent, &attempt,
			&claim.ClaimedAt, &claim.HeartbeatAt, &lease); err != nil {
			return nil, fmt.Errorf("scan run claim: %w", err)
		}
		if attempt.Valid {
			claim.Attempt = int(attempt.Int64)
		}
		if lease.Valid {
			claim.LeaseSeconds = int(lease.Int64)
		}
		claims = append(claims, claim)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read run claims: %w", err)
	}
	return claims, nil
}

// upsertRunSQL records the current state of a run without touching its
// creation time; the payload is stored so a future recovery can re-run it.
const upsertRunSQL = `INSERT INTO runs
		(task_id, agent, executor, model, payload, status, attempt, started_at,
		 finished_at, exit_code, duration_ms, error, created_at, updated_at)
	VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(task_id) DO UPDATE SET
		agent       = excluded.agent,
		executor    = excluded.executor,
		model       = excluded.model,
		payload     = excluded.payload,
		status      = excluded.status,
		attempt     = excluded.attempt,
		started_at  = excluded.started_at,
		finished_at = excluded.finished_at,
		exit_code   = excluded.exit_code,
		duration_ms = excluded.duration_ms,
		error       = excluded.error,
		updated_at  = excluded.updated_at`

// SaveRun upserts one run row.
func (s *Store) SaveRun(run Run) error {
	if strings.TrimSpace(run.TaskID) == "" {
		return errors.New("save run: empty id")
	}
	created := run.CreatedAt
	if created == "" {
		created = formatRunTime(time.Time{})
	}
	updated := run.UpdatedAt
	if updated == "" {
		updated = formatRunTime(time.Time{})
	}
	_, err := s.db.Exec(upsertRunSQL, run.TaskID, run.Agent, run.Executor, run.Model,
		run.Payload, run.Status, run.Attempt, run.StartedAt, run.FinishedAt,
		nullableInt(run.ExitCode), nullableInt64(run.DurationMS), run.Error, created, updated)
	if err != nil {
		return fmt.Errorf("save run %s: %w", run.TaskID, err)
	}
	return nil
}

const insertAttemptSQL = `INSERT INTO run_attempts
		(task_id, seq, attempt_id, agent, executor, command, exit_code, stdout_sha256,
		 stdout_length, stderr_sha256, stderr_length, started_at, finished_at,
		 duration_ms, status, error)
	VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

// StartAttempt appends a running attempt and returns its sequence number. The
// row is written BEFORE the worker starts, so a crash leaves a visible attempt
// instead of a silent gap (crash-safe ordering).
//
// When the caller leaves AttemptID blank it is derived from the sequence number
// assigned here (the authoritative value), so the column is never empty even if
// the process dies before FinishAttempt. Deriving it inside the transaction
// avoids a read-then-write race between the caller and a concurrent attempt.
func (s *Store) StartAttempt(attempt RunAttempt) (int, error) {
	if strings.TrimSpace(attempt.TaskID) == "" {
		return 0, errors.New("start attempt: empty id")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin attempt: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var seq int
	if err := tx.QueryRow("SELECT COALESCE(MAX(seq), 0) + 1 FROM run_attempts WHERE task_id = ?",
		attempt.TaskID).Scan(&seq); err != nil {
		return 0, fmt.Errorf("next attempt %s: %w", attempt.TaskID, err)
	}
	if strings.TrimSpace(attempt.AttemptID) == "" {
		attempt.AttemptID = fmt.Sprintf("attempt-%d", seq)
	}
	if _, err := tx.Exec(insertAttemptSQL, attempt.TaskID, seq, attempt.AttemptID, attempt.Agent,
		attempt.Executor, attempt.Command, nullableInt(attempt.ExitCode), attempt.StdoutSHA256,
		nullableInt(attempt.StdoutLength), attempt.StderrSHA256, nullableInt(attempt.StderrLength),
		attempt.StartedAt, attempt.FinishedAt, nullableInt64(attempt.DurationMS), attempt.Status,
		attempt.Error,
	); err != nil {
		return 0, fmt.Errorf("start attempt %s/%d: %w", attempt.TaskID, seq, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit attempt %s/%d: %w", attempt.TaskID, seq, err)
	}
	return seq, nil
}

const finishAttemptSQL = `UPDATE run_attempts SET
		attempt_id = COALESCE(NULLIF(?, ''), attempt_id),
		exit_code = ?, stdout_sha256 = ?, stdout_length = ?, stderr_sha256 = ?,
		stderr_length = ?, finished_at = ?, duration_ms = ?, status = ?, error = ?
	WHERE task_id = ? AND seq = ?`

// FinishAttempt persists the outcome of a started attempt. It reports false
// when the attempt is unknown instead of failing, so a crash between the two
// writes can be reconciled without an error path.
func (s *Store) FinishAttempt(attempt RunAttempt) (bool, error) {
	if strings.TrimSpace(attempt.TaskID) == "" {
		return false, errors.New("finish attempt: empty id")
	}
	result, err := s.db.Exec(finishAttemptSQL, attempt.AttemptID, nullableInt(attempt.ExitCode),
		attempt.StdoutSHA256, nullableInt(attempt.StdoutLength), attempt.StderrSHA256,
		nullableInt(attempt.StderrLength), attempt.FinishedAt, nullableInt64(attempt.DurationMS),
		attempt.Status, attempt.Error, attempt.TaskID, attempt.Seq)
	if err != nil {
		return false, fmt.Errorf("finish attempt %s/%d: %w", attempt.TaskID, attempt.Seq, err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("finish attempt %s/%d: %w", attempt.TaskID, attempt.Seq, err)
	}
	return affected > 0, nil
}

// AppendEvent adds one lifecycle event and returns its row id.
func (s *Store) AppendEvent(event RunEvent) (int64, error) {
	createdAt := event.CreatedAt
	if createdAt == "" {
		createdAt = formatRunTime(time.Time{})
	}
	result, err := s.db.Exec("INSERT INTO run_events (task_id, attempt, kind, detail, created_at) VALUES (?, ?, ?, ?, ?)",
		event.TaskID, event.Attempt, event.Kind, event.Detail, createdAt)
	if err != nil {
		return 0, fmt.Errorf("append event %s: %w", event.Kind, err)
	}
	id, err := result.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("append event %s: %w", event.Kind, err)
	}
	return id, nil
}

// Runs returns every durable run, newest first.
func (s *Store) Runs() ([]Run, error) {
	rows, err := s.db.Query(`SELECT task_id, agent, executor, model, payload, status, attempt,
			started_at, finished_at, exit_code, duration_ms, error, created_at, updated_at
		FROM runs ORDER BY updated_at DESC, task_id`)
	if err != nil {
		return nil, fmt.Errorf("query runs: %w", err)
	}
	defer rows.Close()

	runs := make([]Run, 0)
	for rows.Next() {
		var (
			run      Run
			exitCode sql.NullInt64
			duration sql.NullInt64
		)
		if err := rows.Scan(&run.TaskID, &run.Agent, &run.Executor, &run.Model, &run.Payload,
			&run.Status, &run.Attempt, &run.StartedAt, &run.FinishedAt, &exitCode, &duration,
			&run.Error, &run.CreatedAt, &run.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan run: %w", err)
		}
		run.ExitCode = optionalInt(exitCode)
		run.DurationMS = optionalInt64(duration)
		runs = append(runs, run)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read runs: %w", err)
	}
	return runs, nil
}

// RunByTask returns one durable run.
func (s *Store) RunByTask(taskID string) (Run, bool, error) {
	runs, err := s.Runs()
	if err != nil {
		return Run{}, false, err
	}
	for _, run := range runs {
		if run.TaskID == taskID {
			return run, true, nil
		}
	}
	return Run{}, false, nil
}

// RunAttempts returns the durable attempts of one id in execution order.
func (s *Store) RunAttempts(taskID string) ([]RunAttempt, error) {
	rows, err := s.db.Query(`SELECT task_id, seq, attempt_id, agent, executor, command, exit_code,
			stdout_sha256, stdout_length, stderr_sha256, stderr_length, started_at, finished_at,
			duration_ms, status, error
		FROM run_attempts WHERE task_id = ? ORDER BY seq`, taskID)
	if err != nil {
		return nil, fmt.Errorf("query run attempts: %w", err)
	}
	defer rows.Close()

	attempts := make([]RunAttempt, 0)
	for rows.Next() {
		var (
			attempt                                        RunAttempt
			exitCode, stdoutLength, stderrLength, duration sql.NullInt64
		)
		if err := rows.Scan(&attempt.TaskID, &attempt.Seq, &attempt.AttemptID, &attempt.Agent,
			&attempt.Executor, &attempt.Command, &exitCode, &attempt.StdoutSHA256, &stdoutLength,
			&attempt.StderrSHA256, &stderrLength, &attempt.StartedAt, &attempt.FinishedAt,
			&duration, &attempt.Status, &attempt.Error); err != nil {
			return nil, fmt.Errorf("scan run attempt: %w", err)
		}
		attempt.ExitCode = optionalInt(exitCode)
		attempt.StdoutLength = optionalInt(stdoutLength)
		attempt.StderrLength = optionalInt(stderrLength)
		attempt.DurationMS = optionalInt64(duration)
		attempts = append(attempts, attempt)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read run attempts: %w", err)
	}
	return attempts, nil
}

// RunEvents returns the lifecycle events of one id in insertion order.
func (s *Store) RunEvents(taskID string) ([]RunEvent, error) {
	rows, err := s.db.Query(`SELECT id, task_id, attempt, kind, detail, created_at
		FROM run_events WHERE task_id = ? ORDER BY id`, taskID)
	if err != nil {
		return nil, fmt.Errorf("query run events: %w", err)
	}
	defer rows.Close()

	events := make([]RunEvent, 0)
	for rows.Next() {
		var event RunEvent
		if err := rows.Scan(&event.ID, &event.TaskID, &event.Attempt, &event.Kind,
			&event.Detail, &event.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan run event: %w", err)
		}
		events = append(events, event)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read run events: %w", err)
	}
	return events, nil
}

// formatRunTime renders a UTC timestamp SQLite's datetime() can parse; a zero
// time means "now".
func formatRunTime(value time.Time) string {
	if value.IsZero() {
		value = time.Now()
	}
	return value.UTC().Format(time.RFC3339Nano)
}
