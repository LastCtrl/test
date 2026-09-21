package net

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ModelHealthFileName is the model-router health state, relative to .memory.
const ModelHealthFileName = "model-health.json"

// ErrNoModelHealth reports that the health state has not been produced yet, so
// callers can recommend `model-router.ps1 -Probe` instead of failing.
var ErrNoModelHealth = errors.New("model-health state not found")

// routerTimeLayout is the invariant timestamp shape used by model-router.ps1.
const routerTimeLayout = "2006-01-02T15:04:05"

// ModelHealth is one model-router health record, enriched with the breaker
// state evaluated at read time.
type ModelHealth struct {
	Model     string `json:"model"`
	Status    string `json:"status"`
	CheckedAt string `json:"checked_at,omitempty"`
	FailCount int    `json:"fail_count"`
	OpenUntil string `json:"open_until,omitempty"`
	// Open is true while the circuit breaker is still parked.
	Open bool `json:"open"`
	// Class is the provider vocabulary of the parsed status.
	Class Status `json:"class"`
}

// ModelHealthPath returns <root>/.memory/model-health.json.
func ModelHealthPath(root string) string {
	return filepath.Join(root, ".memory", ModelHealthFileName)
}

// ReadModelHealthFile parses the model-router health document. A missing file
// returns ErrNoModelHealth; a corrupt file returns a parse error. Both keep the
// caller (and therefore the CLI) alive.
func ReadModelHealthFile(path string, now time.Time) ([]ModelHealth, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, ErrNoModelHealth
		}
		return nil, fmt.Errorf("read model-health %s: %w", path, err)
	}
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, ErrNoModelHealth
	}

	var document map[string]struct {
		Model     string `json:"model"`
		Status    string `json:"status"`
		CheckedAt string `json:"checked_at"`
		FailCount *int   `json:"fail_count"`
		OpenUntil string `json:"open_until"`
	}
	if err := json.Unmarshal(raw, &document); err != nil {
		return nil, fmt.Errorf("parse model-health %s: %w", path, err)
	}

	records := make([]ModelHealth, 0, len(document))
	for key, entry := range document {
		model := strings.TrimSpace(entry.Model)
		if model == "" {
			model = key
		}
		record := ModelHealth{
			Model:     model,
			Status:    strings.TrimSpace(entry.Status),
			CheckedAt: strings.TrimSpace(entry.CheckedAt),
			OpenUntil: strings.TrimSpace(entry.OpenUntil),
		}
		if entry.FailCount != nil {
			record.FailCount = *entry.FailCount
		}
		record.Class = ParseHealthStatus(record.Status)
		record.Open = IsBreakerOpen(record.OpenUntil, now)
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool { return records[i].Model < records[j].Model })
	return records, nil
}

// IsBreakerOpen reports whether an open_until timestamp is still in the future.
// An empty or unparsable value means the breaker is closed, mirroring
// Test-ModelOpen in model-router.ps1.
func IsBreakerOpen(openUntil string, now time.Time) bool {
	until, ok := parseRouterTime(openUntil)
	if !ok {
		return false
	}
	return until.After(now)
}

// parseRouterTime accepts the invariant model-router layout first and falls
// back to a general parse, matching ConvertTo-RouterDate.
func parseRouterTime(value string) (time.Time, bool) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return time.Time{}, false
	}
	if parsed, err := time.ParseInLocation(routerTimeLayout, trimmed, time.Local); err == nil {
		return parsed, true
	}
	if parsed, err := time.Parse(time.RFC3339, trimmed); err == nil {
		return parsed, true
	}
	if parsed, err := time.Parse("2006-01-02 15:04:05", trimmed); err == nil {
		return parsed, true
	}
	return time.Time{}, false
}

// OpenModels returns the models whose breaker is currently open.
func OpenModels(records []ModelHealth) []ModelHealth {
	open := make([]ModelHealth, 0)
	for _, record := range records {
		if record.Open {
			open = append(open, record)
		}
	}
	return open
}

// Recommend turns probe/health observations into operator-facing next steps,
// the same guidance model-router.ps1 prints.
func Recommend(proxy ProxyResult, health []ModelHealth, healthErr error) []string {
	steps := make([]string, 0, 4)
	if strings.EqualFold(strings.TrimSpace(proxy.Mode), "off") {
		steps = append(steps, fmt.Sprintf("proxy %s is disabled (mode=off): direct connection, cntlm not required", proxy.Address))
	} else {
		switch proxy.Status {
		case StatusOK:
			steps = append(steps, fmt.Sprintf("proxy %s is up (%dms)", proxy.Address, proxy.LatencyMS))
		case StatusTimeout:
			steps = append(steps, fmt.Sprintf("proxy %s did not answer within the probe budget: check cntlm load, restart only the owned PID", proxy.Address))
		default:
			steps = append(steps, fmt.Sprintf("proxy %s is DOWN: start or restart cntlm and verify the listener (AGENTS.md section 10)", proxy.Address))
		}
	}

	open := OpenModels(health)
	if len(open) > 0 {
		names := make([]string, 0, len(open))
		for _, record := range open {
			names = append(names, fmt.Sprintf("%s (until %s)", record.Model, record.OpenUntil))
		}
		steps = append(steps, "breaker OPEN for: "+strings.Join(names, ", ")+" - route around them or wait for the cooldown")
	}

	if healthErr != nil {
		if errors.Is(healthErr, ErrNoModelHealth) {
			steps = append(steps, "no model-health state yet: run model-router.ps1 -Probe to populate .memory/model-health.json")
		} else {
			steps = append(steps, "model-health state is unreadable: "+healthErr.Error()+" - re-run model-router.ps1 -Probe")
		}
	} else if len(health) == 0 {
		steps = append(steps, "model-health holds no records: run model-router.ps1 -Probe")
	}
	return steps
}
