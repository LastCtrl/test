// Package bus implements the on-disk contract of the agent-hq message bus.
//
// The PowerShell engine (inbox-engine.ps1 / inbox-poller.ps1) owns these
// artifacts today: .memory/inbox/<agent>/*.json in, .memory/outbox and
// .memory/dead-letter out, .memory/archive as the processed-inbox history and
// .memory/evidence/<id>.json as machine evidence. The Go driver (run-loop) has
// to write the same shapes into the same folders, otherwise the bridge, the
// timers and every consumer script would have to learn a second format. This
// package is that shared contract: same file names, same JSON keys, same
// destinations, same success rule.
//
// Writers return an error instead of silently dropping a result, so a caller
// can report an honest failure.
package bus

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"agent-hq/internal/state"
)

// Directory names inside .memory, one per bus scope.
const (
	InboxDirName      = "inbox"
	OutboxDirName     = "outbox"
	ArchiveDirName    = "archive"
	DeadLetterDirName = "dead-letter"
	EvidenceDirName   = "evidence"
	ClaimsDirName     = "claims"
	TracesDirName     = "traces"
)

// MaxResponseLength mirrors $script:maxResponseLength in inbox-engine.ps1: the
// outbox response and both dead-letter streams are cut at this many characters.
const MaxResponseLength = 4000

// ClaimTimeLayout is the timestamp shape the file leases use; it mirrors
// (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff") in the task state helper.
const ClaimTimeLayout = "2006-01-02T15:04:05.000"

// FormatDateTime mirrors Format-DateTime in inbox-engine.ps1: local time, no
// fractional seconds and no zone, used for message lifecycle stamps.
func FormatDateTime(at time.Time) string {
	return at.Format("2006-01-02T15:04:05")
}

// FormatClaimTime renders a lease timestamp.
func FormatClaimTime(at time.Time) string {
	return at.Format(ClaimTimeLayout)
}

// MemoryDir returns <root>/.memory.
func MemoryDir(root string) string { return state.MemoryDir(root) }

// InboxDir returns <root>/.memory/inbox.
func InboxDir(root string) string { return state.InboxDir(root) }

// OutboxDir returns <root>/.memory/outbox.
func OutboxDir(root string) string { return state.OutboxDir(root) }

// DeadLetterDir returns <root>/.memory/dead-letter.
func DeadLetterDir(root string) string { return state.DeadLetterDir(root) }

// ClaimsDir returns <root>/.memory/claims.
func ClaimsDir(root string) string { return state.ClaimsDir(root) }

// ArchiveDir returns <root>/.memory/archive.
func ArchiveDir(root string) string {
	return filepath.Join(state.MemoryDir(root), ArchiveDirName)
}

// EvidenceDir returns <root>/.memory/evidence.
func EvidenceDir(root string) string { return state.EvidenceDir(root) }

// ProjectsDir returns <root>/projects.
func ProjectsDir(root string) string { return state.ProjectsDir(root) }

// TracesDir returns <root>/.memory/traces.
func TracesDir(root string) string {
	return filepath.Join(state.MemoryDir(root), TracesDirName)
}

// ProjectQueuePath returns <root>/projects/<project>/queue.json.
func ProjectQueuePath(root, project string) string {
	return filepath.Join(state.ProjectsDir(root), project, state.QueueFileName)
}

// ProjectClaimsDir returns the per-project lease directory used by
// project-queue.ps1: <root>/projects/<project>/.memory/claims. Task ids are only
// unique inside a project, so queue leases must not share the inbox claims dir.
func ProjectClaimsDir(root, project string) string {
	return filepath.Join(state.ProjectsDir(root), project, ".memory", ClaimsDirName)
}

// EnsureDir creates dir when it is missing.
func EnsureDir(dir string) error {
	if dir == "" {
		return nil
	}
	return os.MkdirAll(dir, 0o755)
}

// safeNamePattern matches the ids the PowerShell task state helper keeps verbatim; everything else
// is hashed so a hostile id can never escape the state directory.
var safeNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,200}$`)

// ClaimFileName maps a task id to a lease file leaf, exactly like
// Get-ClaimFileName in the task state helper.
func ClaimFileName(taskID string) string {
	if safeNamePattern.MatchString(taskID) {
		return taskID + ".claim.json"
	}
	sum := sha256.Sum256([]byte(taskID))
	return "h" + hex.EncodeToString(sum[:])[:40] + ".claim.json"
}

// SHA256Hex returns the lowercase hex SHA-256 of text, the encoding
// evidence-writer.ps1 uses for output hashes.
func SHA256Hex(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

// FileName returns the last path element of a path.
func FileName(path string) string { return filepath.Base(path) }

// BaseName returns a file name without its extension.
func BaseName(path string) string {
	name := filepath.Base(path)
	return strings.TrimSuffix(name, filepath.Ext(name))
}

// fsRetryAttempts and fsRetryBackoff bound the wait for a transient Windows
// sharing violation. A corporate AV scanner opens a just-written file to inspect
// it, and for a few milliseconds an otherwise legal write or rename fails
// instead of replacing the target. The bounds cap the wait at 200 ms and keep a
// genuinely broken path failing loudly instead of retrying forever.
const (
	fsRetryAttempts = 8
	fsRetryBackoff  = 25 * time.Millisecond
)

// renameWithRetry renames oldpath to newpath, tolerating the transient Windows
// sharing violation described above. os.Rename replaces an existing target on
// Windows, which mirrors Move-Item -Force; a permanent error is returned after
// the bounded retries.
func renameWithRetry(oldpath, newpath string) error {
	var err error
	for attempt := 0; attempt < fsRetryAttempts; attempt++ {
		if err = os.Rename(oldpath, newpath); err == nil {
			return nil
		}
		time.Sleep(fsRetryBackoff)
	}
	return err
}

// WriteFileAtomic writes data to path through a temporary sibling and a rename,
// so a reader never observes a half-written document. The rename replaces an
// existing file on Windows, which mirrors Move-Item -Force.
//
// Both the write and the rename are retried: without the retry a transient AV
// scan of the previous revision fails the rename, and the caller would silently
// lose the new durable document (an audit gap in evidence/queue, the flake of
// BUG-040). The retry only turns a transient failure into the success the caller
// expects; the happy path is unchanged.
func WriteFileAtomic(path string, data []byte) error {
	if err := EnsureDir(filepath.Dir(path)); err != nil {
		return err
	}
	tmp := path + ".tmp"
	var err error
	for attempt := 0; attempt < fsRetryAttempts; attempt++ {
		if err = os.WriteFile(tmp, data, 0o644); err != nil {
			time.Sleep(fsRetryBackoff)
			continue
		}
		if err = os.Rename(tmp, path); err == nil {
			return nil
		}
		time.Sleep(fsRetryBackoff)
	}
	_ = os.Remove(tmp)
	return err
}

// ReadTextFile reads a file as UTF-8 and strips a byte order mark, mirroring
// the encoding handling of the PowerShell readers.
func ReadTextFile(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimPrefix(string(raw), "\ufeff"), nil
}
