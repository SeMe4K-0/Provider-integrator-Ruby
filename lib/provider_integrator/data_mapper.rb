# frozen_string_literal: true

require "yaml"
require_relative "mapping_report"

module ProviderIntegrator
  # Сопоставляет данные провайдера с каноническими значениями Space Payments:
  # статусы операций (statuses.yml), HTTP-коды ошибок (errors.yml), поля запроса
  # (field_aliases.yml). Все три словаря редактируются без изменения кода.
  # Всё, что не нашло соответствия, не додумывается — попадает в MappingReport
  # как unresolved с объяснением причины.
  class DataMapper
    DEFAULT_RULES_DIR = File.expand_path("../../config/rules", __dir__)
    UNIT_KEYWORDS = %w[копе kopeck cent центы].freeze

    def self.map(spec_model, analysis, rules_dir: DEFAULT_RULES_DIR)
      new(spec_model, analysis, rules_dir).map
    end

    def initialize(spec_model, analysis, rules_dir)
      @spec_model = spec_model
      @analysis = analysis
      @statuses_rules = YAML.load_file(File.join(rules_dir, "statuses.yml"))
      @errors_rules = YAML.load_file(File.join(rules_dir, "errors.yml"))
      @field_rules = YAML.load_file(File.join(rules_dir, "field_aliases.yml"))
      @report = MappingReport.new
    end

    def map
      map_statuses
      map_errors
      map_fields
      @report
    end

    private

    def map_statuses
      enum = status_enum
      if enum.nil? || enum.empty?
        @report.add_unresolved(:status, "(поле status)",
                                "в схемах спецификации не найдено поле status с перечислением значений")
        return
      end

      enum.each do |value|
        canonical = canonical_status(value)
        if canonical
          @report.add_resolved(:status, value, "→ #{canonical}")
        else
          @report.add_unresolved(:status, value, "нет соответствия в config/rules/statuses.yml — добавьте синоним вручную")
        end
      end
    end

    def canonical_status(value)
      normalized = value.to_s.downcase
      @statuses_rules.each do |canonical, synonyms|
        return canonical if Array(synonyms).map(&:downcase).include?(normalized)
      end
      nil
    end

    # Ищет поле с именем "status" (без учёта регистра) среди всех components/schemas
    # и возвращает его enum, если он есть
    def status_enum
      Hash(@spec_model.schemas).each_value do |schema|
        next unless schema.is_a?(Hash)

        props = schema["properties"]
        next unless props.is_a?(Hash)

        props.each do |name, prop_schema|
          next unless name.downcase == "status" && prop_schema.is_a?(Hash)

          enum = prop_schema["enum"]
          return enum if enum.is_a?(Array)
        end
      end
      nil
    end

    def map_errors
      http_codes.each do |code|
        rule = @errors_rules[code] || @errors_rules[code.to_s]
        if rule
          @report.add_resolved(:error, code, "→ #{rule['code']} (#{rule['action']})")
        else
          @report.add_unresolved(:error, code, "нет правила в config/rules/errors.yml — добавьте вручную")
        end
      end
    end

    # Собирает уникальные HTTP-коды ошибок (4xx/5xx), встречающиеся в ответах эндпоинтов
    def http_codes
      @spec_model.endpoints
                 .flat_map { |e| e.responses.keys }
                 .select { |status| status.match?(/\A[45]\d\d\z/) }
                 .map(&:to_i)
                 .uniq
                 .sort
    end

    def map_fields
      create_endpoint = @analysis.by_role(:create).first
      unless create_endpoint
        @report.add_unresolved(:field, "(create-эндпоинт)",
                                "не найден эндпоинт создания операции — сопоставление полей пропущено")
        return
      end

      properties = flat_properties(create_endpoint.request_body_schema)
      @field_rules.each_key { |canonical| map_field(canonical, properties) }
    end

    def map_field(canonical, properties)
      match_name = properties.keys.find { |name| Array(@field_rules[canonical]).map(&:downcase).include?(name.downcase) }
      unless match_name
        @report.add_unresolved(:field, canonical, "не найдено ни одно из известных имён в схеме запроса")
        return
      end

      @report.add_resolved(:field, canonical, "поле \"#{match_name}\"")
      check_amount_unit(properties[match_name]) if canonical == "amount"
    end

    # Собирает свойства верхнего уровня и один уровень вложенности (например, recipient.*)
    def flat_properties(schema)
      return {} unless schema.is_a?(Hash)

      top = Hash(schema["properties"])
      nested = top.each_value.each_with_object({}) do |prop, acc|
        acc.merge!(prop["properties"]) if prop.is_a?(Hash) && prop["properties"].is_a?(Hash)
      end
      top.merge(nested)
    end

    # Определяет по description, минорные ли единицы (копейки/центы) у суммы.
    # Если признаков не найдено — не додумывает, а помечает как unresolved:
    # генератор в этом случае не будет применять конвертацию ×100.
    def check_amount_unit(schema)
      description = schema.is_a?(Hash) ? schema["description"].to_s.downcase : ""
      if UNIT_KEYWORDS.any? { |kw| description.include?(kw) }
        @report.add_resolved(:field, "amount.unit", "минорные единицы (копейки/центы) — при генерации применяется конвертация ×100")
      else
        @report.add_unresolved(:field, "amount.unit",
                                "единицы измерения суммы не указаны в description — конвертация не применяется, требуется подтверждение")
      end
    end
  end
end
