# frozen_string_literal: true

module ProviderIntegrator
  # Сводит композитные схемы к одному виду, понятному остальному конвейеру.
  # Без этой стадии схема, собранная из подсхем, приходит дальше с единственным
  # ключом allOf, и сопоставление полей не находит ничего.
  #
  # allOf   — сливается в одну схему: объединяются properties, складываются
  #           списки required. Конфликт типов у одноимённых полей не разрешается
  #           молча, а попадает в замечания.
  # oneOf   — выбирается один вариант (по дискриминатору или первый), остальные
  # anyOf     перечисляются в замечаниях: отправить в одном запросе можно только
  #           один вариант реквизитов.
  # nullable — 3.0-форма nullable: true и 3.1-форма type: [x, "null"] сводятся
  #           к одному признаку.
  class SchemaNormalizer
    COMPOSITION_KEYS = %w[allOf oneOf anyOf].freeze

    attr_reader :notes

    def self.normalize(document)
      normalizer = new
      [normalizer.walk(document), normalizer.notes]
    end

    def initialize
      @notes = []
      # Резолвер отдаёт один и тот же объект на каждое упоминание общей схемы.
      # Без запоминания по тождеству нормализатор обходил бы такое поддерево
      # заново на каждом упоминании — на документе с переиспользуемыми
      # компонентами это давало экспоненциальный рост времени.
      @seen = {}
    end

    def walk(node, path = [])
      case node
      when Hash then @seen[node.object_id] ||= walk_hash(node, path)
      when Array then node.each_with_index.map { |item, index| walk(item, path + [index.to_s]) }
      else node
      end
    end

    private

    def walk_hash(node, path)
      normalized = node.each_with_object({}) { |(key, value), acc| acc[key] = walk(value, path + [key]) }

      normalized = merge_all_of(normalized, path) if normalized.key?("allOf")
      normalized = pick_variant(normalized, "oneOf", path) if normalized.key?("oneOf")
      normalized = pick_variant(normalized, "anyOf", path) if normalized.key?("anyOf")
      normalize_nullable(normalized)
    end

    def merge_all_of(schema, path)
      branches = Array(schema["allOf"]).select { |branch| branch.is_a?(Hash) }
      merged = { "type" => "object", "properties" => {}, "required" => [] }

      branches.each { |branch| absorb(merged, branch, path) }
      absorb(merged, schema.reject { |key, _| key == "allOf" }, path)

      merged["required"].empty? ? merged.reject { |key, _| key == "required" } : merged
    end

    def absorb(merged, branch, path)
      Hash(branch["properties"]).each do |name, property|
        existing = merged["properties"][name]
        note_type_conflict(path, name, existing, property) if conflicting?(existing, property)
        merged["properties"][name] = property
      end

      merged["required"] |= Array(branch["required"])
      branch.each do |key, value|
        next if %w[properties required allOf].include?(key)
        next if key == "type" && value == "object"

        merged[key] = value
      end
    end

    def conflicting?(existing, property)
      return false unless existing.is_a?(Hash) && property.is_a?(Hash)
      return false if existing["type"].nil? || property["type"].nil?

      existing["type"] != property["type"]
    end

    def note_type_conflict(path, name, existing, property)
      @notes << "#{location(path)}: поле \"#{name}\" объявлено в allOf дважды с разными типами " \
                "(#{existing['type']} и #{property['type']}) — взят последний, проверьте вручную"
    end

    # Из набора вариантов берётся один: тот, что указан дискриминатором, иначе
    # первый. Остальные не теряются молча — о них сообщается в замечаниях.
    def pick_variant(schema, keyword, path)
      variants = Array(schema[keyword]).select { |variant| variant.is_a?(Hash) }
      return schema.reject { |key, _| key == keyword } if variants.empty?

      chosen = choose_variant(variants, schema["discriminator"])
      rest = schema.reject { |key, _| [keyword, "discriminator"].include?(key) }
      note_variants(path, keyword, variants, schema["discriminator"])

      merged = { "type" => "object", "properties" => {}, "required" => [] }
      absorb(merged, chosen, path)
      absorb(merged, rest, path)
      merged["required"].empty? ? merged.reject { |key, _| key == "required" } : merged
    end

    # Дискриминатор называет поле, по которому провайдер различает варианты.
    # Канонически каждый вариант объявляет это поле enum из одного значения —
    # такой вариант и берётся. Если разметки нет, остаётся первый.
    def choose_variant(variants, discriminator)
      property = discriminator.is_a?(Hash) ? discriminator["propertyName"] : nil
      return variants.first if property.nil?

      marked = variants.find do |variant|
        values = variant.dig("properties", property, "enum")
        values.is_a?(Array) && values.size == 1
      end
      marked || variants.first
    end

    def note_variants(path, keyword, variants, discriminator)
      names = variants.map { |variant| variant_name(variant) }
      property = discriminator.is_a?(Hash) ? discriminator["propertyName"] : nil
      suffix = property ? ", различаются по полю \"#{property}\"" : ""

      @notes << "#{location(path)}: #{keyword} из #{variants.size} вариантов (#{names.join(', ')})#{suffix} — " \
                "взят первый, остальные требуют отдельной ветки интеграции"
    end

    def variant_name(variant)
      Hash(variant["properties"]).keys.first(3).join("/")
    end

    # nullable: true (3.0) и type: [x, "null"] (3.1) — одно и то же
    def normalize_nullable(schema)
      type = schema["type"]
      return schema unless type.is_a?(Array)

      schema.merge("type" => (type - ["null"]).first, "nullable" => type.include?("null"))
    end

    def location(path)
      relevant = path.reject { |part| part.match?(/\A\d+\z/) }
      relevant.empty? ? "схема" : relevant.last(3).join("/")
    end
  end
end
