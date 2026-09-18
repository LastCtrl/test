package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Status describes one project worktree. The JSON field names match the output
// of Get-ProjectWorktree in project-worktree.ps1, so both tooling layers can
// consume the same documents.
type Status struct {
	Project          string `json:"project"`
	Path             string `json:"path"`
	Branch           string `json:"branch"`
	Exists           bool   `json:"exists"`
	Registered       bool   `json:"registered"`
	RegisteredBranch string `json:"registered_branch"`
	Error            string `json:"error,omitempty"`
}

// Registration is the filesystem-derived link between a worktree directory and
// the repository that owns it.
type Registration struct {
	GitDir string
	Branch string
}

// AddResult mirrors the output of New-ProjectWorktree.
type AddResult struct {
	Project string `json:"project"`
	Path    string `json:"path"`
	Branch  string `json:"branch"`
	Mode    string `json:"mode"`
	Created bool   `json:"created"`
	OK      bool   `json:"ok"`
	Reason  string `json:"reason"`
}

// RemoveResult mirrors the output of Remove-ProjectWorktree.
type RemoveResult struct {
	Project string `json:"project"`
	Path    string `json:"path"`
	Branch  string `json:"branch"`
	Removed bool   `json:"removed"`
	OK      bool   `json:"ok"`
	Reason  string `json:"reason"`
}

// Get returns the worktree status of a project.
func Get(root, project string) (Status, error) {
	path, err := WorktreePath(root, project)
	if err != nil {
		return Status{}, err
	}

	status := Status{Project: project, Path: path, Branch: Branch(project), Exists: isDir(path)}
	if status.Exists {
		if registration, err := FindRegistration(root, project); err == nil && registration != nil {
			status.Registered = true
			status.RegisteredBranch = registration.Branch
		}
	}
	return status, nil
}

// Registration reads the worktree registration straight from the filesystem:
//
//	<worktree>/.git  -> "gitdir: <repo>/.git/worktrees/<id>"
//	<id>/HEAD        -> "ref: refs/heads/<branch>"
//
// Both files are raw UTF-8, so a Cyrillic branch survives. Parsing the stdout
// of `git worktree list` is avoided on purpose (project-worktree.ps1 documents
// the mojibake trap: PowerShell 5.1 decodes native output with the console code
// page). Returns nil when the directory is not a registered worktree of this
// repository.
func FindRegistration(root, project string) (*Registration, error) {
	path, err := WorktreePath(root, project)
	if err != nil {
		return nil, err
	}
	if !isDir(path) {
		return nil, nil
	}

	registration, err := readRegistration(path)
	if err != nil || registration == nil {
		return registration, err
	}
	// It must be a worktree of THIS repository, not of some other checkout.
	if !isWithin(gitWorktreesDir(root), registration.GitDir) {
		return nil, nil
	}
	return registration, nil
}

func readRegistration(worktreePath string) (*Registration, error) {
	pointerFile := filepath.Join(worktreePath, GitDirName)
	info, err := os.Stat(pointerFile)
	if err != nil || info.IsDir() {
		// A missing or directory .git means "plain directory", not an error.
		return nil, nil
	}

	raw, err := os.ReadFile(pointerFile)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", pointerFile, err)
	}
	pointer := strings.TrimSpace(strings.TrimPrefix(string(raw), "\ufeff"))
	const prefix = "gitdir:"
	if !strings.HasPrefix(pointer, prefix) {
		return nil, nil
	}

	gitDir := strings.TrimSpace(pointer[len(prefix):])
	if gitDir == "" {
		return nil, nil
	}
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(worktreePath, gitDir)
	}
	if !isDir(gitDir) {
		return nil, nil
	}

	registration := &Registration{GitDir: filepath.Clean(gitDir)}
	if headRaw, err := os.ReadFile(filepath.Join(gitDir, "HEAD")); err == nil {
		head := strings.TrimSpace(string(headRaw))
		const refPrefix = "ref: refs/heads/"
		if strings.HasPrefix(head, refPrefix) {
			registration.Branch = strings.TrimSpace(strings.TrimPrefix(head, refPrefix))
		}
	}
	return registration, nil
}

