package main

import (
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"

	"agent-hq/internal/worktree"
)

// runWorktree dispatches the per-project worktree commands. They are safe by
// construction: the package validates every name and refuses any path outside
// <root>/projects/<name>/ or <root>/.agents/worktrees/<name>/.
func runWorktree(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: %s worktree list|add <name>|remove <name> [-force] [-json] [-root <path>]\n", cliName)
		return 2
	}
	switch strings.ToLower(args[0]) {
	case "list":
		return runWorktreeList(globals, args[1:], stdout, stderr)
	case "add":
		return runWorktreeAdd(globals, args[1:], stdout, stderr)
	case "remove":
		return runWorktreeRemove(globals, args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "%s: unknown worktree subcommand %q\n\nusage: %s worktree list|add <name>|remove <name>\n",
			cliName, args[0], cliName)
		return 2
	}
}

func runWorktreeList(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("worktree list", stderr)
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}
	if len(flags.Args()) != 0 {
		fmt.Fprintf(stderr, "usage: %s worktree list [-json] [-root <path>]\n", cliName)
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	statuses, err := worktree.List(root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot list worktrees: %v\n", cliName, err)
		return 1
	}

	if globals.json {
		if !writeJSON(stdout, statuses) {
			return 1
		}
		return 0
	}
	if len(statuses) == 0 {
		fmt.Fprintln(stdout, "no project worktrees")
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "PROJECT\tPATH\tBRANCH\tEXISTS\tREGISTERED")
	for _, status := range statuses {
		registered := status.RegisteredBranch
		if status.Registered && registered == "" {
			registered = "yes"
		}
		if status.Error != "" {
			registered = "ERROR: " + status.Error
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%t\t%s\n",
			status.Project, status.Path, status.Branch, status.Exists, registered)
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

func runWorktreeAdd(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("worktree add", stderr)
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}
	rest := flags.Args()
	if len(rest) != 1 {
		fmt.Fprintf(stderr, "usage: %s worktree add <name> [-json] [-root <path>]\n", cliName)
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	result, err := worktree.Add(root, rest[0])
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 2
	}

	if globals.json {
		if !writeJSON(stdout, result) {
			return 1
		}
	} else {
		fmt.Fprintf(stdout, "%s: mode=%s created=%t\n", result.Project, result.Mode, result.Created)
		fmt.Fprintf(stdout, "  path: %s\n  branch: %s\n", result.Path, result.Branch)
		if result.Reason != "" {
			fmt.Fprintf(stdout, "  reason: %s\n", result.Reason)
		}
	}
	if !result.OK {
		fmt.Fprintf(stderr, "%s: %s\n", cliName, result.Reason)
		return 1
	}
	return 0
}

func runWorktreeRemove(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	// -force is accepted before or after the project name, as documented
	// (`worktree remove <name> [-force]`), so it is extracted by hand instead
	// of relying on flag.Parse, which stops at the first positional argument.
	force, rest := extractForceFlag(args)
	if len(rest) != 1 {
		fmt.Fprintf(stderr, "usage: %s worktree remove <name> [-force] [-json] [-root <path>]\n", cliName)
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	result, err := worktree.Remove(root, rest[0], force)
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 2
	}

	if globals.json {
		if !writeJSON(stdout, result) {
			return 1
		}
	} else {
		fmt.Fprintf(stdout, "%s: removed=%t\n", result.Project, result.Removed)
		if result.Reason != "" {
			fmt.Fprintf(stdout, "  reason: %s\n", result.Reason)
		}
	}
	if !result.OK {
		fmt.Fprintf(stderr, "%s: %s\n", cliName, result.Reason)
		return 1
	}
	return 0
}

// projectBufferOutput is the JSON shape of `project buffer`.
type projectBufferOutput struct {
	Project string `json:"project"`
	Exists  bool   `json:"exists"`
	Path    string `json:"path,omitempty"`
	Content string `json:"content"`
}

// runProject dispatches project-scoped shared memory commands.
func runProject(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintf(stderr, "usage: %s project buffer <name> [-tail N] [-append <text> -source <name>] [-json] [-root <path>]\n", cliName)
		return 2
	}
	switch strings.ToLower(args[0]) {
	case "buffer":
		return runProjectBuffer(globals, args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "%s: unknown project subcommand %q\n\nusage: %s project buffer <name>\n",
			cliName, args[0], cliName)
		return 2
	}
}

