package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"agent-hq/internal/driver"
	"agent-hq/internal/loop"
	"agent-hq/internal/state"
)

// runloop.go is the M5 cut-over entry point: `agent-hq run-loop` drives the bus
// the PowerShell engine owns, and `agent-hq driver` flips the switch between the
// two drivers. Default is PowerShell: with no mode file the Go loop refuses to
// daemonise and the scheduled PowerShell poller stays in charge.

type runLoopOptions struct {
	once     bool
	max      int
	interval int
	executor string
	queue    bool
}

func runRunLoop(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("run-loop", stderr)
	once := flags.Bool("once", false, "run a single pass and exit")
	maxItems := flags.Int("max", 0, "process at most N items per pass (0 = all pending)")
	interval := flags.Int("interval", int(loop.DefaultInterval/time.Second), "seconds between passes in daemon mode")
	executorName := flags.String("executor", "opencode", "worker executor: opencode or fake")
	queue := flags.Bool("queue", true, "also dispatch pending project queue tasks")
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}
	options := runLoopOptions{once: *once, max: *maxItems, interval: *interval, executor: *executorName, queue: *queue}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	if err := state.ValidateRoot(root); err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 1
	}

	mode, source, warning := driver.Resolve(root)
	if warning != "" {
		fmt.Fprintf(stderr, "%s: %s\n", cliName, warning)
	}
	if !options.once && mode != driver.ModeGo {
		fmt.Fprintf(stdout, "%s: driver mode is %q (from %s); nothing to do.\n", cliName, mode, source)
		fmt.Fprintf(stdout, "Enable the Go driver with: %s driver -set go\n", cliName)
		return 0
	}

	worker, err := buildExecutor(options.executor, root)
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 2
	}

	logger := newLoopLogger(stderr, globals.json)
	runner, err := loop.New(loop.Options{
		Root:       root,
		Executor:   worker,
		Max:        options.max,
		Once:       options.once,
		Interval:   time.Duration(options.interval) * time.Second,
		DriverMode: mode,
		Queue:      options.queue,
		Logger:     logger,
	})
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 1
	}
	defer func() { _ = runner.Close() }()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger("run-loop start: root=%s mode=%s executor=%s queue=%t", root, mode, worker.Name(), options.queue)
	report := runner.Run(ctx)
	logger("run-loop done: passes=%d processed=%d done=%d dead-letter=%d skipped=%d errors=%d",
		report.Passes, report.Processed, report.Done, report.DeadLetter, report.Skipped, report.Errors)

	if globals.json {
		if !writeJSON(stdout, report) {
			return 1
		}
		return 0
	}
	printRunLoopReport(stdout, report)
	if report.Errors > 0 {
		return 1
	}
	return 0
}

func printRunLoopReport(stdout io.Writer, report *loop.Report) {
	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s run-loop (driver: %s)\n", cliName, report.DriverMode)
	fmt.Fprintf(writer, "root:\t%s\n", report.Root)
	fmt.Fprintf(writer, "executor:\t%s\n", report.Executor)
	fmt.Fprintf(writer, "started:\t%s\n", report.StartedAt)
	fmt.Fprintf(writer, "finished:\t%s\n", report.FinishedAt)
	fmt.Fprintln(writer)
	fmt.Fprintf(writer, "  passes\t%d\n", report.Passes)
	fmt.Fprintf(writer, "  processed\t%d\n", report.Processed)
	fmt.Fprintf(writer, "  done\t%d\n", report.Done)
	fmt.Fprintf(writer, "  dead-letter\t%d\n", report.DeadLetter)
	fmt.Fprintf(writer, "  skipped\t%d\n", report.Skipped)
	fmt.Fprintf(writer, "  errors\t%d\n", report.Errors)
	if len(report.Recovered) > 0 {
		fmt.Fprintf(writer, "  recovered\t%d\n", len(report.Recovered))
	}

	if len(report.Items) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintln(writer, "SOURCE\tPROJECT\tTASK\tAGENT\tSTATUS\tATTEMPTS\tREASON")
		for _, item := range report.Items {
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%d\t%s\n",
				item.Source, item.Project, item.TaskID, item.Agent, item.Status, item.Attempts, item.Reason)
		}
	}
	if len(report.Warnings) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintf(writer, "warnings (%d)\n", len(report.Warnings))
		for _, warning := range report.Warnings {
			fmt.Fprintf(writer, "  %s\n", warning)
		}
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(os.Stderr, "%s: cannot write output: %v\n", cliName, err)
	}
}

