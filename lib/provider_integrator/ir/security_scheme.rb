# frozen_string_literal: true

module ProviderIntegrator
  module IR
    # Схема авторизации, объявленная в components/securitySchemes
    class SecurityScheme
      attr_reader :name, :type, :scheme, :location, :header_name, :description

      def initialize(name:, type:, scheme: nil, location: nil, header_name: nil, description: nil)
        @name = name
        @type = type
        @scheme = scheme
        @location = location
        @header_name = header_name
        @description = description
      end
    end
  end
end
