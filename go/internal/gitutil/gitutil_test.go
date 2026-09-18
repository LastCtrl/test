package gitutil

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// TestGitHelperProcess is not a real test: when the test binary is re-executed
// as a stand-in for git (GitBin = os.Args[0]) with GITUTIL_HELPER_MODE set, it
// emits a deterministic stream/exit combination and exits immediately. This
// makes the "stderr on success", "non-zero exit" and "timeout" cases exact
// instead of depending on the installed git version's chatter.
func TestGitHelperProcess(t *testing.T) {
	mode := os.Getenv("GITUTIL_HELPER_MODE")
	if mode == "" {
		t.Skip("helper process only")
	}
	switch mode {
	case "stderr-ok":
		fmt.Fprint(os.Stdout, "done\n")
		fmt.Fprint(os.Stderr, "Preparing worktree (new branch 'x')\n")
		os.Exit(0)
	case "fail":
		fmt.Fprint(os.Stdout, "partial\n")
		fmt.Fprint(os.Stderr, "fatal: not a git repository\n")
		os.Exit(3)
	case "sleep":
		time.Sleep(30 * time.Second)
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "unknown helper mode %q\n", mode)
		os.Exit(2)
	}
}

func helperEnv(mode string) []string {
	return append(os.Environ(), "GITUTIL_HELPER_MODE="+mode)
}

// --- core Run contract ------------------------------------------------------

func TestRunSuccessWithStderrIsNotAnError(t *testing.T) {
	c := &Client{GitBin: os.Args[0], Timeout: 20 * time.Second, Env: helperEnv("stderr-ok")}
	stdout, stderr, code := c.Run(context.Background(), "-test.run=TestGitHelperProcess")
	if code != 0 {
		t.Fatalf("exit = %d, want 0: a non-empty stderr with exit 0 must be a success", code)
	}
	if !strings.Contains(stdout, "done") {
		t.Errorf("stdout = %q, want the success marker", stdout)
	}
	if !strings.Contains(stderr, "Preparing worktree") {
		t.Errorf("stderr = %q, want success-time noise captured", stderr)
	}
}

func TestRunNonZeroExitReturnsCode(t *testing.T) {
	c := &Client{GitBin: os.Args[0], Timeout: 20 * time.Second, Env: helperEnv("fail")}
	stdout, stderr, code := c.Run(context.Background(), "-test.run=TestGitHelperProcess")
	if code != 3 {
		t.Fatalf("exit = %d, want 3", code)
	}
	if !strings.Contains(stdout, "partial") {
		t.Errorf("stdout = %q, want partial output preserved", stdout)
	}
	if !strings.Contains(stderr, "fatal") {
		t.Errorf("stderr = %q, want the diagnostic", stderr)
	}
}

func TestRunTimeout(t *testing.T) {
	c := &Client{GitBin: os.Args[0], Timeout: 300 * time.Millisecond, Env: helperEnv("sleep")}
	start := time.Now()
	_, stderr, code := c.Run(context.Background(), "-test.run=TestGitHelperProcess")
	elapsed := time.Since(start)
	if code != ExitNotStarted {
		t.Fatalf("exit = %d, want ExitNotStarted (%d)", code, ExitNotStarted)
	}
	if !strings.Contains(stderr, "deadline") {
		t.Errorf("stderr = %q, want a deadline note", stderr)
	}
	if elapsed > 10*time.Second {
		t.Errorf("the timed-out call took %s, want it to return promptly", elapsed)
	}
}

func TestRunCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	c := &Client{GitBin: os.Args[0], Env: helperEnv("sleep")}
	_, stderr, code := c.Run(ctx, "-test.run=TestGitHelperProcess")
	if code != ExitNotStarted {
		t.Fatalf("exit = %d, want ExitNotStarted", code)
	}
	if !strings.Contains(stderr, "canceled") {
		t.Errorf("stderr = %q, want a cancellation note", stderr)
	}
}

