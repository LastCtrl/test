package executor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// DefaultJobTimeout mirrors the PowerShell engine default when
// AGENT_HQ_JOB_TIMEOUT is unset: 900 seconds.
const DefaultJobTimeout = 900 * time.Second

// vaultSecretNames are the provider keys the wrapper injects. Only names that
// exist in the vault are requested, so one missing key never aborts a launch.
var vaultSecretNames = []string{
	"opencode-api-key",
	"aihubmix-api-key",
	"openrouter-api-key",
	"groq-api-key",
	"tokenrouter-api-key",
}

// LaunchPlan describes how the CLI would be started. It carries names only,
// never secret values.
type LaunchPlan struct {
	Cli      string
	UseVault bool
	Wrapper  string
	Secrets  []string
}

// OpenCodeExecutor launches `opencode run --agent <agent> <prompt>`, through
// the DPAPI vault wrapper when provider keys are present, mirroring
// inbox-engine.ps1 (resolved CLI, vault opt-in, env hooks, job timeout).
type OpenCodeExecutor struct {
	root    string
	plan    LaunchPlan
	timeout time.Duration
}

// NewOpenCodeExecutor resolves the launch plan for root. Environment is read
// once here (AGENT_HQ_OPENCODE, AGENT_HQ_OPENCODE_PATH, AGENT_HQ_NO_VAULT,
// AGENT_HQ_SECRETS, APPDATA, AGENT_HQ_JOB_TIMEOUT).
func NewOpenCodeExecutor(root string) *OpenCodeExecutor {
	return &OpenCodeExecutor{root: root, plan: PlanOpenCode(root), timeout: JobTimeout()}
}

// Plan returns the resolved launch plan (no secret values).
func (e *OpenCodeExecutor) Plan() LaunchPlan { return e.plan }

// Version implements Executor.
func (e *OpenCodeExecutor) Version() int { return InterfaceVersion }

// Name implements Executor.
func (e *OpenCodeExecutor) Name() string { return "opencode" }

// Command reproduces the informational command string the PowerShell engine
// stores in machine evidence.
func (e *OpenCodeExecutor) Command(spec TaskSpec) string {
	command := e.plan.Cli + " run --agent " + spec.Agent
	if e.plan.UseVault {
		command += " [vault: run-with-secrets.ps1]"
	}
	return command
}

// Execute runs one attempt. A non-nil error means the executor could not start
// the worker at all; a started-but-failed worker is reported as a Result.
func (e *OpenCodeExecutor) Execute(ctx context.Context, spec TaskSpec) (Result, error) {
	if strings.TrimSpace(spec.Agent) == "" {
		return Result{}, errors.New("opencode executor: empty agent")
	}
	timeout := e.timeout
	if timeout <= 0 {
		timeout = DefaultJobTimeout
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	command, args, err := e.buildCommand(spec)
	if err != nil {
		return Result{}, err
	}

	started := time.Now()
	cmd := exec.CommandContext(runCtx, command, args...)
	cmd.Dir = e.root
	cmd.Env = withEnvHooks(os.Environ(), spec)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()
	duration := time.Since(started)
	out := stdout.String()
	errOut := stderr.String()

	if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
		return Result{
			Status: StatusTimeout, ExitCode: 124, Stdout: out, Stderr: errOut,
			Duration: duration, Error: fmt.Sprintf("timeout after %s", timeout),
		}, nil
	}

	if cmd.ProcessState == nil {
		message := "worker did not start"
		if runErr != nil {
			message = runErr.Error()
		}
		return Result{Status: StatusError, ExitCode: -1, Stdout: out, Stderr: errOut,
			Duration: duration, Error: message}, nil
	}

	exitCode := cmd.ProcessState.ExitCode()
	status, reason := Classify(exitCode, out, errOut)
	return Result{Status: status, ExitCode: exitCode, Stdout: out, Stderr: errOut,
		Duration: duration, Error: reason}, nil
}

// buildCommand returns the executable and argv for one attempt.
func (e *OpenCodeExecutor) buildCommand(spec TaskSpec) (string, []string, error) {
	cliArgs := []string{"run", "--agent", spec.Agent, spec.Payload}

	if e.plan.UseVault {
		powershell, err := powershellPath()
		if err != nil {
			return "", nil, err
		}
		script := "& " + psQuote(e.plan.Wrapper) +
			" -Secret @(" + psQuoteList(e.plan.Secrets) + ")" +
			" -FilePath " + psQuote(e.plan.Cli) +
			" -Args @(" + psQuoteList(cliArgs) + ")"
		return powershell, []string{
			"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script,
		}, nil
	}

	if isPS1(e.plan.Cli) {
		powershell, err := powershellPath()
		if err != nil {
			return "", nil, err
		}
		parts := make([]string, 0, len(cliArgs))
		for _, argument := range cliArgs {
			parts = append(parts, psQuote(argument))
		}
		script := "& " + psQuote(e.plan.Cli) + " " + strings.Join(parts, " ")
		return powershell, []string{
			"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script,
		}, nil
	}
	return e.plan.Cli, cliArgs, nil
}

