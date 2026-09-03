# frozen_string_literal: true

module ProviderIntegrator
  module IR
    # Один эндпоинт API: путь, HTTP-метод и всё, что о нём известно из спецификации
    class Endpoint
      attr_reader :path, :http_method, :operation_id, :summary, :parameters,
                  :request_body_schema, :responses, :security_names,
                  :request_examples, :response_examples

      # Роль эндпоинта (create/status/cancel/webhook/other) — заполняется во второй
      # части конвейера (SemanticAnalyzer), здесь всегда nil
      attr_accessor :role

      def initialize(path:, http_method:, operation_id:, summary:, parameters:,
                      request_body_schema:, responses:, security_names:,
                      request_examples: {}, response_examples: {})
        @path = path
        @http_method = http_method
        @operation_id = operation_id
        @summary = summary
        @parameters = parameters
        @request_body_schema = request_body_schema
        @responses = responses
        @security_names = security_names
        @request_examples = request_examples
        @response_examples = response_examples
        @role = nil
      end

      # Эндпоинт явно объявлен без требования авторизации (security: [])
      def public?
        security_names.empty?
      end

      def to_s
        "#{http_method.upcase} #{path}"
      end
    end
  end
end