// newLoopLogger returns the progress sink: human lines go to stderr so -json
// output on stdout stays machine-readable.
func newLoopLogger(stderr io.Writer, quiet bool) func(string, ...any) {
	return func(format string, args ...any) {
		if quiet {
			return
		}
		fmt.Fprintf(stderr, "%s\n", fmt.Sprintf(format, args...))
	}
}

// ---------------------------------------------------------------------------
// driver
// ---------------------------------------------------------------------------

type driverOutput struct {
	Mode      string `json:"mode"`
	Source    string `json:"source"`
	GoAlive   bool   `json:"go_alive"`
	LockPID   int    `json:"lock_pid,omitempty"`
	LockAgeMS int64  `json:"lock_age_ms,omitempty"`
	ModePath  string `json:"mode_path"`
	LockPath  string `json:"lock_path"`
	Warning   string `json:"warning,omitempty"`
}

func runDriver(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("driver", stderr)
	set := flags.String("set", "", "switch the driver: go or ps")
	clear := flags.Bool("clear", false, "remove the mode file (back to the ps default)")
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}
	if flags.NArg() > 0 {
		fmt.Fprintf(stderr, "usage: %s driver [-set go|ps] [-clear] [-json]\n", cliName)
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	if err := state.ValidateRoot(root); err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 1
	}

	if *clear {
		if err := driver.Clear(root); err != nil {
			fmt.Fprintf(stderr, "%s: cannot clear mode: %v\n", cliName, err)
			return 1
		}
	} else if strings.TrimSpace(*set) != "" {
		if err := driver.Write(root, *set); err != nil {
			fmt.Fprintf(stderr, "%s: %v (want go or ps)\n", cliName, err)
			return 2
		}
	}

	mode, source, warning := driver.Resolve(root)
	output := driverOutput{
		Mode:     mode,
		Source:   source,
		GoAlive:  mode == driver.ModeGo && driver.Alive(root, driver.DefaultLockTTL),
		ModePath: driver.ModePath(root),
		LockPath: driver.LockPath(root),
		Warning:  warning,
	}
	if lock, found := driver.ReadLock(root); found {
		output.LockPID = lock.PID
		if heartbeat, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(lock.HeartbeatAt)); err == nil {
			output.LockAgeMS = time.Since(heartbeat).Milliseconds()
		}
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s driver\n", cliName)
	fmt.Fprintf(writer, "mode:\t%s\n", output.Mode)
	fmt.Fprintf(writer, "source:\t%s\n", output.Source)
	fmt.Fprintf(writer, "go-heartbeat:\t%t\n", output.GoAlive)
	if output.LockPID != 0 {
		fmt.Fprintf(writer, "go-pid:\t%d\n", output.LockPID)
		fmt.Fprintf(writer, "lock-age:\t%v\n", time.Duration(output.LockAgeMS)*time.Millisecond)
	}
	fmt.Fprintf(writer, "mode-file:\t%s\n", output.ModePath)
	fmt.Fprintf(writer, "lock-file:\t%s\n", output.LockPath)
	if output.Warning != "" {
		fmt.Fprintf(writer, "warning:\t%s\n", output.Warning)
	}
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "ps is the default; the PowerShell poller stands down only while")
	fmt.Fprintln(writer, "mode=go AND the Go heartbeat is fresh (a crash falls back to ps).")
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}
