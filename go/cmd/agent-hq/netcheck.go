package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"agent-hq/internal/net"
	"agent-hq/internal/state"
)

// netProber is the probe implementation used by net-check and doctor. It is a
// package variable so tests can replace the socket with a deterministic dialer,
// the same pattern heartbeatIntervalOverride uses in run.go.
var netProber = net.DefaultProber()

// netCheckOptions carries the net-check flags.
type netCheckOptions struct {
	proxy   string
	timeout int
	model   string
}

type fallbackView struct {
	Current string `json:"current,omitempty"`
	Model   string `json:"model,omitempty"`
	Reason  string `json:"reason"`
}

type netHealthView struct {
	Path      string            `json:"path"`
	Available bool              `json:"available"`
	Models    []net.ModelHealth `json:"models"`
	Open      int               `json:"open"`
	Error     string            `json:"error,omitempty"`
}

type netCheckOutput struct {
	Version         string          `json:"version"`
	Root            string          `json:"root"`
	CheckedAt       string          `json:"checked_at"`
	Proxy           net.ProxyResult `json:"proxy"`
	Health          netHealthView   `json:"model_health"`
	Fallback        *fallbackView   `json:"fallback,omitempty"`
	Recommendations []string        `json:"recommendations"`
	OK              bool            `json:"ok"`
}

// runNetCheck reports the network health of one root and the recommended next
// steps. It is read-only: a TCP probe of the proxy plus reads of
// .memory/model-health.json and (optionally) the capability passport.
func runNetCheck(globals globalOptions, args []string, stdout, stderr io.Writer) int {
	options, rest := extractNetCheckOptions(args)
	if len(rest) != 0 {
		fmt.Fprintf(stderr, "usage: %s net-check [-proxy <host:port>] [-timeout <seconds>] [-model <name>] [-json] [-root <path>]\n", cliName)
		return 2
	}

	root, ok := resolveRoot(globals, stderr)
	if !ok {
		return 1
	}
	if options.proxy == "" {
		options.proxy = net.DefaultProxyAddress
	}
	if options.timeout <= 0 {
		options.timeout = int(net.DialTimeout / time.Second)
	}

	prober := netProber
	prober.Timeout = time.Duration(options.timeout) * time.Second
	now := time.Now()

	proxy := prober.ProbeProxy(context.Background(), options.proxy)
	healthPath := net.ModelHealthPath(root)
	health, healthErr := net.ReadModelHealthFile(healthPath, now)

	output := netCheckOutput{
		Version:   version,
		Root:      root,
		CheckedAt: now.Format(time.RFC3339),
		Proxy:     proxy,
		Health: netHealthView{
			Path:      healthPath,
			Available: healthErr == nil,
			Models:    health,
			Open:      len(net.OpenModels(health)),
		},
		Recommendations: net.Recommend(proxy, health, healthErr),
		OK:              proxy.Status == net.StatusOK,
	}
	if output.Health.Models == nil {
		output.Health.Models = []net.ModelHealth{}
	}
	if healthErr != nil {
		output.Health.Error = healthErr.Error()
	}

	if strings.TrimSpace(options.model) != "" {
		candidates := net.MergeCandidates(net.PassportPath(root), net.DefaultLadder)
		fallback, reason := net.SelectFallback(options.model, candidates, health, now)
		output.Fallback = &fallbackView{Current: options.model, Model: fallback, Reason: reason}
	}

	if globals.json {
		if !writeJSON(stdout, output) {
			return 1
		}
		if !output.OK {
			return 1
		}
		return 0
	}

	writer := tabwriter.NewWriter(stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "%s net-check\n", cliName)
	fmt.Fprintf(writer, "root:\t%s\n", output.Root)
	fmt.Fprintf(writer, "checked:\t%s\n", output.CheckedAt)
	fmt.Fprintf(writer, "proxy:\t%s\t%s\t%dms\n", proxy.Address, proxy.Status, proxy.LatencyMS)
	if output.Health.Available {
		fmt.Fprintf(writer, "health:\t%s\t%d model(s), %d open\n", output.Health.Path, len(health), output.Health.Open)
		for _, record := range health {
			breaker := "closed"
			if record.Open {
				breaker = "OPEN until " + record.OpenUntil
			}
			fmt.Fprintf(writer, "  %s\t%s\tfails=%d\tbreaker=%s\n", record.Model, record.Status, record.FailCount, breaker)
		}
	} else {
		fmt.Fprintf(writer, "health:\t%s\tunavailable\n", output.Health.Path)
	}
	if output.Fallback != nil {
		chosen := output.Fallback.Model
		if chosen == "" {
			chosen = "(none)"
		}
		fmt.Fprintf(writer, "fallback:\t%s\t%s\n", chosen, output.Fallback.Reason)
	}
	fmt.Fprintln(writer)
	fmt.Fprintln(writer, "recommendations")
	for _, step := range output.Recommendations {
		fmt.Fprintf(writer, "  - %s\n", step)
	}
	if err := writer.Flush(); err != nil {
		fmt.Fprintf(stderr, "%s: cannot write output: %v\n", cliName, err)
		return 1
	}
	if !output.OK {
		return 1
	}
	return 0
}

