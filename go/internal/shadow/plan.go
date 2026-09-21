// Package shadow implements the M5 read-only shadow planner: it scans the same
// inbox and project queues the PowerShell engine owns, builds the plan of what
// a Go control plane would do (item -> agent -> model -> executor) and records
// it under .memory/shadow.
//
// The planner is strictly observational. It never claims a lease, never runs a
// worker and never writes to any state file the PowerShell engine owns; the
// only path it creates is its own report directory.
package shadow

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"agent-hq/internal/state"
)

// Mode is the fixed marker written into every report.
const Mode = "shadow"

// DefaultExecutor is the worker the plan would drive. The PowerShell engine
// drives opencode; the Go path mirrors it.
const DefaultExecutor = "opencode"

// Actions describe what the shadow would do with one unit of work.
const (
	ActionRun  = "would-run"
	ActionSkip = "would-skip"
)

// Routes describe how a unit of work reached its target agent.
const (
	RouteDirect     = "direct"     // inbox message with an explicit to field
	RouteFolder     = "folder"     // inbox message routed by its folder name
	RouteAssigned   = "assigned"   // queue task with an assigned agent
	RouteUnassigned = "unassigned" // queue task without an assigned agent
)

// Reasons explain a would-skip action.
const (
	ReasonProcessed = "processed-by-ps"
	ReasonNoAgent   = "no-target-agent"
)

// Sources are the two state views the planner merges.
const (
	SourceInbox = "inbox"
	SourceQueue = "queue"
)

// Step is one planned unit of work: the task, the agent it would run as, the
// model resolved for that agent and the executor that would drive it.
type Step struct {
	Source        string `json:"source"`
	Project       string `json:"project,omitempty"`
	TaskID        string `json:"task_id"`
	Title         string `json:"title,omitempty"`
	Priority      string `json:"priority,omitempty"`
	Status        string `json:"status,omitempty"`
	Agent         string `json:"agent,omitempty"`
	Model         string `json:"model,omitempty"`
	Executor      string `json:"executor"`
	Route         string `json:"route"`
	Action        string `json:"action"`
	ProcessedByPS bool   `json:"processed_by_ps"`
	Reason        string `json:"reason,omitempty"`
}

// Summary is the numeric digest of a plan.
type Summary struct {
	Total         int `json:"total"`
	WouldRun      int `json:"would_run"`
	WouldSkip     int `json:"would_skip"`
	ProcessedByPS int `json:"processed_by_ps"`
	Inbox         int `json:"inbox"`
	Queue         int `json:"queue"`
}

// Report is the persisted shadow document. ReadOnly is always true and exists
// to make the guarantee explicit in the artifact itself.
type Report struct {
	Mode      string   `json:"mode"`
	ReadOnly  bool     `json:"read_only"`
	Version   string   `json:"version"`
	Root      string   `json:"root"`
	CreatedAt string   `json:"created_at"`
	Path      string   `json:"report_path,omitempty"`
	Executor  string   `json:"default_executor"`
	Steps     []Step   `json:"steps"`
	Summary   Summary  `json:"summary"`
	Warnings  []string `json:"warnings"`
}

// Build scans root read-only and returns the plan a Go control plane would
// execute. It never mutates the state below root.
func Build(root, version string, now time.Time) *Report {
	models, warnings := LoadAgentModels(root)
	snapshot := state.Load(root, version, 0, now)

	processed := processedMessageIDs(snapshot)
	completed := completedTaskIDs(snapshot)

	report := &Report{
		Mode:      Mode,
		ReadOnly:  true,
		Version:   version,
		Root:      root,
		CreatedAt: now.UTC().Format(time.RFC3339),
		Executor:  DefaultExecutor,
		Steps:     make([]Step, 0),
		Warnings:  make([]string, 0),
	}
	report.Warnings = append(report.Warnings, warnings...)
	report.Warnings = append(report.Warnings, snapshot.Warnings...)

	for _, message := range snapshot.Inbox {
		report.Steps = append(report.Steps, planInbox(message, models, processed))
	}
	for _, task := range snapshot.Tasks() {
		report.Steps = append(report.Steps, planQueue(task, models, completed))
	}

	sort.SliceStable(report.Steps, func(i, j int) bool {
		if report.Steps[i].Source != report.Steps[j].Source {
			return report.Steps[i].Source < report.Steps[j].Source
		}
		if report.Steps[i].Project != report.Steps[j].Project {
			return report.Steps[i].Project < report.Steps[j].Project
		}
		return report.Steps[i].TaskID < report.Steps[j].TaskID
	})

	report.Summary = summarize(report.Steps)
	return report
}

