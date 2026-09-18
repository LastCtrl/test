package store

// schemaV1 is the initial index schema.
//
// Shape notes:
//   - String columns use an empty default (NOT NULL), so scans never need NullString;
//     only the optional numeric fields written by the evidence/queue tooling
//     (exit_code, lengths, duration, pid, retries) are nullable, which lets the
//     read path rebuild the original *int / *int64 pointers exactly.
//   - Timestamps are stored as the raw source strings. The index mirrors the
//     files instead of normalising them, so a value round-trips character for
//     character; time-ordered queries still work because every producer writes
//     ISO-8601-like text.
//   - Natural keys are source identity (project+id for tasks, path for claims
//     and messages), so re-indexing the same state is a no-op rather than a
//     duplicate insert.
var schemaV1 = []string{
	`CREATE TABLE IF NOT EXISTS meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)`,

	`CREATE TABLE IF NOT EXISTS projects (
		project    TEXT PRIMARY KEY,
		queue_path TEXT NOT NULL,
		task_count INTEGER NOT NULL DEFAULT 0
	)`,

	`CREATE TABLE IF NOT EXISTS tasks (
		project        TEXT NOT NULL,
		id             TEXT NOT NULL,
		title          TEXT NOT NULL DEFAULT '',
		priority       TEXT NOT NULL DEFAULT '',
		status         TEXT NOT NULL DEFAULT '',
		assigned_agent TEXT NOT NULL DEFAULT '',
		worktree       TEXT NOT NULL DEFAULT '',
		created_at     TEXT NOT NULL DEFAULT '',
		started_at     TEXT NOT NULL DEFAULT '',
		completed_at   TEXT NOT NULL DEFAULT '',
		retries        INTEGER,
		source         TEXT NOT NULL DEFAULT 'queue',
		path           TEXT NOT NULL DEFAULT '',
		PRIMARY KEY (project, id)
	)`,

	`CREATE TABLE IF NOT EXISTS evidence (
		task_id          TEXT PRIMARY KEY,
		path             TEXT NOT NULL DEFAULT '',
		attempt_count    INTEGER NOT NULL DEFAULT 0,
		last_finished_at TEXT NOT NULL DEFAULT '',
		agents           TEXT NOT NULL DEFAULT ''
	)`,

	`CREATE TABLE IF NOT EXISTS evidence_attempts (
		task_id         TEXT NOT NULL,
		seq             INTEGER NOT NULL,
		attempt_id      TEXT NOT NULL DEFAULT '',
		agent           TEXT NOT NULL DEFAULT '',
		command         TEXT NOT NULL DEFAULT '',
		exit_code       INTEGER,
		stdout_sha256   TEXT NOT NULL DEFAULT '',
		stdout_length   INTEGER,
		stderr_sha256   TEXT NOT NULL DEFAULT '',
		stderr_length   INTEGER,
		started_at      TEXT NOT NULL DEFAULT '',
		finished_at     TEXT NOT NULL DEFAULT '',
		duration_ms     INTEGER,
		status          TEXT NOT NULL DEFAULT '',
		reason          TEXT NOT NULL DEFAULT '',
		git_head        TEXT NOT NULL DEFAULT '',
		git_diff_sha256 TEXT NOT NULL DEFAULT '',
		host            TEXT NOT NULL DEFAULT '',
		pid             INTEGER,
		PRIMARY KEY (task_id, seq)
	)`,

	`CREATE TABLE IF NOT EXISTS claims (
		path         TEXT PRIMARY KEY,
		task_id      TEXT NOT NULL DEFAULT '',
		agent        TEXT NOT NULL DEFAULT '',
		attempt      INTEGER NOT NULL DEFAULT 0,
		claimed_at   TEXT NOT NULL DEFAULT '',
		heartbeat_at TEXT NOT NULL DEFAULT '',
		ttl_seconds  INTEGER NOT NULL DEFAULT 0
	)`,

	`CREATE TABLE IF NOT EXISTS messages (
		scope            TEXT NOT NULL,
		path             TEXT NOT NULL,
		id               TEXT NOT NULL DEFAULT '',
		from_agent       TEXT NOT NULL DEFAULT '',
		to_agent         TEXT NOT NULL DEFAULT '',
		kind             TEXT NOT NULL DEFAULT '',
		priority         TEXT NOT NULL DEFAULT '',
		payload          TEXT NOT NULL DEFAULT '',
		status           TEXT NOT NULL DEFAULT '',
		started_at       TEXT NOT NULL DEFAULT '',
		finished_at      TEXT NOT NULL DEFAULT '',
		response         TEXT NOT NULL DEFAULT '',
		evidence         TEXT NOT NULL DEFAULT '',
		agent            TEXT NOT NULL DEFAULT '',
		created_at       TEXT NOT NULL DEFAULT '',
		created          TEXT NOT NULL DEFAULT '',
		last_activity_at TEXT NOT NULL DEFAULT '',
		PRIMARY KEY (scope, path)
	)`,

	// Indexes: one per access path the CLI and future queries need
	// (task_id / agent / status / time axes). Primary keys already cover their
	// leftmost column, so no redundant index on tasks.project or
	// evidence_attempts.task_id is created.
	`CREATE INDEX IF NOT EXISTS idx_tasks_agent ON tasks (assigned_agent)`,
	`CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks (status)`,
	`CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks (created_at)`,
	`CREATE INDEX IF NOT EXISTS idx_evidence_last_finished ON evidence (last_finished_at)`,
	`CREATE INDEX IF NOT EXISTS idx_attempts_agent ON evidence_attempts (agent)`,
	`CREATE INDEX IF NOT EXISTS idx_attempts_status ON evidence_attempts (status)`,
	`CREATE INDEX IF NOT EXISTS idx_attempts_started ON evidence_attempts (started_at)`,
	`CREATE INDEX IF NOT EXISTS idx_claims_task ON claims (task_id)`,
	`CREATE INDEX IF NOT EXISTS idx_claims_agent ON claims (agent)`,
	`CREATE INDEX IF NOT EXISTS idx_claims_heartbeat ON claims (heartbeat_at)`,
	`CREATE INDEX IF NOT EXISTS idx_messages_id ON messages (id)`,
	`CREATE INDEX IF NOT EXISTS idx_messages_status ON messages (scope, status)`,
	`CREATE INDEX IF NOT EXISTS idx_messages_created ON messages (created_at)`,
}

