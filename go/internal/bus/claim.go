package bus

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// claim.go mirrors the file-atomic lease of the PowerShell task state helper:
//
//	<state dir>/<safe id>.claim.json  { task_id, agent, claimed_at,
//	                                    heartbeat_at, lease_seconds, attempt }
//
// The Go driver takes its durable lease in SQLite (store.AcquireClaim), which is
// its own atomic single-winner decision. It ALSO mirrors that lease into the
// file the PowerShell engine reads, so the two drivers can never run the same
// message twice during a cut-over when both are briefly alive, and so the
// existing `agent-hq leases` and the PS stale sweep keep seeing real leases.
//
// Creation uses O_CREATE|O_EXCL, the Go equivalent of the CreateNew the
// PowerShell helper relies on: exactly one process can create the file.

// FileClaim is the lease document written into a claims directory.
type FileClaim struct {
	TaskID       string `json:"task_id"`
	Agent        string `json:"agent"`
	ClaimedAt    string `json:"claimed_at"`
	HeartbeatAt  string `json:"heartbeat_at"`
	LeaseSeconds int    `json:"lease_seconds"`
	Attempt      int    `json:"attempt"`
}

// ClaimFilePath returns the lease file of a task inside stateDir.
func ClaimFilePath(stateDir, taskID string) string {
	return filepath.Join(stateDir, ClaimFileName(taskID))
}

// ErrClaimWrite reports a lease that could not be persisted at all (as opposed to
// a lease somebody else already owns, which is reported as false, nil).
var ErrClaimWrite = errors.New("cannot write claim")

// ClaimFile atomically creates the lease file. It returns false when a lease
// already exists, which is the normal "another worker owns this task" answer.
func ClaimFile(stateDir, taskID, agent string, leaseSeconds, attempt int) (bool, error) {
	if strings.TrimSpace(taskID) == "" {
		return false, nil
	}
	if leaseSeconds <= 0 {
		leaseSeconds = 900
	}
	if attempt <= 0 {
		attempt = 1
	}
	if err := EnsureDir(stateDir); err != nil {
		return false, err
	}

	now := time.Now()
	claim := FileClaim{
		TaskID:       taskID,
		Agent:        agent,
		ClaimedAt:    FormatClaimTime(now),
		HeartbeatAt:  FormatClaimTime(now),
		LeaseSeconds: leaseSeconds,
		Attempt:      attempt,
	}
	encoded, err := json.Marshal(claim)
	if err != nil {
		return false, err
	}

	path := ClaimFilePath(stateDir, taskID)
	handle, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		if errors.Is(err, fs.ErrExist) {
			return false, nil
		}
		return false, err
	}
	if _, err := handle.Write(encoded); err != nil {
		_ = handle.Close()
		_ = os.Remove(path)
		return false, ErrClaimWrite
	}
	if err := handle.Close(); err != nil {
		_ = os.Remove(path)
		return false, ErrClaimWrite
	}
	return true, nil
}

// HeartbeatFile refreshes the lease timestamp. A lease owned by a different
// agent is never touched, so a stale-swept task re-claimed elsewhere is safe.
func HeartbeatFile(stateDir, taskID, agent string) (bool, error) {
	path := ClaimFilePath(stateDir, taskID)
	claim, ok, err := ReadClaimFile(path)
	if err != nil {
		return false, err
	}
	if !ok {
		return false, nil
	}
	owner := strings.TrimSpace(claim.Agent)
	if owner != "" && strings.TrimSpace(agent) != "" && !strings.EqualFold(owner, agent) {
		return false, nil
	}
	claim.HeartbeatAt = FormatClaimTime(time.Now())
	if claim.ClaimedAt == "" {
		claim.ClaimedAt = claim.HeartbeatAt
	}
	if claim.LeaseSeconds <= 0 {
		claim.LeaseSeconds = 900
	}
	encoded, err := json.Marshal(claim)
	if err != nil {
		return false, err
	}
	if err := WriteFileAtomic(path, encoded); err != nil {
		return false, err
	}
	return true, nil
}

// ReleaseFile drops the lease. An empty agent releases unconditionally (the
// legacy PowerShell behaviour); a named agent only releases its own lease.
func ReleaseFile(stateDir, taskID, agent string) (bool, error) {
	if strings.TrimSpace(taskID) == "" {
		return false, nil
	}
	path := ClaimFilePath(stateDir, taskID)
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return true, nil
		}
		return false, err
	}

	if owner := strings.TrimSpace(agent); owner != "" {
		claim, ok, err := ReadClaimFile(path)
		if err != nil {
			return false, err
		}
		if ok {
			recorded := strings.TrimSpace(claim.Agent)
			if recorded != "" && !strings.EqualFold(recorded, owner) {
				return false, nil
			}
		}
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return false, err
	}
	return true, nil
}

// ReadClaimFile reads one lease file. ok is false when the file is missing or
// unreadable, which the callers treat as "no lease".
func ReadClaimFile(path string) (FileClaim, bool, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return FileClaim{}, false, nil
		}
		return FileClaim{}, false, err
	}
	var claim FileClaim
	if err := json.Unmarshal(trimBOM(raw), &claim); err != nil {
		return FileClaim{}, false, nil
	}
	return claim, true, nil
}

// RevokeStaleClaims releases leases whose heartbeat is older than ttl and
// returns the revoked task ids. The heartbeat falls back to the file's
// modification time, mirroring Get-StaleClaims so a corrupt lease still expires.
func RevokeStaleClaims(stateDir string, ttl time.Duration, now time.Time) ([]string, error) {
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	if ttl <= 0 {
		ttl = 900 * time.Second
	}

	revoked := make([]string, 0)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".claim.json") {
			continue
		}
		path := filepath.Join(stateDir, entry.Name())
		claim, ok, err := ReadClaimFile(path)
		if err != nil {
			continue
		}
		taskID := strings.TrimSuffix(entry.Name(), ".claim.json")
		if ok && strings.TrimSpace(claim.TaskID) != "" {
			taskID = strings.TrimSpace(claim.TaskID)
		}

		heartbeat, parsed := time.Time{}, false
		if ok {
			heartbeat, parsed = parseClaimTime(claim.HeartbeatAt)
		}
		if !parsed {
			if info, statErr := entry.Info(); statErr == nil {
				heartbeat, parsed = info.ModTime(), true
			}
		}
		if !parsed || now.Sub(heartbeat) <= ttl {
			continue
		}

		// Re-read right before deleting: a heartbeat that landed after the scan
		// keeps its lease.
		if current, currentOK, readErr := ReadClaimFile(path); readErr == nil && currentOK {
			if refreshed, refreshOK := parseClaimTime(current.HeartbeatAt); refreshOK && now.Sub(refreshed) <= ttl {
				continue
			}
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			continue
		}
		revoked = append(revoked, taskID)
	}
	return revoked, nil
}

// parseClaimTime accepts the claim layout and the ISO-8601 shapes the runtime
// writes, so a lease written by either driver expires correctly.
func parseClaimTime(value string) (time.Time, bool) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return time.Time{}, false
	}
	for _, layout := range []string{ClaimTimeLayout, time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05"} {
		if parsed, err := time.ParseInLocation(layout, trimmed, time.Local); err == nil {
			return parsed, true
		}
	}
	return time.Time{}, false
}
