package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Check statuses used by the doctor command.
const (
	CheckOK   = "ok"
	CheckWarn = "warn"
	CheckFail = "fail"
)

// Check is one diagnostic result.
type Check struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

// Doctor inspects the layout the read-only CLI depends on. It never modifies
// anything. Failures mean "this does not look like an agent-hq root"; warnings
// mean an optional directory or config is missing but the CLI still works.
func Doctor(root string, snapshot *Snapshot) []Check {
	checks := make([]Check, 0, 12)

	checks = append(checks, checkDir("root", root, true))
	checks = append(checks, checkDir("memory", MemoryDir(root), true))
	checks = append(checks, checkDir("projects", ProjectsDir(root), false))
	checks = append(checks, checkDir("scripts", ScriptsDir(root), false))
	checks = append(checks, checkDir("evidence", EvidenceDir(root), false))
	checks = append(checks, checkDir("claims", ClaimsDir(root), false))
	checks = append(checks, checkDir("inbox", InboxDir(root), false))
	checks = append(checks, checkDir("outbox", OutboxDir(root), false))
	checks = append(checks, checkDir("dead-letter", DeadLetterDir(root), false))

	checks = append(checks, checkJSONFile("metadata", filepath.Join(root, MetadataConfigName), false))
	checks = append(checks, checkJSONFile("opencode-config", filepath.Join(root, OpenCodeConfigName), false))

	if snapshot != nil {
		status := CheckOK
		detail := "no broken state files"
		if len(snapshot.Warnings) > 0 {
			status = CheckWarn
			detail = fmt.Sprintf("%d broken state file(s)", len(snapshot.Warnings))
		}
		checks = append(checks, Check{Name: "state-files", Status: status, Detail: detail})
	}

	return checks
}

func checkDir(name, path string, required bool) Check {
	info, err := os.Stat(path)
	switch {
	case err == nil && info.IsDir():
		return Check{Name: name, Status: CheckOK, Detail: path}
	case err == nil:
		return Check{Name: name, Status: CheckFail, Detail: path + " is not a directory"}
	case os.IsNotExist(err):
		if required {
			return Check{Name: name, Status: CheckFail, Detail: path + " is missing"}
		}
		return Check{Name: name, Status: CheckWarn, Detail: path + " is missing (optional)"}
	default:
		return Check{Name: name, Status: CheckFail, Detail: fmt.Sprintf("%s: %v", path, err)}
	}
}

func checkJSONFile(name, path string, required bool) Check {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if required {
				return Check{Name: name, Status: CheckFail, Detail: path + " is missing"}
			}
			return Check{Name: name, Status: CheckWarn, Detail: path + " is missing (optional)"}
		}
		return Check{Name: name, Status: CheckFail, Detail: fmt.Sprintf("%s: %v", path, err)}
	}
	if !json.Valid(raw) {
		return Check{Name: name, Status: CheckFail, Detail: path + " is not valid JSON"}
	}
	return Check{Name: name, Status: CheckOK, Detail: path}
}

// DoctorOK reports whether no check failed (warnings are tolerated).
func DoctorOK(checks []Check) bool {
	for _, check := range checks {
		if check.Status == CheckFail {
			return false
		}
	}
	return true
}
