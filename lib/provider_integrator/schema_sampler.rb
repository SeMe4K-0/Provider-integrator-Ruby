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

      # Тип может быть не указан: по наличию properties или items видно,
      # что это объект или массив, иначе значение считается строкой
      case schema["type"] || implied_type(schema)
      when "object" then sample_object(schema, depth)
      when "array" then [sample(schema["items"], depth + 1)].compact
      when "integer", "number" then sample_number(schema)
      when "boolean" then true
      else sample_string(schema)
      end
    end

    def self.implied_type(schema)
      return "object" if schema["properties"].is_a?(Hash)
      return "array" if schema.key?("items")

      nil
    end

    def self.sample_object(schema, depth)
      Hash(schema["properties"]).each_with_object({}) do |(name, property), acc|
        acc[name] = sample(property, depth + 1)
      end
    end

    # Ноль в примере платежа выглядит как ошибка, поэтому при отсутствии
    # минимума берётся правдоподобная величина, а не пустое значение
    def self.sample_number(schema)
      minimum = schema["minimum"]
      return minimum if minimum.is_a?(Numeric) && minimum.positive?

      1000
    end

    # Регулярное выражение из pattern — это описание формата, а не значение:
    # подставлять его в фикстуру нельзя. Для известных форматов берётся
    # правдоподобный образец, иначе — нейтральная строка.
    def self.sample_string(schema)
      case schema["format"]
      when "date-time" then "2026-01-01T00:00:00Z"
      when "date" then "2026-01-01"
      when "uuid" then "00000000-0000-4000-8000-000000000000"
      when "email" then "user@example.com"
      else schema["pattern"] ? "string_matching_pattern" : "string"
      end
    end

    private_class_method :implied_type, :sample_object, :sample_number, :sample_string
  end
end
