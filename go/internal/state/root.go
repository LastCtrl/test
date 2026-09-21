// Package state contains read-only parsers for the agent-hq on-disk state:
// evidence documents, task leases (claims), project queues and bus messages.
//
// Every loader in this package is fault tolerant by contract: a missing
// directory yields an empty result and a malformed file is reported as a
// warning instead of an error, so a single corrupt artifact can never stop the
// CLI from reporting the rest of the state (G1 is strictly read-only).
package state

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Directory and file names inside an agent-hq checkout. They are the single
// source of truth for every loader in this package.
const (
	MemoryDirName      = ".memory"
	EvidenceDirName    = "evidence"
	ClaimsDirName      = "claims"
	InboxDirName       = "inbox"
	OutboxDirName      = "outbox"
	DeadLetterDirName  = "dead-letter"
	ProjectsDirName    = "projects"
	AgentsDirName      = ".agents"
	ScriptsDirName     = "scripts"
	QueueFileName      = "queue.json"
	OpenCodeConfigName = "opencode.json"
	MetadataConfigName = "agent-hq.json"
)

// ResolveRoot picks the repository root. The AGENT_HQ_ROOT environment
// variable wins (the PowerShell tooling uses it for isolated roots), then the
// explicit -root value, then the current working directory.
func ResolveRoot(flagValue string) (string, error) {
	if envRoot := strings.TrimSpace(os.Getenv("AGENT_HQ_ROOT")); envRoot != "" {
		return filepath.Clean(envRoot), nil
	}
	if flagRoot := strings.TrimSpace(flagValue); flagRoot != "" {
		return filepath.Clean(flagRoot), nil
	}
	return os.Getwd()
}

// ValidateRoot checks that root is an existing agent-hq checkout: the path must
// exist, be a directory and contain the .memory directory. Callers that would
// otherwise create files below root (such as the shadow planner) use this first
// so a typo in -root fails loudly instead of silently growing a stray tree.
func ValidateRoot(root string) error {
	info, err := os.Stat(root)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("root %s does not exist", root)
		}
		return fmt.Errorf("cannot stat root %s: %w", root, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("root %s is not a directory", root)
	}

	memoryInfo, err := os.Stat(MemoryDir(root))
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("root %s does not look like an agent-hq checkout: missing %s", root, MemoryDirName)
		}
		return fmt.Errorf("cannot stat %s: %w", MemoryDir(root), err)
	}
	if !memoryInfo.IsDir() {
		return fmt.Errorf("%s is not a directory", MemoryDir(root))
	}
	return nil
}

// MemoryDir returns <root>/.memory.
func MemoryDir(root string) string {
	return filepath.Join(root, MemoryDirName)
}

// EvidenceDir returns <root>/.memory/evidence.
func EvidenceDir(root string) string {
	return filepath.Join(MemoryDir(root), EvidenceDirName)
}

// ClaimsDir returns <root>/.memory/claims.
func ClaimsDir(root string) string {
	return filepath.Join(MemoryDir(root), ClaimsDirName)
}

// InboxDir returns <root>/.memory/inbox.
func InboxDir(root string) string {
	return filepath.Join(MemoryDir(root), InboxDirName)
}

// OutboxDir returns <root>/.memory/outbox.
func OutboxDir(root string) string {
	return filepath.Join(MemoryDir(root), OutboxDirName)
}

// DeadLetterDir returns <root>/.memory/dead-letter.
func DeadLetterDir(root string) string {
	return filepath.Join(MemoryDir(root), DeadLetterDirName)
}

// ProjectsDir returns <root>/projects.
func ProjectsDir(root string) string {
	return filepath.Join(root, ProjectsDirName)
}

// ScriptsDir returns <root>/.agents/scripts.
func ScriptsDir(root string) string {
	return filepath.Join(root, AgentsDirName, ScriptsDirName)
}

// jsonFiles lists the direct *.json children of dir, sorted by name. A missing
// directory is not an error; it produces an empty list.
func jsonFiles(dir string) ([]string, []string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, []string{fmt.Sprintf("cannot list directory %s: %v", dir, err)}
	}

	files := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(strings.ToLower(entry.Name()), ".json") {
			continue
		}
		files = append(files, filepath.Join(dir, entry.Name()))
	}
	sort.Strings(files)
	return files, nil
}

// trimBOM removes a UTF-8 byte order mark. PowerShell's Get-Content strips the
// mark transparently, so the Go readers must do the same: otherwise a
// BOM-prefixed artifact (some legacy bus files are written with one) would be
// reported as corrupt JSON.
func trimBOM(raw []byte) []byte {
	return bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
}