// planInbox turns one pending inbox message into a step. The target agent is
// the message "to" field when present, otherwise the folder the message lives
// in, exactly like Process-InboxFile in the PowerShell engine.
func planInbox(message state.Message, models map[string]string, processed map[string]bool) Step {
	agent := strings.TrimSpace(message.To)
	route := RouteDirect
	if agent == "" {
		agent = strings.TrimSpace(message.Agent)
		route = RouteFolder
	}

	step := Step{
		Source:   SourceInbox,
		TaskID:   strings.TrimSpace(message.ID),
		Priority: strings.TrimSpace(message.Priority),
		Status:   strings.TrimSpace(message.Status),
		Agent:    agent,
		Model:    models[strings.ToLower(agent)],
		Executor: DefaultExecutor,
		Route:    route,
		Action:   ActionRun,
	}

	switch {
	case agent == "":
		step.Action = ActionSkip
		step.Reason = ReasonNoAgent
	case processed[step.TaskID]:
		step.Action = ActionSkip
		step.ProcessedByPS = true
		step.Reason = ReasonProcessed
	}
	return step
}

// planQueue turns one queue task into a step. A task already completed on disk
// (or with a successful evidence attempt) is marked as processed by PowerShell.
func planQueue(task state.Task, models map[string]string, completed map[string]bool) Step {
	agent := strings.TrimSpace(task.AssignedAgent)
	route := RouteAssigned
	if agent == "" {
		route = RouteUnassigned
	}
	status := strings.ToLower(strings.TrimSpace(task.Status))

	step := Step{
		Source:   SourceQueue,
		Project:  strings.TrimSpace(task.Project),
		TaskID:   strings.TrimSpace(task.ID),
		Title:    strings.TrimSpace(task.Title),
		Priority: strings.TrimSpace(task.Priority),
		Status:   status,
		Agent:    agent,
		Model:    models[strings.ToLower(agent)],
		Executor: DefaultExecutor,
		Route:    route,
		Action:   ActionRun,
	}

	switch {
	case agent == "":
		step.Action = ActionSkip
		step.Reason = ReasonNoAgent
	case status == "done" || status == "dead" || completed[step.TaskID]:
		step.Action = ActionSkip
		step.ProcessedByPS = true
		step.Reason = ReasonProcessed
	}
	return step
}

// processedMessageIDs collects the identifiers already delivered by the
// PowerShell engine (outbox) or parked by it (dead-letter).
func processedMessageIDs(snapshot *state.Snapshot) map[string]bool {
	ids := make(map[string]bool)
	for _, group := range [][]state.Message{snapshot.Outbox, snapshot.DeadLetter} {
		for _, message := range group {
			if id := strings.TrimSpace(message.ID); id != "" {
				ids[id] = true
			}
		}
	}
	return ids
}

// completedTaskIDs collects queue task identifiers that already have a
// successful machine evidence attempt on disk.
func completedTaskIDs(snapshot *state.Snapshot) map[string]bool {
	ids := make(map[string]bool)
	for _, doc := range snapshot.Evidence {
		id := strings.TrimSpace(doc.TaskID)
		if id == "" {
			continue
		}
		for _, attempt := range doc.Attempts {
			if strings.EqualFold(strings.TrimSpace(attempt.Status), "success") {
				ids[id] = true
				break
			}
		}
	}
	return ids
}

