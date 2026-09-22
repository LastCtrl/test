package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// RunCheckpoint is one durable handoff point of a run. The format is fixed and
// deliberately minimal, so a future resume can rebuild the worker context from
// the database alone:
//
//	run_id     TEXT     non-empty run/task id (the natural key)
//	seq        INTEGER  1-based, monotonic per run_id, assigned by the store
//	path       TEXT     artifact the worker last operated on (may be empty)
//	state      TEXT     opaque free-form handoff state (may be empty)
//	created_at TEXT     UTC RFC3339Nano, assigned by the store when empty
//
// The store never interprets Path or State; they are the worker's words. That
// keeps checkpoints usable by any executor without a schema change.
type RunCheckpoint struct {
	RunID     string `json:"run_id"`
	Seq       int    `json:"seq"`
	Path      string `json:"path,omitempty"`
	State     string `json:"state,omitempty"`
	CreatedAt string `json:"created_at"`
}

const insertCheckpointSQL = `INSERT INTO run_checkpoints (run_id, seq, path, state, created_at)
	VALUES (?, ?, ?, ?, ?)`

// SaveCheckpoint appends one checkpoint and returns its sequence number.
//
// The write is idempotent for a retry of the latest state: when the newest
// checkpoint of the run already carries the same path and state, its sequence
// is returned without inserting a duplicate. A different state always appends,
// so the history stays append-only.
func (s *Store) SaveCheckpoint(checkpoint RunCheckpoint) (int, error) {
	if strings.TrimSpace(checkpoint.RunID) == "" {
		return 0, errors.New("save checkpoint: empty run id")
	}
	createdAt := strings.TrimSpace(checkpoint.CreatedAt)
	if createdAt == "" {
		createdAt = formatRunTime(time.Time{})
	}

	tx, err := s.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin checkpoint %s: %w", checkpoint.RunID, err)
	}
	defer func() { _ = tx.Rollback() }()

	latest, found, err := latestCheckpointTx(tx, checkpoint.RunID)
	if err != nil {
		return 0, err
	}
	if found && latest.Path == checkpoint.Path && latest.State == checkpoint.State {
		return latest.Seq, nil
	}

	seq, err := nextCheckpointSequence(tx, checkpoint.RunID)
	if err != nil {
		return 0, err
	}
	if _, err := tx.Exec(insertCheckpointSQL, checkpoint.RunID, seq, checkpoint.Path,
		checkpoint.State, createdAt); err != nil {
		return 0, fmt.Errorf("save checkpoint %s/%d: %w", checkpoint.RunID, seq, err)
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit checkpoint %s/%d: %w", checkpoint.RunID, seq, err)
	}
	return seq, nil
}

const selectCheckpointsSQL = `SELECT run_id, seq, path, state, created_at
	FROM run_checkpoints WHERE run_id = ? ORDER BY seq`

// Checkpoints returns every checkpoint of one run in execution order.
func (s *Store) Checkpoints(runID string) ([]RunCheckpoint, error) {
	if strings.TrimSpace(runID) == "" {
		return nil, errors.New("list checkpoints: empty run id")
	}
	rows, err := s.db.Query(selectCheckpointsSQL, runID)
	if err != nil {
		return nil, fmt.Errorf("query checkpoints %s: %w", runID, err)
	}
	defer rows.Close()

	checkpoints := make([]RunCheckpoint, 0)
	for rows.Next() {
		checkpoint, err := scanCheckpoint(rows)
		if err != nil {
			return nil, fmt.Errorf("scan checkpoint %s: %w", runID, err)
		}
		checkpoints = append(checkpoints, checkpoint)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read checkpoints %s: %w", runID, err)
	}
	return checkpoints, nil
}

// LatestCheckpoint returns the newest checkpoint of a run. found is false when
// the run never wrote one.
func (s *Store) LatestCheckpoint(runID string) (RunCheckpoint, bool, error) {
	if strings.TrimSpace(runID) == "" {
		return RunCheckpoint{}, false, errors.New("latest checkpoint: empty run id")
	}
	row := s.db.QueryRow(`SELECT run_id, seq, path, state, created_at
		FROM run_checkpoints WHERE run_id = ? ORDER BY seq DESC LIMIT 1`, runID)
	checkpoint, err := scanCheckpoint(row)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return RunCheckpoint{}, false, nil
	case err != nil:
		return RunCheckpoint{}, false, fmt.Errorf("latest checkpoint %s: %w", runID, err)
	}
	return checkpoint, true, nil
}

// nextCheckpointSequence picks the next sequence inside the caller's
// transaction, so two writers cannot select the same free slot.
func nextCheckpointSequence(tx *sql.Tx, runID string) (int, error) {
	var seq int
	if err := tx.QueryRow("SELECT COALESCE(MAX(seq), 0) + 1 FROM run_checkpoints WHERE run_id = ?",
		runID).Scan(&seq); err != nil {
		return 0, fmt.Errorf("next checkpoint %s: %w", runID, err)
	}
	return seq, nil
}

func latestCheckpointTx(tx *sql.Tx, runID string) (RunCheckpoint, bool, error) {
	row := tx.QueryRow(`SELECT run_id, seq, path, state, created_at
		FROM run_checkpoints WHERE run_id = ? ORDER BY seq DESC LIMIT 1`, runID)
	checkpoint, err := scanCheckpoint(row)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return RunCheckpoint{}, false, nil
	case err != nil:
		return RunCheckpoint{}, false, fmt.Errorf("latest checkpoint %s: %w", runID, err)
	}
	return checkpoint, true, nil
}

// scanner is satisfied by both *sql.Row and *sql.Rows, so one scan helper
// serves the list and the single-row path.
type checkpointScanner interface {
	Scan(dest ...any) error
}

func scanCheckpoint(row checkpointScanner) (RunCheckpoint, error) {
	var (
		checkpoint RunCheckpoint
		seq        sql.NullInt64
	)
	if err := row.Scan(&checkpoint.RunID, &seq, &checkpoint.Path, &checkpoint.State,
		&checkpoint.CreatedAt); err != nil {
		return RunCheckpoint{}, err
	}
	if seq.Valid {
		checkpoint.Seq = int(seq.Int64)
	}
	return checkpoint, nil
}
