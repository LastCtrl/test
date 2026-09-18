package store

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"agent-hq/internal/state"
)

// Fingerprint returns a stable digest of the state files the index covers.
//
// It hashes the relative path, size and modification time of every evidence
// document, task lease, project queue and bus message — the same file sets the
// loaders in package state read. File content is deliberately not hashed: the
// index only needs re-reading when an artifact appeared, disappeared or was
// rewritten, so a stat-only scan keeps the freshness check cheap enough to run
// on every command.
//
// The database itself is never part of the digest (it lives in .memory, outside
// the scanned directories), so indexing does not invalidate the fingerprint it
// just stored.
func Fingerprint(root string) (string, error) {
	hash := sha256.New()
	err := walkState(root, func(relative string, size, modUnixNano int64) {
		fmt.Fprintf(hash, "%s\x00%d\x00%d\n", relative, size, modUnixNano)
	})
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// stateDir describes one directory that contributes to the fingerprint: which
// children match, and whether the inbox-style one-level nesting is scanned.
type stateDir struct {
	dir    string
	match  func(name string) bool
	nested bool
}

func stateDirs(root string) []stateDir {
	return []stateDir{
		{dir: state.EvidenceDir(root), match: isJSONFile},
		{dir: state.ClaimsDir(root), match: isClaimFile},
		{dir: state.InboxDir(root), match: isJSONFile, nested: true},
		{dir: state.OutboxDir(root), match: isJSONFile, nested: true},
		{dir: state.DeadLetterDir(root), match: isJSONFile, nested: true},
	}
}

// walkState visits every state file below root in a deterministic order.
// Missing directories contribute nothing (they are normal on a fresh root);
// any other listing error aborts, which makes the caller fall back to the files.
func walkState(root string, visit func(relative string, size, modUnixNano int64)) error {
	for _, spec := range stateDirs(root) {
		entries, err := os.ReadDir(spec.dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("fingerprint: cannot list %s: %w", spec.dir, err)
		}
		for _, entry := range entries {
			switch {
			case !entry.IsDir():
				if spec.match(entry.Name()) {
					if err := visitFile(root, filepath.Join(spec.dir, entry.Name()), entry, visit); err != nil {
						return err
					}
				}
			case spec.nested && entry.Name() != ".gitkeep":
				if err := visitNested(root, filepath.Join(spec.dir, entry.Name()), spec.match, visit); err != nil {
					return err
				}
			}
		}
	}
	return walkQueues(root, visit)
}

// visitNested scans one level below an inbox-style directory.
func visitNested(root, dir string, match func(name string) bool, visit func(string, int64, int64)) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("fingerprint: cannot list %s: %w", dir, err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !match(entry.Name()) {
			continue
		}
		if err := visitFile(root, filepath.Join(dir, entry.Name()), entry, visit); err != nil {
			return err
		}
	}
	return nil
}

// walkQueues visits projects/*/queue.json, mirroring state.LoadQueues.
func walkQueues(root string, visit func(relative string, size, modUnixNano int64)) error {
	projectsDir := state.ProjectsDir(root)
	entries, err := os.ReadDir(projectsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("fingerprint: cannot list %s: %w", projectsDir, err)
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		queuePath := filepath.Join(projectsDir, entry.Name(), state.QueueFileName)
		info, err := os.Stat(queuePath)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("fingerprint: cannot stat %s: %w", queuePath, err)
		}
		visitFileInfo(root, queuePath, info, visit)
	}
	return nil
}

// visitFile stats a directory entry and reports its root-relative identity.
func visitFile(root, path string, entry os.DirEntry, visit func(string, int64, int64)) error {
	info, err := entry.Info()
	if err != nil {
		return fmt.Errorf("fingerprint: cannot stat %s: %w", path, err)
	}
	visitFileInfo(root, path, info, visit)
	return nil
}

func visitFileInfo(root, path string, info os.FileInfo, visit func(string, int64, int64)) {
	relative, err := filepath.Rel(root, path)
	if err != nil {
		relative = path
	}
	visit(filepath.ToSlash(relative), info.Size(), info.ModTime().UnixNano())
}

func isJSONFile(name string) bool {
	return strings.HasSuffix(strings.ToLower(name), ".json")
}

func isClaimFile(name string) bool {
	return strings.HasSuffix(strings.ToLower(name), ".claim.json")
}
