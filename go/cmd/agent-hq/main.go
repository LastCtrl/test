// Command agent-hq is the read-only Go CLI for the agent-hq state store (G1).
//
// It inspects evidence documents, task leases, project queues and bus messages
// without ever writing to them. All output is available as human-readable text
// or machine-readable JSON via -json.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"agent-hq/internal/state"
	"agent-hq/internal/store"
)

const (
	cliName = "agent-hq"
	version = "0.5.0-g3m3"
)

const usageText = `agent-hq <command> [flags]

State view of the agent-hq repository (G1 readers, G2 SQLite index, G3 durable runs/recovery/self-healing).

Commands:
  status              counters and recent activity
  tasks               project queue tasks (flags: -agent, -status)
  leases              task leases and their TTL state (flags: -ttl, -stale)
  evidence <id>       details of one evidence document
  index               (re)build the SQLite index of .memory and project queues
  db status           report what the SQLite index contains
  doctor              health of directories, configs and the network
  net-check           probe the CNTLM proxy and report network/model health
  run <agent> <text>  claim an id, execute it through an Executor and record the result
  recover             mark stale running attempts stale, release their lease (flags: -requeue, -ttl, -json, -net)
  checkpoint <op>     save|list|latest durable handoff points of a run
  version             print the CLI version

Shared flags (before or after the command):
  -root <path>        repository root (AGENT_HQ_ROOT overrides it)
  -json               machine-readable output

Retries read from the SQLite index when it exists and matches the current
files, and fall back to reading the files otherwise. The index is a derived
artifact: deleting it only costs one 'agent-hq index'.

Examples:
  agent-hq status
  agent-hq status -json
  agent-hq tasks -status queued
  agent-hq leases -ttl 600 -stale
  agent-hq evidence a1b2c3
  agent-hq index
  agent-hq db status -json
  agent-hq doctor -json
  agent-hq net-check
  agent-hq net-check -model opencode-go/deepseek-v4.1-flash -json
  agent-hq run dev-2 "summarise the open tasks" -executor fake
  agent-hq run dev-2 "summarise the open tasks" -executor opencode -json
  agent-hq recover -json
  agent-hq recover -requeue
  agent-hq checkpoint save run-1 -state "step 2 done" -path src/app.go
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	globals, rest := extractGlobals(args)
	if len(rest) == 0 {
		fmt.Fprint(stdout, usageText)
		return 0
	}

	command := strings.ToLower(rest[0])
	commandArgs := rest[1:]

	switch command {
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usageText)
		return 0
	case "version", "-version", "--version":
		fmt.Fprintf(stdout, "%s %s\n", cliName, version)
		return 0
	case "status":
		return runStatus(globals, commandArgs, stdout, stderr)
	case "tasks":
		return runTasks(globals, commandArgs, stdout, stderr)
	case "leases":
		return runLeases(globals, commandArgs, stdout, stderr)
	case "evidence":
		return runEvidence(globals, commandArgs, stdout, stderr)
	case "index":
		return runIndex(globals, commandArgs, stdout, stderr)
	case "db":
		return runDB(globals, commandArgs, stdout, stderr)
	case "doctor":
		return runDoctor(globals, commandArgs, stdout, stderr)
	case "net-check", "netcheck":
		return runNetCheck(globals, commandArgs, stdout, stderr)
	case "run":
		return runRun(globals, commandArgs, stdout, stderr)
	case "recover":
		return runRecover(globals, commandArgs, stdout, stderr)
	case "checkpoint":
		return runCheckpoint(globals, commandArgs, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "%s: unknown command %q\n\n%s", cliName, rest[0], usageText)
		return 2
	}
}

// globalOptions carries the flags that are valid for every subcommand.
type globalOptions struct {
	root string
	json bool
}

// extractGlobals pulls -root and -json out of args so they work both before
// and after the subcommand. Everything else is passed through untouched.
func extractGlobals(args []string) (globalOptions, []string) {
	options := globalOptions{}
	rest := make([]string, 0, len(args))

	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch {
		case arg == "-json" || arg == "--json":
			options.json = true
		case arg == "-root" || arg == "--root":
			if index+1 < len(args) {
				options.root = args[index+1]
				index++
			}
		case strings.HasPrefix(arg, "-root=") || strings.HasPrefix(arg, "--root="):
			if equals := strings.Index(arg, "="); equals >= 0 {
				options.root = arg[equals+1:]
			}
		default:
			rest = append(rest, arg)
		}
	}

	return options, rest
}

func newFlagSet(name string, stderr io.Writer) *flag.FlagSet {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	return flags
}

// parseFlags returns false when the caller should stop. helpHandled reports
// whether the stop was a requested -h (exit 0) rather than a real error.
func parseFlags(flags *flag.FlagSet, args []string) (ok, helpHandled bool) {
	err := flags.Parse(args)
	if err == nil {
		return true, false
	}
	if errors.Is(err, flag.ErrHelp) {
		return false, true
	}
	return false, false
}

func resolveRoot(globals globalOptions, stderr io.Writer) (string, bool) {
	root, err := state.ResolveRoot(globals.root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot resolve root: %v\n", cliName, err)
		return "", false
	}
	return root, true
}

// loadSnapshot prefers the SQLite index when it exists and still matches the
// files, and falls back to parsing the files otherwise. The fallback keeps the
// G1 behaviour intact for roots that were never indexed, for a stale index and
// for a database that cannot be opened at all.
func loadSnapshot(root, version string, ttlOverride time.Duration, now time.Time, stderr io.Writer) *state.Snapshot {
	handle, err := store.OpenReadOnly(root)
	if err == nil {
		defer func() { _ = handle.Close() }()
		fresh, freshErr := handle.IsFresh()
		if freshErr == nil && fresh {
			snapshot, loadErr := handle.Snapshot(version, ttlOverride, now)
			if loadErr == nil {
				return snapshot
			}
			fmt.Fprintf(stderr, "%s: index read failed, using files: %v\n", cliName, loadErr)
		} else if freshErr != nil {
			fmt.Fprintf(stderr, "%s: index freshness check failed, using files: %v\n", cliName, freshErr)
		}
	} else if !errors.Is(err, store.ErrNotIndexed) {
		fmt.Fprintf(stderr, "%s: index unavailable, using files: %v\n", cliName, err)
	}
	return state.Load(root, version, ttlOverride, now)
}

func writeJSON(writer io.Writer, value any) bool {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: cannot encode json: %v\n", cliName, err)
		return false
	}
	_, err = fmt.Fprintln(writer, string(encoded))
	return err == nil
}

// ---------------------------------------------------------------------------
// status
// ---------------------------------------------------------------------------

type statusOutput struct {
	Version  string           `json:"version"`
	Root     string           `json:"root"`
	LoadedAt string           `json:"loaded_at"`
	Counts   state.Counts     `json:"counts"`
	Recent   []state.Activity `json:"recent"`
	Warnings []string         `json:"warnings"`
}

func runStatus(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("status", stderr)
	limit := flags.Int("limit", 10, "number of recent activity rows (0 = all)")
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	now := time.Now()
	snapshot := state.Load(root, version, 0, now)
	output := statusOutput{
		Version:  version,
		Root:     root,
		LoadedAt: now.Format(time.RFC3339),
		Counts:   snapshot.Counts(),
		Recent:   snapshot.RecentActivity(*limit),
		Warnings: snapshot.Warnings,
	}
	if output.Recent == nil {
		output.Recent = []state.Activity{}
	}
	if output.Warnings == nil {
		output.Warnings = []string{}
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s %s\n", cliName, output.Version)
	fmt.Fprintf(writer, "root:\t%s\n", output.Root)
	fmt.Fprintf(writer, "loaded:\t%s\n", output.LoadedAt)
	fmt.Fprintln(writer)

	fmt.Fprintln(writer, "state")
	fmt.Fprintf(writer, "  evidence\t%d\n", output.Counts.Evidence)
	fmt.Fprintf(writer, "  evidence attempts\t%d\n", output.Counts.EvidenceAttempts)
	fmt.Fprintf(writer, "  claims\t%d\n", output.Counts.Claims)
	fmt.Fprintf(writer, "  stale claims\t%d\n", output.Counts.StaleClaims)
	fmt.Fprintf(writer, "  inbox\t%d\n", output.Counts.Inbox)
	fmt.Fprintf(writer, "  outbox\t%d\n", output.Counts.Outbox)
	fmt.Fprintf(writer, "  dead-letter\t%d\n", output.Counts.DeadLetter)
	fmt.Fprintf(writer, "  queue tasks\t%d\n", output.Counts.QueueTasks)
	fmt.Fprintf(writer, "  projects\t%d\n", output.Counts.Projects)

	if len(output.Recent) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintln(writer, "recent activity")
		fmt.Fprintln(writer, "  TIME\tSOURCE\tID\tAGENT\tSTATUS\tTITLE")
		for _, activity := range output.Recent {
			fmt.Fprintf(writer, "  %s\t%s\t%s\t%s\t%s\t%s\n",
				state.FormatTime(activity.Time), activity.Source, activity.ID,
				activity.Agent, activity.Status, activity.Title)
		}
	}

	if len(output.Warnings) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintf(writer, "warnings (%d)\n", len(output.Warnings))
		for _, warning := range output.Warnings {
			fmt.Fprintf(writer, "  %s\n", warning)
		}
	}

	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// tasks
// ---------------------------------------------------------------------------

type taskRow struct {
	Source   string `json:"source"`
	Project  string `json:"project,omitempty"`
	ID       string `json:"id"`
	Priority string `json:"priority,omitempty"`
	Status   string `json:"status,omitempty"`
	Agent    string `json:"agent,omitempty"`
	Title    string `json:"title,omitempty"`
	Created  string `json:"created_at,omitempty"`
}

func runTasks(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("tasks", stderr)
	agentFilter := flags.String("agent", "", "only tasks assigned to this agent")
	statusFilter := flags.String("status", "", "only tasks with this status (queued, assigned, in_progress, done, dead, evidence)")
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	snapshot := loadSnapshot(root, version, 0, time.Now(), stderr)
	rows := collectTaskRows(snapshot)
	rows = filterTaskRows(rows, strings.TrimSpace(*agentFilter), strings.TrimSpace(*statusFilter))

	if globals.json {
		if rows == nil {
			rows = []taskRow{}
		}
		if !writeJSON(stdout, rows) {
			return 1
		}
		return 0
	}

	if len(rows) == 0 {
		fmt.Fprintln(stdout, "no tasks")
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "SOURCE\tPROJECT\tID\tPRIORITY\tSTATUS\tAGENT\tTITLE")
	for _, row := range rows {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			row.Source, row.Project, row.ID, row.Priority, row.Status, row.Agent, row.Title)
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

// collectTaskRows merges queued project tasks with evidence-only identifiers,
// so the command also shows work that has machine evidence but no queue entry.
func collectTaskRows(snapshot *state.Snapshot) []taskRow {
	rows := make([]taskRow, 0)
	queued := make(map[string]struct{})

	for _, task := range snapshot.Tasks() {
		queued[task.ID] = struct{}{}
		created := task.CreatedAt
		if parsed, ok := state.ParseTime(created); ok {
			created = parsed.Format(time.RFC3339)
		}
		rows = append(rows, taskRow{
			Source:   "queue",
			Project:  task.Project,
			ID:       task.ID,
			Priority: task.Priority,
			Status:   task.Status,
			Agent:    task.AssignedAgent,
			Title:    task.Title,
			Created:  created,
		})
	}

	for _, doc := range snapshot.Evidence {
		if _, exists := queued[doc.TaskID]; exists {
			continue
		}
		agents := doc.Agents()
		agent := ""
		if len(agents) > 0 {
			agent = strings.Join(agents, ",")
		}
		status := "evidence"
		if len(doc.Attempts) > 0 {
			last := doc.Attempts[len(doc.Attempts)-1]
			if last.Status != "" {
				status = last.Status
			}
		}
		rows = append(rows, taskRow{
			Source: "evidence",
			ID:     doc.TaskID,
			Status: status,
			Agent:  agent,
		})
	}

	return rows
}

func filterTaskRows(rows []taskRow, agentFilter, statusFilter string) []taskRow {
	filtered := make([]taskRow, 0, len(rows))
	for _, row := range rows {
		if agentFilter != "" && !containsAgent(row.Agent, agentFilter) {
			continue
		}
		if statusFilter != "" && !strings.EqualFold(row.Status, statusFilter) && !strings.EqualFold(row.Source, statusFilter) {
			continue
		}
		filtered = append(filtered, row)
	}
	return filtered
}

// containsAgent matches a single agent name against a comma-separated list.
func containsAgent(agentList, wanted string) bool {
	for _, candidate := range strings.Split(agentList, ",") {
		if strings.EqualFold(strings.TrimSpace(candidate), wanted) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// leases
// ---------------------------------------------------------------------------

func runLeases(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("leases", stderr)
	ttl := flags.Int("ttl", 0, "lease TTL override in seconds (0 = per-claim lease_seconds)")
	staleOnly := flags.Bool("stale", false, "show only stale leases")
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	ttlOverride := time.Duration(0)
	if *ttl > 0 {
		ttlOverride = time.Duration(*ttl) * time.Second
	}
	snapshot := loadSnapshot(root, version, ttlOverride, time.Now(), stderr)

	claims := make([]state.ClaimStatus, 0, len(snapshot.Claims))
	for _, claim := range snapshot.Claims {
		if *staleOnly && !claim.Stale {
			continue
		}
		claims = append(claims, claim)
	}

	if globals.json {
		if !writeJSON(stdout, claims) {
			return 1
		}
		return 0
	}

	if len(claims) == 0 {
		fmt.Fprintln(stdout, "no leases")
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "TASK\tAGENT\tATTEMPT\tHEARTBEAT-AGE\tTTL\tSTATE\tREASON")
	for _, claim := range claims {
		stateLabel := "active"
		if claim.Stale {
			stateLabel = "STALE"
		}
		fmt.Fprintf(writer, "%s\t%s\t%d\t%s\t%ds\t%s\t%s\n",
			claim.TaskID, claim.Agent, claim.Attempt,
			state.FormatAge(time.Duration(claim.HeartbeatAgeSeconds)*time.Second),
			claim.TTLSeconds, stateLabel, claim.Reason)
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// evidence
// ---------------------------------------------------------------------------

type evidenceAttemptView struct {
	Index        int    `json:"index"`
	AttemptID    string `json:"attempt_id,omitempty"`
	Agent        string `json:"agent,omitempty"`
	Status       string `json:"status,omitempty"`
	ExitCode     int    `json:"exit_code"`
	DurationMS   int64  `json:"duration_ms"`
	StartedAt    string `json:"started_at,omitempty"`
	FinishedAt   string `json:"finished_at,omitempty"`
	StdoutLength int    `json:"stdout_length"`
	StderrLength int    `json:"stderr_length"`
	StdoutSHA256 string `json:"stdout_sha256,omitempty"`
	StderrSHA256 string `json:"stderr_sha256,omitempty"`
	Reason       string `json:"reason,omitempty"`
}

type evidenceOutput struct {
	TaskID   string                `json:"task_id"`
	Found    bool                  `json:"found"`
	Path     string                `json:"path,omitempty"`
	Attempts []evidenceAttemptView `json:"attempts"`
	Warnings []string              `json:"warnings"`
}

func runEvidence(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("evidence", stderr)
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}

	remainder := flags.Args()
	if len(remainder) != 1 {
		fmt.Fprintf(stderr, "usage: %s evidence <id> [-json] [-root <path>]\n", cliName)
		return 2
	}
	taskID := remainder[0]

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	snapshot := loadSnapshot(root, version, 0, time.Now(), stderr)
	doc, found := snapshot.EvidenceByTaskID(taskID)

	output := evidenceOutput{TaskID: taskID, Found: found, Attempts: []evidenceAttemptView{}, Warnings: []string{}}
	if found {
		output.Path = doc.Path
		for index, attempt := range doc.Attempts {
			output.Attempts = append(output.Attempts, evidenceAttemptView{
				Index:        index + 1,
				AttemptID:    attempt.AttemptID,
				Agent:        attempt.Agent,
				Status:       attempt.Status,
				ExitCode:     attempt.ExitCodeValue(),
				DurationMS:   attempt.DurationMillis(),
				StartedAt:    attempt.StartedAt,
				FinishedAt:   attempt.FinishedAt,
				StdoutLength: attempt.StdoutBytes(),
				StderrLength: attempt.StderrBytes(),
				StdoutSHA256: attempt.StdoutSHA256,
				StderrSHA256: attempt.StderrSHA256,
				Reason:       attempt.Reason,
			})
		}
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		if !found {
			return 1
		}
		return 0
	}

	if !found {
		fmt.Fprintf(stdout, "no evidence document for %q\n", taskID)
		for _, warning := range snapshot.Warnings {
			fmt.Fprintf(stdout, "  warning: %s\n", warning)
		}
		return 1
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "task:\t%s\n", output.TaskID)
	fmt.Fprintf(writer, "path:\t%s\n", output.Path)
	fmt.Fprintf(writer, "attempts:\t%d\n", len(output.Attempts))
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "  #\tATTEMPT\tAGENT\tSTATUS\tEXIT\tDURATION\tSTDOUT\tSTDERR\tSTARTED")
	for _, attempt := range output.Attempts {
		fmt.Fprintf(writer, "  %d\t%s\t%s\t%s\t%d\t%dms\t%d b\t%d b\t%s\n",
			attempt.Index, attempt.AttemptID, attempt.Agent, attempt.Status,
			attempt.ExitCode, attempt.DurationMS, attempt.StdoutLength, attempt.StderrLength,
			state.FormatTime(attempt.StartedAt))
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

type doctorOutput struct {
	Version  string        `json:"version"`
	Root     string        `json:"root"`
	OK       bool          `json:"ok"`
	Checks   []state.Check `json:"checks"`
	Warnings []string      `json:"warnings"`
}

func runDoctor(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("doctor", stderr)
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	snapshot := state.Load(root, version, 0, time.Now())
	checks := state.Doctor(root, snapshot)
	checks = append(checks, netChecks(root)...)
	healthy := state.DoctorOK(checks)

	output := doctorOutput{
		Version:  version,
		Root:     root,
		OK:       healthy,
		Checks:   checks,
		Warnings: snapshot.Warnings,
	}
	if output.Warnings == nil {
		output.Warnings = []string{}
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		if !healthy {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s %s\n", cliName, output.Version)
	fmt.Fprintf(writer, "root:\t%s\n", output.Root)
	if healthy {
		fmt.Fprintln(writer, "verdict:\tok")
	} else {
		fmt.Fprintln(writer, "verdict:\tFAILED")
	}
	fmt.Fprintln(writer)
	for _, check := range checks {
		fmt.Fprintf(writer, "  %s\t%s\t%s\n", check.Status, check.Name, check.Detail)
	}
	if len(output.Warnings) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintf(writer, "warnings (%d)\n", len(output.Warnings))
		for _, warning := range output.Warnings {
			fmt.Fprintf(writer, "  %s\n", warning)
		}
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	if !healthy {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// index
// ---------------------------------------------------------------------------

type indexOutput struct {
	Root          string       `json:"root"`
	Database      string       `json:"database"`
	SchemaVersion int          `json:"schema_version"`
	IndexedAt     string       `json:"indexed_at"`
	Counts        store.Counts `json:"counts"`
	Warnings      []string     `json:"warnings"`
}

func runIndex(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("index", stderr)
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	memoryDir := state.MemoryDir(root)
	if info, err := os.Stat(memoryDir); err != nil || !info.IsDir() {
		fmt.Fprintf(stderr, "%s: %s is missing; refusing to index a path that does not look like an agent-hq root\n", cliName, memoryDir)
		return 1
	}

	now := time.Now()
	snapshot := state.Load(root, version, 0, now)
	fingerprint, err := store.Fingerprint(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot fingerprint state: %v\n", cliName, err)
		return 1
	}

	handle, err := store.Open(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot open index: %v\n", cliName, err)
		return 1
	}
	defer func() { _ = handle.Close() }()

	counts, err := handle.Index(snapshot, fingerprint, now)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot index state: %v\n", cliName, err)
		return 1
	}

	output := indexOutput{
		Root:          root,
		Database:      handle.Path(),
		SchemaVersion: store.SchemaVersion,
		IndexedAt:     now.Format(time.RFC3339),
		Counts:        counts,
		Warnings:      snapshot.Warnings,
	}
	if output.Warnings == nil {
		output.Warnings = []string{}
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s index\n", cliName)
	fmt.Fprintf(writer, "root:\t%s\n", output.Root)
	fmt.Fprintf(writer, "database:\t%s\n", output.Database)
	fmt.Fprintf(writer, "schema:\t%d\n", output.SchemaVersion)
	fmt.Fprintf(writer, "indexed:\t%s\n", output.IndexedAt)
	fmt.Fprintln(writer)
	fmt.Fprintf(writer, "  projects\t%d\n", counts.Projects)
	fmt.Fprintf(writer, "  tasks\t%d\n", counts.Tasks)
	fmt.Fprintf(writer, "  evidence\t%d (%d attempts)\n", counts.Evidence, counts.EvidenceAttempts)
	fmt.Fprintf(writer, "  claims\t%d\n", counts.Claims)
	fmt.Fprintf(writer, "  messages\t%d\n", counts.Messages)
	if len(output.Warnings) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintf(writer, "warnings (%d)\n", len(output.Warnings))
		for _, warning := range output.Warnings {
			fmt.Fprintf(writer, "  %s\n", warning)
		}
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// db status
// ---------------------------------------------------------------------------

func runDB(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: %s db status [-json] [-root <path>]\n", cliName)
		return 2
	}
	switch strings.ToLower(args[0]) {
	case "status":
		return runDBStatus(globals, args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "%s: unknown db subcommand %q\n\nusage: %s db status\n", cliName, args[0], cliName)
		return 2
	}
}

type dbStatusOutput struct {
	Path          string         `json:"path"`
	Exists        bool           `json:"exists"`
	SchemaVersion int            `json:"schema_version,omitempty"`
	IndexedAt     string         `json:"indexed_at,omitempty"`
	Fresh         bool           `json:"fresh"`
	SizeBytes     int64          `json:"size_bytes,omitempty"`
	Counts        store.Counts   `json:"counts"`
	MessageScopes map[string]int `json:"message_scopes,omitempty"`
	Warning       string         `json:"warning,omitempty"`
}

func runDBStatus(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("db status", stderr)
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	path := store.Path(root)
	output := dbStatusOutput{Path: path, Counts: store.Counts{}}

	info, statErr := os.Stat(path)
	if statErr != nil || info.IsDir() {
		output.Warning = "no index yet; run: agent-hq index"
		if globals.json {
			if !writeJSON(stdout, output) {
				return 1
			}
			return 1
		}
		fmt.Fprintf(stdout, "no index database at %s\nrun: %s index\n", path, cliName)
		return 1
	}
	output.Exists = true
	output.SizeBytes = info.Size()

	handle, err := store.OpenReadOnly(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot open index: %v\n", cliName, err)
		return 1
	}
	defer func() { _ = handle.Close() }()

	schemaVersion, err := handle.SchemaVersion()
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot read schema version: %v\n", cliName, err)
		return 1
	}
	output.SchemaVersion = schemaVersion

	if indexedAt, found, err := handle.IndexedAt(); err == nil && found {
		output.IndexedAt = indexedAt.Format(time.RFC3339)
	}

	if schemaVersion == store.SchemaVersion {
		counts, err := handle.Counts()
		if err != nil {
			fmt.Fprintf(stderr, "%s: cannot count index rows: %v\n", cliName, err)
			return 1
		}
		output.Counts = counts
		if scopes, err := handle.MessageCountsByScope(); err == nil {
			output.MessageScopes = scopes
		}
		if fresh, err := handle.IsFresh(); err == nil {
			output.Fresh = fresh
		}
	} else {
		output.Warning = fmt.Sprintf("schema version %d is not supported by this CLI (want %d); run: %s index", schemaVersion, store.SchemaVersion, cliName)
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s db status\n", cliName)
	fmt.Fprintf(writer, "database:\t%s\n", output.Path)
	fmt.Fprintf(writer, "exists:\t%t\n", output.Exists)
	fmt.Fprintf(writer, "schema:\t%d\n", output.SchemaVersion)
	if output.IndexedAt != "" {
		fmt.Fprintf(writer, "indexed:\t%s\n", output.IndexedAt)
	}
	fmt.Fprintf(writer, "fresh:\t%t\n", output.Fresh)
	fmt.Fprintf(writer, "size:\t%d b\n", output.SizeBytes)
	fmt.Fprintln(writer)
	fmt.Fprintf(writer, "  projects\t%d\n", output.Counts.Projects)
	fmt.Fprintf(writer, "  tasks\t%d\n", output.Counts.Tasks)
	fmt.Fprintf(writer, "  evidence\t%d (%d attempts)\n", output.Counts.Evidence, output.Counts.EvidenceAttempts)
	fmt.Fprintf(writer, "  claims\t%d\n", output.Counts.Claims)
	fmt.Fprintf(writer, "  messages\t%d\n", output.Counts.Messages)
	if len(output.MessageScopes) > 0 {
		for _, scope := range []string{"inbox", "outbox", "dead-letter"} {
			if count, ok := output.MessageScopes[scope]; ok {
				fmt.Fprintf(writer, "    %s\t%d\n", scope, count)
			}
		}
	}
	if output.Warning != "" {
		fmt.Fprintln(writer)
		fmt.Fprintf(writer, "warning:\t%s\n", output.Warning)
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}
