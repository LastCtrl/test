// Package driver resolves which execution driver owns the agent-hq loop.
//
// Default is PowerShell ("ps"): nothing changes for the running fleet. Setting
// the mode to "go" hands the loop to `agent-hq run-loop`. The switch is a plain
// text file (plus an environment override) so an operator can flip it without
// touching the task scheduler:
//
//	<root>/.memory/driver.mode   one line: "go" or "ps"
//	AGENT_HQ_DRIVER              environment override, wins over the file
//
// The Go loop writes a liveness file while it runs:
//
//	<root>/.memory/driver.lock   {mode,pid,started_at,heartbeat_at,cycles}
//
// The PowerShell runner reads both files: when the mode is "go" and the
// heartbeat is fresh it stands down, when the heartbeat is stale (the Go loop
// crashed or never started) it keeps working. That is the fallback: a broken Go
// driver degrades to the old one instead of stopping the fleet.
package driver

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Modes.
const (
	ModePS = "ps"
	ModeGo = "go"
)

// File and environment names understood by both drivers.
const (
	ModeEnvName  = "AGENT_HQ_DRIVER"
	ModeFileName = "driver.mode"
	LockFileName = "driver.lock"
)

// DefaultLockTTL is how long a lock heartbeat stays valid without a refresh. The
// driver loop refreshes it once per cycle (30 s by default), so a missed
// heartbeat window only appears after three consecutive failed cycles.
const DefaultLockTTL = 180 * time.Second

// Lock is the liveness document of a running Go driver.
type Lock struct {
	Mode        string `json:"mode"`
	PID         int    `json:"pid"`
	StartedAt   string `json:"started_at"`
	HeartbeatAt string `json:"heartbeat_at"`
	Cycles      int    `json:"cycles"`
}

// ModePath returns <root>/.memory/driver.mode.
func ModePath(root string) string {
	return filepath.Join(root, ".memory", ModeFileName)
}

// LockPath returns <root>/.memory/driver.lock.
func LockPath(root string) string {
	return filepath.Join(root, ".memory", LockFileName)
}

// Resolve returns the effective mode, where it came from and a warning when a
// value had to be rejected (an unknown mode always degrades to "ps").
func Resolve(root string) (mode, source, warning string) {
	if raw := strings.TrimSpace(os.Getenv(ModeEnvName)); raw != "" {
		normalized := normalize(raw)
		if normalized == "" {
			return ModePS, ModeEnvName, "unknown " + ModeEnvName + " value " + quote(raw) + "; using ps"
		}
		return normalized, ModeEnvName, ""
	}

	raw, err := os.ReadFile(ModePath(root))
	if err != nil {
		if os.IsNotExist(err) {
			return ModePS, "default", ""
		}
		return ModePS, "default", "cannot read driver.mode: " + err.Error()
	}
	content := strings.TrimSpace(strings.TrimPrefix(string(raw), "\ufeff"))
	if content == "" {
		return ModePS, ModeFileName, ""
	}
	normalized := normalize(content)
	if normalized == "" {
		return ModePS, ModeFileName, "unknown driver.mode value " + quote(content) + "; using ps"
	}
	return normalized, ModeFileName, ""
}

// ErrUnknownMode is returned when a caller asks for a mode other than go or ps.
var ErrUnknownMode = errors.New("unknown driver mode (want go or ps)")

// Write stores the mode file (single line, UTF-8 without BOM).
func Write(root, mode string) error {
	normalized := normalize(mode)
	if normalized == "" {
		return ErrUnknownMode
	}
	if err := os.MkdirAll(filepath.Dir(ModePath(root)), 0o755); err != nil {
		return err
	}
	return os.WriteFile(ModePath(root), []byte(normalized+"\n"), 0o644)
}

// Clear removes the mode file, which restores the default ("ps").
func Clear(root string) error {
	err := os.Remove(ModePath(root))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// WriteLock writes the liveness document atomically.
func WriteLock(root string, lock Lock) error {
	encoded, err := json.Marshal(lock)
	if err != nil {
		return err
	}
	return writeAtomic(LockPath(root), encoded)
}

// ReadLock reads the liveness document. ok is false when it is absent or broken.
func ReadLock(root string) (Lock, bool) {
	raw, err := os.ReadFile(LockPath(root))
	if err != nil {
		return Lock{}, false
	}
	var lock Lock
	if err := json.Unmarshal([]byte(strings.TrimPrefix(string(raw), "\ufeff")), &lock); err != nil {
		return Lock{}, false
	}
	return lock, true
}

// Alive reports whether a Go driver heartbeat is fresh enough to trust.
func Alive(root string, ttl time.Duration) bool {
	if ttl <= 0 {
		ttl = DefaultLockTTL
	}
	lock, ok := ReadLock(root)
	if !ok {
		return false
	}
	heartbeat, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(lock.HeartbeatAt))
	if err != nil {
		return false
	}
	age := time.Since(heartbeat)
	return age >= 0 && age <= ttl
}

// RemoveLock deletes the liveness document after a clean shutdown.
func RemoveLock(root string) error {
	err := os.Remove(LockPath(root))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func normalize(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case ModeGo:
		return ModeGo
	case ModePS:
		return ModePS
	}
	return ""
}

// quote keeps the warning readable without importing fmt for one call.
func quote(value string) string { return "\"" + value + "\"" }

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
