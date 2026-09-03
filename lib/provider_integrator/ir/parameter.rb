# frozen_string_literal: true

module ProviderIntegrator
  module IR
    # Параметр запроса: значение из query-строки, пути или заголовка
    class Parameter
      attr_reader :name, :location, :schema_type, :format, :pattern, :description

      def initialize(name:, location:, required:, schema_type:, format: nil, pattern: nil, description: nil)
        @name = name
        @location = location
        @required = required
        @schema_type = schema_type
        @format = format
        @pattern = pattern
        @description = description
      end

      def required?
        @required
      end
    end
  end
end
