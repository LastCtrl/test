package executor

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClassifySuccess(t *testing.T) {
	status, reason := Classify(0, "all good\nSTATUS: resolved", "")
	if status != StatusSuccess || reason != "" {
		t.Fatalf("Classify success = %q, %q; want success, empty", status, reason)
	}
	for _, marker := range []string{"STATUS: done", "status: COMPLETED", "STATUS:resolved"} {
		if status, _ := Classify(0, marker, ""); status != StatusSuccess {
			t.Errorf("Classify(%q) = %q, want success", marker, status)
		}
	}
}

func TestClassifyFailures(t *testing.T) {
	cases := []struct {
		name     string
		exitCode int
		stdout   string
		stderr   string
	}{
		{"nonzero exit", 1, "STATUS: resolved", ""},
		{"empty stdout", 0, "   ", ""},
		{"missing marker", 0, "did some work", ""},
		{"error marker stdout", 0, "Error: boom\nSTATUS: resolved", ""},
		{"error marker stderr", 0, "STATUS: resolved", "permission denied"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			status, reason := Classify(testCase.exitCode, testCase.stdout, testCase.stderr)
			if status != StatusFailed {
				t.Errorf("Classify = %q, want failed", status)
			}
			if reason == "" {
				t.Error("Classify returned an empty reason for a failure")
			}
		})
	}
}

func TestFakeExecutorModes(t *testing.T) {
	cases := []struct {
		mode     FakeMode
		status   Status
		exitCode int
	}{
		{FakeSuccess, StatusSuccess, 0},
		{FakeFail, StatusFailed, 1},
		{FakeEmpty, StatusFailed, 0},
	}
	for _, testCase := range cases {
		t.Run(string(testCase.mode), func(t *testing.T) {
			fake := NewFakeExecutor(testCase.mode)
			result, err := fake.Execute(context.Background(), TaskSpec{ID: "run-1", Agent: "dev-2"})
			if err != nil {
				t.Fatalf("Execute: %v", err)
			}
			if result.Status != testCase.status || result.ExitCode != testCase.exitCode {
				t.Errorf("result = %q exit %d, want %q exit %d",
					result.Status, result.ExitCode, testCase.status, testCase.exitCode)
			}
		})
	}
}

