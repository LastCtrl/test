# redact.ps1 - best-effort secret redaction for the agent-hq message bus (P0-D).
#
# PURPOSE: the poller persists agent stdout/stderr and message payloads into
# .memory\outbox and .memory\dead-letter. If an agent echoed a credential, it
# would land in the bus files. Redact-Secrets masks well-known credential
# shapes before persistence so no plaintext secret reaches those files.
#
# Pure PowerShell 5.1. Idempotent: applying it twice yields the same output.
# This is a safety net, NOT a substitute for agents avoiding secrets at all.

function Redact-Secrets {
    param([string]$Text)

    # Defensive: $null / empty input must never throw.
    if ([string]::IsNullOrEmpty($Text)) { return "" }

    $value = $Text

    # Well-known credential shapes -> whole match replaced. Case-sensitive
    # (-creplace) so ordinary lowercase words are not over-redacted.
    $patterns = @(
        'sk-[A-Za-z0-9]{16,}',                                           # OpenAI-style key
        'ghp_[A-Za-z0-9]{20,}',                                          # GitHub PAT (classic)
        'github_pat_[A-Za-z0-9_]{20,}',                                  # GitHub PAT (fine-grained)
        'xox[baprs]-[A-Za-z0-9-]{10,}',                                  # Slack token
        'AKIA[0-9A-Z]{16}',                                              # AWS access key id
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}',  # JWT
        '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'  # PEM private key
    )
    foreach ($pattern in $patterns) {
        $value = $value -creplace $pattern, '[REDACTED]'
    }

    # Bearer <credential>: keep the scheme word, mask only the token.
    $value = $value -replace '(bearer)\s+[A-Za-z0-9._-]{16,}', '$1 [REDACTED]'

    # key: value / key=value: keep the key name and separator, mask the value.
    $value = $value -replace '(password|passwd|pwd|secret|token|api[_-]?key)(\s*[:=]\s*)\S+', '$1$2[REDACTED]'

    return $value
}