func TestRunRejectsUnsafeInput(t *testing.T) {
	c := &Client{GitBin: os.Args[0], Env: helperEnv("stderr-ok")}
	if _, stderr, code := c.Run(context.Background()); code != ExitNotStarted || !strings.Contains(stderr, "empty argument") {
		t.Errorf("Run() = code %d, stderr %q; want ExitNotStarted with an empty-argument note", code, stderr)
	}
	if _, stderr, code := c.Run(context.Background(), "arg\x00with-nul"); code != ExitNotStarted || !strings.Contains(stderr, "NUL") {
		t.Errorf("Run(NUL) = code %d, stderr %q; want ExitNotStarted with a NUL note", code, stderr)
	}
}

func TestPackageRunReturnsExitCode(t *testing.T) {
	out, _, code := Run(context.Background(), "--version")
	if code != 0 || !strings.Contains(out, "git version") {
		t.Fatalf("Run(--version) = %q, exit %d; want a git version line", out, code)
	}
}

// --- wrapper contract -------------------------------------------------------

func TestNonRepo(t *testing.T) {
	c := New(t.TempDir())
	ctx := context.Background()

	if c.IsRepo(ctx) {
		t.Error("IsRepo = true outside a repository")
	}
	if _, err := c.WorktreeList(ctx); err == nil {
		t.Error("WorktreeList outside a repository: want an error")
	}
	if c.BranchExists(ctx, "main") {
		t.Error("BranchExists outside a repository: want false")
	}
	if _, err := c.RevParse(ctx, "HEAD"); err == nil {
		t.Error("RevParse outside a repository: want an error")
	}
	if err := c.WorktreeRemove(ctx, filepath.Join(c.Dir, "x"), true); err == nil {
		t.Error("WorktreeRemove outside a repository: want an error")
	}
}

func TestWorktreeLifecycle(t *testing.T) {
	dir := initRepo(t)
	c := New(dir)
	ctx := context.Background()

	if !c.IsRepo(ctx) {
		t.Fatal("IsRepo = false in a fresh repository")
	}
	head, err := c.RevParse(ctx, "HEAD")
	if err != nil {
		t.Fatalf("RevParse(HEAD): %v", err)
	}
	if len(head) < 7 {
		t.Fatalf("RevParse(HEAD) = %q, want a SHA", head)
	}

	wt := filepath.Join(dir, "wt")
	// BUG-025 regression: real git prints progress on stderr on SUCCESS, so an
	// implementation that treats stderr as a failure fails on this call.
	if err := c.WorktreeAdd(ctx, wt, "feature-x", true); err != nil {
		t.Fatalf("WorktreeAdd on a successful run returned an error (stderr trap): %v", err)
	}
	if !c.BranchExists(ctx, "feature-x") {
		t.Error("BranchExists(feature-x) = false after WorktreeAdd -b")
	}

	list, err := c.WorktreeList(ctx)
	if err != nil {
		t.Fatalf("WorktreeList: %v", err)
	}
	if !containsWorktree(list, wt, "feature-x") {
		t.Fatalf("WorktreeList = %+v, want the new worktree %q on feature-x", list, wt)
	}

	if err := c.WorktreeRemove(ctx, wt, true); err != nil {
		t.Fatalf("WorktreeRemove: %v", err)
	}
	list, err = c.WorktreeList(ctx)
	if err != nil {
		t.Fatalf("WorktreeList after remove: %v", err)
	}
	if containsWorktree(list, wt, "") {
		t.Errorf("worktree %q is still listed after removal: %+v", wt, list)
	}
}

func TestWorktreeAddFailureReturnsError(t *testing.T) {
	dir := initRepo(t)
	c := New(dir)
	ctx := context.Background()

	wt1 := filepath.Join(dir, "wt-1")
	if err := c.WorktreeAdd(ctx, wt1, "shared", true); err != nil {
		t.Fatalf("first WorktreeAdd: %v", err)
	}
	// A branch already checked out elsewhere is a git failure (exit != 0).
	err := c.WorktreeAdd(ctx, filepath.Join(dir, "wt-2"), "shared", false)
	if err == nil {
		t.Fatal("second WorktreeAdd on an already checked-out branch unexpectedly succeeded")
	}
	if !strings.Contains(err.Error(), "exit") {
		t.Errorf("error = %v, want it to mention the git exit code", err)
	}
}

