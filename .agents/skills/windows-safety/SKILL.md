# Windows Safety & PowerShell 5.1 — обязательный скилл

## Когда использовать
ПЕРЕД любой командой сложнее `git status`, ПЕРЕД любым скачиванием/установкой, ПЕРЕД запуском чужих скриптов.

## 1. Синтаксис PowerShell 5.1
- НЕТ `&&` и `||` (это PS7/bash). Правильно:
  `cmd1; if ($LASTEXITCODE -eq 0) { cmd2 }`
- НЕТ bash: `[ -f file ]` → `Test-Path "file"`; `[ -d dir ]` → `Test-Path "dir" -PathType Container`; `rm -rf x` → `Remove-Item -Recurse -Force x`; `mkdir -p d` → `New-Item -ItemType Directory -Force d`
- НЕТ `curl -L`: использовать `curl.exe -L -o out URL` или `Invoke-WebRequest -Uri URL -OutFile out`
- Пути с кириллицей/пробелами — всегда в двойных кавычках: `cd "D:\Тест\agent-hq"`

## 2. Перед сложной цепочкой команд — синтаксис-чек
```powershell
$e=$null; [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw "скрипт.ps1"), [ref]$e); $e.Count
```

## 3. Скачивание файлов
1. Только официальные GitHub Releases / npm / Maven. Точный URL релиза указать в отчёте.
2. Прокси: проверить `netstat -ano | findstr ":3128"` (cntlm). Если активен — предпочесть `certutil -urlcache -split -f "URL" "путь"`.
3. После скачивания ОБЯЗАТЕЛЬНО: `certutil -hashfile "файл" SHA256`, сверить с checksums.txt релиза. Не совпало → удалить файл, НЕ запускать, доложить.
4. Бинарник ставим в `.agents\tools\<имя>\` (в .gitignore), НЕ в корень репо.

## 4. Чужие скрипты (install.ps1 и т.п.)
1. `Get-Content install.ps1` — прочитать ЦЕЛИКОМ до запуска.
2. Искать: Invoke-Expression, IEX, скрытые Invoke-WebRequest/DownloadString, net user, reg add, schtasks.
3. Запуск — только после явного ОК пользователя в чате.

## 5. Корпоративный антивирус (Kaspersky)
- Детект `PDM:Trojan.Win32.Generic` — поведенческая эвристика; Bun-скомпилированные бинарники (opencode и др.) ловят ложняка.
- Если файл удалён АВ при скачивании: НЕ переустанавливать молча. Доложить пользователю: нужен тикет в ИБ на исключение папки `.agents\tools\`. Повторять установку только после подтверждения.
- Самому антивирус не трогать, исключения не добавлять.

## 6. Гигиена
- Временные файлы: `$env:TEMP` или `C:\Users\<user>\AppData\Local\Temp\opencode`; после работы удалить.
- Запись файлов: UTF-8 без BOM `[System.IO.File]::WriteAllText("путь",$c,[System.Text.UTF8Encoding]::new($false))`
- Чужие репозитории НЕ клонировать в корень проекта; если нужен исходник — во временную папку, поверхностно (`--depth 1`).
