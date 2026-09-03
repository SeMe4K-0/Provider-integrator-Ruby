# frozen_string_literal: true

module ProviderIntegrator
  # Строит пример значения по JSON-схеме, когда в спецификации нет готового example.
  # Приоритет: example из схемы → первое значение enum → значение по типу.
  class SchemaSampler
    MAX_DEPTH = 6

    def self.sample(schema, depth = 0)
      return nil unless schema.is_a?(Hash)
      return schema["example"] if schema.key?("example")
      return Array(schema["enum"]).first if schema["enum"].is_a?(Array)
      return nil if depth > MAX_DEPTH

      case schema["type"]
      when "object" then sample_object(schema, depth)
      when "array" then [sample(schema["items"], depth + 1)].compact
      when "integer" then schema["minimum"] || 0
      when "number" then schema["minimum"] || 0
      when "boolean" then true
      else sample_string(schema)
      end
    end

    def self.sample_object(schema, depth)
      Hash(schema["properties"]).each_with_object({}) do |(name, property), acc|
        acc[name] = sample(property, depth + 1)
      end
    end

    # Для строк с pattern возвращается сам шаблон: подставить осмысленное значение
    # без генерации по регулярному выражению нельзя, а выдумывать его не нужно
    def self.sample_string(schema)
      return schema["pattern"] if schema["pattern"]

      schema["format"] == "date-time" ? "2026-01-01T00:00:00Z" : "string"
    end

    private_class_method :sample_object, :sample_string
  end
end