// withEnvHooks exports the correlation ids the tracer/scoring plugins read.
func withEnvHooks(base []string, spec TaskSpec) []string {
	env := base
	env = setEnv(env, "AGENT_HQ_TASK_ID", spec.ID)
	env = setEnv(env, "AGENT_HQ_ATTEMPT_ID", spec.AttemptID)
	env = setEnv(env, "AGENT_HQ_AGENT", spec.Agent)
	env = setEnv(env, "AGENT_HQ_MODEL", spec.Model)
	return env
}

// setEnv replaces a variable case-insensitively; an empty value removes it so
// a stale value cannot leak from the parent process.
func setEnv(env []string, name, value string) []string {
	prefix := strings.ToUpper(name) + "="
	filtered := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if strings.HasPrefix(strings.ToUpper(entry), prefix) {
			continue
		}
		filtered = append(filtered, entry)
	}
	if value != "" {
		filtered = append(filtered, name+"="+value)
	}
	return filtered
}

// JobTimeout reads AGENT_HQ_JOB_TIMEOUT (positive seconds), else the default.
func JobTimeout() time.Duration {
	if raw := strings.TrimSpace(os.Getenv("AGENT_HQ_JOB_TIMEOUT")); raw != "" {
		if seconds, err := strconv.Atoi(raw); err == nil && seconds > 0 {
			return time.Duration(seconds) * time.Second
		}
	}
	return DefaultJobTimeout
}

// PlanOpenCode mirrors Get-OpencodeLaunchPlan from inbox-engine.ps1.
func PlanOpenCode(root string) LaunchPlan {
	plan := LaunchPlan{Cli: resolveCli()}
	if strings.TrimSpace(os.Getenv("AGENT_HQ_OPENCODE")) != "" {
		return plan
	}
	if strings.TrimSpace(os.Getenv("AGENT_HQ_NO_VAULT")) != "" {
		return plan
	}
	wrapper := filepath.Join(root, ".agents", "scripts", "run-with-secrets.ps1")
	if !isFile(wrapper) {
		return plan
	}
	secrets := vaultSecretNamesPresent(vaultDir())
	if len(secrets) == 0 {
		return plan
	}
	if !isFile(plan.Cli) {
		resolved, err := exec.LookPath(plan.Cli)
		if err != nil || !isFile(resolved) {
			return LaunchPlan{Cli: plan.Cli}
		}
		plan.Cli = resolved
	}
	plan.UseVault = true
	plan.Wrapper = wrapper
	plan.Secrets = secrets
	return plan
}

func resolveCli() string {
	if value := strings.TrimSpace(os.Getenv("AGENT_HQ_OPENCODE")); value != "" {
		return value
	}
	if value := strings.TrimSpace(os.Getenv("AGENT_HQ_OPENCODE_PATH")); value != "" {
		return value
	}
	if appData := strings.TrimSpace(os.Getenv("APPDATA")); appData != "" {
		shim := filepath.Join(appData, "npm", "opencode.ps1")
		if isFile(shim) {
			return shim
		}
	}
	if found, err := exec.LookPath("opencode"); err == nil {
		return found
	}
	return "opencode"
}

func vaultDir() string {
	if value := strings.TrimSpace(os.Getenv("AGENT_HQ_SECRETS")); value != "" {
		return value
	}
	if home := strings.TrimSpace(os.Getenv("USERPROFILE")); home != "" {
		return filepath.Join(home, ".agent-secrets")
	}
	return ""
}

func vaultSecretNamesPresent(dir string) []string {
	if dir == "" {
		return nil
	}
	found := make([]string, 0, len(vaultSecretNames))
	for _, name := range vaultSecretNames {
		if isFile(filepath.Join(dir, "secret."+name+".enc")) {
			found = append(found, name)
		}
	}
	return found
}

func powershellPath() (string, error) {
	for _, candidate := range []string{"powershell.exe", "pwsh.exe"} {
		if path, err := exec.LookPath(candidate); err == nil {
			return path, nil
		}
	}
	return "", errors.New("opencode executor: no PowerShell interpreter found")
}

func isPS1(path string) bool {
	return strings.EqualFold(filepath.Ext(path), ".ps1")
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// psQuote renders one literal for a single-quoted PowerShell string.
func psQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

// psQuoteList renders a comma-separated PowerShell array literal.
func psQuoteList(values []string) string {
	quoted := make([]string, 0, len(values))
	for _, value := range values {
		quoted = append(quoted, psQuote(value))
	}
	return strings.Join(quoted, ",")
}
