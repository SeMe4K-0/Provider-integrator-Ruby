# frozen_string_literal: true

module ProviderIntegrator
  # Результат сопоставления данных: структурированные соответствия для кодогенерации
  # и человекочитаемый отчёт (report) — оба строятся за один проход DataMapper.
  #
  # fields — канонический признак поля → { name:, path:, schema:, required: },
  # где path хранит путь до поля в теле запроса (например ["recipient", "phone"]),
  # чтобы генератор восстановил вложенную структуру, а не плоский список.
  class MappingResult
    attr_reader :report, :status_field, :status_map, :error_map, :provider_error_codes,
                :fields, :amount_factor, :amount_confirmed, :min_amount, :currency,
                :provider_id_field, :webhook_id_field, :signature

    def initialize(report:, status_field:, status_map:, error_map:, provider_error_codes:,
                    fields:, amount_factor:, amount_confirmed:, min_amount:, currency:,
                    provider_id_field:, webhook_id_field:, signature:)
      @provider_error_codes = provider_error_codes
      @report = report
      @status_field = status_field
      @status_map = status_map
      @error_map = error_map
      @fields = fields
      @amount_factor = amount_factor
      @amount_confirmed = amount_confirmed
      @min_amount = min_amount
      @currency = currency
      @provider_id_field = provider_id_field
      @webhook_id_field = webhook_id_field
      @signature = signature
    end

    # Нужна ли конвертация суммы в минорные единицы при сборке запроса
    def amount_conversion?
      amount_factor != 1
    end
  end
end