// schemaV2 adds the durable write path of G3-M1. Unlike the derived tables of
// schemaV1 (which `agent-hq index` rebuilds from the files), these tables are
// authoritative: the control plane writes claims, runs, attempts and events
// here and never reconstructs them from disk. They are deliberately excluded
// from resetTables so a re-index cannot destroy execution history.
//
// Raw worker output is NOT stored: attempts keep only hashes and lengths, which
// is enough for tamper-evidence and keeps credentials out of the database.
var schemaV2 = []string{
	`CREATE TABLE IF NOT EXISTS run_claims (
		task_id       TEXT PRIMARY KEY,
		owner         TEXT NOT NULL DEFAULT '',
		agent         TEXT NOT NULL DEFAULT '',
		attempt       INTEGER NOT NULL DEFAULT 0,
		claimed_at    TEXT NOT NULL DEFAULT '',
		heartbeat_at  TEXT NOT NULL DEFAULT '',
		lease_seconds INTEGER NOT NULL DEFAULT 0
	)`,

	`CREATE TABLE IF NOT EXISTS runs (
		task_id     TEXT PRIMARY KEY,
		agent       TEXT NOT NULL DEFAULT '',
		executor    TEXT NOT NULL DEFAULT '',
		model       TEXT NOT NULL DEFAULT '',
		payload     TEXT NOT NULL DEFAULT '',
		status      TEXT NOT NULL DEFAULT '',
		attempt     INTEGER NOT NULL DEFAULT 0,
		started_at  TEXT NOT NULL DEFAULT '',
		finished_at TEXT NOT NULL DEFAULT '',
		exit_code   INTEGER,
		duration_ms INTEGER,
		error       TEXT NOT NULL DEFAULT '',
		created_at  TEXT NOT NULL DEFAULT '',
		updated_at  TEXT NOT NULL DEFAULT ''
	)`,

	`CREATE TABLE IF NOT EXISTS run_attempts (
		task_id       TEXT NOT NULL,
		seq           INTEGER NOT NULL,
		attempt_id    TEXT NOT NULL DEFAULT '',
		agent         TEXT NOT NULL DEFAULT '',
		executor      TEXT NOT NULL DEFAULT '',
		command       TEXT NOT NULL DEFAULT '',
		exit_code     INTEGER,
		stdout_sha256 TEXT NOT NULL DEFAULT '',
		stdout_length INTEGER,
		stderr_sha256 TEXT NOT NULL DEFAULT '',
		stderr_length INTEGER,
		started_at    TEXT NOT NULL DEFAULT '',
		finished_at   TEXT NOT NULL DEFAULT '',
		duration_ms   INTEGER,
		status        TEXT NOT NULL DEFAULT '',
		error         TEXT NOT NULL DEFAULT '',
		PRIMARY KEY (task_id, seq)
	)`,

	`CREATE TABLE IF NOT EXISTS run_events (
		id         INTEGER PRIMARY KEY AUTOINCREMENT,
		task_id    TEXT NOT NULL DEFAULT '',
		attempt    INTEGER NOT NULL DEFAULT 0,
		kind       TEXT NOT NULL DEFAULT '',
		detail     TEXT NOT NULL DEFAULT '',
		created_at TEXT NOT NULL DEFAULT ''
	)`,

	`CREATE INDEX IF NOT EXISTS idx_run_attempts_status ON run_attempts (status)`,
	`CREATE INDEX IF NOT EXISTS idx_run_events_task ON run_events (task_id, id)`,
	`CREATE INDEX IF NOT EXISTS idx_runs_status ON runs (status)`,
}

