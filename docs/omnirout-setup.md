# Настройка OmniRoute для agent-hq

> ⚠️ **СТАТУС 2026-08-26: ПРИОСТАНОВЛЕНО (блокировка среды).**
> Шлюз установлен (omniroute 3.8.49, localhost:20128, health OK), OpenRouter-ключ валиден,
> но исходящие вызовы апстримов игнорируют прокси корпсети (cntlm): ping проходит, реальные вызовы падают.
> Возобновление: VPN или тикет в ИБ на доступ к api.openrouter.ai / api.groq.com. Инструкция ниже актуальна.

> **Цель**: подключить шлюз OmniRoute к системе agent-hq для ротации бесплатных моделей, авто-fallback и единого эндпоинта.

---

## Содержание

1. [Что даёт OmniRoute](#1-что-даёт-omniroute)
2. [Шаг 1 — Регистрация у провайдеров](#2-шаг-1--регистрация-у-провайдеров)
3. [Шаг 2 — Установка и запуск OmniRoute](#3-шаг-2--установка-и-запуск-omniroute)
4. [Шаг 3 — Куда вставить ключи провайдеров](#4-шаг-3--куда-вставить-ключ провайдеров)
5. [Шаг 4 — Конфигурация opencode.json](#5-шаг-4--конфигурация-opencodejson)
6. [Шаг 5 — Проверочный запрос](#6-шаг-5--проверочный-запрос)
7. [Откат](#7-откат)

---

## 1. Что даёт OmniRoute

[OmniRoute](https://github.com/diegosouzapw/OmniRoute) — бесплатный MIT AI-шлюз, который объединяет **350+ провайдеров** (включая **90+ бесплатных**) за одним эндпоинтом.

**Ключевые возможности для agent-hq:**

| Возможность | Описание |
|-------------|----------|
| **Ротация бесплатных моделей** | Auto-Combo (`model: "auto"`) автоматически выбирает лучшую доступную бесплатную модель из 455+ бесплатных опций |
| **Авто-fallback** | 4-уровневая каскадная маршрутизация: Subscription → API Key → Cheap → Free. Если один провайдер упал — запрос переключается на следующий |
| **Единый эндпоинт** | Все 353 провайдера доступны через `http://localhost:20128/v1` — один URL для всех инструментов |
| **Экономия токенов** | RTK + Caveman сжатие экономит 15–95% токенов автоматически |
| **Плагин @omniroute/opencode-plugin** | Динамическое обнаружение моделей — при старте OpenCode подтягивается актуальный каталог моделей из `/v1/models` |

**Схема работы:**

```
OpenCode (агенты)
    ↓ HTTP POST
OmniRoute (localhost:20128/v1)
    ↓ Auto-Combo / circuit breaker / quota-aware routing
    ↓
┌─────────────────────────────────────────────┐
│  Tier 1: Subscription (платные подписки)    │
│  Tier 2: API Key (ключи провайдеров)        │
│  Tier 3: Cheap (дешёвые модели)             │
│  Tier 4: Free (бесплатные модели)           │
└─────────────────────────────────────────────┘
```

---

## 2. Шаг 1 — Регистрация у провайдеров

### Минимум для старта

| Провайдер | Ссылка | Что бесплатно | Где получить ключ |
|-----------|--------|---------------|-------------------|
| **OpenRouter** | [openrouter.ai](https://openrouter.ai) | Модели `:free` (28+ моделей: DeepSeek R1, Llama 3.3, Qwen3 Coder, Gemini Flash) — 20 RPM, 50 RPD | Settings → API Keys → Create Key |
| **Groq** | [console.groq.com](https://console.groq.com) | 30 RPM, до 14.4K RPD на Llama 3.1 8B, быстрый инференс | API Keys → Create API Key |

### Дополнительные провайдеры (расширяют доступные модели)

| Провайдер | Ссылка | Что бесплатно | Где получить ключ |
|-----------|--------|---------------|-------------------|
| **Cerebras** | [cloud.cerebras.ai](https://cloud.cerebras.ai) | 1M токенов/день, 5 RPM, GPT-OSS 120B, GLM 4.7 | Dashboard → API Keys |
| **GitHub Models** | [github.com/marketplace/models](https://github.com/marketplace/models) | 160+ моделей (GPT-5, DeepSeek-R1, Grok-3) — 50 RPD для топ-моделей, 150 RPD для остальных. **Без ключа** для базового доступа, PAT для расширенных лимитов | Settings → Developer settings → Tokens → Generate new token (classic) |
| **OpenCode Free** | [opencode.ai](https://opencode.ai) | Ключless — работает без API-ключа | Не требуется |

> **Совет**: Начните с OpenRouter + Groq. Это покроет 90% потребностей. Остальные добавляйте по необходимости.

---

## 3. Шаг 2 — Установка и запуск OmniRoute

### Вариант A: npm (рекомендуется)

```bash
npm install -g omniroute
```

После установки запустите:

```bash
omniroute
```

> При первом запуске откроется веб-панель на `http://localhost:20128`. Следуйте интерактивному мастеру настройки.

### Вариант B: Docker

```bash
docker run -d `
  --name omniroute `
  --restart unless-stopped `
  --stop-timeout 40 `
  -p 127.0.0.1:20128:20128 `
  -v omniroute-data:/app/data `
  diegosouzapw/omniroute:latest
```

> ⚠️ **Проверить при установке**: порт 20128 не занят другим сервисом. Проверка: `netstat -ano | findstr ":20128"`

### Вариант C: From Source

```bash
git clone https://github.com/diegosouzapw/OmniRoute.git
cd OmniRoute
npm install
npm run dev
```

### Вариант D: Без ключей (zero-config)

OmniRoute работает сразу после установки — `model: "auto"` маршрутизирует через бесплатные keyless-провайдеры (OpenCode Free, Felo). Ключи провайдеров добавляются позже для расширения каталога.

```bash
# Проверка без ключей:
curl http://localhost:20128/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'
```

> ⚠️ **Проверить при установке**: Node.js ≥ 22 (рекомендуется 24 LTS). Проверка: `node --version`

---

## 4. Шаг 3 — Куда вставить ключи провайдеров

### Способ 1: Через веб-панель (рекомендуется)

1. Откройте `http://localhost:20128` в браузере
2. Перейдите в раздел **Providers**
3. Подключите нужные провайдеры и вставьте API-ключи
4. Ключи сохраняются локально в зашифрованном виде (AES-256-GCM)

### Способ 2: Через переменные окружения

Создайте файл `.env` в корне проекта (или установите системные переменные):

```bash
# OpenRouter
OPENROUTER_API_KEY=sk-or-v1-ваш-ключ

# Groq
GROQ_API_KEY=gsk_ваш-ключ

# Cerebras
CEREBRAS_API_KEY=csk-ваш-ключ

# GitHub Models (PAT)
GITHUB_TOKEN=ghp_ваш-токен
```

> ⚠️ **Важно**: файл `.env` должен быть в `.gitignore`. Никогда не коммитьте ключи.

### Способ 3: API-ключ самого OmniRoute

Для локальной установки можно отключить требование API-ключа OmniRoute:

```
REQUIRE_API_KEY=false
```

Тогда используется ключ по умолчанию `sk_omniroute`. Это безопасно только для локальной работы.

---

## 5. Шаг 4 — Конфигурация opencode.json

### Путь A: Плагин (рекомендуется — динамический каталог моделей)

Добавьте в `opencode.json`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["@omniroute/opencode-plugin"]
}
```

Плагин при старте OpenCode обращается к `GET /v1/models` и автоматически подтягивает актуальный каталог моделей. Новые модели в OmniRoute появляются без переконфигурации.

### Путь B: Статический провайдер (legacy)

Если плагин не подходит (CI/скрипты), используйте `@omniroute/opencode-provider`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "omniroute": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:20128/v1",
        "apiKey": "sk_omniroute"
      },
      "models": {
        "auto": { "name": "Auto-Combo (recommended)" },
        "claude-opus-4-5-thinking": { "name": "Claude Opus 4.5 Thinking" },
        "claude-sonnet-4-5-thinking": { "name": "Claude Sonnet 4.5 Thinking" },
        "gemini-3.1-pro-high": { "name": "Gemini 3.1 Pro" },
        "gemini-3-flash": { "name": "Gemini 3 Flash" }
      }
    }
  }
}
```

> ⚠️ **Проверить при установке**: `@omniroute/opencode-plugin` — рекомендуемый путь. Статический блок `@omniroute/opencode-provider` помечен как deprecated.

### Пример: переключение агента на OmniRoute

В секции `agent` конкретного агента:

```jsonc
{
  "agent": {
    "dev-1": {
      "model": "omniroute/auto",
      "small_model": "omniroute/auto"
    }
  }
}
```

Или для конкретной модели:

```jsonc
{
  "agent": {
    "dev-1": {
      "model": "omniroute/claude-opus-4-5-thinking"
    }
  }
}
```

---

## 6. Шаг 5 — Проверочный запрос

### Тест шлюза

```bash
# Проверка что OmniRoute работает
curl http://localhost:20128/v1/chat/completions `
  -H "Content-Type: application/json" `
  -d '{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}'
```

Ожидаемый результат: JSON-ответ с `"choices"` и содержимым `"OK"`.

### Тест из OpenCode

Запустите OpenCode и выполните запрос к агенту, использующему OmniRoute:

```
/model omniroute/auto
Привет! Скажи OK если ты работаешь через OmniRoute.
```

### Запись в CONTEXT-BUFFER

После успешной проверки добавьте запись:

```
[дата] team-lead → bus:
TYPE: update | PRIORITY: medium
CONTENT: OmniRoute подключён. Шлюз: localhost:20128. Провайдеры: OpenRouter, Groq. Тест: model "auto" → OK. Плагин @omniroute/opencode-plugin активен.
STATUS: resolved
```

---

## 7. Откат

Если OmniRoute не подходит или вызывает проблемы:

### Шаг 1: Остановите шлюз

```bash
# npm
omniroute stop

# Docker
docker stop omniroute
docker rm omniroute
```

### Шаг 2: Верните прямой конфиг

Удалите блок `plugin` или `provider.omniroute` из `opencode.json`:

```jsonc
// Было:
{
  "plugin": ["@omniroute/opencode-plugin"]
}

// Стало:
{
  "$schema": "https://opencode.ai/config.json"
  // ... остальные настройки без OmniRoute
}
```

### Шаг 3: Проверьте работоспособность

Запустите OpenCode и убедитесь, что модели работают напрямую (как до подключения OmniRoute).

---

## Список того, что пользователю подготовить

| # | Что подготовить | Статус |
|---|-----------------|--------|
| 1 | Node.js ≥ 22 (рекомендуется 24 LTS) | Проверить: `node --version` |
| 2 | Аккаунт OpenRouter (бесплатно, без карты) | Зарегистрироваться, получить API-ключ |
| 3 | Аккаунт Groq (бесплатно, без карты) | Зарегистрироваться, получить API-ключ |
| 4 | *(Опционально)* Аккаунт Cerebras | Зарегистрироваться, получить API-ключ |
| 5 | *(Опционально)* GitHub PAT | Settings → Developer settings → Tokens |
| 6 | Порт 20128 свободен | `netstat -ano | findstr ":20128"` |
| 7 | Backup текущего `opencode.json` | Скопировать перед изменениями |

---

*Документ создан для проекта agent-hq. Источники: [OmniRoute GitHub](https://github.com/diegosouzapw/OmniRoute), [OPENCODE.md](https://github.com/diegosouzapw/OmniRoute/blob/main/docs/frameworks/OPENCODE.md), [Free Tiers](https://github.com/diegosouzapw/OmniRoute/wiki/Free-Tiers).*
