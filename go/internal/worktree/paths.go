package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Directory and file names inside an agent-hq checkout. They are the single
// source of truth for the path helpers below.
const (
	ProjectsDirName   = "projects"
	AgentsDirName     = ".agents"
	WorktreesDirName  = "worktrees"
	GitDirName        = ".git"
	ContextBufferName = "CONTEXT-BUFFER.md"
)

// ProjectsDir returns <root>/projects.
func ProjectsDir(root string) string {
	return filepath.Join(root, ProjectsDirName)
}

// WorktreesDir returns <root>/.agents/worktrees.
func WorktreesDir(root string) string {
	return filepath.Join(root, AgentsDirName, WorktreesDirName)
}

// ProjectDir returns the canonical directory of a project. The result is
// guaranteed to stay inside <root>/projects: an invalid or traversing name is
// rejected instead of being joined.
func ProjectDir(root, project string) (string, error) {
	if err := AssertName(project); err != nil {
		return "", err
	}
	base := ProjectsDir(root)
	full := filepath.Join(base, project)
	if !isWithin(base, full) {
		return "", fmt.Errorf("path traversal detected: %q escapes the projects root", project)
	}
	return filepath.Clean(full), nil
}

// WorktreePath returns <root>/.agents/worktrees/<project>.
func WorktreePath(root, project string) (string, error) {
	if err := AssertName(project); err != nil {
		return "", err
	}
	base := WorktreesDir(root)
	full := filepath.Join(base, project)
	if !isWithin(base, full) {
		return "", fmt.Errorf("path traversal detected: %q escapes the worktrees root", project)
	}
	return filepath.Clean(full), nil
}

// BufferPath returns the canonical CONTEXT-BUFFER.md path of a project.
func BufferPath(root, project string) (string, error) {
	dir, err := ProjectDir(root, project)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, ContextBufferName), nil
}

// TestPathBoundary reports whether path lies inside projects/<project>/ or
// .agents/worktrees/<project>/. It is the Go twin of Test-ProjectPathBoundary:
// when the project name itself is invalid the answer is false because no valid
// boundary can be derived for it.
func TestPathBoundary(root, project, path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}
	target, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return false
	}

	bases := make([]string, 0, 2)
	if dir, err := ProjectDir(root, project); err == nil {
		bases = append(bases, dir)
	}
	if dir, err := WorktreePath(root, project); err == nil {
		bases = append(bases, dir)
	}
	for _, base := range bases {
		if isWithin(base, target) {
			return true
		}
	}
	return false
}

// IsWithin reports whether target is a strict child of base. The comparison is
// case-insensitive, like the OrdinalIgnoreCase check in project-worktree.ps1.
func IsWithin(base, target string) bool {
	return isWithin(base, target)
}

func isWithin(base, target string) bool {
	baseFull, err := filepath.Abs(filepath.Clean(base))
	if err != nil {
		return false
	}
	targetFull, err := filepath.Abs(filepath.Clean(target))
	if err != nil {
		return false
	}
	if len(targetFull) <= len(baseFull) {
		return false
	}
	prefix := baseFull + string(os.PathSeparator)
	return strings.HasPrefix(strings.ToLower(targetFull), strings.ToLower(prefix))
}

// gitWorktreesDir returns <root>/.git/worktrees, where git stores the
// administrative directory of every linked worktree.
func gitWorktreesDir(root string) string {
	return filepath.Join(root, GitDirName, WorktreesDirName)
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
