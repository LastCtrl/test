# UTF-8 console helper: dot-source only.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try {
    [Console]::OutputEncoding = $utf8NoBom
    [Console]::InputEncoding = $utf8NoBom
} catch { }
$OutputEncoding = $utf8NoBom
chcp 65001 | Out-Null
