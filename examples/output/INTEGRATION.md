# NovaPay Payout API — руководство по интеграции

Документ сгенерирован из спецификации OpenAPI (версия 1.0.0).

## Авторизация

- Схема: ApiKeyAuth (apiKey, заголовок X-API-Key)
- Хранение секретов: `providers.credentials` (encrypted)
- Базовый адрес: `https://api.sandbox.novapay.example/v1`, переопределяется переменной окружения `NOVAPAY_BASE_URL`

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
| 409 | conflict | reject |
| 422 | validation_error | reject |
| 429 | rate_limit | retry_backoff |
| 500 | internal_error | alert_and_retry |

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
    bank_name: operation.payout_requisite.dig("sbp", "bank_name"),
    card_number: operation.payout_requisite.dig("card", "number")
  }.compact
}
```

## ProviderGateway config

```json
{ "external_method": "sbp_payout", "gateway": "RUB_SBP_WITHDRAW" }
```

## Подпись webhook

HMAC-SHA256(тело запроса, `credentials.callback_secret`) → hex → заголовок `X-NovaPay-Signature`

## Требует ручного решения

Нераспознанных элементов нет: все статусы, коды ошибок и поля запроса сопоставлены автоматически.

## Тестирование

Рядом лежат `fixtures.json` с примерами запросов, ответов и уведомлений и самотест
`novapay_integration_self_test_spec.rb`, который поднимает локальный мок провайдера и прогоняет
полный цикл: создание операции → запрос статуса → входящее уведомление с подписью.

```bash
rspec novapay_integration_self_test_spec.rb
```
