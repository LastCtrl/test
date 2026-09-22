package worktree

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func requireGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not available; skipping real worktree test")
	}
}

// assertGit runs a git command that must succeed.
func assertGit(t *testing.T, root string, args ...string) gitResult {
	t.Helper()
	result, err := runGit(root, args...)
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	if result.exitCode != 0 {
		t.Fatalf("git %v exit %d: %s", args, result.exitCode, result.output)
	}
	return result
}

// newRepo creates a throwaway git repository with one commit, because a git
// worktree cannot be created in an empty repository.
func newRepo(t *testing.T) string {
	t.Helper()
	requireGit(t)

	root := t.TempDir()
	assertGit(t, root, "init")
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("agent-hq test repository\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	assertGit(t, root, "add", "-A")
	assertGit(t, root, "-c", "user.name=agent-hq", "-c", "user.email=agent-hq@example.invalid", "commit", "-m", "init")
	return root
}

func findStatus(t *testing.T, statuses []Status, project string) Status {
	t.Helper()
	for _, status := range statuses {
		if status.Project == project {
			return status
		}
	}
	t.Fatalf("project %q not found in %+v", project, statuses)
	return Status{}
}

func TestAddCreatesRegisteredGitWorktree(t *testing.T) {
	root := newRepo(t)

	result, err := Add(root, "dev-2")
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if !result.OK || !result.Created || result.Mode != "git-worktree" {
		t.Fatalf("result = %+v, want a created git worktree", result)
	}
	if !isDir(result.Path) {
		t.Fatalf("worktree path %q does not exist", result.Path)
	}
	if !pathExists(filepath.Join(result.Path, GitDirName)) {
		t.Errorf("the worktree has no .git pointer file")
	}

	registration, err := FindRegistration(root, "dev-2")
	if err != nil || registration == nil {
		t.Fatalf("Registration = %+v, %v; want a registration", registration, err)
	}
	if registration.Branch != "project/dev-2" {
		t.Errorf("registered branch = %q, want %q", registration.Branch, "project/dev-2")
	}
	if !branchExists(root, "project/dev-2") {
		t.Errorf("branch project/dev-2 was not created")
	}
}

func TestAddIsIdempotentAndCreatesNoGarbage(t *testing.T) {
	root := newRepo(t)

	first, err := Add(root, "dev-2")
	if err != nil || !first.OK {
		t.Fatalf("first Add = %+v, %v", first, err)
	}
	second, err := Add(root, "dev-2")
	if err != nil {
		t.Fatalf("second Add: %v", err)
	}
	if !second.OK || second.Created || second.Mode != "git-worktree" {
		t.Errorf("second Add = %+v, want an idempotent hit", second)
	}
	if !samePath(second.Path, first.Path) {
		t.Errorf("second path = %q, want %q", second.Path, first.Path)
	}
	if !strings.Contains(second.Reason, "idempotent") {
		t.Errorf("second reason = %q, want it to mention idempotency", second.Reason)
	}

	// Exactly two entries (the main checkout plus one worktree): the second Add
	// must not have registered a duplicate.
	out := assertGit(t, root, "worktree", "list", "--porcelain").output
	if got := strings.Count(out, "worktree "); got != 2 {
		t.Errorf("git worktree count = %d, want 2 (%s)", got, out)
	}
}

func TestAddListRemoveLifecycle(t *testing.T) {
	root := newRepo(t)

	added, err := Add(root, "dev-2")
	if err != nil || !added.OK {
		t.Fatalf("Add = %+v, %v", added, err)
	}

	status := findStatus(t, mustList(t, root), "dev-2")
	if !status.Exists || !status.Registered || status.RegisteredBranch != "project/dev-2" {
		t.Fatalf("status = %+v, want an existing registered worktree", status)
	}

	removed, err := Remove(root, "dev-2", false)
	if err != nil {
		t.Fatalf("Remove: %v", err)
	}
	if !removed.OK || !removed.Removed {
		t.Fatalf("Remove = %+v, want a removal", removed)
	}
	if pathExists(added.Path) {
		t.Errorf("worktree path %q still exists", added.Path)
	}
	if branchExists(root, "project/dev-2") {
		t.Errorf("branch project/dev-2 survived the removal")
	}
	for _, leftover := range mustList(t, root) {
		if leftover.Project == "dev-2" {
			t.Errorf("dev-2 is still listed after removal: %+v", leftover)
		}
	}

	// No registration garbage must stay behind in .git/worktrees.
	out := assertGit(t, root, "worktree", "list", "--porcelain").output
	if strings.Contains(out, ".agents") {
		t.Errorf("worktree registration leak: %s", out)
	}
}

func TestCyrillicSpaceNameRoundTrip(t *testing.T) {
	root := newRepo(t)
	project := "\u041f\u0440\u043e\u0435\u043a\u0442 \u0410"

	result, err := Add(root, project)
	if err != nil || !result.OK || !result.Created {
		t.Fatalf("Add(%q) = %+v, %v", project, result, err)
	}
	wantBranch := "project/\u041f\u0440\u043e\u0435\u043a\u0442%20\u0410"
	if result.Branch != wantBranch {
		t.Errorf("branch = %q, want %q", result.Branch, wantBranch)
	}
	registration, err := FindRegistration(root, project)
	if err != nil || registration == nil {
		t.Fatalf("Registration = %+v, %v", registration, err)
	}
	if registration.Branch != wantBranch {
		t.Errorf("registered branch = %q, want %q", registration.Branch, wantBranch)
	}

	status := findStatus(t, mustList(t, root), project)
	if !status.Registered || status.RegisteredBranch != wantBranch {
		t.Errorf("status = %+v, want the encoded branch", status)
	}

	removed, err := Remove(root, project, false)
	if err != nil || !removed.OK {
		t.Fatalf("Remove(%q) = %+v, %v", project, removed, err)
	}
	if branchExists(root, wantBranch) {
		t.Errorf("branch %q survived the removal", wantBranch)
	}
}

func TestRemoveUnregisteredDirectoryNeedsForce(t *testing.T) {
	root := t.TempDir()
	path, err := WorktreePath(root, "loose")
	if err != nil {
		t.Fatalf("WorktreePath: %v", err)
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	refused, err := Remove(root, "loose", false)
	if err != nil {
		t.Fatalf("Remove without force: %v", err)
	}
	if refused.OK {
		t.Errorf("Remove(force=false) = %+v, want a refusal", refused)
	}
	if !pathExists(path) {
		t.Fatalf("the unregistered directory was deleted without force")
	}

	forced, err := Remove(root, "loose", true)
	if err != nil {
		t.Fatalf("Remove with force: %v", err)
	}
	if !forced.OK || !forced.Removed || pathExists(path) {
		t.Errorf("Remove(force=true) = %+v, want the directory gone", forced)
	}
}

func TestRemoveMissingIsIdempotent(t *testing.T) {
	root := t.TempDir()
	result, err := Remove(root, "ghost", false)
	if err != nil {
		t.Fatalf("Remove: %v", err)
	}
	if !result.OK || result.Removed {
		t.Errorf("Remove(missing) = %+v, want ok without a removal", result)
	}
	if !strings.Contains(result.Reason, "not present") {
		t.Errorf("reason = %q, want it to say the path was absent", result.Reason)
	}
}

func TestAddWithoutGitHeadUsesPlainDirectory(t *testing.T) {
	root := t.TempDir() // not a git repository at all

	result, err := Add(root, "sandbox")
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if !result.OK || !result.Created || result.Mode != "directory" {
		t.Fatalf("result = %+v, want a created plain directory", result)
	}
	if !isDir(result.Path) {
		t.Fatalf("directory %q does not exist", result.Path)
	}

	second, err := Add(root, "sandbox")
	if err != nil {
		t.Fatalf("second Add: %v", err)
	}
	if !second.OK || second.Created || second.Mode != "directory" {
		t.Errorf("second Add = %+v, want an idempotent directory hit", second)
	}
}

func TestAddRejectsInvalidNames(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"", "   ", "../evil", "a/b", "con", strings.Repeat("a", MaxNameLength+1)} {
		if _, err := Add(root, name); err == nil {
			t.Errorf("Add(%q) = nil error, want a rejection", name)
		}
	}
}

func TestGetRejectsInvalidName(t *testing.T) {
	if _, err := Get(t.TempDir(), "../evil"); err == nil {
		t.Error("Get(traversal) = nil error, want a rejection")
	}
}

func TestListReportsInvalidDirectoryWithoutAborting(t *testing.T) {
	root := t.TempDir()
	broken := filepath.Join(WorktreesDir(root), "bad.name")
	if err := os.MkdirAll(broken, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(WorktreesDir(root), "good"), 0o755); err != nil {
		t.Fatalf("mkdir good: %v", err)
	}

	statuses, err := List(root)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if statuses[0].Project != "bad.name" || statuses[0].Error == "" {
		t.Errorf("first entry = %+v, want the invalid name reported with an error", statuses[0])
	}
	if good := findStatus(t, statuses, "good"); good.Error != "" || !good.Exists {
		t.Errorf("good = %+v, want a valid entry", good)
	}
}

// TestRunGitCapturesStderrOnSuccess is the Go counterpart of the PowerShell
// BUG-025 trap: `git worktree add` writes progress to stderr even when it
// succeeds, so a non-empty captured stream must not be treated as a failure.
func TestRunGitCapturesStderrOnSuccess(t *testing.T) {
	root := newRepo(t)
	path, err := WorktreePath(root, "probe")
	if err != nil {
		t.Fatalf("WorktreePath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	result, err := runGit(root, "worktree", "add", "-b", "project/probe", path)
	if err != nil {
		t.Fatalf("runGit: %v", err)
	}
	if result.exitCode != 0 {
		t.Fatalf("exit = %d, output = %s; want success", result.exitCode, result.output)
	}
	// Success with a non-empty stream proves the stderr progress was captured
	// into the result instead of becoming an error.
	if result.output == "" {
		t.Errorf("captured output is empty, want git's stderr progress on success")
	}
}

func mustList(t *testing.T, root string) []Status {
	t.Helper()
	statuses, err := List(root)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	return statuses
}