// schemaV3 adds the M2 durability layer: run checkpoints, the handoff state a
// long task can resume from, plus the index the watchdog uses to look up
// checkpoints by creation time.
//
// The attempt heartbeat is deliberately NOT a new column. A running attempt
// belongs to the task lease in run_claims, and `agent-hq run` refreshes that
// lease with a ticker, so recovery joins run_attempts to run_claims by task_id
// and evaluates the heartbeat age against the lease in Go -- the same rule the
// file-based sweep applies to .claim.json. Keeping v3 to CREATE ... IF NOT
// EXISTS statements makes the migration safe to re-run after an interrupted
// upgrade, which an ALTER TABLE would not be.
var schemaV3 = []string{
	`CREATE TABLE IF NOT EXISTS run_checkpoints (
		run_id     TEXT NOT NULL,
		seq        INTEGER NOT NULL,
		path       TEXT NOT NULL DEFAULT '',
		state      TEXT NOT NULL DEFAULT '',
		created_at TEXT NOT NULL DEFAULT '',
		PRIMARY KEY (run_id, seq)
	)`,

	`CREATE INDEX IF NOT EXISTS idx_run_checkpoints_created ON run_checkpoints (created_at)`,
}

// schemaV4 adds the M3 session-invalid marker: when the provider rejects a
// session (expired/invalid credentials), the control plane records the task as
// needing a fresh session instead of silently retrying it forever.
//
// Like v3, every statement is CREATE ... IF NOT EXISTS, so an interrupted
// migration is re-runnable. The table is authoritative (not a derived index)
// and is deliberately excluded from the G2 full-resync.
var schemaV4 = []string{
	`CREATE TABLE IF NOT EXISTS session_marks (
		task_id    TEXT PRIMARY KEY,
		agent      TEXT NOT NULL DEFAULT '',
		status     TEXT NOT NULL DEFAULT '',
		reason     TEXT NOT NULL DEFAULT '',
		marked_at  TEXT NOT NULL DEFAULT '',
		cleared_at TEXT NOT NULL DEFAULT ''
	)`,

	`CREATE INDEX IF NOT EXISTS idx_session_marks_status ON session_marks (status)`,
}