// List returns the status of every project. The union of projects/ and
// .agents/worktrees/ is reported, sorted by project name, so a worktree is
// visible even when its project directory has not been created yet. A name
// that is not a valid project identifier is reported with its error instead of
// aborting the whole listing.
func List(root string) ([]Status, error) {
	names := make(map[string]struct{})
	for _, dir := range []string{ProjectsDir(root), WorktreesDir(root)} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("cannot list %s: %w", dir, err)
		}
		for _, entry := range entries {
			if entry.IsDir() {
				names[entry.Name()] = struct{}{}
			}
		}
	}

	sorted := make([]string, 0, len(names))
	for name := range names {
		sorted = append(sorted, name)
	}
	sort.Strings(sorted)

	statuses := make([]Status, 0, len(sorted))
	for _, name := range sorted {
		status, err := Get(root, name)
		if err != nil {
			statuses = append(statuses, Status{Project: name, Error: err.Error()})
			continue
		}
		statuses = append(statuses, status)
	}
	return statuses, nil
}

// Add creates the worktree of a project idempotently. Modes:
//
//   - "git-worktree": a registered worktree on the project branch already
//     exists, or `git worktree add` just created it;
//   - "directory": the repository has no HEAD (or git add failed) and a plain
//     directory is used instead, or such a directory already existed.
//
// An existing worktree on a DIFFERENT branch is refused, never overwritten.
func Add(root, project string) (AddResult, error) {
	path, err := WorktreePath(root, project)
	if err != nil {
		return AddResult{}, err
	}
	branch := Branch(project)
	result := AddResult{Project: project, Path: path, Branch: branch}

	if isDir(path) {
		registration, regErr := FindRegistration(root, project)
		if regErr == nil && registration != nil {
			if strings.EqualFold(registration.Branch, branch) {
				result.Mode = "git-worktree"
				result.OK = true
				result.Reason = fmt.Sprintf("already exists for branch %q (idempotent)", branch)
			} else {
				result.Reason = fmt.Sprintf("path %q is a worktree of branch %q, not %q", path, registration.Branch, branch)
			}
			return result, nil
		}
		result.Mode = "directory"
		result.OK = true
		result.Reason = "directory already exists (idempotent, not a registered git worktree)"
		return result, nil
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		result.Reason = fmt.Sprintf("failed to create worktree parent: %v", err)
		return result, nil
	}

	if isGitRepo(root) && hasHead(root) {
		args := []string{"worktree", "add", "-b", branch, path}
		if branchExists(root, branch) {
			args = []string{"worktree", "add", path, branch}
		}
		run, runErr := runGit(root, args...)
		if runErr == nil && run.exitCode == 0 && isDir(path) {
			result.Mode = "git-worktree"
			result.Created = true
			result.OK = true
			result.Reason = fmt.Sprintf("created git worktree on branch %q", branch)
			return result, nil
		}
		if runErr != nil {
			result.Reason = fmt.Sprintf("git worktree add failed: %v", runErr)
		} else {
			result.Reason = "git worktree add failed: " + gitMessage(run)
		}
	} else {
		result.Reason = "repository has no git HEAD; using a plain directory"
	}

	if err := os.MkdirAll(path, 0o755); err != nil {
		result.Reason = fmt.Sprintf("failed to create worktree directory: %v", err)
		return result, nil
	}
	result.Mode = "directory"
	result.Created = true
	result.OK = true
	return result, nil
}

// Remove deletes a project worktree idempotently. A registered git worktree is
// removed with `git worktree remove --force` and its branch is deleted; an
// unregistered directory is only deleted when force is true. A missing path is
// a success.
func Remove(root, project string, force bool) (RemoveResult, error) {
	path, err := WorktreePath(root, project)
	if err != nil {
		return RemoveResult{}, err
	}
	branch := Branch(project)
	result := RemoveResult{Project: project, Path: path, Branch: branch}

	if !pathExists(path) {
		result.OK = true
		result.Reason = "not present (idempotent)"
		return result, nil
	}

	registration, regErr := FindRegistration(root, project)
	if regErr == nil && registration != nil {
		// --force keeps the removal non-interactive (a dirty worktree would
		// otherwise abort) and matches project-worktree.ps1.
		_, _ = runGit(root, "worktree", "remove", "--force", path)
		_, _ = runGit(root, "branch", "-D", branch)
	} else if !force {
		result.Reason = "not a registered git worktree; pass -force to delete the directory"
		return result, nil
	}

	if pathExists(path) {
		if err := os.RemoveAll(path); err != nil {
			result.Reason = fmt.Sprintf("failed to remove %q: %v", path, err)
			return result, nil
		}
	}

	result.Removed = !pathExists(path)
	result.OK = result.Removed
	if result.Removed {
		result.Reason = "removed"
	} else {
		result.Reason = "path still present after removal"
	}
	return result, nil
}
