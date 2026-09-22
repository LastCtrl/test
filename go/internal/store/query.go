package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"agent-hq/internal/state"
)

// SchemaVersion returns the schema revision recorded in the database.
func (s *Store) SchemaVersion() (int, error) {
	return schemaVersionOf(s.db)
}

// IndexedAt returns the time of the last successful index run.
func (s *Store) IndexedAt() (time.Time, bool, error) {
	value, found, err := s.metaValue(metaIndexedAt)
	if err != nil || !found {
		return time.Time{}, false, err
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("parse indexed_at: %w", err)
	}
	return parsed, true, nil
}

// FingerprintValue returns the fingerprint recorded by the last index run.
func (s *Store) FingerprintValue() (string, bool, error) {
	return s.metaValue(metaFingerprint)
}

// IsFresh reports whether the database matches the current on-disk state: the
// stored fingerprint equals a freshly computed one. A missing or unreadable
// fingerprint is simply "not fresh", never an error the caller must handle.
func (s *Store) IsFresh() (bool, error) {
	stored, found, err := s.FingerprintValue()
	if err != nil {
		return false, err
	}
	if !found || stored == "" {
		return false, nil
	}
	current, err := Fingerprint(s.root)
	if err != nil {
		return false, err
	}
	return stored == current, nil
}

// Counts returns the number of rows per indexed entity.
func (s *Store) Counts() (Counts, error) {
	var counts Counts
	specs := []struct {
		target *int
		query  string
	}{
		{&counts.Projects, "SELECT COUNT(*) FROM projects"},
		{&counts.Tasks, "SELECT COUNT(*) FROM tasks"},
		{&counts.Evidence, "SELECT COUNT(*) FROM evidence"},
		{&counts.EvidenceAttempts, "SELECT COUNT(*) FROM evidence_attempts"},
		{&counts.Claims, "SELECT COUNT(*) FROM claims"},
		{&counts.Messages, "SELECT COUNT(*) FROM messages"},
	}
	for _, spec := range specs {
		if err := s.db.QueryRow(spec.query).Scan(spec.target); err != nil {
			return Counts{}, fmt.Errorf("count rows: %w", err)
		}
	}
	return counts, nil
}

const selectTasks = `SELECT project, id, title, priority, status, assigned_agent, worktree,
		created_at, started_at, completed_at, retries, source, path
	FROM tasks ORDER BY project, id`

// Tasks returns every indexed queue task.
func (s *Store) Tasks() ([]state.Task, error) {
	rows, err := s.db.Query(selectTasks)
	if err != nil {
		return nil, fmt.Errorf("query tasks: %w", err)
	}
	defer rows.Close()

	tasks := make([]state.Task, 0)
	for rows.Next() {
		var (
			task    state.Task
			retries sql.NullInt64
		)
		if err := rows.Scan(
			&task.Project, &task.ID, &task.Title, &task.Priority, &task.Status,
			&task.AssignedAgent, &task.Worktree, &task.CreatedAt, &task.StartedAt,
			&task.CompletedAt, &retries, &task.Source, &task.QueuePath,
		); err != nil {
			return nil, fmt.Errorf("scan task: %w", err)
		}
		if retries.Valid {
			value := int(retries.Int64)
			task.Retries = &value
		}
		tasks = append(tasks, task)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read tasks: %w", err)
	}
	return tasks, nil
}

// Queues returns the indexed tasks grouped per project, matching the shape of
// state.LoadQueues so state.Snapshot.Tasks() behaves identically.
func (s *Store) Queues() ([]state.Queue, error) {
	projectRows, err := s.db.Query("SELECT project, queue_path FROM projects ORDER BY project")
	if err != nil {
		return nil, fmt.Errorf("query projects: %w", err)
	}
	defer projectRows.Close()

	queues := make([]state.Queue, 0)
	for projectRows.Next() {
		var queue state.Queue
		if err := projectRows.Scan(&queue.Project, &queue.Path); err != nil {
			return nil, fmt.Errorf("scan project: %w", err)
		}
		queue.Tasks = []state.Task{}
		queues = append(queues, queue)
	}
	if err := projectRows.Err(); err != nil {
		return nil, fmt.Errorf("read projects: %w", err)
	}

	tasks, err := s.Tasks()
	if err != nil {
		return nil, err
	}
	index := make(map[string]int, len(queues))
	for position, queue := range queues {
		index[queue.Project] = position
	}
	for _, task := range tasks {
		position, ok := index[task.Project]
		if !ok {
			// A task whose project row is missing (should not happen) is kept
			// rather than silently dropped.
			queues = append(queues, state.Queue{Project: task.Project, Tasks: []state.Task{task}})
			index[task.Project] = len(queues) - 1
			continue
		}
		queues[position].Tasks = append(queues[position].Tasks, task)
	}
	return queues, nil
}

