package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agent-hq/internal/driver"
)

// runloop_test.go covers the cut-over switch: the Go driver is OFF by default,
// a single pass can still be requested explicitly (tests, verification) and the
// driver command is what flips the mode.

// removeAllRetry deletes path the way t.TempDir does, but tolerates the transient
// Windows failure corporate AV produces: Kaspersky scans a just-written file and
// its directory entry outlives the unlink by a few milliseconds, so a single
// os.RemoveAll reports ERROR_DIR_NOT_EMPTY ("The directory is not empty", the
// flake of BUG-040). Retrying with a short backoff lets the scanner release the
// handle. On a clean machine the first attempt always succeeds.
func removeAllRetry(t *testing.T, path string) {
	t.Helper()
	const (
		attempts = 40
		backoff  = 50 * time.Millisecond
	)
	var err error
	for attempt := 0; attempt < attempts; attempt++ {
		err = os.RemoveAll(path)
		if err == nil {
			if attempt > 0 {
				t.Logf("cleanup: %s removed after %d retries", filepath.Base(path), attempt)
			}
			return
		}
		time.Sleep(backoff)
	}
	t.Errorf("cleanup: %s is still present after %d attempts: %v", path, attempts, err)
}

// tempRoot is t.TempDir with the BUG-040 tolerant cleanup: the returned tree may
// be written to heavily and is removed by a retrying RemoveAll that runs before
// the testing package's own single-attempt RemoveAll (cleanups are LIFO).
func tempRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Cleanup(func() { removeAllRetry(t, root) })
	return root
}

func loopFixture(t *testing.T) string {
	t.Helper()
	root := tempRoot(t)
	for _, dir := range []string{
		filepath.Join(".memory", "inbox", "dev-2"),
		filepath.Join(".memory", "outbox"),
		filepath.Join(".memory", "claims"),
		filepath.Join(".memory", "evidence"),
		filepath.Join(".memory", "dead-letter"),
		filepath.Join(".memory", "archive"),
	} {
		writeShadowFile(t, filepath.Join(root, dir, ".gitkeep"), "")
	}
	writeShadowFile(t, filepath.Join(root, "CONTEXT-BUFFER.md"), "context\n")
	writeShadowFile(t, filepath.Join(root, ".memory", "inbox", "dev-2", "m-1.json"),
		`{"id":"m-1","from":"team-lead","to":"dev-2","payload":"task"}`)
	return root
}

func runLoopCLI(t *testing.T, root string, extra ...string) (int, string, string) {
	t.Helper()
	t.Setenv("AGENT_HQ_ROOT", "")
	t.Setenv("AGENT_HQ_DRIVER", "")
	t.Setenv("AGENT_HQ_FAKE_MODE", "success")
	args := append([]string{"run-loop", "-root", root, "-executor", "fake"}, extra...)
	var stdout, stderr bytes.Buffer
	code := run(args, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestRunLoopDaemonIsOffByDefault(t *testing.T) {
	root := loopFixture(t)

	// Daemon mode without a mode file: nothing runs, and the exit code says
	// "nothing to do" rather than failure.
	code, stdout, _ := runLoopCLI(t, root, "-json")
	if code != 0 {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "driver mode") {
		t.Errorf("stdout = %q, want a note that the driver is off", stdout)
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "outbox", "m-1.json")); !os.IsNotExist(err) {
		t.Errorf("the daemon processed work while the driver was ps")
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "inbox", "dev-2", "m-1.json")); err != nil {
		t.Errorf("the inbox message was touched: %v", err)
	}
}

func TestRunLoopOnceProcessesRegardlessOfMode(t *testing.T) {
	root := loopFixture(t)
	// mode stays default (ps): a single pass is an explicit operator/test action.
	code, stdout, stderr := runLoopCLI(t, root, "-once", "-json")
	if code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, stderr)
	}
	var report struct {
		Processed int `json:"processed"`
		Done      int `json:"done"`
		Items     []struct {
			TaskID string `json:"task_id"`
			Status string `json:"status"`
		} `json:"items"`
	}
	if err := json.Unmarshal([]byte(stdout), &report); err != nil {
		t.Fatalf("report is not json: %v\n%s", err, stdout)
	}
	if report.Processed != 1 || report.Done != 1 || len(report.Items) != 1 || report.Items[0].TaskID != "m-1" {
		t.Fatalf("report = %+v", report)
	}
	if _, err := os.Stat(filepath.Join(root, ".memory", "outbox", "m-1.json")); err != nil {
		t.Errorf("no outbox message: %v", err)
	}
}

