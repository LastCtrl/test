package main

import (
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"agent-hq/internal/state"
	"agent-hq/internal/store"
)

// recoverOptions carries the watchdog flags. They are parsed by hand so the
// spelling -requeue / -Requeue / --requeue all work and so the flags may follow
// the command name.
type recoverOptions struct {
	requeue bool
	ttl     int
}

// recoveredAttempt is one stale attempt plus whether this sweep reconciled it.
// A second sweep finds the same row already reconciled and reports it as not
// recovered, which is what makes the command's idempotency observable.
type recoveredAttempt struct {
	store.StaleAttempt
	Recovered bool `json:"recovered"`
}

type recoverOutput struct {
	Root       string             `json:"root"`
	Now        string             `json:"now"`
	Requeue    bool               `json:"requeue"`
	TTLSeconds int                `json:"ttl_seconds,omitempty"`
	Stale      int                `json:"stale"`
	Recovered  int                `json:"recovered"`
	Attempts   []recoveredAttempt `json:"attempts"`
}

// runRecover is the M2 watchdog: it finds running attempts whose lease
// heartbeat expired, marks them stale, releases the lease and (optionally)
// requeues the task. It only touches this root's SQLite database, never the
// PowerShell-managed files.
func runRecover(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	options, rest := extractRecoverOptions(args)
	if len(rest) != 0 {
		fmt.Fprintf(stderr, "usage: %s recover [-requeue] [-ttl <seconds>] [-json] [-root <path>]\n", cliName)
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

	now := time.Now()
	ttlOverride := time.Duration(0)
	if options.ttl > 0 {
		ttlOverride = time.Duration(options.ttl) * time.Second
	}

	stale, err := handle.StaleAttempts(now, ttlOverride)
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot scan for stale attempts: %v\n", cliName, err)
		return 1
	}

	attempts := make([]recoveredAttempt, 0, len(stale))
	recovered := 0
	for _, attempt := range stale {
		done, err := handle.RecoverAttempt(store.RecoverRequest{
			TaskID:  attempt.TaskID,
			Seq:     attempt.Seq,
			Owner:   attempt.Owner,
			Reason:  attempt.Reason,
			Requeue: options.requeue,
			Now:     now,
		})
		if err != nil {
			fmt.Fprintf(stderr, "%s: recover %s/%d: %v\n", cliName, attempt.TaskID, attempt.Seq, err)
			return 1
		}
		if done {
			recovered++
		}
		attempts = append(attempts, recoveredAttempt{StaleAttempt: attempt, Recovered: done})
	}

	output := recoverOutput{
		Root:       root,
		Now:        now.Format(time.RFC3339),
		Requeue:    options.requeue,
		TTLSeconds: options.ttl,
		Stale:      len(stale),
		Recovered:  recovered,
		Attempts:   attempts,
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s recover\n", cliName)
	fmt.Fprintf(writer, "root:\t%s\n", output.Root)
	fmt.Fprintf(writer, "now:\t%s\n", output.Now)
	fmt.Fprintf(writer, "requeue:\t%t\n", output.Requeue)
	fmt.Fprintf(writer, "stale found:\t%d\n", output.Stale)
	fmt.Fprintf(writer, "recovered:\t%d\n", output.Recovered)
	if len(output.Attempts) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintln(writer, "  TASK\tSEQ\tAGENT\tOWNER\tHEARTBEAT-AGE\tTTL\tREASON\tRESULT")
		for _, attempt := range output.Attempts {
			result := "skipped"
			if attempt.Recovered {
				result = "stale"
				if options.requeue {
					result = "requeued"
				}
			}
			fmt.Fprintf(writer, "  %s\t%d\t%s\t%s\t%s\t%ds\t%s\t%s\n",
				attempt.TaskID, attempt.Seq, attempt.Agent, attempt.Owner,
				state.FormatAge(time.Duration(attempt.AgeSeconds)*time.Second),
				attempt.LeaseSeconds, attempt.Reason, result)
		}
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	return 0
}

// extractRecoverOptions accepts -requeue (any case, so -Requeue works too) and
// -ttl, both bare and with an = value.
func extractRecoverOptions(args []string) (recoverOptions, []string) {
	options := recoverOptions{}
	rest := make([]string, 0, len(args))

	for index := 0; index < len(args); index++ {
		arg := args[index]
		lower := strings.ToLower(arg)
		switch {
		case lower == "-requeue" || lower == "--requeue":
			options.requeue = true
		case lower == "-ttl" || lower == "--ttl":
			if index+1 < len(args) {
				if seconds, err := strconv.Atoi(args[index+1]); err == nil && seconds > 0 {
					options.ttl = seconds
				}
				index++
			}
		case strings.HasPrefix(lower, "-ttl=") || strings.HasPrefix(lower, "--ttl="):
			if seconds, err := strconv.Atoi(arg[strings.Index(arg, "=")+1:]); err == nil && seconds > 0 {
				options.ttl = seconds
			}
		default:
			rest = append(rest, arg)
		}
	}
	return options, rest
}
