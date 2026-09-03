# frozen_string_literal: true

module ProviderIntegrator
  module IR
    # Корневая модель разобранной спецификации — результат работы SpecLoader.
    # Не зависит от конкретного провайдера: одинаково описывает NovaPay и любой
    # другой провайдер, чья спецификация соответствует OpenAPI 3.x.
    class SpecModel
      attr_reader :title, :version, :servers, :security_schemes, :global_security,
                  :endpoints, :schemas, :raw_webhooks

      def initialize(title:, version:, servers:, security_schemes:, global_security:,
                      endpoints:, schemas:, raw_webhooks:)
        @title = title
        @version = version
        @servers = servers
        @security_schemes = security_schemes
        @global_security = global_security
        @endpoints = endpoints
        @schemas = schemas
        @raw_webhooks = raw_webhooks
      end
    end
  end
end
