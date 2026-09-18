// Package store implements the SQLite-backed index of the agent-hq state (G2).
//
// The index is a derived read model, never an authority: `agent-hq index`
// parses the same artifacts as package state (evidence documents, task leases,
// project queues and bus messages) and upserts them into one SQLite database.
// Deleting the database only costs one re-index, and the file loaders stay the
// source of truth, so the G1 behaviour is preserved whenever the database is
// absent, stale or unreadable.
//
// Writes are confined to <root>/.memory/agent-hq.db. Readers open the database
// without creating or migrating it, so "not indexed yet" is a normal condition
// that callers resolve by falling back to the files.
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite" // registers the pure-Go "sqlite" database/sql driver
)

const (
	// DriverName is the database/sql driver registered by modernc.org/sqlite.
	DriverName = "sqlite"
	// DBFileName is the index database file name inside <root>/.memory.
	DBFileName = "agent-hq.db"
	// SchemaVersion is the schema revision this build creates and understands.
	// v2 adds the durable write path (run claims, runs, attempts, events).
	SchemaVersion = 2
)

// ErrNotIndexed reports that no index database exists for a root. Callers use
// errors.Is to distinguish "run agent-hq index first" from a real I/O failure.
var ErrNotIndexed = errors.New("no index database")

// meta keys stored in the meta table.
const (
	metaIndexedAt   = "indexed_at"
	metaFingerprint = "fingerprint"
)

// Path returns the index database location for root: <root>/.memory/agent-hq.db.
//
// The database lives next to the artifacts it indexes because .memory already is
// the durable state home of agent-hq. Keeping it there namespaces the derived
// artifact with the rest of the state, isolates worktrees automatically (every
// root owns its index) and avoids dropping a binary file into the repository
// root. .gitignore excludes the database and its journal side files.
func Path(root string) string {
	return filepath.Join(root, ".memory", DBFileName)
}

// Store is an open index database.
type Store struct {
	db   *sql.DB
	root string
	path string
}

// Open creates or opens the index database and migrates it to SchemaVersion. It
// is the write path.
//
// The parent directory (<root>/.memory) must already exist: Open deliberately
// does not create repository directories, so indexing a path that is not an
// agent-hq root fails loudly instead of scattering new folders.
func Open(root string) (*Store, error) {
	path := Path(root)
	dir := filepath.Dir(path)
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("state directory %s is missing: index a valid agent-hq root", dir)
	}

	db, err := open(path)
	if err != nil {
		return nil, err
	}
	if err := migrate(db, path); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{db: db, root: root, path: path}, nil
}

// OpenReadOnly opens an existing index without creating or migrating it. The
// returned error wraps ErrNotIndexed when the database file is absent, which
// lets callers fall back to reading the files.
func OpenReadOnly(root string) (*Store, error) {
	path := Path(root)
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return nil, fmt.Errorf("%w at %s", ErrNotIndexed, path)
	}
	db, err := open(path)
	if err != nil {
		return nil, err
	}
	return &Store{db: db, root: root, path: path}, nil
}

// open dials a plain-file DSN. modernc.org/sqlite treats a name without a
// "file:" prefix and without a query string as a filename, which keeps Windows
// paths (drive letters, backslashes, non-ASCII directory names) out of URI
// escaping entirely.
func open(path string) (*sql.DB, error) {
	db, err := sql.Open(DriverName, path)
	if err != nil {
		return nil, fmt.Errorf("open index %s: %w", path, err)
	}
	// The CLI is a short-lived single-threaded process; one connection avoids
	// pool-level lock churn between the writer and SQLite.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec("PRAGMA busy_timeout = 5000"); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("configure index %s: %w", path, err)
	}
	// Force the connection open now so a bad path fails at Open, not later.
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("open index %s: %w", path, err)
	}
	return db, nil
}

// Path returns the database file this store works on.
func (s *Store) Path() string { return s.path }

// Root returns the repository root this store was opened for.
func (s *Store) Root() string { return s.root }

// Close releases the database handle. It is safe to call on a nil receiver.
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// migrate brings the database up to SchemaVersion. Migrations are append-only:
// adding a version means appending to the migrations table, never editing an
// already released statement list.
func migrate(db *sql.DB, path string) error {
	current, err := schemaVersionOf(db)
	if err != nil {
		return fmt.Errorf("read schema version of %s: %w", path, err)
	}

	if current > SchemaVersion {
		return fmt.Errorf("index %s has schema version %d, newer than supported %d: upgrade the CLI or delete the database", path, current, SchemaVersion)
	}
	if current == 0 {
		if err := apply(db, schemaV1); err != nil {
			return fmt.Errorf("create schema in %s: %w", path, err)
		}
		current = 1
	}
	if current == 1 && SchemaVersion >= 2 {
		if err := apply(db, schemaV2); err != nil {
			return fmt.Errorf("upgrade schema in %s: %w", path, err)
		}
		current = 2
	}
	if current != SchemaVersion {
		return fmt.Errorf("index %s has schema version %d, cannot upgrade to %d", path, current, SchemaVersion)
	}
	if _, err := db.Exec(fmt.Sprintf("PRAGMA user_version = %d", SchemaVersion)); err != nil {
		return fmt.Errorf("set schema version of %s: %w", path, err)
	}
	return nil
}

// schemaVersionOf reads PRAGMA user_version, SQLite's built-in schema marker.
// Using it avoids a chicken-and-egg bootstrap row in a table that may not exist
// yet on a brand-new database.
func schemaVersionOf(db *sql.DB) (int, error) {
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return 0, err
	}
	return version, nil
}

// apply runs every statement of a migration in order.
func apply(db *sql.DB, statements []string) error {
	for _, statement := range statements {
		if _, err := db.Exec(statement); err != nil {
			return fmt.Errorf("%w (statement: %s)", err, firstLine(statement))
		}
	}
	return nil
}

// firstLine keeps migration errors readable by quoting only the statement head.
func firstLine(statement string) string {
	for index, char := range statement {
		if char == '\n' {
			return statement[:index]
		}
	}
	return statement
}

// metaValue reads one meta row. found is false when the key is absent (for
// example in a database created by an older or interrupted run).
func (s *Store) metaValue(key string) (string, bool, error) {
	var value string
	err := s.db.QueryRow("SELECT value FROM meta WHERE key = ?", key).Scan(&value)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return "", false, nil
	case err != nil:
		return "", false, err
	}
	return value, true, nil
}
