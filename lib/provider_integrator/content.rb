# frozen_string_literal: true

module ProviderIntegrator
  # Выбор типа содержимого и извлечение схем и примеров. Логика общая для трёх
  # мест, где встречается content: обычные операции в paths, раздел webhooks:
  # (OpenAPI 3.1) и раздел callbacks: внутри операции (OpenAPI 3.0). Раньше она
  # была продублирована с жёстким ключом application/json, из-за чего вебхуки
  # и вендорные типы теряли и схемы, и примеры.
  module Content
    # Приоритет: обычный JSON, затем любой вендорный +json, затем форма,
    # и лишь потом первый объявленный тип
    PRIORITY = [
      ->(type) { type == "application/json" },
      ->(type) { type.end_with?("+json") },
      ->(type) { type == "application/x-www-form-urlencoded" }
    ].freeze

    def self.select_media_type(content)
      return nil unless content.is_a?(Hash) && !content.empty?

      types = content.keys
      PRIORITY.each do |matcher|
        found = types.find { |type| matcher.call(type.to_s.downcase) }
        return found if found
      end
      types.first
    end

    # Схема тела из requestBody или из объекта ответа
    def self.schema(container)
      media_type = media_type_of(container)
      media_type ? container.dig("content", media_type, "schema") : nil
    end

    # Примеры: одиночный example под ключом "default", именованные — под своими
    def self.examples(container)
      media_type = media_type_of(container)
      return {} if media_type.nil?

      media = container.dig("content", media_type)
      return {} unless media.is_a?(Hash)

      result = {}
      result["default"] = media["example"] if media.key?("example")
      Hash(media["examples"]).each do |name, entry|
        result[name] = entry["value"] if entry.is_a?(Hash) && entry.key?("value")
      end
      result
    end

    def self.responses(responses)
      Hash(responses).each_with_object({}) do |(status, response), acc|
        acc[status] = response.is_a?(Hash) ? schema(response) : nil
      end
    end

    def self.response_examples(responses)
      Hash(responses).each_with_object({}) do |(status, response), acc|
        next unless response.is_a?(Hash)

        found = examples(response)
        acc[status] = found unless found.empty?
      end
    end

    def self.media_type_of(container)
      return nil unless container.is_a?(Hash)

      select_media_type(container["content"])
    end

    private_class_method :media_type_of
  end
end
