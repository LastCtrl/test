package store

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"agent-hq/internal/state"
)

// Counts is the number of indexed rows per entity, as reported by
// `agent-hq index` and `agent-hq db status`.
type Counts struct {
	Projects         int `json:"projects"`
	Tasks            int `json:"tasks"`
	Evidence         int `json:"evidence"`
	EvidenceAttempts int `json:"evidence_attempts"`
	Claims           int `json:"claims"`
	Messages         int `json:"messages"`
}

// resetTables lists the derived tables cleared by a resync. Order is irrelevant
// because the schema declares no foreign keys (the index is a flat read model).
var resetTables = []string{
	"messages",
	"claims",
	"evidence_attempts",
	"evidence",
	"tasks",
	"projects",
}

// Upsert statements. Every write goes through ON CONFLICT so the same input can
// be applied repeatedly without creating duplicates; Index clears the derived
// tables first, so the upsert path is also directly reusable for incremental
// updates later.
const (
	upsertProject = `INSERT INTO projects (project, queue_path, task_count)
		VALUES (?, ?, ?)
		ON CONFLICT(project) DO UPDATE SET
			queue_path = excluded.queue_path,
			task_count = excluded.task_count`

	upsertTask = `INSERT INTO tasks
			(project, id, title, priority, status, assigned_agent, worktree,
			 created_at, started_at, completed_at, retries, source, path)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(project, id) DO UPDATE SET
			title = excluded.title,
			priority = excluded.priority,
			status = excluded.status,
			assigned_agent = excluded.assigned_agent,
			worktree = excluded.worktree,
			created_at = excluded.created_at,
			started_at = excluded.started_at,
			completed_at = excluded.completed_at,
			retries = excluded.retries,
			source = excluded.source,
			path = excluded.path`

	upsertEvidence = `INSERT INTO evidence
			(task_id, path, attempt_count, last_finished_at, agents)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(task_id) DO UPDATE SET
			path = excluded.path,
			attempt_count = excluded.attempt_count,
			last_finished_at = excluded.last_finished_at,
			agents = excluded.agents`

	upsertAttempt = `INSERT INTO evidence_attempts
			(task_id, seq, attempt_id, agent, command, exit_code, stdout_sha256,
			 stdout_length, stderr_sha256, stderr_length, started_at, finished_at,
			 duration_ms, status, reason, git_head, git_diff_sha256, host, pid)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(task_id, seq) DO UPDATE SET
			attempt_id = excluded.attempt_id,
			agent = excluded.agent,
			command = excluded.command,
			exit_code = excluded.exit_code,
			stdout_sha256 = excluded.stdout_sha256,
			stdout_length = excluded.stdout_length,
			stderr_sha256 = excluded.stderr_sha256,
			stderr_length = excluded.stderr_length,
			started_at = excluded.started_at,
			finished_at = excluded.finished_at,
			duration_ms = excluded.duration_ms,
			status = excluded.status,
			reason = excluded.reason,
			git_head = excluded.git_head,
			git_diff_sha256 = excluded.git_diff_sha256,
			host = excluded.host,
			pid = excluded.pid`

	upsertClaim = `INSERT INTO claims
			(path, task_id, agent, attempt, claimed_at, heartbeat_at, ttl_seconds)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(path) DO UPDATE SET
			task_id = excluded.task_id,
			agent = excluded.agent,
			attempt = excluded.attempt,
			claimed_at = excluded.claimed_at,
			heartbeat_at = excluded.heartbeat_at,
			ttl_seconds = excluded.ttl_seconds`

	upsertMessage = `INSERT INTO messages
			(scope, path, id, from_agent, to_agent, kind, priority, payload, status,
			 started_at, finished_at, response, evidence, agent, created_at, created,
			 last_activity_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(scope, path) DO UPDATE SET
			id = excluded.id,
			from_agent = excluded.from_agent,
			to_agent = excluded.to_agent,
			kind = excluded.kind,
			priority = excluded.priority,
			payload = excluded.payload,
			status = excluded.status,
			started_at = excluded.started_at,
			finished_at = excluded.finished_at,
			response = excluded.response,
			evidence = excluded.evidence,
			agent = excluded.agent,
			created_at = excluded.created_at,
			created = excluded.created,
			last_activity_at = excluded.last_activity_at`

	upsertMeta = `INSERT INTO meta (key, value)
		VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`
)