func TestFakeExecutorTimeout(t *testing.T) {
	fake := NewFakeExecutor(FakeTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()

	result, err := fake.Execute(ctx, TaskSpec{ID: "run-1", Agent: "dev-2"})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if result.Status != StatusTimeout || result.ExitCode != 124 {
		t.Errorf("result = %q exit %d, want timeout exit 124", result.Status, result.ExitCode)
	}
}

func TestFakeExecutorUnknownMode(t *testing.T) {
	fake := NewFakeExecutor(FakeMode("bogus"))
	if _, err := fake.Execute(context.Background(), TaskSpec{ID: "run-1"}); err == nil {
		t.Error("Execute with an unknown mode returned no error")
	}
}

func TestFakeExecutorFromEnv(t *testing.T) {
	t.Setenv("AGENT_HQ_FAKE_MODE", "fail")
	t.Setenv("AGENT_HQ_FAKE_DELAY_MS", "5")
	fake := NewFakeExecutorFromEnv()
	if fake.Mode != FakeFail || fake.Delay != 5*time.Millisecond {
		t.Errorf("fake = %+v, want mode fail and delay 5ms", fake)
	}
	t.Setenv("AGENT_HQ_FAKE_DELAY_MS", "not-a-number")
	if delay := NewFakeExecutorFromEnv().Delay; delay != 0 {
		t.Errorf("invalid delay produced %s, want 0", delay)
	}
}

func TestPlanOpenCodeUsesVaultWhenSecretsExist(t *testing.T) {
	root := t.TempDir()
	wrapper := filepath.Join(root, ".agents", "scripts", "run-with-secrets.ps1")
	if err := os.MkdirAll(filepath.Dir(wrapper), 0o755); err != nil {
		t.Fatalf("mkdir wrapper: %v", err)
	}
	writeTestFile(t, wrapper, "param()")

	vault := t.TempDir()
	writeTestFile(t, filepath.Join(vault, "secret.opencode-api-key.enc"), "x")

	cli := filepath.Join(t.TempDir(), "opencode.ps1")
	writeTestFile(t, cli, "param()")

	t.Setenv("AGENT_HQ_OPENCODE", "")
	t.Setenv("AGENT_HQ_OPENCODE_PATH", cli)
	t.Setenv("AGENT_HQ_NO_VAULT", "")
	t.Setenv("AGENT_HQ_SECRETS", vault)

	plan := PlanOpenCode(root)
	if !plan.UseVault {
		t.Fatalf("plan.UseVault = false, want true (plan=%+v)", plan)
	}
	if plan.Wrapper != wrapper || plan.Cli != cli {
		t.Errorf("plan paths = %+v, want wrapper %s and cli %s", plan, wrapper, cli)
	}
	if len(plan.Secrets) != 1 || plan.Secrets[0] != "opencode-api-key" {
		t.Errorf("plan.Secrets = %v, want [opencode-api-key]", plan.Secrets)
	}
}

func TestPlanOpenCodeOverrideBypassesVault(t *testing.T) {
	root := t.TempDir()
	wrapper := filepath.Join(root, ".agents", "scripts", "run-with-secrets.ps1")
	if err := os.MkdirAll(filepath.Dir(wrapper), 0o755); err != nil {
		t.Fatalf("mkdir wrapper: %v", err)
	}
	writeTestFile(t, wrapper, "param()")
	vault := t.TempDir()
	writeTestFile(t, filepath.Join(vault, "secret.opencode-api-key.enc"), "x")

	t.Setenv("AGENT_HQ_OPENCODE", "C:\\fake\\cli.ps1")
	t.Setenv("AGENT_HQ_SECRETS", vault)

	plan := PlanOpenCode(root)
	if plan.UseVault {
		t.Errorf("plan.UseVault = true, want false when AGENT_HQ_OPENCODE overrides")
	}
	if plan.Cli != "C:\\fake\\cli.ps1" {
		t.Errorf("plan.Cli = %q, want the override path", plan.Cli)
	}
}

func TestPlanOpenCodeWithoutSecrets(t *testing.T) {
	root := t.TempDir()
	wrapper := filepath.Join(root, ".agents", "scripts", "run-with-secrets.ps1")
	if err := os.MkdirAll(filepath.Dir(wrapper), 0o755); err != nil {
		t.Fatalf("mkdir wrapper: %v", err)
	}
	writeTestFile(t, wrapper, "param()")

	t.Setenv("AGENT_HQ_OPENCODE", "")
	t.Setenv("AGENT_HQ_SECRETS", t.TempDir())

	if plan := PlanOpenCode(root); plan.UseVault {
		t.Error("plan.UseVault = true with an empty vault, want false")
	}
}

func TestWithEnvHooksReplacesAndClears(t *testing.T) {
	base := []string{"PATH=C:\\bin", "AGENT_HQ_AGENT=stale"}
	env := withEnvHooks(base, TaskSpec{ID: "run-9", Agent: "dev-2", AttemptID: "attempt-1"})
	joined := strings.Join(env, "\n")
	for _, want := range []string{"AGENT_HQ_TASK_ID=run-9", "AGENT_HQ_AGENT=dev-2", "AGENT_HQ_ATTEMPT_ID=attempt-1"} {
		if !strings.Contains(joined, want) {
			t.Errorf("env missing %q: %v", want, env)
		}
	}
	if strings.Contains(joined, "stale") {
		t.Errorf("stale agent value survived: %v", env)
	}

	cleared := withEnvHooks([]string{"AGENT_HQ_MODEL=x"}, TaskSpec{})
	if strings.Join(cleared, "\n") != "" {
		t.Errorf("empty spec kept values: %v", cleared)
	}
}

func TestJobTimeout(t *testing.T) {
	t.Setenv("AGENT_HQ_JOB_TIMEOUT", "42")
	if got := JobTimeout(); got != 42*time.Second {
		t.Errorf("JobTimeout = %s, want 42s", got)
	}
	t.Setenv("AGENT_HQ_JOB_TIMEOUT", "-3")
	if got := JobTimeout(); got != DefaultJobTimeout {
		t.Errorf("JobTimeout with a negative value = %s, want the default", got)
	}
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
