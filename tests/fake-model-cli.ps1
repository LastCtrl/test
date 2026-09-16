# fake-model-cli.ps1 - deterministic stand-in for `opencode run --model <id> "<prompt>"`.
#
# Used by tests/test-model-router.ps1 through $env:AGENT_HQ_OPENCODE, so the
# router can be exercised without touching the real provider quota. Every CLI
# argument (`run --model <id> <prompt>` or `debug config`) is accepted and
# ignored on purpose: the behaviour is selected by FAKE_MODEL_CLI_MODE.
#
# Supported modes:
#   pong        -> stdout "PONG", exit 0                       (router: OK)
#   rate-limit  -> "Free usage exceeded, subscribe to Go", 1   (router: RATE_LIMIT)
#   dead        -> "No available channel", exit 1              (router: DEAD)
#   unknown     -> "UnknownError", exit 1                      (router: DEAD)
#   silent      -> no output, exit 0                           (router: DEAD)
#   hang        -> sleeps 600s (router must classify TIMEOUT)
#   config-json -> prints a fake config document; the payload is taken from the
#                  environment when set, otherwise a built-in agent map.
#   (unset)     -> exit 2 with a diagnostic

$mode = $env:FAKE_MODEL_CLI_MODE

switch ($mode) {
    "pong" {
        Write-Output "PONG"
        exit 0
    }
    "rate-limit" {
        Write-Output "Error: Free usage exceeded, subscribe to Go"
        exit 1
    }
    "dead" {
        Write-Output "Error: No available channel for model"
        exit 1
    }
    "unknown" {
        Write-Output "UnknownError: provider returned an unexpected response"
        exit 1
    }
    "silent" {
        exit 0
    }
    "hang" {
        Start-Sleep -Seconds 600
        exit 0
    }
    "config-json" {
        if ($env:FAKE_MODEL_CLI_CONFIG_JSON) {
            Write-Output $env:FAKE_MODEL_CLI_CONFIG_JSON
        } else {
            Write-Output '{"agent":{"qa-engineer":{"model":"opencode/ling-3.0-flash-fin-free"},"dev-1":{"model":"opencode-go/deepseek-v4.1-flash"}}}'
        }
        exit 0
    }
    default {
        Write-Output ("fake-model-cli: unknown or missing FAKE_MODEL_CLI_MODE ('" + $mode + "')")
        exit 2
    }
}
