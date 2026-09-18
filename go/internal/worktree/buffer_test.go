package worktree

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAppendAndReadBuffer(t *testing.T) {
	root := t.TempDir()

	result, err := AppendBuffer(root, "alpha", "first entry\n", "alpha", false)
	if err != nil {
		t.Fatalf("AppendBuffer: %v", err)
	}
	if !result.OK || result.Reason != "appended" || result.Bytes == 0 {
		t.Fatalf("result = %+v, want a verified append", result)
	}
	wantPath, err := BufferPath(root, "alpha")
	if err != nil {
		t.Fatalf("BufferPath: %v", err)
	}
	if result.Path != wantPath {
		t.Errorf("path = %q, want %q", result.Path, wantPath)
	}

	content, found, err := ReadBuffer(root, "alpha")
	if err != nil || !found {
		t.Fatalf("ReadBuffer = %q, %t, %v", content, found, err)
	}
	if !strings.Contains(content, "first entry") {
		t.Errorf("content = %q, want the appended entry", content)
	}
}

// TestBufferLeakGuardIsolatesProjects is the core shared-memory guarantee: a
// write into project A never appears in project B.
func TestBufferLeakGuardIsolatesProjects(t *testing.T) {
	root := t.TempDir()

	if _, err := AppendBuffer(root, "alpha", "alpha secret\n", "alpha", false); err != nil {
		t.Fatalf("AppendBuffer(alpha): %v", err)
	}
	if _, err := AppendBuffer(root, "beta", "beta content\n", "beta", false); err != nil {
		t.Fatalf("AppendBuffer(beta): %v", err)
	}

	alpha, alphaFound, err := ReadBuffer(root, "alpha")
	if err != nil || !alphaFound {
		t.Fatalf("ReadBuffer(alpha) = %q, %t, %v", alpha, alphaFound, err)
	}
	beta, betaFound, err := ReadBuffer(root, "beta")
	if err != nil || !betaFound {
		t.Fatalf("ReadBuffer(beta) = %q, %t, %v", beta, betaFound, err)
	}
	if strings.Contains(beta, "alpha secret") {
		t.Errorf("beta buffer leaked content from alpha: %q", beta)
	}
	if strings.Contains(alpha, "beta content") {
		t.Errorf("alpha buffer leaked content from beta: %q", alpha)
	}

	// The isolation is also physical: two distinct files under two dirs.
	alphaPath, _ := BufferPath(root, "alpha")
	betaPath, _ := BufferPath(root, "beta")
	if alphaPath == betaPath {
		t.Errorf("both projects share one buffer path %q", alphaPath)
	}
}

func TestAppendBufferRejectsCrossProjectWrite(t *testing.T) {
	root := t.TempDir()

	result, err := AppendBuffer(root, "alpha", "from beta", "beta", false)
	if err != nil {
		t.Fatalf("AppendBuffer: %v", err)
	}
	if result.OK {
		t.Fatalf("result = %+v, want a rejection", result)
	}
	if !strings.Contains(result.Reason, "cross-project write blocked") {
		t.Errorf("reason = %q, want the leak guard message", result.Reason)
	}

	// The rejected content must not have reached either buffer.
	for _, project := range []string{"alpha", "beta"} {
		content, found, err := ReadBuffer(root, project)
		if err != nil {
			t.Fatalf("ReadBuffer(%s): %v", project, err)
		}
		if found && strings.Contains(content, "from beta") {
			t.Errorf("%s buffer contains the rejected write: %q", project, content)
		}
	}
}

func TestAppendBufferAllowsExplicitCrossProjectWrite(t *testing.T) {
	root := t.TempDir()

	result, err := AppendBuffer(root, "alpha", "handoff\n", "beta", true)
	if err != nil {
		t.Fatalf("AppendBuffer: %v", err)
	}
	if !result.OK {
		t.Fatalf("result = %+v, want the explicit override to succeed", result)
	}
}

func TestAppendBufferSeparator(t *testing.T) {
	root := t.TempDir()

	if result, _ := AppendBuffer(root, "alpha", "one\n", "alpha", false); !result.OK {
		t.Fatalf("first append = %+v", result)
	}
	// Existing content ends with a true newline: no extra separator.
	if result, _ := AppendBuffer(root, "alpha", "two", "alpha", false); !result.OK {
		t.Fatalf("second append = %+v", result)
	}
	// Existing content does not end with a newline: CRLF is inserted.
	if result, _ := AppendBuffer(root, "alpha", "three", "alpha", false); !result.OK {
		t.Fatalf("third append = %+v", result)
	}

	content, _, err := ReadBuffer(root, "alpha")
	if err != nil {
		t.Fatalf("ReadBuffer: %v", err)
	}
	if content != "one\ntwo\r\nthree" {
		t.Errorf("content = %q, want %q", content, "one\ntwo\r\nthree")
	}
}

func TestBufferPathBoundary(t *testing.T) {
	root := t.TempDir()

	bufferPath, err := BufferPath(root, "alpha")
	if err != nil {
		t.Fatalf("BufferPath: %v", err)
	}
	if !TestPathBoundary(root, "alpha", bufferPath) {
		t.Errorf("TestPathBoundary(%q) = false, want true", bufferPath)
	}

	otherPath, err := BufferPath(root, "beta")
	if err != nil {
		t.Fatalf("BufferPath(beta): %v", err)
	}
	if TestPathBoundary(root, "alpha", otherPath) {
		t.Errorf("TestPathBoundary(beta path) = true, want false for project alpha")
	}

	outside := filepath.Join(t.TempDir(), "CONTEXT-BUFFER.md")
	if TestPathBoundary(root, "alpha", outside) {
		t.Errorf("TestPathBoundary(outside) = true, want false")
	}
	if TestPathBoundary(root, "alpha", "") {
		t.Errorf("TestPathBoundary(empty) = true, want false")
	}
}

func TestReadBufferMissing(t *testing.T) {
	content, found, err := ReadBuffer(t.TempDir(), "absent")
	if err != nil {
		t.Fatalf("ReadBuffer: %v", err)
	}
	if found || content != "" {
		t.Errorf("ReadBuffer(missing) = %q, %t; want empty and not found", content, found)
	}
}

func TestAppendBufferRejectsInvalidNames(t *testing.T) {
	root := t.TempDir()

	badTarget, err := AppendBuffer(root, "../evil", "x", "", false)
	if err != nil {
		t.Fatalf("AppendBuffer: %v", err)
	}
	if badTarget.OK || !strings.Contains(badTarget.Reason, "invalid target project") {
		t.Errorf("bad target = %+v, want a target rejection", badTarget)
	}

	badSource, err := AppendBuffer(root, "alpha", "x", "../evil", false)
	if err != nil {
		t.Fatalf("AppendBuffer: %v", err)
	}
	if badSource.OK || !strings.Contains(badSource.Reason, "invalid source project") {
		t.Errorf("bad source = %+v, want a source rejection", badSource)
	}

	// A rejected write must not create any directory.
	if pathExists(ProjectsDir(root)) {
		entries, _ := os.ReadDir(ProjectsDir(root))
		if len(entries) != 0 {
			t.Errorf("a rejected write created %d entries under projects/", len(entries))
		}
	}
}

func TestReadBufferRejectsInvalidName(t *testing.T) {
	if _, _, err := ReadBuffer(t.TempDir(), "../evil"); err == nil {
		t.Error("ReadBuffer(traversal) = nil error, want a rejection")
	}
}
