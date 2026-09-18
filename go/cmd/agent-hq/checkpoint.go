package main

import (
	"fmt"
	"io"
	"strings"
	"text/tabwriter"

	"agent-hq/internal/store"
)

// checkpointOptions carries the flags of `checkpoint save`.
type checkpointOptions struct {
	state string
	path  string
}

// runCheckpoint dispatches the minimal checkpoint API: save appends a handoff
// point, list returns the history and latest returns the newest one. All three
// read or write only this root's SQLite database.
func runCheckpoint(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: %s checkpoint save|list|latest <run-id> [-state <text>] [-path <artifact>] [-json] [-root <path>]\n", cliName)
		return 2
	}
	switch strings.ToLower(args[0]) {
	case "save":
		return runCheckpointSave(globals, args[1:], stdout, stderr)
	case "list":
		return runCheckpointList(globals, args[1:], stdout, stderr)
	case "latest":
		return runCheckpointLatest(globals, args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "%s: unknown checkpoint subcommand %q\n\nusage: %s checkpoint save|list|latest <run-id>\n", cliName, args[0], cliName)
		return 2
	}
}

func runCheckpointSave(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	options, rest := extractCheckpointOptions(args)
	if len(rest) != 1 {
		fmt.Fprintf(stderr, "usage: %s checkpoint save <run-id> [-state <text>] [-path <artifact>]\n", cliName)
		return 2
	}
	runID := strings.TrimSpace(rest[0])
	if runID == "" {
		fmt.Fprintln(stderr, cliName+": checkpoint save needs a non-empty run id")
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	handle, err := store.Open(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot open state: %v\n", cliName, err)
		return 1
	}
	defer func() { _ = handle.Close() }()

	seq, err := handle.SaveCheckpoint(store.RunCheckpoint{RunID: runID, Path: options.path, State: options.state})
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot save checkpoint: %v\n", cliName, err)
		return 1
	}
	checkpoint, found, err := handle.LatestCheckpoint(runID)
	if err != nil || !found {
		fmt.Fprintf(stderr, "%s: checkpoint %s/%d was not readable back: %v\n", cliName, runID, seq, err)
		return 1
	}

	if globals.json {
		if !writeJSON(stdout, checkpoint) {
			return 1
		}
		return 0
	}
	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "run:\t%s\n", checkpoint.RunID)
	fmt.Fprintf(writer, "seq:\t%d\n", checkpoint.Seq)
	if checkpoint.Path != "" {
		fmt.Fprintf(writer, "path:\t%s\n", checkpoint.Path)
	}
	fmt.Fprintf(writer, "created:\t%s\n", checkpoint.CreatedAt)
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

func runCheckpointList(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	_, rest := extractCheckpointOptions(args)
	if len(rest) != 1 {
		fmt.Fprintf(stderr, "usage: %s checkpoint list <run-id>\n", cliName)
		return 2
	}
	runID := strings.TrimSpace(rest[0])
	if runID == "" {
		fmt.Fprintln(stderr, cliName+": checkpoint list needs a non-empty run id")
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	handle, err := store.Open(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot open state: %v\n", cliName, err)
		return 1
	}
	defer func() { _ = handle.Close() }()

	checkpoints, err := handle.Checkpoints(runID)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot list checkpoints: %v\n", cliName, err)
		return 1
	}

	if globals.json {
		if !writeJSON(stdout, checkpoints) {
			return 1
		}
		return 0
	}
	if len(checkpoints) == 0 {
		fmt.Fprintf(stdout, "no checkpoints for %q\n", runID)
		return 0
	}
	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "SEQ\tPATH\tCREATED\tSTATE")
	for _, checkpoint := range checkpoints {
		fmt.Fprintf(writer, "%d\t%s\t%s\t%s\n", checkpoint.Seq, checkpoint.Path,
			checkpoint.CreatedAt, truncateState(checkpoint.State))
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

func runCheckpointLatest(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	_, rest := extractCheckpointOptions(args)
	if len(rest) != 1 {
		fmt.Fprintf(stderr, "usage: %s checkpoint latest <run-id>\n", cliName)
		return 2
	}
	runID := strings.TrimSpace(rest[0])
	if runID == "" {
		fmt.Fprintln(stderr, cliName+": checkpoint latest needs a non-empty run id")
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	handle, err := store.Open(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot open state: %v\n", cliName, err)
		return 1
	}
	defer func() { _ = handle.Close() }()

	checkpoint, found, err := handle.LatestCheckpoint(runID)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot read latest checkpoint: %v\n", cliName, err)
		return 1
	}
	if !found {
		if globals.json {
			if !writeJSON(stdout, map[string]any{"run_id": runID, "found": false}) {
				return 1
			}
		} else {
			fmt.Fprintf(stdout, "no checkpoints for %q\n", runID)
		}
		return 1
	}

	if globals.json {
		if !writeJSON(stdout, checkpoint) {
			return 1
		}
		return 0
	}
	fmt.Fprintf(stdout, "seq: %d\n", checkpoint.Seq)
	if checkpoint.Path != "" {
		fmt.Fprintf(stdout, "path: %s\n", checkpoint.Path)
	}
	fmt.Fprintf(stdout, "created: %s\n", checkpoint.CreatedAt)
	if checkpoint.State != "" {
		fmt.Fprintf(stdout, "state: %s\n", checkpoint.State)
	}
	return 0
}

// extractCheckpointOptions reads -state and -path in the bare and = forms.
func extractCheckpointOptions(args []string) (checkpointOptions, []string) {
	options := checkpointOptions{}
	rest := make([]string, 0, len(args))

	for index := 0; index < len(args); index++ {
		arg := args[index]
		lower := strings.ToLower(arg)
		switch {
		case lower == "-state" || lower == "--state":
			if index+1 < len(args) {
				options.state = args[index+1]
				index++
			}
		case strings.HasPrefix(lower, "-state=") || strings.HasPrefix(lower, "--state="):
			options.state = arg[strings.Index(arg, "=")+1:]
		case lower == "-path" || lower == "--path":
			if index+1 < len(args) {
				options.path = args[index+1]
				index++
			}
		case strings.HasPrefix(lower, "-path=") || strings.HasPrefix(lower, "--path="):
			options.path = arg[strings.Index(arg, "=")+1:]
		default:
			rest = append(rest, arg)
		}
	}
	return options, rest
}

// truncateState keeps the text listing readable without losing the JSON form,
// which always carries the full state.
func truncateState(value string) string {
	const limit = 60
	collapsed := strings.ReplaceAll(strings.ReplaceAll(value, "\r", " "), "\n", " ")
	// Slice on rune boundaries: a byte-wise cut of limit would split a
	// multi-byte character (Cyrillic, emoji) and emit invalid UTF-8.
	runes := []rune(collapsed)
	if len(runes) <= limit {
		return collapsed
	}
	return string(runes[:limit]) + "..."
}
