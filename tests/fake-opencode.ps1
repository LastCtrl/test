# fake-opencode.ps1 - deterministic stand-in for `opencode run ...` used by pipeline tests.
# The behaviour is selected by the FAKE_OPENCODE_MODE environment variable; every CLI
# argument (e.g. `run --agent <name> <prompt>`) is accepted and ignored on purpose.
#
# Supported modes:
#   success      -> stdout "TASK done.\nSTATUS: resolved", exit 0
#   exit1        -> stdout "boom", exit 1
#   timeout      -> sleeps, exit 0 (lets the poller hit its job timeout)
#   empty        -> no stdout, exit 0
#   stderr-only  -> stderr only, no stdout, exit 0
#   nomarker     -> stdout without a success marker, exit 0
#   errormarker  -> stdout with an error marker, exit 0

$mode = $env:FAKE_OPENCODE_MODE

switch ($mode) {
    "success" {
        Write-Output "TASK done.`nSTATUS: resolved"
        exit 0
    }
    "exit1" {
        Write-Output "boom"
        exit 1
    }
    "timeout" {
        Start-Sleep -Seconds 600
        exit 0
    }
    "empty" {
        exit 0
    }
    "stderr-only" {
        [Console]::Error.WriteLine("stderr-only: nothing on stdout")
        exit 0
    }
    "nomarker" {
        Write-Output "everything fine, but no status marker"
        exit 0
    }
    "errormarker" {
        Write-Output "STATUS: resolved`nError: something broke"
        exit 0
    }
    default {
        Write-Output "fake-opencode: unknown or missing FAKE_OPENCODE_MODE ('$mode')"
        exit 2
    }
}
