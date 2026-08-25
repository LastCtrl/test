import json
import os

mcp_block = "\n\n## ИНСТРУМЕНТЫ MCP (обязательно применять)\n- context7 (context7_resolve-library-id / context7_query-docs): перед написанием кода на ЛЮБОЙ библиотеке/фреймворке — сначала актуальная документация оттуда, не полагайся на память модели.\n- sequential-thinking: при получении сложной многошаговой задачи (3+ шага, архитектура, дебаг непонятного) — планируй через него.\n- hermes-atlas-mcp: если задаче нужен скилл/тул, которого нет в .agents/skills/ — поискай готовый в каталоге Atlas, прежде чем писать с нуля.\nЕсли инструмент недоступен в твоей сессии — не падай, работай без него и отметь это в ответе."

agents_to_update = [
    "team-lead",
    "product-manager", 
    "dev-1",
    "dev-2", 
    "dev-3",
    "frontend",
    "backend",
    "db-specialist",
    "mobile-dev",
    "qa-engineer"
]

agents_dir = r"D:\Тест\agent-hq\.opencode\agents"

for filename in os.listdir(agents_dir):
    if not filename.endswith(".json"):
        continue
    if filename.replace(".json", "") not in agents_to_update:
        continue
    
    filepath = os.path.join(agents_dir, filename)
    with open(filepath, "r", encoding="utf8") as f:
        data = json.load(f)
    
    original_prompt = data["prompt"]
    data["prompt"] += mcp_block
    
    with open(filepath, "w", encoding="utf8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    print(f"Updated: {filename}")

print("Done!")