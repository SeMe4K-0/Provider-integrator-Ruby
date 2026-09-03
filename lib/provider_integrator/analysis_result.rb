# frozen_string_literal: true

module ProviderIntegrator
  # Результат смыслового анализа спецификации: эндпоинты с проставленной ролью
  # (create/status/cancel/webhook/other) и сводка по обнаружению webhook
  class AnalysisResult
    attr_reader :endpoints, :webhook_found, :webhook_source

    def initialize(endpoints:, webhook_found:, webhook_source:)
      @endpoints = endpoints
      @webhook_found = webhook_found
      @webhook_source = webhook_source
    end

    def by_role(role)
      endpoints.select { |e| e.role == role }
    end
  end
end
