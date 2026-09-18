# Free-модели для кодинга/агентов — сводка (2026-09)

Единый числовой критерий качества: **SWE-bench Verified %** (автономное решение реальных GitHub-issue = написание кода + правка).
Второй фактор: скорость (P50 tokens/sec). Где числа нет — `n/a` (не выдумано).
Источники: OpenRouter docs/rankings/model-карточки, benchlm/steel/metatext/anotherwrapper (SWE-bench, авг-сен 2026), opencode.ai/docs/zen, docs Groq/Google/Mistral.

## Лимиты free-провайдеров
| Провайдер | Лимит |
|---|---|
| OpenRouter `:free` | 20 req/min; 50 req/day (<$10 кредитов) или 1000 req/day (>= $10 хотя бы раз). Учёт на уровне аккаунта (ключи/модели не суммируются). |
| Google AI Studio | до ~1000 req/day |
| Groq | до 14 400 req/day, 30 rpm, ~1000 tokens/sec |
| Mistral | ~1 млрд токенов/мес (без жёсткого дневного) |
| OpenCode Zen (free) | публичного числа нет; fair-use, «limited time», список ротируется |

## Итоговая таблица (лучшие -> худшие)
| # | Модель | Провайдер (free) | SWE-bench Verified | tps P50 | Latency | Контекст | Вердикт |
|---|---|---|---|---|---|---|---|
| 1 | MiniMax M3 | OpenRouter/Zen | 80.5% | н/д | н/д | 1M | Топ качества, медленный/флейки |
| 2 | Inkling-Small | OpenRouter | 80.2% | 93 | 1.19 s | 1.05M | Лучший баланс качество+скорость |
| 3 | DeepSeek V4 Flash 0731 | OpenCode Zen | 79.0% | н/д | н/д | 1M | Сильный код, дешёвый |
| 4 | GLM 5.2 | OpenRouter | 78.7-80% | н/д | н/д | н/д | Отличное ревью/код |
| 5 | Dots3-Note Preview | OpenRouter | 78.4% | н/д | н/д | 512K | Уходит 30.09.2026 |
| 6 | Gemini 3 Flash | Google AI Studio | 78% | высокая | низкая | 1M | Лучший для объёма (1000/сут) |
| 7 | MiMo-V2.5 | OpenCode Zen | ~78% | н/д | н/д | 200K | Резкий рост, годный |
| 8 | Muse Spark 1.2 | OpenCode Zen | 77.4% | н/д | н/д | 1.05M | Contributor-free, сильный |
| 9 | Inkling | OpenRouter | 77.6% | 47 | 1.68 s | 1.05M | Apache 2.0, мультимодал |
| 10 | Nemotron 3 Ultra | OpenRouter/Zen | 70.7-71.9% | 7 | 31 s | 1M | Качество ок, скорость — провал |
| 11 | Laguna XS 2.1 | OpenRouter/Zen | 70.9% | н/д | н/д | 262K | Компактный код-агент |
| 12 | Laguna S 2.1 | OpenRouter/Zen | n/a (T-Bench2.1 70.2%) | н/д | н/д | 262K | Сильный агент, бенча SWE нет |
| 13 | Nemotron 3 Super | OpenCode Zen | 60.5% | 52 | 1.18 s | 262K | structured output, ровный |
| 14 | Nemotron 3.5 Lightning | OpenRouter/Zen | 52.8% | 30 | 1.44 s | 1M | Слабее по коду |
| 15 | North Mini Code | OpenRouter/Zen | n/a | н/д | н/д | 256K | Заточен под OpenCode/SWE-Agent, 64K out |
| 16 | Nemotron 3 Nano 30B | OpenRouter | n/a | 67 | 0.48 s | 256K | Самый быстрый, для мелочей |
| 17 | Ling 3.0 Flash Fin | OpenRouter/Zen | n/a | 169 | 1.09 s | 262K | Финансы, очень быстрый |
| 18 | Nex-N2.5-Pro / Mini | OpenRouter | n/a | н/д | н/д | 262K | GUI/computer-use QA |
| 19 | Nemotron 3 Nano Omni | OpenRouter | n/a | н/д | н/д | 256K | Мультимодал (img/video/audio) |
| 20 | Big Pickle (stealth) | OpenCode Zen | n/a | н/д | н/д | 200K | По отзывам медленный, error-prone |
| 21 | Gemini 3.1 Flash-Lite | Google AI Studio | n/a | высокая | низкая | 1M | Объём/черновики |
| 22 | Codestral | Mistral | n/a | н/д | н/д | 32K | 80+ языков, чистый синтаксис |
| 23 | Mistral Large | Mistral | n/a | н/д | н/д | 128K | ~1 млрд ток/мес |
| 24 | GPT-OSS 20B | Groq | n/a (gpt-oss-120b 26%) | ~1000 | мгновенная | 131K | Сверхскорость, слаб на сложном |
| 25 | DeepSeek R1 (distilled) | Groq | n/a (старая) | ~1000 | мгновенная | 131K | Reasoning, 2025-класс |
| 26 | Llama 3.1 8B | Groq | n/a (низкий) | ~1000 | мгновенная | 131K | Автодополнение, правки 1 функции |
| 27 | Llama 3 / Qwen variants :free | OpenRouter | n/a | н/д | н/д | 8-32K | Тесты редких OSS, 50/сут |

## Выводы
1. Топ: `Inkling-Small` (80.2% + 93 tps) — единственный, кто и качество, и скорость. Далее `DeepSeek V4 Flash`, `Gemini 3 Flash` (для объёма).
2. Избегать для кода: `Nemotron 3 Ultra` free — 7 tps/31 с при 71%. `Nemotron 3.5 Lightning` (52.8%).
3. Ревью: `MiniMax M3`, `GLM 5.2`, `Muse Spark 1.2`. Быстрые мелкие (Groq/Llama 8B/Nano) — только черновики.
4. OpenCode Zen free (задокументированные 8): big-pickle, deepseek-v4-flash-free, mimo-v2.5-free, north-mini-code-free, nemotron-3-ultra-free, nemotron-3.5-lightning-free, ling-3.0-flash-fin-free, muse-spark-1.2-contributor-free.

Оговорка: SWE-bench-числа сторонние (не аудированы), у части free-endpoint'ов публичного прогона нет -> `n/a`.