// extractNetCheckOptions parses the net-check flags by hand, so they may follow
// the command name and accept both "-flag value" and "-flag=value".
func extractNetCheckOptions(args []string) (netCheckOptions, []string) {
	options := netCheckOptions{}
	rest := make([]string, 0, len(args))

	valueFor := func(index int, arg string) (string, int, bool) {
		if equals := strings.Index(arg, "="); equals >= 0 {
			return arg[equals+1:], index, true
		}
		if index+1 < len(args) {
			return args[index+1], index + 1, true
		}
		return "", index, false
	}

	for index := 0; index < len(args); index++ {
		arg := args[index]
		lower := strings.ToLower(arg)
		name := lower
		if equals := strings.Index(lower, "="); equals >= 0 {
			name = lower[:equals]
		}
		switch name {
		case "-proxy", "--proxy":
			value, next, ok := valueFor(index, arg)
			if ok {
				options.proxy = strings.TrimSpace(value)
				index = next
			}
		case "-timeout", "--timeout":
			value, next, ok := valueFor(index, arg)
			if ok {
				if seconds, err := strconv.Atoi(strings.TrimSpace(value)); err == nil && seconds > 0 {
					options.timeout = seconds
				}
				index = next
			}
		case "-model", "--model":
			value, next, ok := valueFor(index, arg)
			if ok {
				options.model = strings.TrimSpace(value)
				index = next
			}
		default:
			rest = append(rest, arg)
		}
	}
	return options, rest
}

// netChecks is the network section of `agent-hq doctor`. Both checks are
// warn-only, so an offline workstation still has a healthy doctor: the probe
// result is information, not a broken installation.
func netChecks(root string) []state.Check {
	prober := netProber
	if prober.Timeout <= 0 || prober.Timeout > time.Second {
		prober.Timeout = time.Second
	}
	proxy := prober.ProbeProxy(context.Background(), net.DefaultProxyAddress)
	checks := []state.Check{{
		Name:   "net-proxy",
		Status: state.CheckOK,
		Detail: fmt.Sprintf("%s %s (%dms)", proxy.Address, proxy.Status, proxy.LatencyMS),
	}}
	if proxy.Status != net.StatusOK {
		checks[0].Status = state.CheckWarn
		checks[0].Detail = fmt.Sprintf("%s %s: %s", proxy.Address, proxy.Status, proxy.Error)
	}

	healthCheck := state.Check{Name: "model-health", Status: state.CheckOK}
	health, err := net.ReadModelHealthFile(net.ModelHealthPath(root), time.Now())
	switch {
	case errors.Is(err, net.ErrNoModelHealth):
		healthCheck.Status = state.CheckWarn
		healthCheck.Detail = "no state yet: run model-router.ps1 -Probe"
	case err != nil:
		healthCheck.Status = state.CheckWarn
		healthCheck.Detail = err.Error()
	default:
		healthCheck.Detail = fmt.Sprintf("%d model(s), %d open breaker(s)", len(health), len(net.OpenModels(health)))
	}
	return append(checks, healthCheck)
}