const selectClaims = `SELECT path, task_id, agent, attempt, claimed_at, heartbeat_at, ttl_seconds
	FROM claims ORDER BY task_id, path`

// Claims returns the indexed leases as raw (unevaluated) state.Claim values.
func (s *Store) Claims() ([]state.Claim, error) {
	rows, err := s.db.Query(selectClaims)
	if err != nil {
		return nil, fmt.Errorf("query claims: %w", err)
	}
	defer rows.Close()

	claims := make([]state.Claim, 0)
	for rows.Next() {
		var (
			claim   state.Claim
			attempt sql.NullInt64
			ttl     sql.NullInt64
		)
		if err := rows.Scan(&claim.Path, &claim.TaskID, &claim.Agent, &attempt,
			&claim.ClaimedAt, &claim.HeartbeatAt, &ttl); err != nil {
			return nil, fmt.Errorf("scan claim: %w", err)
		}
		if attempt.Valid {
			value := int(attempt.Int64)
			claim.Attempt = &value
		}
		if ttl.Valid {
			value := int(ttl.Int64)
			claim.LeaseSeconds = &value
		}
		claims = append(claims, claim)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read claims: %w", err)
	}
	return claims, nil
}

const (
	selectEvidence = `SELECT task_id, path FROM evidence ORDER BY task_id`

	selectAttempts = `SELECT task_id, seq, attempt_id, agent, command, exit_code,
			stdout_sha256, stdout_length, stderr_sha256, stderr_length, started_at,
			finished_at, duration_ms, status, reason, git_head, git_diff_sha256, host, pid
		FROM evidence_attempts ORDER BY task_id, seq`
)

// Evidence returns the indexed evidence documents with their attempts attached,
// reproducing the shape of state.LoadEvidence.
func (s *Store) Evidence() ([]state.EvidenceDoc, error) {
	docs, err := s.evidenceDocs()
	if err != nil {
		return nil, err
	}
	if err := s.attachAttempts(docs); err != nil {
		return nil, err
	}
	return docs, nil
}

func (s *Store) evidenceDocs() ([]state.EvidenceDoc, error) {
	rows, err := s.db.Query(selectEvidence)
	if err != nil {
		return nil, fmt.Errorf("query evidence: %w", err)
	}
	defer rows.Close()

	docs := make([]state.EvidenceDoc, 0)
	for rows.Next() {
		var doc state.EvidenceDoc
		if err := rows.Scan(&doc.TaskID, &doc.Path); err != nil {
			return nil, fmt.Errorf("scan evidence: %w", err)
		}
		doc.Attempts = []state.EvidenceAttempt{}
		docs = append(docs, doc)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read evidence: %w", err)
	}
	return docs, nil
}