func TestCyrillicWorktreePath(t *testing.T) {
	base := t.TempDir()
	repo := filepath.Join(base, "\u0440\u0435\u043f\u043e") // Cyrillic "repo"
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatalf("mkdir Cyrillic repository dir: %v", err)
	}
	initRepoAt(t, repo)
	c := New(repo)
	ctx := context.Background()

	wt := filepath.Join(repo, "\u0432\u0435\u0442\u043a\u0430") // Cyrillic "branch"
	if err := c.WorktreeAdd(ctx, wt, "cyr-branch", true); err != nil {
		t.Fatalf("WorktreeAdd with a Cyrillic path: %v", err)
	}

	list, err := c.WorktreeList(ctx)
	if err != nil {
		t.Fatalf("WorktreeList: %v", err)
	}
	if !containsWorktree(list, wt, "cyr-branch") {
		t.Fatalf("WorktreeList = %+v, want the Cyrillic worktree %q decoded correctly", list, wt)
	}

	head, err := c.RevParse(ctx, "HEAD")
	if err != nil || len(head) < 7 {
		t.Fatalf("RevParse in a Cyrillic repository path = %q, %v", head, err)
	}
}

func TestRevParseValidation(t *testing.T) {
	c := New(initRepo(t))
	ctx := context.Background()
	if _, err := c.RevParse(ctx, "   "); err == nil {
		t.Error("RevParse(blank) = nil error, want an error")
	}
	if _, err := c.RevParse(ctx, "--upload-pack=evil"); err == nil {
		t.Error("RevParse(option-like) = nil error, want an error")
	}
	if _, err := c.RevParse(ctx, "no-such-rev"); err == nil {
		t.Error("RevParse(missing rev) = nil error, want an error")
	}
}

func TestWorktreeValidation(t *testing.T) {
	c := New(t.TempDir())
	ctx := context.Background()
	if err := c.WorktreeAdd(ctx, " ", "b", true); err == nil {
		t.Error("WorktreeAdd(empty path) = nil error")
	}
	if err := c.WorktreeAdd(ctx, "p", " ", true); err == nil {
		t.Error("WorktreeAdd(empty branch) = nil error")
	}
	if err := c.WorktreeRemove(ctx, " ", true); err == nil {
		t.Error("WorktreeRemove(empty path) = nil error")
	}
}

// --- output safety ----------------------------------------------------------

func TestSanitizeRedactsURLCredentials(t *testing.T) {
	secret := "sup3r-" + "s3cret-value"
	text := "Cloning https://builder:" + secret + "@example.invalid/repo.git failed"
	got := sanitize(text)
	if strings.Contains(got, secret) {
		t.Fatalf("sanitize left the credential in place: %q", got)
	}
	if !strings.Contains(got, "***@") {
		t.Errorf("sanitize = %q, want the userinfo replaced", got)
	}
}

func TestTruncateKeepsValidUTF8(t *testing.T) {
	value := strings.Repeat("\u043f", 60) // 120 bytes of two-byte runes
	got := truncate(value, 7)
	if !utf8.ValidString(got) {
		t.Fatalf("truncate = %q, not valid UTF-8", got)
	}
	if !strings.HasSuffix(got, "[truncated]") {
		t.Errorf("truncate = %q, want the truncated marker", got)
	}
}

// --- helpers ----------------------------------------------------------------

func initRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	initRepoAt(t, dir)
	return dir
}

func initRepoAt(t *testing.T, dir string) {
	t.Helper()
	runGit(t, dir, "init", "-q")
	runGit(t, dir, "config", "user.email", "gitutil@example.invalid")
	runGit(t, dir, "config", "user.name", "gitutil test")
	runGit(t, dir, "config", "commit.gpgsign", "false")
	runGit(t, dir, "config", "core.autocrlf", "false")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello\n"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	runGit(t, dir, "add", "a.txt")
	runGit(t, dir, "commit", "-q", "-m", "init")
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	c := &Client{Dir: dir, Timeout: 20 * time.Second}
	_, stderr, code := c.Run(context.Background(), args...)
	if code != 0 {
		t.Fatalf("git %s failed (exit %d): %s", strings.Join(args, " "), code, stderr)
	}
}

func containsWorktree(list []Worktree, path, branch string) bool {
	for _, w := range list {
		if samePath(w.Path, path) && (branch == "" || w.Branch == branch) {
			return true
		}
	}
	return false
}

func samePath(a, b string) bool {
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}
