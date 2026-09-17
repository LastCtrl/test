# PowerShell-профиль agent-hq (вариант B: ключи только в vault)

Файл: `C:\Users\Ermak_DS\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`

## Назначение
Команда `opencode` (и алиас `oc`) в интерактивных сессиях PowerShell запускается через
`.agents\scripts\run-with-secrets.ps1`: враппер расшифровывает ключи провайдеров из DPAPI-vault
и кладёт их в окружение ДОЧЕРНЕГО процесса на время одного запуска. В `HKCU\Environment`
ключей нет; в argv/файлы/логи они не попадают.

Vault: `%USERPROFILE%\.agent-secrets\` (переопределяется `$env:AGENT_HQ_SECRETS`).

## Ловушка — рекурсия
Функция `opencode()` перекрывает native-команду `opencode` из PATH. Внутри функции
`opencode` по имени НЕ вызывается (была бы бесконечная рекурсия): запуск идёт только
по абсолютному пути к npm-шиму через `-FilePath` враппера.

## Безопасность сессии
Если враппер/шим/CLI недоступны — сессия не ломается: warning + доступный путь без ключей.
Отключить vault-путь: `$env:AGENT_HQ_NO_VAULT = '1'`.

## Границы
- Сессии с `-NoProfile` профиль не читают → `opencode` там без ключей из vault.
- Служебные процессы (poller/daemon) получают ключи своим путём — в `inbox-engine.ps1` (через враппер).

## ВАЖНО: AMSI/Kaspersky и комментарии
Комментарии в профиле **нельзя раздувать**. Kaspersky AMSI применяет к содержимому `.ps1`
**кумулятивную эвристику**: отдельные «подозрительные» токены проходят, а их накопление
(упоминания путей вида `...\secret.<имя>.enc`, `HKCU\Environment`, `vault`, `argv`, `.ps1`,
`-NoProfile` и т.п.) переводит файл в `ParserError / FQID=ScriptContainedMaliciousContent`
— файл не грузится ни через `-File`, ни через dot-source.

**Правило:** держать в профиле минимум комментариев (1 короткая шапка), вся документация — здесь,
в `.md`. Проверено: профиль с кодом без комментариев и с одной шапкой грузится (exit 0).

Проверка после любой правки профиля:
```
powershell -NoProfile -File "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"; $LASTEXITCODE  # ждём 0
powershell -NoProfile -Command ". '$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'; [bool](Get-Command opencode -ErrorAction SilentlyContinue)"  # ждём True
```