func TestRunLoopRejectsUnknownExecutor(t *testing.T) {
	root := loopFixture(t)
	code, _, stderr := runLoopCLI(t, root, "-once", "-executor", "bogus")
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr, "unknown executor") {
		t.Errorf("stderr = %q", stderr)
	}
}

func TestRunLoopRejectsNonAgentHQRoot(t *testing.T) {
	empty := tempRoot(t)
	code, _, stderr := runLoopCLI(t, empty, "-once")
	if code == 0 {
		t.Fatalf("exit = 0, want a failure for a root without .memory")
	}
	if !strings.Contains(stderr, ".memory") {
		t.Errorf("stderr = %q, want a diagnostic about .memory", stderr)
	}
}

func TestDriverCommandSwitchAndReport(t *testing.T) {
	root := loopFixture(t)
	t.Setenv("AGENT_HQ_ROOT", "")
	t.Setenv("AGENT_HQ_DRIVER", "")

	// Default: ps, nothing else to do.
	var stdout, stderr bytes.Buffer
	if code := run([]string{"driver", "-root", root, "-json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("driver exit = %d, stderr = %s", code, stderr.String())
	}
	var reported driverOutput
	if err := json.Unmarshal(stdout.Bytes(), &reported); err != nil {
		t.Fatalf("driver json: %v\n%s", err, stdout.String())
	}
	if reported.Mode != driver.ModePS || reported.Source != "default" || reported.GoAlive {
		t.Fatalf("default driver report = %+v", reported)
	}

	// Switch to go.
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"driver", "-root", root, "-set", "go", "-json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("driver -set go exit = %d, stderr = %s", code, stderr.String())
	}
	if err := json.Unmarshal(stdout.Bytes(), &reported); err != nil {
		t.Fatalf("driver json: %v", err)
	}
	if reported.Mode != driver.ModeGo || reported.Source != driver.ModeFileName {
		t.Fatalf("after -set go: %+v", reported)
	}
	raw, err := os.ReadFile(driver.ModePath(root))
	if err != nil {
		t.Fatalf("mode file: %v", err)
	}
	if strings.TrimSpace(string(raw)) != "go" {
		t.Errorf("mode file content = %q", raw)
	}
	if _, err := os.Stat(driver.LockPath(root)); !os.IsNotExist(err) {
		t.Errorf("the driver command must not create a liveness file")
	}

	// A fresh heartbeat makes the Go driver report as alive.
	if err := driver.WriteLock(root, driver.Lock{Mode: driver.ModeGo, PID: os.Getpid(),
		HeartbeatAt: time.Now().UTC().Format(time.RFC3339Nano)}); err != nil {
		t.Fatalf("WriteLock: %v", err)
	}
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"driver", "-root", root, "-json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("driver exit = %d", code)
	}
	if err := json.Unmarshal(stdout.Bytes(), &reported); err != nil {
		t.Fatalf("driver json: %v", err)
	}
	if !reported.GoAlive || reported.LockPID != os.Getpid() {
		t.Errorf("live driver report = %+v", reported)
	}

	// And the daemon now accepts to start... which would block, so only the
	// resolved mode is asserted through the report above.
	stdout.Reset()
	stderr.Reset()
	if code := run([]string{"driver", "-root", root, "-clear", "-json"}, &stdout, &stderr); code != 0 {
		t.Fatalf("driver -clear exit = %d", code)
	}
	if err := json.Unmarshal(stdout.Bytes(), &reported); err != nil {
		t.Fatalf("driver json: %v", err)
	}
	if reported.Mode != driver.ModePS {
		t.Errorf("after -clear: %+v", reported)
	}
	if _, err := os.Stat(driver.ModePath(root)); !os.IsNotExist(err) {
		t.Errorf("mode file survived -clear")
	}
	// The rollback must also drop the Go liveness file: one command restores the
	// PS default with no leftover heartbeat for the guard to read.
	if _, err := os.Stat(driver.LockPath(root)); !os.IsNotExist(err) {
		t.Errorf("liveness file survived -clear")
	}
}

func TestDriverRejectsUnknownMode(t *testing.T) {
	root := loopFixture(t)
	t.Setenv("AGENT_HQ_ROOT", "")
	t.Setenv("AGENT_HQ_DRIVER", "")
	var stdout, stderr bytes.Buffer
	code := run([]string{"driver", "-root", root, "-set", "sometimes"}, &stdout, &stderr)
	if code != 2 {
		t.Fatalf("exit = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "want go or ps") {
		t.Errorf("stderr = %q", stderr.String())
	}
}
