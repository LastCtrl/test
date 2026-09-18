package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// WriteResult mirrors the output of Write-ProjectContextBuffer. Bytes is the
// length of the resulting buffer in characters (PowerShell's String.Length),
// not in bytes, so the value is comparable across the two tooling layers.
type WriteResult struct {
	OK     bool   `json:"ok"`
	Reason string `json:"reason"`
	Path   string `json:"path"`
	Bytes  int    `json:"bytes"`
}

// ReadBuffer returns the UTF-8 content of a project's CONTEXT-BUFFER.md. A
// missing file is a normal state: found is false and the content is empty. An
// invalid project name is an error.
func ReadBuffer(root, project string) (content string, found bool, err error) {
	path, err := BufferPath(root, project)
	if err != nil {
		return "", false, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("read %s: %w", path, err)
	}
	return strings.TrimPrefix(string(raw), "\ufeff"), true, nil
}

// AppendBuffer appends content to a project's buffer. The write is refused
// when the target path leaves the project boundary, when the target name is
// invalid, or when sourceProject names a DIFFERENT project and
// allowCrossProject is false (the leak guard). A missing file is created,
// including its project directory.
func AppendBuffer(root, project, content, sourceProject string, allowCrossProject bool) (WriteResult, error) {
	result := WriteResult{}

	if err := AssertName(project); err != nil {
		result.Reason = "invalid target project: " + err.Error()
		return result, nil
	}
	if strings.TrimSpace(sourceProject) != "" {
		if err := AssertName(sourceProject); err != nil {
			result.Reason = "invalid source project: " + err.Error()
			return result, nil
		}
		if sourceProject != project && !allowCrossProject {
			result.Reason = fmt.Sprintf("cross-project write blocked: source %q != target %q", sourceProject, project)
			return result, nil
		}
	}

	path, err := BufferPath(root, project)
	if err != nil {
		result.Reason = "invalid target project: " + err.Error()
		return result, nil
	}
	if !TestPathBoundary(root, project, path) {
		result.Reason = fmt.Sprintf("path boundary violation: %q is outside project %q", path, project)
		return result, nil
	}
	result.Path = path

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		result.Reason = "write failed: " + err.Error()
		return result, nil
	}

	existing := ""
	if raw, readErr := os.ReadFile(path); readErr == nil {
		existing = string(raw)
		// Same rule as Write-ProjectContextBuffer: only a true newline ends a
		// record, so an existing CRLF-terminated file needs no extra separator.
		if len(existing) > 0 && !strings.HasSuffix(existing, "\n") {
			existing += "\r\n"
		}
	} else if !os.IsNotExist(readErr) {
		result.Reason = "write failed: " + readErr.Error()
		return result, nil
	}

	if err := os.WriteFile(path, []byte(existing+content), 0o644); err != nil {
		result.Reason = "write failed: " + err.Error()
		return result, nil
	}

	written, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(written), content) {
		result.Reason = "write verification failed"
		return result, nil
	}
	result.Bytes = utf8.RuneCountInString(string(written))
	result.OK = true
	result.Reason = "appended"
	return result, nil
}
