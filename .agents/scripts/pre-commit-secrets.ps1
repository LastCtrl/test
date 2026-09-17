# pre-commit-secrets.ps1 - Scan staged diff for leaked secrets before a commit.
# Blocks the commit (exit 1) when a suspicious literal is found in ADDED lines.
# Never prints the full secret: only first 3 chars of the value + ***.
# Repo root is derived from this script's location (.agents/scripts -> root),
# so it works no matter what the current directory is (cyrillic paths included).

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Get-StagedAddedLines {
    # returns array of @{ File=...; Line=...; Text=... } for '+' lines of the staged diff
    $diff = & git -C $repoRoot diff --cached --unified=0 --no-color
    if ($LASTEXITCODE -ne 0) { return @() }
    $result = @()
    $file = $null
    $lineNo = 0
    foreach ($l in ($diff -split "`n")) {
        if ($l -match '^\+\+\+ b/(.+)$') {
            $file = $Matches[1]
            continue
        }
        if ($l -match '^@@ .*\+(\d+)(?:,\d+)? @@') {
            $lineNo = [int]$Matches[1]
            continue
        }
        if ($l.Length -gt 0 -and $l[0] -eq '+' -and $file) {
            $result += ,@{ File = $file; Line = $lineNo; Text = $l.Substring(1) }
            $lineNo++
        }
    }
    return ,$result
}

# (pattern, type) pairs; value captured into group 1 where applicable
# NOTE: single-quoted PS strings with doubled '' — in PS 5.1 the sequence \"
# inside a double-quoted string does NOT escape the quote (escape char is `).
$patterns = @(
    @{ Re = '(?i)password\s*[:=]\s*[''"]([^''"]{4,})[''"]';       Type = 'password' },
    @{ Re = '(?i)\bpwd[''"]?\s*[:=]\s*[''"]?([A-Za-z0-9_\-]{4,})[''"]?';          Type = 'pwd' },
    @{ Re = '(?i)secret\s*[:=]\s*[''"]([^''"]{4,})[''"]';          Type = 'secret' },
    @{ Re = '(?i)token[''"]?\s*[:=]\s*[''"]?([A-Za-z0-9_\-\.]{10,})[''"]?'; Type = 'token' },
    @{ Re = '(?i)api[_\-]?key\s*[:=]\s*[''"]([^''"]{8,})[''"]';   Type = 'api-key' },
    @{ Re = 'eyJ[A-Za-z0-9_-]{10,}';                              Type = 'JWT' },
    @{ Re = 'ghp_[A-Za-z0-9]{20,}';                               Type = 'GitHub token' },
    @{ Re = 'xoxb-[A-Za-z0-9-]{10,}';                             Type = 'Slack token' },
    @{ Re = 'sk-[A-Za-z0-9][A-Za-z0-9_-]{19,}';                              Type = 'OpenAI-style key' },
    @{ Re = 'AKIA[0-9A-Z]{16}';                                   Type = 'AWS key id' },
    @{ Re = '-----BEGIN [A-Z ]*PRIVATE KEY-----';                Type = 'private key' }
)

# exclusion: mock / doc / env-read / vault-reference lines are fine
$exclValue = '(?i)^(test|example|placeholder|xxxx|dummy|mock)[a-z0-9_-]*$'
$exclLine  = '(?i)\$env:|get-secret|set-secret'

# prefix-token types (JWT, ghp_, xoxb-, sk-, AKIA, PEM): the literal ITSELF is the
# giveaway, so the hyphen shape of the value must never exempt them; only an
# explicit vault/env mechanism reference in the line can exclude them.
$prefixTypes = @('JWT', 'GitHub token', 'Slack token', 'OpenAI-style key', 'AWS key id', 'private key')

$added = Get-StagedAddedLines
$findings = @()
foreach ($a in $added) {
    $text = $a.Text
    # whole-line exclusions
    if ($text -match $exclLine) { continue }
    foreach ($p in $patterns) {
        $m = [regex]::Match($text, $p.Re)
        if (-not $m.Success) { continue }
        # candidate literal value (group 1 when the pattern has one, else full match)
        $val = if ($m.Groups.Count -gt 1) { $m.Groups[1].Value } else { $m.Value }
        # excluded fake values
        if ($val -and ($val -match $exclValue)) { continue }
        # a pure a-z0-9- token that is a vault secret-NAME reference (not a literal):
        # case-sensitive: a vault name is lowercase[-hyphen-lowercase] (tg-bot-token);
        # allowed with a vault/env mechanism reference in the line, or — for non-prefix
        # types only — when the value itself is hyphen-joined lowercase words.
        # Prefix tokens (xoxb-/sk-/ghp_/AKIA/JWT/PEM) are NEVER exempt by hyphen shape:
        # xoxb-123... is a literal token, not a vault name. SuperSecret99/hardcoded123 never pass.
        if ($val -and $val -cmatch '^[a-z0-9][a-z0-9-]{1,39}$') {
            $vaultCtx = $text -cmatch '(get-secret|set-secret|\-Name|\-AsEnv|\$env:|env:)'
            $hyphenName = $val -cmatch '[a-z0-9]-[a-z0-9]'
            if ($vaultCtx -or ($hyphenName -and ($prefixTypes -notcontains $p.Type))) { continue }
        }
        $masked = if ($val.Length -gt 3) { $val.Substring(0,3) + '***' } else { '***' }
        $findings += ("{0}:{1} — подозрение на {2} ({3})" -f $a.File, $a.Line, $p.Type, $masked)
    }
}

if ($findings.Count -gt 0) {
    Write-Host 'COMMIT ЗАБЛОКИРОВАН: найдены подозрительные строки (секреты?):' -ForegroundColor Red
    $findings | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host 'Секреты храните так: set-secret.ps1 -Name <name>, используйте get-secret.ps1 -Name <name> -AsEnv <ENV>.' -ForegroundColor Yellow
    exit 1
}

# clean -> silent pass
exit 0
