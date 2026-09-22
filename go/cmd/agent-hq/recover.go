package main

import (
	"context"
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"agent-hq/internal/net"
	"agent-hq/internal/state"
	"agent-hq/internal/store"
)

// recoverOptions carries the watchdog flags. They are parsed by hand so the
// spelling -requeue / -Requeue / --requeue all work and so the flags may follow
// the command name.
type recoverOptions struct {
	requeue bool
	ttl     int
	// net adds the M3 network section (proxy probe) to the report. It is opt-in
	// because the default watchdog is a pure database sweep.
	net bool
	// warnings collects rejected -ttl values (non-numeric, non-positive or a
	// missing argument) so the caller can report them instead of silently
	// falling back to the per-attempt lease.
	warnings []string
}

// recoveredAttempt is one stale attempt plus whether this sweep reconciled it.
// A second sweep finds the same row already reconciled and reports it as not
// recovered, which is what makes the command's idempotency observable.
type recoveredAttempt struct {
	store.StaleAttempt
	Recovered bool `json:"recovered"`
}

// recoverNetView is the optional network section (`-net`): it explains whether
// the watchdog ran while the transport layer was healthy.
type recoverNetView struct {
	Proxy           net.ProxyResult `json:"proxy"`
	Recommendations []string        `json:"recommendations"`
}

type recoverOutput struct {
	Root            string              `json:"root"`
	Now             string              `json:"now"`
	Requeue         bool                `json:"requeue"`
	TTLSeconds      int                 `json:"ttl_seconds,omitempty"`
	Stale           int                 `json:"stale"`
	Recovered       int                 `json:"recovered"`
	InvalidSessions int                 `json:"invalid_sessions"`
	Sessions        []store.SessionMark `json:"sessions"`
	Attempts        []recoveredAttempt  `json:"attempts"`
	Net             *recoverNetView     `json:"net,omitempty"`
}

// runRecover is the M2 watchdog: it finds running attempts whose lease
// heartbeat expired, marks them stale, releases the lease and (optionally)
// requeues the task. It only touches this root's SQLite database, never the
// PowerShell-managed files.
func runRecover(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	options, rest := extractRecoverOptions(args)
	for _, warning := range options.warnings {
		fmt.Fprintf(stderr, "%s: recover: %s\n", cliName, warning)
	}
	if len(rest) != 0 {
		fmt.Fprintf(stderr, "usage: %s recover [-requeue] [-ttl <seconds>] [-net] [-json] [-root <path>]\n", cliName)
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

	invalidSessions, err := handle.InvalidSessionCount()
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot count session marks: %v\n", cliName, err)
		return 1
	}
	sessions, err := handle.SessionMarks()
	if err != nil {
		fmt.Fprintf(stderr, "%s: cannot read session marks: %v\n", cliName, err)
		return 1
	}

	output := recoverOutput{
		Root:            root,
		Now:             now.Format(time.RFC3339),
		Requeue:         options.requeue,
		TTLSeconds:      options.ttl,
		Stale:           len(stale),
		Recovered:       recovered,
		InvalidSessions: invalidSessions,
		Sessions:        sessions,
		Attempts:        attempts,
	}
	if options.net {
		health, healthErr := net.ReadModelHealthFile(net.ModelHealthPath(root), now)
		proxy := netProber.ProbeProxy(context.Background(), net.DefaultProxyAddress)
		output.Net = &recoverNetView{Proxy: proxy, Recommendations: net.Recommend(proxy, health, healthErr)}
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
	fmt.Fprintf(writer, "invalid sessions:\t%d\n", output.InvalidSessions)
	if len(output.Sessions) > 0 {
		fmt.Fprintln(writer)
		fmt.Fprintln(writer, "  TASK\tSTATUS\tAGENT\tMARKED_AT\tREASON")
		for _, mark := range output.Sessions {
			fmt.Fprintf(writer, "  %s\t%s\t%s\t%s\t%s\n",
				mark.TaskID, mark.Status, mark.Agent, mark.MarkedAt, mark.Reason)
		}
	}
	if output.Net != nil {
		fmt.Fprintln(writer)
		fmt.Fprintf(writer, "net proxy:\t%s\t%s\t%dms\n",
			output.Net.Proxy.Address, output.Net.Proxy.Status, output.Net.Proxy.LatencyMS)
		for _, step := range output.Net.Recommendations {
			fmt.Fprintf(writer, "  - %s\n", step)
		}
	}
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

// extractRecoverOptions accepts -requeue (any case, so -Requeue works too),
// -ttl and -net, both bare and with an = value.
func extractRecoverOptions(args []string) (recoverOptions, []string) {
	options := recoverOptions{}
	rest := make([]string, 0, len(args))

	for index := 0; index < len(args); index++ {
		arg := args[index]
		lower := strings.ToLower(arg)
		switch {
		case lower == "-requeue" || lower == "--requeue":
			options.requeue = true
		case lower == "-net" || lower == "--net":
			options.net = true
		case lower == "-ttl" || lower == "--ttl":
			if index+1 < len(args) {
				raw := args[index+1]
				if seconds, err := strconv.Atoi(raw); err == nil && seconds > 0 {
					options.ttl = seconds
				} else {
					options.warnings = append(options.warnings, ttlWarning(raw))
				}
				index++
			} else {
				options.warnings = append(options.warnings,
					"ignoring -ttl: missing value; expected a positive integer number of seconds; using the per-attempt lease")
			}
		case strings.HasPrefix(lower, "-ttl=") || strings.HasPrefix(lower, "--ttl="):
			raw := arg[strings.Index(arg, "=")+1:]
			if seconds, err := strconv.Atoi(raw); err == nil && seconds > 0 {
				options.ttl = seconds
			} else {
				options.warnings = append(options.warnings, ttlWarning(raw))
			}
		default:
			rest = append(rest, arg)
		}
	}
	return options, rest
}

// ttlWarning explains a rejected -ttl value so an operator cannot mistake the
// fallback (the per-attempt lease) for an applied override.
func ttlWarning(raw string) string {
	return fmt.Sprintf("ignoring -ttl %q: expected a positive integer number of seconds; using the per-attempt lease", raw)
}