// summarize folds the steps into the report summary.
func summarize(steps []Step) Summary {
	summary := Summary{Total: len(steps)}
	for _, step := range steps {
		switch step.Source {
		case SourceInbox:
			summary.Inbox++
		case SourceQueue:
			summary.Queue++
		}
		if step.Action == ActionRun {
			summary.WouldRun++
		} else {
			summary.WouldSkip++
		}
		if step.ProcessedByPS {
			summary.ProcessedByPS++
		}
	}
	return summary
}

// LoadAgentModels builds the agent -> model routing table from the repository
// configuration. The agent block of opencode.json wins over the per-agent
// files, because opencode reads that block at runtime. Missing or malformed
// sources are warnings, never errors: the planner must still work without them.
func LoadAgentModels(root string) (map[string]string, []string) {
	models := make(map[string]string)
	warnings := make([]string, 0)

	fromFiles, err := loadAgentFiles(filepath.Join(root, ".opencode", "agents"))
	if err != nil {
		warnings = append(warnings, "agent-models: "+err.Error())
	} else {
		for name, model := range fromFiles {
			models[strings.ToLower(name)] = model
		}
	}

	fromConfig, err := loadOpenCodeConfig(filepath.Join(root, state.OpenCodeConfigName))
	if err != nil {
		warnings = append(warnings, "agent-models: "+err.Error())
	} else {
		for name, model := range fromConfig {
			models[strings.ToLower(name)] = model
		}
	}
	return models, warnings
}

// loadAgentFiles reads .opencode/agents/*.json. One broken agent file is
// skipped so it cannot hide the others.
func loadAgentFiles(dir string) (map[string]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, fmt.Errorf("cannot list %s: %w", dir, err)
	}

	models := make(map[string]string)
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			return nil, fmt.Errorf("cannot read %s: %w", entry.Name(), err)
		}
		var doc struct {
			Name  string `json:"name"`
			Model string `json:"model"`
		}
		if err := json.Unmarshal(trimBOM(raw), &doc); err != nil {
			continue
		}
		name := strings.TrimSpace(doc.Name)
		if name == "" {
			name = strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))
		}
		if model := strings.TrimSpace(doc.Model); name != "" && model != "" {
			models[name] = model
		}
	}
	return models, nil
}

// loadOpenCodeConfig reads the agent block of opencode.json.
func loadOpenCodeConfig(path string) (map[string]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, fmt.Errorf("cannot read %s: %w", path, err)
	}
	var doc struct {
		Agent map[string]struct {
			Model string `json:"model"`
		} `json:"agent"`
	}
	if err := json.Unmarshal(trimBOM(raw), &doc); err != nil {
		return nil, fmt.Errorf("broken json %s: %w", path, err)
	}

	models := make(map[string]string)
	for name, agent := range doc.Agent {
		if model := strings.TrimSpace(agent.Model); name != "" && model != "" {
			models[name] = model
		}
	}
	return models, nil
}

// ReportPath returns the timestamped report file under .memory/shadow.
func ReportPath(root string, now time.Time) string {
	name := now.UTC().Format("20060102T150405.000000000Z") + ".json"
	return filepath.Join(state.MemoryDir(root), "shadow", name)
}

// Write stores the report at path. It creates only the shadow directory: no
// other path below the root is touched.
func Write(path string, report *Report) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("cannot create shadow directory: %w", err)
	}
	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		return fmt.Errorf("cannot encode shadow report: %w", err)
	}
	encoded = append(encoded, '\n')
	if err := os.WriteFile(path, encoded, 0o644); err != nil {
		return fmt.Errorf("cannot write shadow report: %w", err)
	}
	return nil
}

// trimBOM removes a UTF-8 byte order mark, mirroring the state loaders so a
// BOM-prefixed config is not reported as corrupt JSON.
func trimBOM(raw []byte) []byte {
	return bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
}
