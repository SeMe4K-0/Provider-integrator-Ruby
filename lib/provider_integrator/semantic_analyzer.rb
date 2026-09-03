# frozen_string_literal: true

require_relative "spec_loader"
require_relative "analysis_result"
require_relative "ir/endpoint"

module ProviderIntegrator
  # Определяет роль каждого эндпоинта (create/status/cancel/webhook/other) по эвристикам:
  # HTTP-метод, паттерны пути, наличие тела запроса, требование авторизации.
  #
  # Поддержаны два способа описания входящих уведомлений в OpenAPI:
  #   1. обычный path с security: [] и характерным именем (как у NovaPay);
  #   2. раздел "webhooks:" верхнего уровня (OpenAPI 3.1) — для каждой операции
  #      внутри него синтезируется псевдо-эндпоинт с путём "webhook:<имя>".
  # Раздел "callbacks:" (колбэки внутри операций, OpenAPI 3.0) сознательно не
  # разбирается — это отдельный механизм, не отражённый в IR Части 1. Лучше явно
  # не поддерживать его, чем притвориться, что он учтён.
  class SemanticAnalyzer
    WEBHOOK_KEYWORDS = %w[webhook callback notification notify].freeze

    def self.analyze(spec_model)
      new(spec_model).analyze
    end

    def initialize(spec_model)
      @spec_model = spec_model
    end

    def analyze
      @heuristic_webhooks = []
      classified = @spec_model.endpoints.map { |endpoint| with_role(endpoint) }
      webhook_from_paths = classified.select { |e| e.role == :webhook }
      webhook_from_section = webhooks_section_endpoints

      AnalysisResult.new(
        endpoints: classified + webhook_from_section,
        webhook_found: !(webhook_from_paths + webhook_from_section).empty?,
        webhook_source: webhook_source(webhook_from_paths, webhook_from_section)
      )
    end

    private

    def with_role(endpoint)
      endpoint.role = classify(endpoint)
      endpoint
    end

    def classify(endpoint)
      return :cancel if cancel?(endpoint)
      return :webhook if webhook?(endpoint)
      return :status if status?(endpoint)
      return :create if create?(endpoint)

      :other
    end

    def cancel?(endpoint)
      %w[post put patch].include?(endpoint.http_method) && endpoint.path.downcase.end_with?("/cancel")
    end

    def webhook?(endpoint)
      return false unless endpoint.http_method == "post"
      return true if name_suggests_webhook?(endpoint)

      # Признак «публичный POST с телом» имеет смысл только там, где спецификация
      # вообще различает открытые и закрытые эндпоинты. Если авторизация не
      # объявлена нигде, публичны все эндпоинты, и создание операции по этому
      # признаку неотличимо от входящего уведомления.
      return false unless auth_distinguishes_endpoints?
      return false unless endpoint.public? && !endpoint.request_body_schema.nil?

      @heuristic_webhooks << endpoint
      true
    end

    def name_suggests_webhook?(endpoint)
      text = "#{endpoint.path} #{endpoint.operation_id}".downcase
      WEBHOOK_KEYWORDS.any? { |keyword| text.include?(keyword) }
    end

    # Спецификация объявляет схемы авторизации и хотя бы один эндпоинт их требует:
    # только тогда security: [] — осознанное исключение, а не общее правило
    def auth_distinguishes_endpoints?
      !@spec_model.security_schemes.empty? && @spec_model.endpoints.any? { |e| !e.public? }
    end

    def status?(endpoint)
      endpoint.http_method == "get" && endpoint.path.include?("{") && !cancel?(endpoint)
    end

    # Проверяется последним: роли cancel и webhook к этому моменту уже исключены
    # порядком проверок в classify
    def create?(endpoint)
      endpoint.http_method == "post" && !endpoint.request_body_schema.nil?
    end

    def webhooks_section_endpoints
      Hash(@spec_model.raw_webhooks).flat_map do |name, path_item|
        next [] unless path_item.is_a?(Hash)

        SpecLoader::HTTP_METHODS.filter_map do |method|
          operation = path_item[method]
          next unless operation.is_a?(Hash)

          synthetic_endpoint(name, method, operation)
        end
      end
    end

    def synthetic_endpoint(name, method, operation)
      endpoint = IR::Endpoint.new(
        path: "webhook:#{name}",
        http_method: method,
        operation_id: operation["operationId"] || name,
        summary: operation["summary"],
        parameters: [],
        request_body_schema: operation.dig("requestBody", "content", "application/json", "schema"),
        responses: {},
        security_names: []
      )
      endpoint.role = :webhook
      endpoint
    end

    # Источник, по которому опознан вебхук. :heuristic означает, что сработал
    # только косвенный признак — такой результат требует проверки человеком.
    def webhook_source(from_paths, from_section)
      return :webhooks_section unless from_section.empty?
      return nil if from_paths.empty?

      (from_paths - @heuristic_webhooks).empty? ? :heuristic : :path
    end
  end
end
