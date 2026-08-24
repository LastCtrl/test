# Active Context — Текущий контекст сессии

## Дата обновления: 2026-08-21

## Текущий статус
- **Этап**: MVP (Foundation + Core Logic) — фазы 2.5, 0, 0.5, 1, 3, 5, 7, 14
- **Система**: agent-hq структура создана, Memory Bank заполнен, inbox/outbox работает
- **Модели**: mimo-v2.5-free (основная), nemotron-3.5-lightning-free (быстрая), nemotron-3-ultra-free (запасная)

## Активные задачи
1. **lk-fl verify-code** (PENDING) — Spring Boot + Angular + Docker Compose, D:\ЛичныйКабинет\lk_fl-main
   - verify-code ПОЧИНЕН (AUTH_CODE_TTL как миллисекунды → @DurationUnit(SECONDS))
   - JIT-ошибка ПОЧИНЕНА (ng-query-params-service → TypeScript)
   - Осталось: убрать debug-логи [MOCK], удалить Dockerfile.checkstyle (СДЕЛАНО)

2. **news-bot** (RESOLVED) — D:\Тест\news-bot\
   - AI-анализатор: duration_minutes влияет на объём саммари
   - TTS-озвучка: предзагрузка кэша, прогресс-сообщения
   - Дайджест: AI-анализ вместо сырого RSS
   - Баг: попадание текстов reply-кнопок в темы/поиск

## Недавняя активность (из CONTEXT-BUFFER.md)

### Последние resolved задачи
- [2026-08-18] backend: verify-code ПОЧИНЕН (AUTH_CODE_TTL milliseconds bug)
- [2026-08-18] frontend: JIT-ошибка ПОЧИНЕНА (ng-query-params-service → TypeScript)
- [2026-08-18] tech-writer: KNOWLEDGE-BASE.md дополнен разделом lk-fl
- [2026-08-18] code-reviewer: APPROVE-WITH-COMMENTS (8/10) - найден родственный баг M1
- [2026-08-18] security-auditor: аудит lk-fl завершён

### Последние открытые задачи
- [2026-08-18] user: "ошибки во фронте: verify-code → 400, JIT compiler unavailable" → ПОЧИНЕН

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
