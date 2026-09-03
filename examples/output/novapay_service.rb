# frozen_string_literal: true

require "json"
require "openssl"

# Сервис сгенерирован из спецификации "NovaPay Payout API" (версия 1.0.0).
# Правки вносите в спецификацию или в config/rules/*.yml и перегенерируйте файл.
class Provider
  class NovapayService < BaseService
    BASE_URL = ENV.fetch("NOVAPAY_BASE_URL", "https://api.sandbox.novapay.example/v1")

    # Заголовок с подписью входящего уведомления
    SIGNATURE_HEADER = "X-NovaPay-Signature"

    # Минимальная сумма операции, из ограничения minimum в спецификации
    MIN_AMOUNT = 1000

    # Статусы провайдера → статусы Space Payments
    STATUS_MAP = {
      "pending" => "in_progress",
      "processing" => "in_progress",
      "completed" => "approved",
      "failed" => "rejected",
      "cancelled" => "rejected",
    }.freeze

    # HTTP-коды провайдера → внутренние коды ошибок и действия
    ERROR_MAP = {
      400 => { code: "validation_error", action: "reject" },
      401 => { code: "invalid_credentials", action: "alert_and_block" },
      402 => { code: "insufficient_balance", action: "retry" },
      404 => { code: "not_found", action: "reject" },
      409 => { code: "conflict", action: "reject" },
      422 => { code: "validation_error", action: "reject" },
      429 => { code: "rate_limit", action: "retry_backoff" },
      500 => { code: "internal_error", action: "alert_and_retry" },
    }.freeze

    def check_conditions(operation, request_method = "create")
      base_result = super
      return base_result if base_result.failed?
      return failure(:unprocessable_entity, "amount_too_low") if operation.amount < MIN_AMOUNT

      success
    end

    def create_request(operation, request_method = "create")
      response = client.post("#{base_url}/payouts", json: build_payload(operation), headers: auth_headers)
      parse_create_response(operation, response)
    rescue Provider::RateLimitError
      failure(:too_many_requests, "provider.rate_limit")
    rescue Provider::UnauthorizedError
      failure(:unauthorized, "provider.invalid_credentials")
    end

    def fetch_status(operation)
      response = client.get("#{base_url}/payouts/#{operation.provider_operation_id}", headers: auth_headers)
      return failure(*error_for(response.code)) unless response.success?

      map_status(response.body["status"])
    rescue Provider::RateLimitError
      failure(:too_many_requests, "provider.rate_limit")
    rescue Provider::UnauthorizedError
      failure(:unauthorized, "provider.invalid_credentials")
    end

    def cancel_request(operation)
      response = client.post("#{base_url}/payouts/#{operation.provider_operation_id}/cancel", json: {}, headers: auth_headers)
      return failure(*error_for(response.code)) unless response.success?

      map_status(response.body["status"])
    end

    # Обработка входящего уведомления. Подпись обязательна: без неё уведомление
    # отклоняется, даже если тело выглядит корректным.
    def process_callback(payload, signature: nil, raw_body: nil)
      return failure(:unauthorized, "provider.missing_signature") if signature.nil?
      return failure(:unauthorized, "provider.invalid_signature") unless valid_signature?(raw_body || JSON.generate(payload), signature)

      provider_operation_id = payload["payout_id"]
      status = payload["status"] || payload["event"].to_s.split(".").last

      case STATUS_MAP[status.to_s]
      when "approved" then approve_operation(provider_operation_id)
      when "rejected" then reject_operation(provider_operation_id, payload.dig("error", "code"))
      when "in_progress" then progress_operation(provider_operation_id)
      else failure(:unprocessable_entity, "provider.unknown_status")
      end
    end

    private

    # Базовый адрес API; переопределяется через переменную окружения для стендов и тестов
    def base_url
      ENV.fetch("NOVAPAY_BASE_URL", BASE_URL)
    end

    # Заголовки авторизации: ApiKeyAuth (apiKey, заголовок X-API-Key)
    def auth_headers
      { "X-API-Key" => credentials.fetch(:api_key) }
    end

    # TODO: поле recipient.type: выбрано "sbp" из вариантов sbp, card — проверьте, что это соответствует шлюзу
    # Незаполненные реквизиты отбрасываются: провайдеру не отправляются поля со значением nil
    def build_payload(operation)
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
      }.compact
    end

    def parse_create_response(operation, response)
      return failure(*error_for(response.code)) unless response.success?

      operation.provider_operation_id = response.body["id"]
      map_status(response.body["status"])
    end

    # Статус провайдера в статус Space Payments; неизвестное значение не угадывается
    def map_status(provider_status)
      canonical = STATUS_MAP[provider_status.to_s]
      return failure(:unprocessable_entity, "provider.unknown_status") if canonical.nil?

      success(status: canonical)
    end

    def error_for(http_code)
      rule = ERROR_MAP[http_code] || { code: "internal_error", action: "alert_and_retry" }
      [:unprocessable_entity, "provider.#{rule[:code]}"]
    end

    # Подпись тела запроса: HMAC-SHA256, кодировка hex
    def valid_signature?(raw_body, signature)
      expected = OpenSSL::HMAC.hexdigest("SHA256", credentials.fetch(:callback_secret), raw_body)
      OpenSSL.secure_compare(expected, signature.to_s)
    end
  end
end
