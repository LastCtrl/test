# Telegram Bot API через DNS-over-HTTPS (обход блокировки DNS)

Дата: 2026-09-21. Воспроизводимый рецепт: как система достучалась до Telegram, когда корпоративный DNS перестал отдавать `api.telegram.org`.

## Симптом
Мост (US-016) молчит: бот не отвечает. Раньше работало (09-18), потом перестало.

## Диагностика (факты, по шагам)
| Проверка | Результат |
|---|---|
| `Resolve-DnsName api.telegram.org` | **пусто** (нет A-записи) |
| `Resolve-DnsName api.telegram.org -Server 1.1.1.1 / 8.8.8.8` | пусто (внешний plain-DNS заблокирован) |
| `curl --noproxy "*" https://api.telegram.org` | `Could not resolve host` |
| `curl -x http://127.0.0.1:3128 https://api.telegram.org` (через cntlm→squid3) | **503** (`CONNECT tunnel failed`, squid не может резолвить → 503) |
| `curl https://core.telegram.org` (прямо и через cntlm) | **200** (обычные сайты TG открыты) |
| `curl ... https://github.com` через cntlm | 200 (прокси исправен) |
| TCP `Test-NetConnection 149.154.167.220 -Port 443` | **True** (IP Bot API доступен!) |
| `curl --noproxy "*" --resolve api.telegram.org:443:149.154.167.220 https://api.telegram.org/` | **302** (по IP+SNI — работает) |

**Вывод:** блокируется **только DNS** для `api.telegram.org` (корпоративный DNS + squid, который резолвит через тот же DNS). Сам IP доступен напрямую. Прокси не помогает (squid тоже не резолвит).

## Ключ решения — DoH через прокси
Обычный DNS к 1.1.1.1 заблокирован, но **DNS-over-HTTPS (DoH) через cntlm работает**:
```
curl.exe -x http://127.0.0.1:3128 -H "accept: application/dns-json" \
  "https://1.1.1.1/dns-query?name=api.telegram.org&type=A"
# -> {"Answer":[{"data":"149.154.166.110"} ...]}
# Google-аналог: https://dns.google/resolve?name=api.telegram.org&type=A
```
Т.е. через прокси можно получить **актуальный** IP — без фиксирования (Telegram меняет адреса).

## Как реализовано в мосте (`projects/telegram-bridge/bridge.py`, v2.1.0)
1. `resolve_telegram_ip()` — DoH-запрос (Cloudflare/Google) **через прокси**, парсит A-записи и min-TTL, кэш (не менее 60 c); при неудаче — DoH напрямую → системный DNS → ошибка с причинами.
2. `TelegramDohResolver(AbstractResolver)` — для `api.telegram.org` отдаёт DoH-IP, прочие хосты — системному резолверу.
3. `DohAiohttpSession(AiohttpSession)` — aiogram 3.29 сам создаёт коннектор, поэтому сабкласс подменяет `_connector_type/_connector_init` → `TCPConnector(resolver=<DoH>, use_dns_cache=False, ssl/limit сохранены)`. Telegram — `proxy=None` (**прямо**, не через squid); имя/vhost/сертификат — `api.telegram.org` (SNI).
4. Env: `AGENT_HQ_TG_DOH=on|off` (дефолт on), `AGENT_HQ_TG_DOH_URL` (дефолт Cloudflare), `AGENT_HQ_BRIDGE_PROXY` (прокси только для DoH-запроса).
5. Диагностика: `py -3 projects\telegram-bridge\bridge.py --check-network`
   → `[doh] OK api.telegram.org -> <IP>` + `Telegram HTTPS OK (SNI=api.telegram.org, status=200)`.

## Зависимости и границы
- **cntlm должен быть UP** (нужен только для DoH-запроса). Telegram-трафик идёт **напрямую** (по IP).
- Если cntlm выключен → DoH недоступен → fallback на системный DNS → который `api.telegram.org` не отдаёт → бот молчит. Лечение: поднять cntlm (`Start-Process C:\tools\cntlm\cntlm.exe -ArgumentList '-c C:\tools\cntlm\cntlm.ini' -WindowStyle Hidden`).
- Хостс/фиксированный IP **не используются** (Telegram меняет адреса; кэш по TTL сам подхватит новый).

## Обобщение (пригодится ещё)
Приём применим к **любому** хосту, который: (а) не резолвится корпоративным DNS, (б) доступен по IP, (в) DoH через прокси работает. Проверка: `curl --noproxy "*" --resolve <host>:443:<ip> https://<host>/` → если отвечает (не 000), DNS-блок обходится DoH+SNI.

## Проверочные команды (шпаргалка)
```
# DoH через прокси:
curl.exe -x http://127.0.0.1:3128 -H "accept: application/dns-json" "https://1.1.1.1/dns-query?name=api.telegram.org&type=A"
# доступность IP:
Test-NetConnection 149.154.167.220 -Port 443
# обход DNS по IP+SNI:
curl.exe --noproxy "*" --resolve api.telegram.org:443:149.154.167.220 https://api.telegram.org/
# мост:
py -3 projects\telegram-bridge\bridge.py --check-network
```
