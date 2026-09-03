# frozen_string_literal: true

require "yaml"
require_relative "mapping_report"
require_relative "mapping_result"
require_relative "signature_detector"

module ProviderIntegrator
  # Сопоставляет данные провайдера с каноническими значениями Space Payments:
  # статусы операций (statuses.yml), HTTP-коды ошибок (errors.yml), поля запроса
  # (field_aliases.yml), схему подписи webhook (signature_schemes.yml).
  # Все словари редактируются без изменения кода.
  #
  # Всё, что не нашло соответствия, не додумывается — попадает в MappingReport
  # как unresolved с объяснением причины, а генератор оставляет в этом месте TODO.
  class DataMapper
    DEFAULT_RULES_DIR = File.expand_path("../../config/rules", __dir__)
    UNIT_KEYWORDS = %w[копе kopeck cent центы].freeze

    def self.map(spec_model, analysis, rules_dir: DEFAULT_RULES_DIR)
      new(spec_model, analysis, rules_dir).map
    end

    def initialize(spec_model, analysis, rules_dir)
      @spec_model = spec_model
      @analysis = analysis
      @rules_dir = rules_dir
      @statuses_rules = load_rules("statuses.yml")
      @errors_rules = load_rules("errors.yml")
      @field_rules = load_rules("field_aliases.yml")
      @report = MappingReport.new
    end

    def map
      status_map = map_statuses
      error_map = map_errors
      fields = map_fields
      amount = map_amount(fields)

      MappingResult.new(
        report: @report,
        status_map: status_map,
        error_map: error_map,
        fields: fields,
        amount_factor: amount[:factor],
        amount_confirmed: amount[:confirmed],
        min_amount: detect_min_amount(fields, amount[:factor]),
        currency: detect_currency(fields),
        provider_id_field: detect_provider_id_field,
        webhook_id_field: detect_webhook_id_field,
        signature: SignatureDetector.detect(@analysis, rules_dir: @rules_dir, report: @report)
      )
    end

    private

    def load_rules(file_name)
      YAML.load_file(File.join(@rules_dir, file_name))
    end

    def map_statuses
      enum = status_enum
      if enum.nil? || enum.empty?
        @report.add_unresolved(:status, "(поле status)",
                                "в схемах спецификации не найдено поле status с перечислением значений")
        return {}
      end

      enum.each_with_object({}) do |value, acc|
        canonical = canonical_status(value)
        if canonical
          @report.add_resolved(:status, value, "→ #{canonical}")
          acc[value.to_s] = canonical
        else
          @report.add_unresolved(:status, value,
                                  "нет соответствия в config/rules/statuses.yml — добавьте синоним вручную")
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
      http_codes.each_with_object({}) do |code, acc|
        rule = @errors_rules[code] || @errors_rules[code.to_s]
        if rule
          @report.add_resolved(:error, code, "→ #{rule['code']} (#{rule['action']})")
          acc[code] = { code: rule["code"], action: rule["action"] }
        else
          @report.add_unresolved(:error, code, "нет правила в config/rules/errors.yml — добавьте вручную")
        end
      end
    end

    # Уникальные HTTP-коды ошибок (4xx/5xx), встречающиеся в ответах эндпоинтов
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
        return {}
      end

      properties = collect_properties(create_endpoint.request_body_schema)
      @field_rules.each_key.with_object({}) do |canonical, acc|
        aliases = Array(@field_rules[canonical]).map(&:downcase)
        match = properties.find { |prop| aliases.include?(prop[:name].downcase) }

        if match
          @report.add_resolved(:field, canonical, "поле #{match[:path].join('.')}")
          acc[canonical] = match
        else
          @report.add_unresolved(:field, canonical, "не найдено ни одно из известных имён в схеме запроса")
        end
      end
    end

    # Собирает свойства тела запроса с сохранением пути до каждого поля.
    # Глубина ограничена одним уровнем вложенности (например recipient.phone) —
    # этого достаточно для платёжных API и защищает от неограниченной рекурсии.
    def collect_properties(schema, prefix = [])
      return [] unless schema.is_a?(Hash)

      Hash(schema["properties"]).flat_map do |name, prop|
        path = prefix + [name]
        entry = { name: name, path: path, schema: prop, required: required?(schema, name) }
        nested = prefix.empty? ? collect_properties(prop, path) : []
        [entry] + nested
      end
    end

    def required?(schema, name)
      Array(schema["required"]).include?(name)
    end

    # Определяет по description, заданы ли суммы в минорных единицах (копейки/центы).
    # Если признаков нет — конвертация не применяется и это помечается как unresolved.
    def map_amount(fields)
      entry = fields["amount"]
      return { factor: 1, confirmed: false } if entry.nil?

      description = entry[:schema].is_a?(Hash) ? entry[:schema]["description"].to_s.downcase : ""
      if UNIT_KEYWORDS.any? { |keyword| description.include?(keyword) }
        @report.add_resolved(:field, "amount.unit", "минорные единицы (копейки/центы) — конвертация ×100")
        { factor: 100, confirmed: true }
      else
        @report.add_unresolved(:field, "amount.unit",
                                "единицы измерения суммы не указаны в description — конвертация не применяется, требуется подтверждение")
        { factor: 1, confirmed: false }
      end
    end

    # Минимальная сумма операции в единицах Space Payments: minimum из спецификации,
    # приведённый обратно к мажорным единицам, если провайдер принимает минорные
    def detect_min_amount(fields, factor)
      entry = fields["amount"]
      minimum = entry && entry[:schema].is_a?(Hash) ? entry[:schema]["minimum"] : nil
      return nil unless minimum.is_a?(Numeric)

      minimum / factor
    end

    def detect_currency(fields)
      entry = fields["currency"]
      enum = entry && entry[:schema].is_a?(Hash) ? entry[:schema]["enum"] : nil
      enum.is_a?(Array) ? enum.first : nil
    end

    def detect_provider_id_field
      endpoint = @analysis.by_role(:create).first
      name = endpoint ? id_property(success_response_schema(endpoint)) : nil

      if name
        @report.add_resolved(:response, "provider_operation_id", "поле \"#{name}\" в ответе на создание")
      else
        @report.add_unresolved(:response, "provider_operation_id",
                                "в ответе на создание не найдено поле с идентификатором операции")
      end
      name
    end

    def detect_webhook_id_field
      endpoint = @analysis.by_role(:webhook).first
      name = endpoint ? id_property(endpoint.request_body_schema) : nil

      if name
        @report.add_resolved(:webhook, "operation_id", "идентификатор операции в уведомлении — поле \"#{name}\"")
      elsif endpoint
        @report.add_unresolved(:webhook, "operation_id",
                                "в теле уведомления не найдено поле с идентификатором операции")
      end
      name
    end

    def success_response_schema(endpoint)
      code = endpoint.responses.keys.find { |status| status.to_s.start_with?("2") }
      code ? endpoint.responses[code] : nil
    end

    # Ищет поле идентификатора: сначала точное "id", затем любое *_id,
    # кроме external_id (это идентификатор на нашей стороне, а не у провайдера)
    def id_property(schema)
      return nil unless schema.is_a?(Hash)

      names = Hash(schema["properties"]).keys
      names.find { |name| name.downcase == "id" } ||
        names.find { |name| name.downcase.end_with?("_id") && name.downcase != "external_id" }
    end
  end
end
