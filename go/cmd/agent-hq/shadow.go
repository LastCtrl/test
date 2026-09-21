package main

import (
	"fmt"
	"io"
	"text/tabwriter"
	"time"

	"agent-hq/internal/shadow"
)

// runShadow implements the M5 read-only shadow pass. It scans the same inbox
// and project queues the PowerShell engine owns, records what a Go control
// plane would do and returns without claiming a lease or starting a worker.
func runShadow(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	flags := newFlagSet("shadow", stderr)
	once := flags.Bool("once", false, "run a single read-only pass (default; no daemon is started)")
	summaryOnly := flags.Bool("summary", false, "print the summary only")
	if ok, helpHandled := parseFlags(flags, args); !ok {
		if helpHandled {
			return 0
		}
		return 2
	}
	// The shadow is deliberately single-shot: -once documents the intent and no
	// background loop or ticker is ever started.
	_ = once

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}

	now := time.Now()
	report := shadow.Build(root, version, now)
	report.Path = shadow.ReportPath(root, now)
	if err := shadow.Write(report.Path, report); err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", cliName, err)
		return 1
	}

	if globals.json {
		if !writeJSON(stdout, report) {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	if !*summaryOnly {
		fmt.Fprintf(writer, "%s shadow (read-only)\n", cliName)
		fmt.Fprintf(writer, "root:\t%s\n", report.Root)
		fmt.Fprintf(writer, "created:\t%s\n", report.CreatedAt)
		fmt.Fprintln(writer)
		if len(report.Steps) == 0 {
			fmt.Fprintln(writer, "no pending work")
		} else {
			fmt.Fprintln(writer, "SOURCE\tTASK\tPROJECT\tAGENT\tMODEL\tEXECUTOR\tROUTE\tACTION\tREASON")
			for _, step := range report.Steps {
				fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
					step.Source, step.TaskID, step.Project, step.Agent, step.Model,
					step.Executor, step.Route, step.Action, step.Reason)
			}
		}
		fmt.Fprintln(writer)
	}
	printShadowSummary(writer, report)
	fmt.Fprintf(writer, "report:\t%s\n", report.Path)
	if len(report.Warnings) > 0 {
		fmt.Fprintf(writer, "warnings:\t%d\n", len(report.Warnings))
		for _, warning := range report.Warnings {
			fmt.Fprintf(writer, "  %s\n", warning)
		}
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

func printShadowSummary(writer io.Writer, report *shadow.Report) {
	summary := report.Summary
	fmt.Fprintln(writer, "summary")
	fmt.Fprintf(writer, "  total\t%d\n", summary.Total)
	fmt.Fprintf(writer, "  would-run\t%d\n", summary.WouldRun)
	fmt.Fprintf(writer, "  would-skip\t%d\n", summary.WouldSkip)
	fmt.Fprintf(writer, "  processed-by-ps\t%d\n", summary.ProcessedByPS)
	fmt.Fprintf(writer, "  inbox\t%d\n", summary.Inbox)
	fmt.Fprintf(writer, "  queue\t%d\n", summary.Queue)
}
