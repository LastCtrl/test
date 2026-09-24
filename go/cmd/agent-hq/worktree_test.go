package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"agent-hq/internal/worktree"
)

func runGitCommand(t *testing.T, root string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v (%s)", args, err, string(out))
	}
	return string(out)
}

// newGitRepo creates a throwaway repository with one commit for the CLI tests.
func newGitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not available; skipping the worktree CLI test")
	}
	root := tempRoot(t)
	runGitCommand(t, root, "init")
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("agent-hq CLI test\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGitCommand(t, root, "add", "-A")
	runGitCommand(t, root, "-c", "user.name=agent-hq", "-c", "user.email=agent-hq@example.invalid", "commit", "-m", "init")
	return root
}

func TestWorktreeCommandLifecycle(t *testing.T) {
	root := newGitRepo(t)
	globals := globalOptions{root: root, json: true}

	var stdout, stderr bytes.Buffer
	if code := runWorktree(globals, []string{"add", "dev-2"}, &stdout, &stderr); code != 0 {
		t.Fatalf("worktree add exit = %d, stderr = %s", code, stderr.String())
	}
	var added worktree.AddResult
	if err := json.Unmarshal(stdout.Bytes(), &added); err != nil {
		t.Fatalf("decode add: %v (%s)", err, stdout.String())
	}
	if !added.OK || !added.Created || added.Branch != "project/dev-2" {
		t.Fatalf("add = %+v, want a created worktree", added)
	}

	stdout.Reset()
	stderr.Reset()
	if code := runWorktree(globals, []string{"add", "dev-2"}, &stdout, &stderr); code != 0 {
		t.Fatalf("idempotent add exit = %d, stderr = %s", code, stderr.String())
	}
	var second worktree.AddResult
	if err := json.Unmarshal(stdout.Bytes(), &second); err != nil {
		t.Fatalf("decode second add: %v", err)
	}
	if second.Created {
		t.Errorf("second add = %+v, want created=false", second)
	}

	stdout.Reset()
	if code := runWorktree(globals, []string{"list"}, &stdout, &stderr); code != 0 {
		t.Fatalf("worktree list exit = %d, stderr = %s", code, stderr.String())
	}
	var statuses []worktree.Status
	if err := json.Unmarshal(stdout.Bytes(), &statuses); err != nil {
		t.Fatalf("decode list: %v (%s)", err, stdout.String())
	}
	found := false
	for _, status := range statuses {
		if status.Project == "dev-2" {
			found = true
			if !status.Registered || status.RegisteredBranch != "project/dev-2" {
				t.Errorf("status = %+v, want a registered worktree", status)
			}
		}
	}
	if !found {
		t.Fatalf("dev-2 missing from list: %+v", statuses)
	}

	stdout.Reset()
	if code := runWorktree(globals, []string{"remove", "dev-2"}, &stdout, &stderr); code != 0 {
		t.Fatalf("worktree remove exit = %d, stderr = %s", code, stderr.String())
	}
	var removed worktree.RemoveResult
	if err := json.Unmarshal(stdout.Bytes(), &removed); err != nil {
		t.Fatalf("decode remove: %v", err)
	}
	if !removed.OK || !removed.Removed {
		t.Fatalf("remove = %+v, want a removal", removed)
	}
	if _, err := os.Stat(added.Path); !os.IsNotExist(err) {
		t.Errorf("worktree path %q still exists (stat err = %v)", added.Path, err)
	}
}

func TestWorktreeCommandRejectsInvalidName(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := runWorktree(globalOptions{root: tempRoot(t)}, []string{"add", "../evil"}, &stdout, &stderr)
	if code != 2 {
		t.Errorf("worktree add traversal exit = %d, want 2 (stderr = %s)", code, stderr.String())
	}
}

func TestWorktreeCommandUsage(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := runWorktree(globalOptions{}, nil, &stdout, &stderr); code != 2 {
		t.Errorf("bare worktree exit = %d, want 2", code)
	}
	stderr.Reset()
	if code := runWorktree(globalOptions{}, []string{"bogus"}, &stdout, &stderr); code != 2 {
		t.Errorf("unknown worktree subcommand exit = %d, want 2", code)
	}
	stderr.Reset()
	if code := runWorktree(globalOptions{}, []string{"remove"}, &stdout, &stderr); code != 2 {
		t.Errorf("remove without a name exit = %d, want 2", code)
	}
}

func TestProjectBufferCommandRoundTrip(t *testing.T) {
	root := tempRoot(t)
	globals := globalOptions{root: root, json: true}

	var stdout, stderr bytes.Buffer
	if code := runProjectBuffer(globals, []string{"absent"}, &stdout, &stderr); code != 1 {
		t.Errorf("missing buffer exit = %d, want 1", code)
	}

	stdout.Reset()
	stderr.Reset()
	if code := runProjectBuffer(globals,
		[]string{"alpha", "-append", "hello\n", "-source", "alpha"}, &stdout, &stderr); code != 0 {
		t.Fatalf("append exit = %d, stderr = %s", code, stderr.String())
	}
	var write worktree.WriteResult
	if err := json.Unmarshal(stdout.Bytes(), &write); err != nil {
		t.Fatalf("decode append: %v (%s)", err, stdout.String())
	}
	if !write.OK || write.Bytes == 0 {
		t.Fatalf("append = %+v, want a verified write", write)
	}

	stdout.Reset()
	if code := runProjectBuffer(globals, []string{"alpha", "-tail", "5"}, &stdout, &stderr); code != 0 {
		t.Fatalf("read exit = %d, stderr = %s", code, stderr.String())
	}
	var read projectBufferOutput
	if err := json.Unmarshal(stdout.Bytes(), &read); err != nil {
		t.Fatalf("decode read: %v (%s)", err, stdout.String())
	}
	if !read.Exists || !strings.Contains(read.Content, "hello") {
		t.Errorf("read = %+v, want the appended content", read)
	}

	// The leak guard must reject a write whose source is another project.
	stdout.Reset()
	stderr.Reset()
	if code := runProjectBuffer(globals,
		[]string{"alpha", "-append", "from beta", "-source", "beta"}, &stdout, &stderr); code != 1 {
		t.Fatalf("cross-project append exit = %d, want 1 (stderr = %s)", code, stderr.String())
	}
	var blocked worktree.WriteResult
	if err := json.Unmarshal(stdout.Bytes(), &blocked); err != nil {
		t.Fatalf("decode blocked write: %v (%s)", err, stdout.String())
	}
	if blocked.OK || !strings.Contains(blocked.Reason, "cross-project write blocked") {
		t.Errorf("blocked = %+v, want the leak guard rejection", blocked)
	}
}

func TestProjectCommandUsage(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := runProject(globalOptions{}, nil, &stdout, &stderr); code != 2 {
		t.Errorf("bare project exit = %d, want 2", code)
	}
	stderr.Reset()
	if code := runProject(globalOptions{}, []string{"bogus"}, &stdout, &stderr); code != 2 {
		t.Errorf("unknown project subcommand exit = %d, want 2", code)
	}
}

func TestTailContent(t *testing.T) {
	cases := []struct {
		content string
		n       int
		want    string
	}{
		{"a\nb\nc", 2, "b\nc"},
		{"a\nb\nc", 0, "a\nb\nc"},
		{"a\nb\nc", 5, "a\nb\nc"},
		{"", 3, ""},
	}
	for _, tc := range cases {
		if got := tailContent(tc.content, tc.n); got != tc.want {
			t.Errorf("tailContent(%q, %d) = %q, want %q", tc.content, tc.n, got, tc.want)
		}
	}
}