// attachAttempts appends each persisted attempt to its document. The docs slice
// is fully built first, so taking element addresses here is safe.
func (s *Store) attachAttempts(docs []state.EvidenceDoc) error {
	if len(docs) == 0 {
		return nil
	}
	index := make(map[string]*state.EvidenceDoc, len(docs))
	for position := range docs {
		index[docs[position].TaskID] = &docs[position]
	}

	rows, err := s.db.Query(selectAttempts)
	if err != nil {
		return fmt.Errorf("query evidence attempts: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var (
			taskID                                                string
			sequence                                              int
			attemptID, agent, command                             string
			exitCode, stdoutLength, stderrLength, durationMS, pid sql.NullInt64
			stdoutSHA256, stderrSHA256, startedAt, finishedAt     string
			status, reason, gitHead, gitDiffSHA256, host          string
		)
		if err := rows.Scan(
			&taskID, &sequence, &attemptID, &agent, &command, &exitCode,
			&stdoutSHA256, &stdoutLength, &stderrSHA256, &stderrLength, &startedAt,
			&finishedAt, &durationMS, &status, &reason, &gitHead, &gitDiffSHA256, &host, &pid,
		); err != nil {
			return fmt.Errorf("scan evidence attempt: %w", err)
		}

		// state.LoadEvidence leaves the per-attempt TaskID empty (the document
		// carries it), so the index mirrors that: task_id is used as the join
		// key only, never synthesised into the reconstructed record.
		attempt := state.EvidenceAttempt{
			AttemptID:     attemptID,
			Agent:         agent,
			Command:       command,
			ExitCode:      optionalInt(exitCode),
			StdoutSHA256:  stdoutSHA256,
			StdoutLength:  optionalInt(stdoutLength),
			StderrSHA256:  stderrSHA256,
			StderrLength:  optionalInt(stderrLength),
			StartedAt:     startedAt,
			FinishedAt:    finishedAt,
			DurationMS:    optionalInt64(durationMS),
			Status:        status,
			Reason:        reason,
			GitHead:       gitHead,
			GitDiffSHA256: gitDiffSHA256,
			Host:          host,
			PID:           optionalInt(pid),
		}
		if doc, ok := index[taskID]; ok {
			doc.Attempts = append(doc.Attempts, attempt)
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("read evidence attempts: %w", err)
	}
	return nil
}

const selectMessages = `SELECT scope, path, id, from_agent, to_agent, kind, priority, payload,
		status, started_at, finished_at, response, evidence, agent, created_at, created
	FROM messages ORDER BY scope, path`

// Messages returns the indexed bus envelopes keyed by scope (inbox, outbox,
// dead-letter), ready to fill a state.Snapshot.
func (s *Store) Messages() (map[string][]state.Message, error) {
	rows, err := s.db.Query(selectMessages)
	if err != nil {
		return nil, fmt.Errorf("query messages: %w", err)
	}
	defer rows.Close()

	messages := make(map[string][]state.Message)
	for rows.Next() {
		var (
			scope, payload string
			message        state.Message
		)
		if err := rows.Scan(
			&scope, &message.Path, &message.ID, &message.From, &message.To, &message.Type,
			&message.Priority, &payload, &message.Status, &message.StartedAt,
			&message.FinishedAt, &message.Response, &message.Evidence, &message.Agent,
			&message.CreatedAt, &message.Created,
		); err != nil {
			return nil, fmt.Errorf("scan message: %w", err)
		}
		if payload != "" {
			message.Payload = json.RawMessage(payload)
		}
		messages[scope] = append(messages[scope], message)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read messages: %w", err)
	}
	return messages, nil
}

// MessageCountsByScope returns the number of indexed messages per scope.
func (s *Store) MessageCountsByScope() (map[string]int, error) {
	rows, err := s.db.Query("SELECT scope, COUNT(*) FROM messages GROUP BY scope")
	if err != nil {
		return nil, fmt.Errorf("count messages: %w", err)
	}
	defer rows.Close()

	counts := make(map[string]int)
	for rows.Next() {
		var (
			scope string
			count int
		)
		if err := rows.Scan(&scope, &count); err != nil {
			return nil, fmt.Errorf("scan message count: %w", err)
		}
		counts[scope] = count
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read message counts: %w", err)
	}
	return counts, nil
}

// Snapshot builds a state.Snapshot from the index. It mirrors state.Load for
// every artifact the index covers, so callers can swap the two transparently
// when the database is fresh.
//
// ttlOverride and now are applied exactly as in state.Load: stored claims carry
// their raw data and are evaluated against the caller's clock, never against
// the time of the last index run.
func (s *Store) Snapshot(version string, ttlOverride time.Duration, now time.Time) (*state.Snapshot, error) {
	queues, err := s.Queues()
	if err != nil {
		return nil, err
	}
	claims, err := s.Claims()
	if err != nil {
		return nil, err
	}
	evidence, err := s.Evidence()
	if err != nil {
		return nil, err
	}
	messages, err := s.Messages()
	if err != nil {
		return nil, err
	}

	return &state.Snapshot{
		Root:       s.root,
		Version:    version,
		LoadedAt:   now,
		Evidence:   evidence,
		Claims:     state.EvaluateClaims(claims, ttlOverride, now),
		Queues:     queues,
		Inbox:      messages["inbox"],
		Outbox:     messages["outbox"],
		DeadLetter: messages["dead-letter"],
	}, nil
}

// optionalInt rebuilds a *int from a nullable column: NULL stays nil so callers
// can distinguish "recorded as 0" from "not recorded" exactly as the files do.
func optionalInt(value sql.NullInt64) *int {
	if !value.Valid {
		return nil
	}
	converted := int(value.Int64)
	return &converted
}

// optionalInt64 is optionalInt for 64-bit columns (attempt duration).
func optionalInt64(value sql.NullInt64) *int64 {
	if !value.Valid {
		return nil
	}
	converted := value.Int64
	return &converted
}
