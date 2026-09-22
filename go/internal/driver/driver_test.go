package driver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".memory"), 0o755); err != nil {
		t.Fatalf("mkdir .memory: %v", err)
	}
	return root
}

func TestResolveDefaultsToPowerShell(t *testing.T) {
	root := newRoot(t)
	t.Setenv(ModeEnvName, "")

	mode, source, warning := Resolve(root)
	if mode != ModePS || source != "default" || warning != "" {
		t.Fatalf("Resolve = %q, %q, %q; want ps/default/no warning", mode, source, warning)
	}
}

func TestResolveReadsFileAndEnv(t *testing.T) {
	root := newRoot(t)
	t.Setenv(ModeEnvName, "")
	if err := Write(root, "GO"); err != nil {
		t.Fatalf("Write: %v", err)
	}
	mode, source, _ := Resolve(root)
	if mode != ModeGo || source != ModeFileName {
		t.Fatalf("Resolve = %q, %q; want go/%s", mode, source, ModeFileName)
	}

	t.Setenv(ModeEnvName, "ps")
	mode, source, _ = Resolve(root)
	if mode != ModePS || source != ModeEnvName {
		t.Fatalf("env must win: Resolve = %q, %q", mode, source)
	}
}

func TestResolveRejectsUnknownValues(t *testing.T) {
	root := newRoot(t)
	t.Setenv(ModeEnvName, "")
	if err := os.WriteFile(ModePath(root), []byte("bogus\n"), 0o644); err != nil {
		t.Fatalf("write mode file: %v", err)
	}
	mode, _, warning := Resolve(root)
	if mode != ModePS {
		t.Errorf("unknown mode = %q, want ps", mode)
	}
	if !strings.Contains(warning, "bogus") {
		t.Errorf("warning = %q, want it to quote the bad value", warning)
	}

	t.Setenv(ModeEnvName, "nonsense")
	mode, _, warning = Resolve(root)
	if mode != ModePS || !strings.Contains(warning, "nonsense") {
		t.Errorf("unknown env mode = %q, %q", mode, warning)
	}
}

func TestWriteRejectsUnknownModeAndClearRestoresDefault(t *testing.T) {
	root := newRoot(t)
	t.Setenv(ModeEnvName, "")
	if err := Write(root, "both"); err == nil {
		t.Error("Write accepted an unknown mode")
	}
	if err := Write(root, ModeGo); err != nil {
		t.Fatalf("Write(go): %v", err)
	}
	if err := Clear(root); err != nil {
		t.Fatalf("Clear: %v", err)
	}
	if mode, _, _ := Resolve(root); mode != ModePS {
		t.Errorf("mode after Clear = %q, want ps", mode)
	}
	// Clearing when nothing is set is not an error.
	if err := Clear(root); err != nil {
		t.Errorf("second Clear: %v", err)
	}
}

func TestLockLiveness(t *testing.T) {
	root := newRoot(t)
	fresh := Lock{Mode: ModeGo, PID: os.Getpid(),
		StartedAt: time.Now().UTC().Format(time.RFC3339Nano), HeartbeatAt: time.Now().UTC().Format(time.RFC3339Nano)}
	if err := WriteLock(root, fresh); err != nil {
		t.Fatalf("WriteLock: %v", err)
	}
	if !Alive(root, time.Minute) {
		t.Error("a fresh heartbeat is not alive")
	}
	if Alive(root, time.Nanosecond) {
		t.Error("a heartbeat from the past is alive with a nanosecond TTL")
	}

	stale := fresh
	stale.HeartbeatAt = time.Now().Add(-time.Hour).UTC().Format(time.RFC3339Nano)
	if err := WriteLock(root, stale); err != nil {
		t.Fatalf("WriteLock(stale): %v", err)
	}
	if Alive(root, time.Minute) {
		t.Error("a stale heartbeat is still alive")
	}

	if err := RemoveLock(root); err != nil {
		t.Fatalf("RemoveLock: %v", err)
	}
	if Alive(root, time.Minute) {
		t.Error("a removed lock reports alive")
	}
	raw, ok := ReadLock(root)
	if ok || raw.PID != 0 {
		t.Errorf("ReadLock after removal = %+v, %v; want a zero lock", raw, ok)
	}
}