// Index resynchronizes the database with one snapshot of the on-disk state and
// records the source fingerprint and timestamp.
//
// The whole resync runs in a single transaction, so a failure leaves the
// previous index untouched and readers never observe a half-empty database. The
// strategy is a full resync (clear then upsert): it is idempotent by
// construction - indexing the same state twice yields the same rows - and it
// also drops rows whose source artifact disappeared, which a pure upsert would
// leave behind.
func (s *Store) Index(snapshot *state.Snapshot, fingerprint string, now time.Time) (Counts, error) {
	if snapshot == nil {
		return Counts{}, errors.New("index: nil snapshot")
	}

	tx, err := s.db.Begin()
	if err != nil {
		return Counts{}, fmt.Errorf("begin index transaction: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	for _, table := range resetTables {
		if _, err := tx.Exec("DELETE FROM " + table); err != nil {
			return Counts{}, fmt.Errorf("reset %s: %w", table, err)
		}
	}

	for _, queue := range snapshot.Queues {
		if _, err := tx.Exec(upsertProject, queue.Project, queue.Path, len(queue.Tasks)); err != nil {
			return Counts{}, fmt.Errorf("index project %s: %w", queue.Project, err)
		}
		for _, task := range queue.Tasks {
			if _, err := tx.Exec(upsertTask,
				task.Project, task.ID, task.Title, task.Priority, task.Status,
				task.AssignedAgent, task.Worktree, task.CreatedAt, task.StartedAt,
				task.CompletedAt, nullableInt(task.Retries), task.Source, task.QueuePath,
			); err != nil {
				return Counts{}, fmt.Errorf("index task %s: %w", task.ID, err)
			}
		}
	}

	for _, doc := range snapshot.Evidence {
		finished := ""
		if last, ok := doc.LastFinished(); ok {
			finished = last.Format(time.RFC3339Nano)
		}
		if _, err := tx.Exec(upsertEvidence,
			doc.TaskID, doc.Path, len(doc.Attempts), finished, strings.Join(doc.Agents(), ","),
		); err != nil {
			return Counts{}, fmt.Errorf("index evidence %s: %w", doc.TaskID, err)
		}
		for sequence, attempt := range doc.Attempts {
			if _, err := tx.Exec(upsertAttempt,
				doc.TaskID, sequence, attempt.AttemptID, attempt.Agent, attempt.Command,
				nullableInt(attempt.ExitCode), attempt.StdoutSHA256, nullableInt(attempt.StdoutLength),
				attempt.StderrSHA256, nullableInt(attempt.StderrLength), attempt.StartedAt,
				attempt.FinishedAt, nullableInt64(attempt.DurationMS), attempt.Status, attempt.Reason,
				attempt.GitHead, attempt.GitDiffSHA256, attempt.Host, nullableInt(attempt.PID),
			); err != nil {
				return Counts{}, fmt.Errorf("index evidence %s attempt %d: %w", doc.TaskID, sequence, err)
			}
		}
	}

	for _, claim := range snapshot.Claims {
		if _, err := tx.Exec(upsertClaim,
			claim.Path, claim.TaskID, claim.Agent, claim.Attempt, claim.ClaimedAt,
			claim.HeartbeatAt, claim.TTLSeconds,
		); err != nil {
			return Counts{}, fmt.Errorf("index claim %s: %w", claim.TaskID, err)
		}
	}

	scoped := []struct {
		scope    string
		messages []state.Message
	}{
		{"inbox", snapshot.Inbox},
		{"outbox", snapshot.Outbox},
		{"dead-letter", snapshot.DeadLetter},
	}
	for _, group := range scoped {
		for _, message := range group.messages {
			lastActivity := ""
			if timestamp, ok := message.LastTimestamp(); ok {
				lastActivity = timestamp
			}
			if _, err := tx.Exec(upsertMessage,
				group.scope, message.Path, message.ID, message.From, message.To, message.Type,
				message.Priority, string(message.Payload), message.Status, message.StartedAt,
				message.FinishedAt, message.Response, message.Evidence, message.Agent,
				message.CreatedAt, message.Created, lastActivity,
			); err != nil {
				return Counts{}, fmt.Errorf("index message %s: %w", message.ID, err)
			}
		}
	}

	if _, err := tx.Exec(upsertMeta, metaIndexedAt, now.UTC().Format(time.RFC3339Nano)); err != nil {
		return Counts{}, fmt.Errorf("record index time: %w", err)
	}
	if _, err := tx.Exec(upsertMeta, metaFingerprint, fingerprint); err != nil {
		return Counts{}, fmt.Errorf("record fingerprint: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return Counts{}, fmt.Errorf("commit index: %w", err)
	}

	return s.Counts()
}

// nullableInt converts an optional counter to a database value: NULL when the
// source record had no value, so the read path can rebuild a nil pointer.
func nullableInt(value *int) any {
	if value == nil {
		return nil
	}
	return *value
}

// nullableInt64 is nullableInt for 64-bit counters (attempt duration).
func nullableInt64(value *int64) any {
	if value == nil {
		return nil
	}
	return *value
}
