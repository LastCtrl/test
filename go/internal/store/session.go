package store

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// Session mark statuses. A task is marked invalid when the provider rejects its
// session; the mark is durable so a later `recover` (or a human) sees that the
// task needs a fresh session rather than another blind retry.
const (
	SessionInvalid = "invalid"
	SessionCleared = "cleared"
)

// SessionMark is one durable session-invalid record.
type SessionMark struct {
	TaskID    string `json:"task_id"`
	Agent     string `json:"agent,omitempty"`
	Status    string `json:"status"`
	Reason    string `json:"reason,omitempty"`
	MarkedAt  string `json:"marked_at,omitempty"`
	ClearedAt string `json:"cleared_at,omitempty"`
}

const markSessionSQL = `INSERT INTO session_marks (task_id, agent, status, reason, marked_at, cleared_at)
		VALUES (?, ?, ?, ?, ?, '')
	ON CONFLICT(task_id) DO UPDATE SET
		agent      = excluded.agent,
		status     = excluded.status,
		reason     = excluded.reason,
		marked_at  = excluded.marked_at,
		cleared_at = ''`

// MarkSessionInvalid records (or refreshes) the session-invalid mark of a task.
func (s *Store) MarkSessionInvalid(mark SessionMark) error {
	if strings.TrimSpace(mark.TaskID) == "" {
		return errors.New("mark session: empty task id")
	}
	status := strings.TrimSpace(mark.Status)
	if status == "" {
		status = SessionInvalid
	}
	markedAt := mark.MarkedAt
	if markedAt == "" {
		markedAt = formatRunTime(time.Time{})
	}
	if _, err := s.db.Exec(markSessionSQL, mark.TaskID, mark.Agent, status, mark.Reason, markedAt); err != nil {
		return fmt.Errorf("mark session %s: %w", mark.TaskID, err)
	}
	return nil
}

// ClearSession mark flips a mark to cleared once a fresh session succeeded.
func (s *Store) ClearSession(taskID string, now time.Time) (bool, error) {
	if strings.TrimSpace(taskID) == "" {
		return false, errors.New("clear session: empty task id")
	}
	result, err := s.db.Exec("UPDATE session_marks SET status = ?, cleared_at = ? WHERE task_id = ? AND status <> ?",
		SessionCleared, formatRunTime(now), taskID, SessionCleared)
	if err != nil {
		return false, fmt.Errorf("clear session %s: %w", taskID, err)
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("clear session %s: %w", taskID, err)
	}
	return affected > 0, nil
}

// SessionMarks returns every mark, invalid ones first, then newest.
func (s *Store) SessionMarks() ([]SessionMark, error) {
	rows, err := s.db.Query(`SELECT task_id, agent, status, reason, marked_at, cleared_at
		FROM session_marks ORDER BY (status = ?) DESC, marked_at DESC, task_id`, SessionInvalid)
	if err != nil {
		return nil, fmt.Errorf("query session marks: %w", err)
	}
	defer rows.Close()

	marks := make([]SessionMark, 0)
	for rows.Next() {
		var mark SessionMark
		if err := rows.Scan(&mark.TaskID, &mark.Agent, &mark.Status, &mark.Reason,
			&mark.MarkedAt, &mark.ClearedAt); err != nil {
			return nil, fmt.Errorf("scan session mark: %w", err)
		}
		marks = append(marks, mark)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read session marks: %w", err)
	}
	return marks, nil
}

// InvalidSessionCount counts the marks that still require a fresh session.
func (s *Store) InvalidSessionCount() (int, error) {
	var count int
	err := s.db.QueryRow("SELECT COUNT(*) FROM session_marks WHERE status = ?", SessionInvalid).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count invalid sessions: %w", err)
	}
	return count, nil
}

// SessionMarkByTask returns one mark. found is false when the task was never
// marked; an empty database is not an error.
func (s *Store) SessionMarkByTask(taskID string) (SessionMark, bool, error) {
	marks, err := s.SessionMarks()
	if err != nil {
		return SessionMark{}, false, err
	}
	for _, mark := range marks {
		if mark.TaskID == taskID {
			return mark, true, nil
		}
	}
	return SessionMark{}, false, nil
}
