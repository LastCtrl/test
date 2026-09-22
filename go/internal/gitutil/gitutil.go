// Package gitutil is the safe git invocation layer of the agent-hq control
// plane (Go phase, M4 support).
//
// The single hard rule this package exists for: a non-empty stderr is NOT a
// failure. Git writes routine progress to stderr even on success - for example
// `git worktree add` prints "Preparing worktree (new branch 'x')" - and on
// PowerShell 5.1 a caller running with $ErrorActionPreference='Stop' turns that
// into a bogus NativeCommandError (BUG-025: a successful worktree registration
// was reported as "git worktree add failed"). Here success is decided ONLY by
// the process exit code, so the same trap cannot reappear on the Go side.
//
// Design constraints:
//   - no third-party dependency and no shell: os/exec with an argument vector,
//     so no quoting/word-splitting issues (Cyrillic paths included);
//   - every call is bounded by a context and by Client.Timeout;
//   - interactive credential prompts are disabled, so git can never block a run
//     waiting on stdin that will not come;
//   - output that ends up in an error is sanitised and truncated, so a
//     credential embedded in a remote URL can never leak into a log/message.
package gitutil

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// ExitNotStarted is returned when the git process could not be launched at
	// all, or when the context terminated it before it exited on its own
	// (timeout or cancellation). A real git exit code is always >= 0, so a
	// caller can tell "git ran and failed" from "git never ran".
	ExitNotStarted = -1

	// DefaultTimeout bounds a single git invocation when Client.Timeout is not
	// set. Plumbing commands (rev-parse, worktree list) finish in milliseconds;
	// the ceiling only guards against a hung process.
	DefaultTimeout = 30 * time.Second

	// defaultMaxOutputBytes caps how much of one stream is retained per call.
	// A plumbing helper never needs more, and the cap keeps a runaway command
	// from exhausting memory.
	defaultMaxOutputBytes = 1 << 20 // 1 MiB

	// waitDelay is how long the runtime waits for the streams to drain after
	// the process is killed or exits, protecting against a grandchild that
	// keeps the pipe open and would otherwise hang the call.
	waitDelay = 3 * time.Second

	// maxErrorDetailBytes caps the diagnostic text folded into an error.
	maxErrorDetailBytes = 500
)

// urlCredentials matches the userinfo part of a URL, e.g. an https remote with
// "user:credential@host". The scheme is matched generically so no concrete
// credential-shaped literal has to appear in this source.
var urlCredentials = regexp.MustCompile(`(?i)([a-z][a-z0-9+.\-]*://)[^/@\s]+@`)

// Client runs git commands against one repository directory. The zero value is
// usable: it resolves the git binary from PATH, inherits the process
// environment and applies DefaultTimeout.
type Client struct {
	// Dir is the working directory for every command (a repository checkout or
	// worktree). Empty means the current process directory.
	Dir string
	// GitBin overrides the git executable (absolute path or command name).
	// Empty means "git" resolved from PATH.
	GitBin string
	// Timeout bounds one invocation. Zero or negative means DefaultTimeout.
	// An earlier deadline already present on the context always wins.
	Timeout time.Duration
	// MaxOutputBytes caps each retained stream (stdout and stderr separately).
	// Zero or negative means defaultMaxOutputBytes.
	MaxOutputBytes int
	// Env overrides the process environment for spawned commands. Nil means
	// os.Environ(). A few safety variables are always enforced afterwards:
	// GIT_TERMINAL_PROMPT=0 and GCM_INTERACTIVE=never (never prompt) and
	// LC_ALL=C (stable, parseable English diagnostics).
	Env []string
}

// New returns a Client whose git commands run in dir.
func New(dir string) *Client { return &Client{Dir: dir} }

// Run executes `git args...` and returns stdout, stderr and the exit code.
//
// A non-empty stderr with exit code 0 is a SUCCESS: git's progress and warning
// chatter are not failures. Only the exit code decides. A missing git binary,
// a bad argument vector or a context deadline/cancellation is reported as
// ExitNotStarted with a diagnostic on stderr.
//
// Run never returns an error by design - the raw layer must not impose a
// failure policy. Wrappers translate a non-zero code into an error.
func (c *Client) Run(ctx context.Context, args ...string) (string, string, int) {
	if c == nil {
		return "", "gitutil: nil client", ExitNotStarted
	}
	// Defensive: a nil context is not a reason to panic or to run unbounded.
	if ctx == nil {
		ctx = context.Background()
	}
	// Defensive: a bare `git` with no subcommand could open help/a pager, so
	// refuse an empty argument vector instead of invoking it.
	if len(args) == 0 {
		return "", "gitutil: empty argument vector", ExitNotStarted
	}
	for _, arg := range args {
		if strings.IndexByte(arg, 0) >= 0 {
			return "", "gitutil: NUL byte in argument", ExitNotStarted
		}
	}

	binary := c.GitBin
	if binary == "" {
		binary = "git"
	}

	runCtx, cancel := c.callContext(ctx)
	defer cancel()

	cmd := exec.CommandContext(runCtx, binary, args...)
	if c.Dir != "" {
		cmd.Dir = c.Dir
	}
	cmd.Env = c.environ()
	// Never inherit an interactive stdin: git must fail rather than block on a
	// credential prompt.
	cmd.Stdin = nil
	stdout := &cappedBuffer{limit: c.outputLimit()}
	stderr := &cappedBuffer{limit: c.outputLimit()}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.WaitDelay = waitDelay

	err := cmd.Run()

	// The context ending first means the process was killed by us, not by git.
	if ctxErr := runCtx.Err(); ctxErr != nil {
		return stdout.String(), withNote(stderr.String(), "gitutil: "+ctxErr.Error()), ExitNotStarted
	}
	if err == nil {
		return stdout.String(), stderr.String(), 0
	}

	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code := exitErr.ExitCode()
		if code < 0 {
			// Killed by a signal without our context being done: still not a
			// real git exit status.
			return stdout.String(), stderr.String(), ExitNotStarted
		}
		return stdout.String(), stderr.String(), code
	}
	// Start failure (binary missing, permission denied, ...).
	return stdout.String(), withNote(stderr.String(), "gitutil: "+err.Error()), ExitNotStarted
}

