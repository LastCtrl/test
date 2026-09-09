# Pull Request Template — agent-hq

## Summary
Краткое описание изменений (1-2 предложения).

## Changes
Список изменений по категориям:

### Skills & MCP Enforcement
- [ ] skill-enforcement/SKILL.md создан
- [ ] registry.json: required_skills для всех 19 агентов
- [ ] AGENTS.md: §3.4 Self-report Mandate, §3.5 Validator Enforcement, §3.6 Superpowers Integration
- [ ] .agents/skills/README.md: каталог 24 скиллов + role→skill mapping
- [ ] .opencode/agents/prompts/README.md: структура промптов + agent→skills+MCP таблица
- [ ] superpowers: 4 скилла (spec, plan, implement, test)
- [ ] sync-agents.ps1 выполнен, opencode.json обновлён

### Documentation
- [ ] AGENTS.md обновлён
- [ ] README.md (если обновлялся)
- [ ] .agents/skills/README.md создан
- [ ] .opencode/agents/prompts/README.md создан
- [ ] CHANGELOG.md обновлён

### Scripts & Validation
- [ ] compliance-gate.ps1 создан
- [ ] health-check.ps1 интегрирован с validator
- [ ] verify-phase.ps1 проходит (29/29+)

### Testing
- [ ] 3 тестовые задачи выполнены через task tool
- [ ] Трейсы показывают SKILLS_LOADED ≠ [] для всех задач
- [ ] MCP_USED содержит context7/sequential-thinking где применимо
- [ ] COMPLIANCE: true в self-report

## Testing
Описание того, как тестировалось:

1. Задача 1: <описание> → <агент> → PASS/FAIL
2. Задача 2: <описание> → <агент> → PASS/FAIL
3. Задача 3: <описание> → <агент> → PASS/FAIL

## Risk Assessment
| Риск | Вероятность | Митигация |
|------|-------------|-----------|
| Дешёвая модель игнорирует enforcement | Высокая | compliance-gate.ps1 REJECT + retry |
| MCP недоступен | Средняя | `mcp: offline` в трейсе, работа без MCP |
| Merge conflicts | Низкая | Короткоживущая branch, squash merge |

## Checklist
- [ ] Все коммиты conventional (`feat:`, `docs:`, `chore:`, `test:`)
- [ ] Self-report записан в CONTEXT-BUFFER.md для всех задач
- [ ] SKILLS_LOADED и MCP_USED заполнены в self-report
- [ ] Нет секретов в коде/конфигах
- [ ] verify-phase.ps1 = 29/29 PASS
- [ ] health-check.ps1 = HEALTH: PASS

## Screenshots / Logs (если применимо)
Вставьте ссылки на трейсы или логи из `%LOCALAPPDATA%\opencode\agent-hq-traces\`

## Reviewers
Обязательные reviewers (GitHub):
- @qa-engineer — приёмка трейсов, compliance
- @code-reviewer — код-ревью всех изменений
- @security-auditor — security audit
- @tech-writer — документация

## Deployment Notes
После merge:
1. Перезапустить opencode TUI (конфиг кэшируется)
2. Проверить что новые скиллы доступны через `skill <name>`
3. Проверить что delegation template работает в team-lead prompt