// runProjectBuffer is read-mostly: without -append it only reports the tail of
// the project's CONTEXT-BUFFER.md. With -append it appends guarded text; the
// leak guard rejects a -source that names a different project.
func runProjectBuffer(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	// The documented order is `project buffer <name> [-tail N]`, so the flags
	// are extracted by hand: flag.Parse would stop at the project name.
	options, rest, err := extractBufferOptions(args)
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 2
	}
	if len(rest) != 1 {
		fmt.Fprintf(stderr, "usage: %s project buffer <name> [-tail N] [-append <text> -source <name>]\n", cliName)
		return 2
	}
	project := rest[0]

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	if options.appendSet || options.sourceSet {
		result, err := worktree.AppendBuffer(root, project, options.appendText, options.source, false)
		if err != nil {
			fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
			return 2
		}
		if globals.json {
			if !writeJSON(stdout, result) {
				return 1
			}
		} else if result.OK {
			fmt.Fprintf(stdout, "appended to %s (%d chars)\n", result.Path, result.Bytes)
		}
		if !result.OK {
			fmt.Fprintf(stderr, "%s: %s\n", cliName, result.Reason)
			return 1
		}
		return 0
	}

	content, found, err := worktree.ReadBuffer(root, project)
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 2
	}
	path, pathErr := worktree.BufferPath(root, project)
	if pathErr != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, pathErr)
		return 2
	}

	output := projectBufferOutput{Project: project, Exists: found, Content: tailContent(content, options.tail)}
	if found {
		output.Path = path
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
		fmt.Fprintf(stdout, "no buffer for %q (expected at %s)\n", project, path)
		return 1
	}
	fmt.Fprint(stdout, output.Content)
	if !strings.HasSuffix(output.Content, "\n") {
		fmt.Fprintln(stdout)
	}
	return 0
}

// bufferOptions carries the flags of `project buffer`, wherever they appear.
type bufferOptions struct {
	tail       int
	appendText string
	appendSet  bool
	source     string
	sourceSet  bool
}

// extractBufferOptions reads -tail, -append and -source in the bare and =
// forms from anywhere in args.
func extractBufferOptions(args []string) (bufferOptions, []string, error) {
	options := bufferOptions{}
	rest := make([]string, 0, len(args))

	for index := 0; index < len(args); index++ {
		arg := args[index]
		lower := strings.ToLower(arg)
		switch {
		case lower == "-tail" || lower == "--tail":
			if index+1 >= len(args) {
				return options, rest, fmt.Errorf("-tail needs a value")
			}
			value, err := strconv.Atoi(args[index+1])
			if err != nil {
				return options, rest, fmt.Errorf("-tail needs an integer: %v", err)
			}
			options.tail = value
			index++
		case strings.HasPrefix(lower, "-tail=") || strings.HasPrefix(lower, "--tail="):
			value, err := strconv.Atoi(arg[strings.Index(arg, "=")+1:])
			if err != nil {
				return options, rest, fmt.Errorf("-tail needs an integer: %v", err)
			}
			options.tail = value
		case lower == "-append" || lower == "--append":
			if index+1 >= len(args) {
				return options, rest, fmt.Errorf("-append needs a value")
			}
			options.appendText = args[index+1]
			options.appendSet = true
			index++
		case strings.HasPrefix(lower, "-append=") || strings.HasPrefix(lower, "--append="):
			options.appendText = arg[strings.Index(arg, "=")+1:]
			options.appendSet = true
		case lower == "-source" || lower == "--source":
			if index+1 >= len(args) {
				return options, rest, fmt.Errorf("-source needs a value")
			}
			options.source = args[index+1]
			options.sourceSet = true
			index++
		case strings.HasPrefix(lower, "-source=") || strings.HasPrefix(lower, "--source="):
			options.source = arg[strings.Index(arg, "=")+1:]
			options.sourceSet = true
		default:
			rest = append(rest, arg)
		}
	}
	return options, rest, nil
}

// extractForceFlag pulls -force/--force out of args, wherever it appears.
func extractForceFlag(args []string) (bool, []string) {
	force := false
	rest := make([]string, 0, len(args))
	for _, arg := range args {
		lower := strings.ToLower(arg)
		if lower == "-force" || lower == "--force" {
			force = true
			continue
		}
		rest = append(rest, arg)
	}
	return force, rest
}

// tailContent returns the last n lines of content. A non-positive n means the
// whole content; a content with fewer lines is returned unchanged.
func tailContent(content string, n int) string {
	if n <= 0 || content == "" {
		return content
	}
	lines := strings.Split(content, "\n")
	if len(lines) <= n {
		return content
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}