// IsRepo reports whether Dir is inside a git work tree.
func (c *Client) IsRepo(ctx context.Context) bool {
	out, _, code := c.Run(ctx, "--no-pager", "rev-parse", "--is-inside-work-tree")
	return code == 0 && strings.TrimSpace(out) == "true"
}

// RevParse resolves rev to an object id (full SHA for a commit). It returns an
// error when rev is empty, looks like an option, or does not resolve.
func (c *Client) RevParse(ctx context.Context, rev string) (string, error) {
	rev = strings.TrimSpace(rev)
	if rev == "" {
		return "", errors.New("gitutil: revision is empty")
	}
	// A revision that starts with '-' would be read as an option; refusing it
	// keeps a caller-supplied value from injecting flags.
	if strings.HasPrefix(rev, "-") {
		return "", fmt.Errorf("gitutil: refusing revision %q: leading '-' looks like an option", rev)
	}
	args := []string{"--no-pager", "rev-parse", "--verify", "--quiet", rev}
	out, errOut, code := c.Run(ctx, args...)
	if code != 0 {
		return "", commandError(args, code, errOut)
	}
	return strings.TrimSpace(out), nil
}

// Worktree is one entry of `git worktree list --porcelain`.
type Worktree struct {
	// Path is the worktree directory in OS-native form (git reports forward
	// slashes; they are converted with filepath.FromSlash).
	Path string
	// HEAD is the checked-out object id, empty for a bare entry.
	HEAD string
	// Branch is the short branch name, empty when detached or bare.
	Branch string
	// Bare and Detached mirror the porcelain flags.
	Bare     bool
	Detached bool
}

// WorktreeList returns every worktree registered in the repository.
func (c *Client) WorktreeList(ctx context.Context) ([]Worktree, error) {
	args := []string{"--no-pager", "worktree", "list", "--porcelain"}
	out, errOut, code := c.Run(ctx, args...)
	if code != 0 {
		return nil, commandError(args, code, errOut)
	}
	return parseWorktreePorcelain(out), nil
}

// WorktreeAdd registers a worktree of the repository at path. When create is
// true a new branch named branch is created and checked out (git -b); when it is
// false branch must already exist and is checked out into the worktree.
func (c *Client) WorktreeAdd(ctx context.Context, path, branch string, create bool) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("gitutil: worktree path is empty")
	}
	if strings.TrimSpace(branch) == "" {
		return errors.New("gitutil: worktree branch is empty")
	}
	args := []string{"--no-pager", "worktree", "add"}
	if create {
		args = append(args, "-b", branch, path)
	} else {
		args = append(args, path, branch)
	}
	_, errOut, code := c.Run(ctx, args...)
	if code != 0 {
		return commandError(args, code, errOut)
	}
	return nil
}

// WorktreeRemove removes the worktree at path. force adds --force, which also
// discards local modifications and removes a locked worktree.
func (c *Client) WorktreeRemove(ctx context.Context, path string, force bool) error {
	if strings.TrimSpace(path) == "" {
		return errors.New("gitutil: worktree path is empty")
	}
	args := []string{"--no-pager", "worktree", "remove"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, path)
	_, errOut, code := c.Run(ctx, args...)
	if code != 0 {
		return commandError(args, code, errOut)
	}
	return nil
}

// BranchExists reports whether a local branch named branch exists. A malformed
// name simply does not exist; the function never panics.
func (c *Client) BranchExists(ctx context.Context, branch string) bool {
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return false
	}
	_, _, code := c.Run(ctx, "--no-pager", "show-ref", "--verify", "--quiet", "refs/heads/"+branch)
	return code == 0
}

// Run is the package-level form of (*Client).Run with the current directory as
// the working directory. Prefer a Client when the repository is known.
func Run(ctx context.Context, args ...string) (string, string, int) {
	return (&Client{}).Run(ctx, args...)
}

