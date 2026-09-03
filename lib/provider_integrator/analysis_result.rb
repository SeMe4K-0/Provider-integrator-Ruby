# frozen_string_literal: true

module ProviderIntegrator
  # Результат смыслового анализа спецификации: эндпоинты с проставленной ролью
  # (create/status/cancel/webhook/other) и сводка по обнаружению webhook
  class AnalysisResult
    attr_reader :endpoints, :webhook_found, :webhook_source, :heuristic_webhooks

    def initialize(endpoints:, webhook_found:, webhook_source:, heuristic_webhooks: [])
      @endpoints = endpoints
      @webhook_found = webhook_found
      @webhook_source = webhook_source
      # Вебхуки, опознанные только по косвенному признаку. Хранятся отдельно
      # от webhook_source: в спецификации, где один вебхук назван явно, а второй
      # угадан, источник останется :path, но предупреждение об угаданном
      # всё равно должно прозвучать.
      @heuristic_webhooks = heuristic_webhooks
    end

    def by_role(role)
      endpoints.select { |e| e.role == role }
    end
  end
end
