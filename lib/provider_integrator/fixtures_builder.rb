# frozen_string_literal: true

require_relative "schema_sampler"

module ProviderIntegrator
  # Собирает тестовые фикстуры: примеры из спецификации, а где их нет — образцы,
  # построенные по схемам. Дополнительно добавляет граничные случаи, которых
  # в спецификации не бывает, но которые обязаны быть в тестах интеграции.
  class FixturesBuilder
    def initialize(analysis:, mapping:)
      @analysis = analysis
      @mapping = mapping
    end

    def build
      {
        "create_request" => create_section,
        "fetch_status" => fetch_section,
        "callback" => callback_section("approved"),
        "callback_failed" => callback_section("rejected"),
        "edge_cases" => edge_cases
      }.compact
    end

    private

    def create_section
      endpoint = @analysis.by_role(:create).first
      return nil if endpoint.nil?

      section = { "request" => request_example(endpoint) }
      endpoint.response_examples.each do |code, examples|
        section["response_#{code}"] = first_example(examples)
      end
      section
    end

    def fetch_section
      endpoint = @analysis.by_role(:status).first
      return nil if endpoint.nil?

      code, examples = endpoint.response_examples.find { |status, _| status.to_s.start_with?("2") }
      body = examples ? first_example(examples) : SchemaSampler.sample(success_schema(endpoint))
      return nil if body.nil?

      { "response_#{code || '200'}" => body }
    end

    # Ищет среди примеров уведомления тот, чей статус приводится к нужному
    # каноническому значению: так фикстура и ожидаемый результат согласованы
    def callback_section(expected_canonical)
      endpoint = @analysis.by_role(:webhook).first
      return nil if endpoint.nil?

      _, payload = endpoint.request_examples.find do |_, value|
        canonical_status(value) == expected_canonical
      end
      return nil if payload.nil?

      { "payload" => payload, "expected_operation_status" => expected_canonical }
    end

    def canonical_status(payload)
      return nil unless payload.is_a?(Hash)

      status = payload[@mapping.status_field.to_s] || payload["event"].to_s.split(".").last
      @mapping.status_map[status.to_s]
    end

    def request_example(endpoint)
      first_example(endpoint.request_examples) || SchemaSampler.sample(endpoint.request_body_schema)
    end

    def first_example(examples)
      return nil unless examples.is_a?(Hash) && !examples.empty?

      examples["default"] || examples.values.first
    end

    def success_schema(endpoint)
      code = endpoint.responses.keys.find { |status| status.to_s.start_with?("2") }
      code ? endpoint.responses[code] : nil
    end

    def edge_cases
      cases = {}
      if @mapping.min_amount
        cases["amount_below_minimum"] = {
          "amount" => @mapping.min_amount - 1,
          "expected" => "check_conditions отклоняет операцию с кодом amount_too_low"
        }
      end
      if @mapping.signature
        cases["invalid_signature"] = {
          "signature" => "0" * 64,
          "expected" => "process_callback возвращает provider.invalid_signature"
        }
      end
      server_error = @mapping.error_map[500]
      if server_error
        cases["provider_error_500"] = {
          "http_code" => 500,
          "expected_code" => server_error[:code],
          "expected_action" => server_error[:action]
        }
      end
      cases.empty? ? nil : cases
    end
  end
end
