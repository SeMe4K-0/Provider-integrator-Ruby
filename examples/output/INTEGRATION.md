# NovaPay Payout API — руководство по интеграции

Документ сгенерирован из спецификации OpenAPI (версия 1.0.0).

## Авторизация

- Схема: ApiKeyAuth (apiKey, заголовок X-API-Key)
- Хранение секретов: `providers.credentials` (encrypted)
- Базовый адрес: `https://api.sandbox.novapay.example/v1`, переопределяется переменной окружения `NOVAPAY_BASE_URL`

Ключи, которые сервис читает из `credentials` (отсутствие любого приведёт к `KeyError`):

| Ключ | Назначение |
|------|------------|
| `api_key` | ключ API, заголовок X-API-Key |
| `callback_secret` | секрет для проверки подписи уведомлений |

## Методы

| Роль | Endpoint | Назначение | Идемпотентность |
|------|----------|------------|-----------------|
| создание | `POST /payouts` | Создать выплату | `Idempotency-Key` |
| статус | `GET /payouts/{payout_id}` | Получить статус выплаты | — |
| отмена | `POST /payouts/{payout_id}/cancel` | Отменить выплату | — |
| webhook | `POST /webhooks/payout` | Webhook уведомление о смене статуса | — |
| прочее | `GET /balance` | Баланс провайдера | — |

## Маппинг статусов

| Провайдер | Space Payments |
|-----------|----------------|
| pending | in_progress |
| processing | in_progress |
| completed | approved |
| failed | rejected |
| cancelled | rejected |

## Обработка ошибок

| HTTP | Внутренний код | Действие |
|------|----------------|----------|
| 400 | validation_error | reject |
| 401 | invalid_credentials | alert_and_block |
| 402 | insufficient_balance | retry |
| 404 | not_found | reject |
| 409 | duplicate_request | fetch_status |
| 422 | validation_error | reject |
| 429 | rate_limit | retry_backoff |
| 500 | internal_error | alert_and_retry |

Провайдер дополнительно возвращает собственный код в теле ошибки. Один и тот же
HTTP-статус может означать разные причины, поэтому код стоит логировать и разбирать
отдельно:

- `validation_error`
- `insufficient_balance`
- `recipient_not_found`
- `bank_unavailable`
- `amount_limit_exceeded`
- `rate_limit_exceeded`
- `internal_error`

## Тело запроса на создание операции

Сумма передаётся в минорных единицах, поэтому умножается на 100.

```ruby
{
  amount: (operation.amount * 100).to_i,
  currency: "RUB",
  external_id: operation.id,
  recipient: {
    type: "sbp",
    phone: operation.payout_requisite.dig("sbp", "phone"),
    bank_code: operation.payout_requisite.dig("sbp", "bank_code"),
    bank_name: operation.payout_requisite.dig("sbp", "bank_name")
  }.compact
}
```

## ProviderGateway config

```json
{ "external_method": "sbp_payout", "gateway": "RUB_SBP_WITHDRAW" }
```

## Формат уведомления

`process_callback(payload)` принимает один аргумент — так требует контракт `Provider::BaseService`.
Платформа передаёт в нём конверт:

```ruby
{
  "body" => { … разобранное тело уведомления … },
  "raw_body" => '{"…"}',                       # сырое тело запроса, байт в байт
  "headers" => { "X-NovaPay-Signature" => "…" }
}
```

Тело можно передать и напрямую, без ключа `body`, но `raw_body` обязателен: подпись считается от исходных байтов, а пересобранный JSON не совпадёт с ними по порядку ключей и экранированию. Уведомление без сырого тела отклоняется с `provider.raw_body_required`, без подписи — с `provider.missing_signature`.

## Подпись webhook

HMAC-SHA256(сырое тело запроса, `credentials.callback_secret`) → hex → заголовок `X-NovaPay-Signature`

## Требует ручного решения

Нераспознанных элементов нет: все статусы, коды ошибок и поля запроса сопоставлены автоматически.

## Тестирование

Рядом лежат `fixtures.json` с примерами запросов, ответов и уведомлений и самотест
`novapay_integration_self_test_spec.rb`, который поднимает локальный мок провайдера и прогоняет
полный цикл: создание операции → запрос статуса → входящее уведомление с подписью.

```bash
rspec novapay_integration_self_test_spec.rb
```
