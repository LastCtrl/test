package worktree

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// gitResult is the outcome of one git invocation. Success is decided by the
// exit code alone: git writes progress ("Preparing worktree ...") to stderr
// even on success, so a non-empty output must never be treated as a failure.
// This is the Go counterpart of the PowerShell BUG-025 trap, where
// $ErrorActionPreference='Stop' turned git's stderr into a terminating error on
// a successful `git worktree add`.
type gitResult struct {
	output   string
	exitCode int
}

// gitBinary resolves the git executable. It is called per invocation so a
// missing git is reported as a normal error instead of a panic.
func gitBinary() (string, error) {
	path, err := exec.LookPath("git")
	if err != nil {
		return "", errors.New("git executable not found in PATH")
	}
	return path, nil
}

// runGit runs `git -C root args...` and captures stdout and stderr into a
// single stream. A non-zero exit code is returned inside the result, not as a
// Go error; the error is reserved for "git could not be started at all".
// GIT_TERMINAL_PROMPT=0 keeps a credential prompt from hanging the CLI.
func runGit(root string, args ...string) (gitResult, error) {
	binary, err := gitBinary()
	if err != nil {
		return gitResult{exitCode: -1}, err
	}

	full := make([]string, 0, len(args)+2)
	full = append(full, "-C", root)
	full = append(full, args...)

	command := exec.Command(binary, full...)
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")

	var buffer bytes.Buffer
	command.Stdout = &buffer
	command.Stderr = &buffer

	runErr := command.Run()
	if runErr == nil {
		return gitResult{output: buffer.String(), exitCode: 0}, nil
	}

	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) {
		return gitResult{output: buffer.String(), exitCode: exitErr.ExitCode()}, nil
	}
	return gitResult{output: buffer.String(), exitCode: -1}, runErr
}

// isGitRepo reports whether root is inside a git working tree.
func isGitRepo(root string) bool {
	result, err := runGit(root, "rev-parse", "--is-inside-work-tree")
	return err == nil && result.exitCode == 0 && strings.TrimSpace(result.output) == "true"
}

// hasHead reports whether the repository has at least one commit. A worktree
// cannot be created from an empty repository.
func hasHead(root string) bool {
	result, err := runGit(root, "rev-parse", "--verify", "--quiet", "HEAD")
	return err == nil && result.exitCode == 0
}

// branchExists reports whether refs/heads/<branch> already exists.
func branchExists(root, branch string) bool {
	result, err := runGit(root, "show-ref", "--verify", "--quiet", "refs/heads/"+branch)
	return err == nil && result.exitCode == 0
}

// gitMessage turns an unsuccessful gitResult into a single-line explanation.
func gitMessage(result gitResult) string {
	message := strings.Join(strings.Fields(result.output), " ")
	if message == "" {
		return fmt.Sprintf("exit code %d", result.exitCode)
	}
	return message
}
