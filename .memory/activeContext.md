# Active Context — Текущий контекст сессии

## Дата обновления: 2026-08-24

## Текущий статус
- **Этап**: Все фазы A–F закрыты. Система полностью работоспособна.
- **Верификация**: verify-phase.ps1 = 29/29 PASSED; health-check.ps1 = HEALTH: PASS
- **Worktrees**: main + agent/dev-1
- **Трейсы**: traces.jsonl живой; performance.jsonl — 3 сессии, avg 36.4s
- **Команда**: 19 агентов зарегистрированы, делегирование работает
- **Модели**: mimo-v2.5-free (основная), nemotron-3.5-lightning-free (быстрая), nemotron-3-ultra-free (запасная)

## Остаток
- **#7** Коммит + push — единственная незавершённая задача (team-lead)
- **/sync** — закрыт этим прогоном (2026-08-24): activeContext, progress, decisionLog обновлены
- **/team-report** — закрыт этим прогоном: отчёт создан в .memory/reports/team-report-2026-08-24.md
- **Inbox**: 12 старых тестовых файлов — тимлид архивирует

## Блокеры
- opencode-go: лимиты 7/30 дней, 80% месячного лимита израсходовано за 3 дня
- Все платные модели (kimi-k2.7, glm-5.2, deepseek-v4-pro, qwen3.7-plus) недоступны

## Решения (ADR)
- ADR-001: Memory Bank (5 файлов) — параллель с RooFlow
- ADR-002: Agent Communication Protocol (inbox/outbox JSON)
- ADR-003: Sandbox через git worktree (ветка на агента)
- ADR-004: Skills-first (подгрузка скиллов перед работой)
- ADR-005: Model Router (длина промпта + триггер-слова)
- ADR-006: Бесплатные модели (mimo-v2.5-free, nemotron-3.5-lightning-free, nemotron-3-ultra-free)
- ADR-007: Отказ от платных моделей (ограничения подписки)
- ADR-008: RSS как основной источник новостей (Google News RSS)
- ADR-009: Отказ от LLM-слоя для простых запросов (fallback на format_simple_list)
- ADR-010: Прямой доступ к 19 именованным агентам через task tool (ограничение №2 FULL_PLAN снято)
