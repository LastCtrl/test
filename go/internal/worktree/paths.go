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
// case-insensitive, like the OrdinalIgnoreCase check in project-worktree.ps1,
// and canonicalises both sides first so the answer does not depend on how a
// path is spelled (see canonicalPath).
func IsWithin(base, target string) bool {
	return isWithin(base, target)
}

func isWithin(base, target string) bool {
	baseFull := canonicalPath(base)
	targetFull := canonicalPath(target)
	if baseFull == "" || targetFull == "" {
		return false
	}
	if len(targetFull) <= len(baseFull) {
		return false
	}
	prefix := baseFull + string(os.PathSeparator)
	return strings.HasPrefix(strings.ToLower(targetFull), strings.ToLower(prefix))
}

// canonicalPath returns the most canonical spelling of path available on this
// system: absolute, cleaned and, when the location exists, with symlinks and
// Windows 8.3 short names resolved. filepath.EvalSymlinks delegates to the OS,
// which maps C:\Users\RUNNER~1\AppData\... to C:\Users\runneradmin\AppData\...
// A path that does not exist yet is normalised through its deepest existing
// ancestor and the missing components are re-appended, so a worktree path can
// be canonicalised before `git worktree add` creates it. Returns "" for an
// empty path.
func canonicalPath(path string) string {
	if strings.TrimSpace(path) == "" {
		return ""
	}
	absolute, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	absolute = filepath.Clean(absolute)
	if resolved, err := filepath.EvalSymlinks(absolute); err == nil {
		return filepath.Clean(resolved)
	}
	// The leaf, or one of its parents, does not exist yet: resolve the deepest
	// existing ancestor and re-append the missing components.
	dir, tail := absolute, ""
	for {
		parent := filepath.Dir(dir)
		if parent == dir {
			return absolute
		}
		tail = filepath.Join(filepath.Base(dir), tail)
		dir = parent
		if resolved, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Clean(filepath.Join(resolved, tail))
		}
	}
}

// samePath reports whether a and b denote the same filesystem location. The
// identity of an existing file is decided by the OS (os.SameFile), which is
// immune to Windows 8.3 short names (C:\Users\RUNNER~1\... versus
// C:\Users\runneradmin\...), symlinks and case differences. Paths that do not
// exist yet fall back to a case-insensitive canonical string comparison.
func samePath(a, b string) bool {
	if strings.TrimSpace(a) == "" || strings.TrimSpace(b) == "" {
		return false
	}
	if infoA, err := os.Stat(a); err == nil {
		if infoB, err := os.Stat(b); err == nil && os.SameFile(infoA, infoB) {
			return true
		}
	}
	canonicalA, canonicalB := canonicalPath(a), canonicalPath(b)
	if canonicalA == "" || canonicalB == "" {
		return false
	}
	return strings.EqualFold(canonicalA, canonicalB)
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
