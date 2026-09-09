# Active Context — Текущий контекст сессии

## Дата обновления: 2026-08-27

## Текущий статус
- **Этап**: Все фазы A–F закрыты. Система работоспособна после рестарта opencode.
- **Верификация**: verify-phase.ps1 = 29/29 PASSED; health-check.ps1 = HEALTH: PASS (последний прогон 24.08)
- **Worktrees**: main + agent/dev-1
- **Трейсы**: traces.jsonl живой; performance.jsonl — 3 сессии, avg 36.4s
- **Команда**: 19 агентов в .opencode/agents/, sync-agents.ps1 синхронизирует секцию agent в opencode.json
- **Модели**: mimo-v2.5-free (основная), nemotron-3.5-lightning-free (быстрая), nemotron-3-ultra-free (запасная + проверяющие)
- **Проверяющие**: qa-engineer, code-reviewer, security-auditor → opencode/nemotron-3-ultra-free (после падения ox-alpha-free "Model not found")
- **Протокол**: AGENTS.md §3.1 (оценка времени 5/10/15/20/30/45 мин), §3.2 (x2 timeout), §3.3 (верификация НЕ тимлидом) — добавлены 27.08
- **Скрипты**: cleanup-garbage.ps1 (.agents/scripts/) — автоочистка temp_*/bak/stray root agent JSON, -DryRun/-Execute

## Остаток
- **#7** Коммит + push — незавершённая задача (team-lead)
- **Stray-JSON** (pending, PRIORITY: high): 16 дубликатов agent JSON в корне + prompts/ (byte-identical копиям в .opencode/agents/). Баг cleanup-garbage.ps1:94 (хардкод 3 имён проверяющих). Делегировать dev-3 на nemotron-ultra (оценка 15 мин): трассировка источника stray-JSON + правка детекта ВСЕХ stray root agent JSON + удаление 16 копий + прогон -DryRun
- **Inbox**: 12 старых тестовых файлов — тимлид архивирует

## Блокеры
- opencode-go/ox-alpha-free упал ("Model not found") — проверяющие переведены на nemotron-3-ultra-free (единственная запасная)
- Все платные модели (kimi-k2.7, glm-5.2, deepseek-v4-pro, qwen3.7-plus) недоступны (лимиты подписки)

## Решения (ADR)
- ADR-001: Memory Bank (5 файлов)
- ADR-002: Agent Communication Protocol (inbox/outbox JSON)
- ADR-003: Sandbox через git worktree
- ADR-004: Skills-first
- ADR-005: Model Router (длина промпта + триггер-слова)
- ADR-006: Бесплатные модели
- ADR-007: Отказ от платных моделей
- ADR-008: RSS как основной источник новостей
- ADR-009: Отказ от LLM-слоя для простых запросов
- ADR-010: Прямой доступ к 19 именованным агентам через task tool
- ADR-011: nemotron-3-ultra-free как модель всех проверяющих (27.08)
- ADR-012: Протокол §3.1-3.3 — оценка времени + x2 timeout + верификация не тимлидом (27.08)
- ADR-013: cleanup-garbage.ps1 автоочистка мусора репо (27.08)

## US-015 Cross-Project Knowledge
- **Статус**: knowledge-index.md создан (8 записей: PAT-001..008)
- **Промпты**: team-lead.txt + team-lead-1/2/3.txt обновлены — добавлена секция Cross-Project Knowledge (US-015)
- **Записи**: ADR-001 Memory Bank, ADR-002 Agent Communication, ADR-003 Sandbox worktree, ADR-004 Skills-first, ADR-005 Model Router, PAT-006 PowerShell encoding, PAT-007 Busy lock recovery, PAT-008 TokenRouter openai-compatible