// callContext derives the per-call context: an existing deadline on the parent
// is never extended, otherwise Client.Timeout (or DefaultTimeout) is applied.
func (c *Client) callContext(ctx context.Context) (context.Context, context.CancelFunc) {
	timeout := c.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) <= timeout {
		return context.WithCancel(ctx)
	}
	return context.WithTimeout(ctx, timeout)
}

// environ returns the environment for a spawned command with the safety
// variables enforced; any caller-supplied value for those names is dropped so
// the Windows environment block has no duplicate keys.
func (c *Client) environ() []string {
	base := c.Env
	if base == nil {
		base = os.Environ()
	}
	out := make([]string, 0, len(base)+3)
	for _, kv := range base {
		name, _, _ := strings.Cut(kv, "=")
		switch strings.ToUpper(name) {
		case "GIT_TERMINAL_PROMPT", "GCM_INTERACTIVE", "LC_ALL":
			continue
		default:
			out = append(out, kv)
		}
	}
	out = append(out,
		"GIT_TERMINAL_PROMPT=0",
		"GCM_INTERACTIVE=never",
		"LC_ALL=C",
	)
	return out
}

func (c *Client) outputLimit() int {
	if c.MaxOutputBytes > 0 {
		return c.MaxOutputBytes
	}
	return defaultMaxOutputBytes
}

// commandError builds a non-zero-exit error from sanitised diagnostics.
func commandError(args []string, code int, stderr string) error {
	detail := sanitize(stderr)
	if detail == "" {
		if code == ExitNotStarted {
			detail = "git could not be started"
		} else {
			detail = "git produced no diagnostic output"
		}
	}
	return fmt.Errorf("gitutil: git %s failed (exit %d): %s", sanitize(formatArgs(args)), code, detail)
}

// formatArgs renders an argument vector for a message, dropping the pager flag
// that only adds noise.
func formatArgs(args []string) string {
	parts := make([]string, 0, len(args))
	for _, arg := range args {
		if arg == "--no-pager" {
			continue
		}
		parts = append(parts, arg)
	}
	return strings.Join(parts, " ")
}

// sanitize strips URL credentials from diagnostic text and truncates it on a
// rune boundary. Git does not print environment variables, so a credential in a
// remote URL is the realistic leak vector.
func sanitize(text string) string {
	text = strings.TrimSpace(text)
	text = urlCredentials.ReplaceAllString(text, "${1}***@")
	return truncate(text, maxErrorDetailBytes)
}

// truncate caps s at max bytes without splitting a multi-byte rune, so a
// Cyrillic path can never become invalid UTF-8 in a message.
func truncate(s string, max int) string {
	if max <= 0 || len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "...[truncated]"
}

// withNote appends a diagnostic line to captured stderr, preserving whatever
// partial output the process produced before it was killed.
func withNote(stderr, note string) string {
	if strings.TrimSpace(stderr) == "" {
		return note
	}
	return strings.TrimRight(stderr, "\r\n") + "\n" + note
}

// parseWorktreePorcelain parses `git worktree list --porcelain`: blank-line
// separated records with `worktree <path>`, `HEAD <sha>` and either
// `branch refs/heads/<name>`, `detached` or `bare`.
func parseWorktreePorcelain(out string) []Worktree {
	var list []Worktree
	var current *Worktree

	flush := func() {
		if current != nil {
			current.Path = filepath.FromSlash(current.Path)
			list = append(list, *current)
			current = nil
		}
	}

	scanner := bufio.NewScanner(strings.NewReader(out))
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		switch {
		case line == "":
			flush()
		case strings.HasPrefix(line, "worktree "):
			flush()
			current = &Worktree{Path: strings.TrimSpace(strings.TrimPrefix(line, "worktree "))}
		case current == nil:
			// Attribute line before any worktree header: ignore.
		case strings.HasPrefix(line, "HEAD "):
			current.HEAD = strings.TrimSpace(strings.TrimPrefix(line, "HEAD "))
		case strings.HasPrefix(line, "branch "):
			ref := strings.TrimSpace(strings.TrimPrefix(line, "branch "))
			current.Branch = strings.TrimPrefix(ref, "refs/heads/")
		case line == "bare":
			current.Bare = true
		case line == "detached":
			current.Detached = true
		}
	}
	flush()
	return list
}

// cappedBuffer is an io.Writer that keeps at most limit bytes and records that
// truncation happened. It always reports a full write to the runtime, so a
// chatty process is never blocked by a full pipe and never sees a short write.
type cappedBuffer struct {
	buf       bytes.Buffer
	limit     int
	truncated bool
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if b.limit <= 0 {
		return b.buf.Write(p)
	}
	remaining := b.limit - b.buf.Len()
	if remaining <= 0 {
		b.truncated = true
		return len(p), nil
	}
	if len(p) > remaining {
		if _, err := b.buf.Write(p[:remaining]); err != nil {
			return 0, err
		}
		b.truncated = true
		return len(p), nil
	}
	return b.buf.Write(p)
}

func (b *cappedBuffer) String() string {
	if b.truncated {
		return b.buf.String() + "\n[gitutil: output truncated at " + strconv.Itoa(b.limit) + " bytes]"
	}
	return b.buf.String()
}
