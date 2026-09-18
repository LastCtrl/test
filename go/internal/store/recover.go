package store

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"agent-hq/internal/state"
)

// StaleAttempt is a running attempt whose heartbeat outlived its lease. It is
// the read model of the watchdog: the CLI lists these, then asks the store to
// reconcile each one.
//
// Owner is the lease owner recorded in run_claims; it is empty when the claim
// row is already gone, in which case reconciliation has nothing to release.
type StaleAttempt struct {
	TaskID       string `json:"task_id"`
	Seq          int    `json:"seq"`
	AttemptID    string `json:"attempt_id,omitempty"`
	Agent        string `json:"agent,omitempty"`
	Executor     string `json:"executor,omitempty"`
	Owner        string `json:"owner,omitempty"`
	StartedAt    string `json:"started_at,omitempty"`
	HeartbeatAt  string `json:"heartbeat_at,omitempty"`
	LeaseSeconds int    `json:"lease_seconds"`
	AgeSeconds   int64  `json:"age_seconds"`
	Reason       string `json:"reason"`
}

// staleAttemptsSQL lists every running attempt with the lease data recovery
// needs. The LEFT JOIN is intentional: an attempt whose claim row has already
// been removed still has to be reconcilable, so it falls back to its own
// started_at as the heartbeat and to the default lease.
const staleAttemptsSQL = `SELECT a.task_id, a.seq, a.attempt_id, a.agent, a.executor, a.started_at,
		COALESCE(NULLIF(c.heartbeat_at, ''), a.started_at),
		COALESCE(c.lease_seconds, 0),
		COALESCE(c.owner, '')
	FROM run_attempts a
	LEFT JOIN run_claims c ON c.task_id = a.task_id
	WHERE a.status = ?
	ORDER BY a.task_id, a.seq`

// StaleAttempts returns the running attempts whose heartbeat is older than
// their lease. An empty or unparsable heartbeat is treated as expired, matching
// the file-based lease sweep (state.EvaluateClaims). A positive ttlOverride
// replaces the per-attempt lease for every row, so an operator can widen or
// narrow the watchdog window without rewriting the stored claims.
func (s *Store) StaleAttempts(now time.Time, ttlOverride time.Duration) ([]StaleAttempt, error) {
	rows, err := s.db.Query(staleAttemptsSQL, RunRunning)
	if err != nil {
		return nil, fmt.Errorf("query running attempts: %w", err)
	}
	defer rows.Close()

	stale := make([]StaleAttempt, 0)
	for rows.Next() {
		var attempt StaleAttempt
		if err := rows.Scan(&attempt.TaskID, &attempt.Seq, &attempt.AttemptID, &attempt.Agent,
			&attempt.Executor, &attempt.StartedAt, &attempt.HeartbeatAt,
			&attempt.LeaseSeconds, &attempt.Owner); err != nil {
			return nil, fmt.Errorf("scan running attempt: %w", err)
		}

		lease := time.Duration(attempt.LeaseSeconds) * time.Second
		if attempt.LeaseSeconds <= 0 {
			lease = DefaultRunLeaseSeconds * time.Second
		}
		if ttlOverride > 0 {
			lease = ttlOverride
		}
		attempt.LeaseSeconds = int(lease.Seconds())

		heartbeat, ok := state.ParseTime(attempt.HeartbeatAt)
		if !ok {
			attempt.Reason = "unparsable-heartbeat"
			stale = append(stale, attempt)
			continue
		}
		age := now.Sub(heartbeat)
		if age < 0 {
			age = 0
		}
		attempt.AgeSeconds = int64(age.Seconds())
		if age <= lease {
			continue
		}
		attempt.Reason = "heartbeat-expired"
		stale = append(stale, attempt)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read running attempts: %w", err)
	}
	return stale, nil
}

// RecoverRequest identifies one stale attempt to reconcile. Reason is the
// watchdog's verdict ("heartbeat-expired" or "unparsable-heartbeat") and is
// persisted in the attempt record and the event so the cause stays auditable.
type RecoverRequest struct {
	TaskID  string
	Seq     int
	Owner   string
	Reason  string
	Requeue bool
	Now     time.Time
}

// RecoverAttempt reconciles one stale attempt in a single transaction:
//
//   - the running attempt becomes stale with a finished_at stamp;
//   - the lease is released, owner-guarded, so a live holder is never dropped;
//   - the run row becomes stale -- or queued when requeue is set, keeping the
//     payload a later attempt can re-dispatch -- only while it is still running;
//   - the lifecycle events are appended.
//
// The update is guarded by status = running, so a second recovery of the same
// attempt changes nothing and reports false. That makes recovery idempotent and
// safe to run repeatedly, including from overlapping watchdog invocations.
func (s *Store) RecoverAttempt(request RecoverRequest) (bool, error) {
	if strings.TrimSpace(request.TaskID) == "" || request.Seq <= 0 {
		return false, errors.New("recover attempt: empty id or sequence")
	}
	reason := strings.TrimSpace(request.Reason)
	if reason == "" {
		reason = "heartbeat-expired"
	}
	now := formatRunTime(request.Now)

	tx, err := s.db.Begin()
	if err != nil {
		return false, fmt.Errorf("begin recovery of %s/%d: %w", request.TaskID, request.Seq, err)
	}
	defer func() { _ = tx.Rollback() }()

	result, err := tx.Exec(`UPDATE run_attempts SET status = ?, error = ?, finished_at = ?
		WHERE task_id = ? AND seq = ? AND status = ?`,
		RunStale, reason, now, request.TaskID, request.Seq, RunRunning)
	if err != nil {
		return false, fmt.Errorf("stale attempt %s/%d: %w", request.TaskID, request.Seq, err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("stale attempt %s/%d: %w", request.TaskID, request.Seq, err)
	}
	if affected == 0 {
		// Already reconciled by an earlier sweep: a no-op, not an error.
		return false, nil
	}

	if strings.TrimSpace(request.Owner) != "" {
		if _, err := tx.Exec("DELETE FROM run_claims WHERE task_id = ? AND owner = ?",
			request.TaskID, request.Owner); err != nil {
			return false, fmt.Errorf("release stale claim %s: %w", request.TaskID, err)
		}
	}

	runStatus := RunStale
	runEvent := EventRunStale
	detail := reason
	if request.Requeue {
		runStatus = RunQueued
		runEvent = EventRecoverRequeued
		detail = "requeued after " + reason
	}
	if _, err := tx.Exec("UPDATE runs SET status = ?, updated_at = ? WHERE task_id = ? AND status = ?",
		runStatus, now, request.TaskID, RunRunning); err != nil {
		return false, fmt.Errorf("mark run %s %s: %w", request.TaskID, runStatus, err)
	}

	for _, event := range []RunEvent{
		{TaskID: request.TaskID, Attempt: request.Seq, Kind: EventAttemptStale, Detail: reason, CreatedAt: now},
		{TaskID: request.TaskID, Attempt: request.Seq, Kind: runEvent, Detail: detail, CreatedAt: now},
	} {
		if _, err := tx.Exec("INSERT INTO run_events (task_id, attempt, kind, detail, created_at) VALUES (?, ?, ?, ?, ?)",
			event.TaskID, event.Attempt, event.Kind, event.Detail, event.CreatedAt); err != nil {
			return false, fmt.Errorf("append recovery event %s: %w", event.Kind, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return false, fmt.Errorf("commit recovery of %s/%d: %w", request.TaskID, request.Seq, err)
	}
	return true, nil
}
