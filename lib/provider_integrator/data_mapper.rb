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
      @amount_rules = load_rules("heuristics.yml")
      @report = MappingReport.new
    end

    def map
      @status_field = detect_status_field
      report_parser_notes
      report_role_ambiguity
      report_unsupported_endpoints
      status_map = map_statuses
      error_map = map_errors
      fields = map_fields
      amount = map_amount(fields)
      currency = detect_currency(fields)
      report_webhook_confidence

      MappingResult.new(
        report: @report,
        status_field: @status_field&.fetch(:name),
        status_map: status_map,
        error_map: error_map,
        provider_error_codes: detect_provider_error_codes,
        fields: fields,
        amount_factor: amount[:factor],
        amount_confirmed: amount[:confirmed],
        min_amount: detect_min_amount(fields, amount[:factor]),
        currency: currency,
        provider_id_field: detect_provider_id_field,
        webhook_id_field: detect_webhook_id_field,
        signature: SignatureDetector.detect(@analysis, rules_dir: @rules_dir, report: @report)
      )
    end

    private

    def load_rules(file_name)
      YAML.load_file(File.join(@rules_dir, file_name))
    end

    # Замечания стадии разбора: слитые композиции, выбранные варианты oneOf,
    # неожиданные типы содержимого
    def report_parser_notes
      Array(@spec_model.notes).each { |note| @report.add_unresolved(:spec, "(разбор)", note) }
    end

    # Если на одну роль претендует несколько эндпоинтов, берётся первый по
    # порядку в спецификации — это допущение, и оно не должно быть молчаливым
    def report_role_ambiguity
      { create: "создания операции", status: "запроса статуса", cancel: "отмены" }.each do |role, title|
        candidates = @analysis.by_role(role)
        next if candidates.size < 2

        @report.add_unresolved(:role, "(#{role})",
                                "на роль #{title} претендуют #{candidates.map(&:to_s).join(', ')} — " \
                                "взят первый, проверьте выбор")
      end
    end

    # Эндпоинты, не попавшие ни в одну роль контракта, в сервис не превращаются.
    # Молчать об этом нельзя: провайдер может считать их обязательными.
    def report_unsupported_endpoints
      others = @analysis.by_role(:other)
      return if others.empty?

      @report.add_skipped(:endpoint, "(вне контракта)",
                           "#{others.map(&:to_s).join(', ')} — не относятся к контракту Provider::BaseService " \
                           "и в сервис не генерируются")
    end

    # Вебхук, опознанный только по косвенному признаку, — не факт, а догадка:
    # она выносится в отчёт, чтобы её проверил человек
    def report_webhook_confidence
      guessed = Array(@analysis.heuristic_webhooks)
      return if guessed.empty?

      @report.add_unresolved(:webhook, "(определение роли)",
                              "#{guessed.map(&:to_s).join(', ')} опознан как входящее уведомление только " \
                              "по косвенному признаку (публичный POST с телом) — убедитесь, что это не создание операции")
    end

    def map_statuses
      if @status_field.nil?
        @report.add_unresolved(:status, "(поле статуса)",
                                "ни одно из имён #{Array(@statuses_rules['field_names']).join(', ')} " \
                                "не найдено в схемах с перечислением значений")
        return {}
      end

      @report.add_resolved(:status, "(поле статуса)", "статус читается из поля \"#{@status_field[:name]}\"")

      @status_field[:enum].each_with_object({}) do |value, acc|
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
      Hash(@statuses_rules["canonical"]).each do |canonical, synonyms|
        return canonical if Array(synonyms).map(&:downcase).include?(normalized)
      end
      nil
    end

    # Имя поля статуса у разных провайдеров отличается (status, state и т.д.),
    # поэтому оно ищется по списку из statuses.yml, а не берётся жёстко.
    def detect_status_field
      candidates = Array(@statuses_rules["field_names"]).map(&:downcase)

      status_schemas.each do |schema|
        found = status_field_in(schema, candidates)
        return found if found
      end
      nil
    end

    # Схемы просматриваются в осмысленном порядке, а не в порядке объявления:
    # сначала ответ на запрос статуса и на создание, затем тело уведомления,
    # и только потом общие схемы. Иначе победит первый попавшийся enum —
    # например, статус баланса вместо статуса операции. Схемы, объявленные
    # прямо в ответах, учитываются наравне с вынесенными в components.
    def status_schemas
      from_endpoints = %i[status create webhook].flat_map do |role|
        endpoint = @analysis.by_role(role).first
        next [] if endpoint.nil?

        [success_response_schema(endpoint), endpoint.request_body_schema]
      end

      (from_endpoints + Hash(@spec_model.schemas).values).compact
    end

    def status_field_in(schema, candidates)
      return nil unless schema.is_a?(Hash)

      Hash(schema["properties"]).each do |name, prop_schema|
        next unless candidates.include?(name.downcase) && prop_schema.is_a?(Hash)

        values = prop_schema["enum"].is_a?(Array) ? prop_schema["enum"] : enum_from_description(prop_schema)
        next if values.nil? || values.empty?

        return { name: name, enum: values }
      end
      nil
    end

    # Перечень статусов нередко описывают текстом, а не enum: "pending|completed|failed"
    # или "one of: pending, completed". Такой список тоже стоит распознать,
    # иначе провайдер остаётся вообще без маппинга статусов.
    def enum_from_description(prop_schema)
      description = prop_schema["description"].to_s
      return nil unless description.match?(/\A[\s\w|,:.\-]+\z/)

      candidates = description.split(%r{[|,]}).map { |part| part.strip.split(/\s+/).last.to_s.downcase }
      values = candidates.select { |value| value.match?(/\A[a-z][a-z0-9_]{2,}\z/) }.uniq
      values.size >= 2 ? values : nil
    end

    # Коды ошибок самого провайдера (enum в схеме ошибки) — отдельная от HTTP
    # плоскость: один и тот же 422 может означать и неверный телефон,
    # и превышение лимита. Их перечень попадает в документацию и в сервис.
    def detect_provider_error_codes
      names = Array(@errors_rules["provider_code_fields"]).map(&:downcase)
      names = %w[code error_code reason] if names.empty?

      Hash(@spec_model.schemas).each_value do |schema|
        next unless schema.is_a?(Hash)

        Hash(schema["properties"]).each do |name, prop|
          next unless names.include?(name.downcase) && prop.is_a?(Hash)
          next unless prop["enum"].is_a?(Array)

          @report.add_resolved(:error, "(коды провайдера)", "#{prop['enum'].size} значений: #{prop['enum'].join(', ')}")
          return prop["enum"]
        end
      end
      []
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
      # Ключи ответов в YAML часто пишут без кавычек, и Psych отдаёт их числами:
      # приведение к строке обязательно, иначе match? падает на Integer
      @spec_model.endpoints
                 .flat_map { |e| e.responses.keys }
                 .select { |status| status.to_s.match?(/\A[45]\d\d\z/) }
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
      fields = {}
      match_group(Hash(@field_rules["required"]), properties, fields, required: true)
      match_group(Hash(@field_rules["optional"]), properties, fields, required: false)
      check_recipient_present(fields)
      report_unknown_fields(properties, fields)
      fields
    end

    # Сопоставление идёт от словаря к спецификации, поэтому поле провайдера,
    # которого нет в словаре, иначе просто исчезло бы: ни в теле запроса,
    # ни в отчёте. Обязательное по спецификации — требует решения, остальные —
    # к сведению.
    def report_unknown_fields(properties, fields)
      matched = fields.values.map { |entry| entry[:path] }
      unknown = properties.reject { |property| matched.include?(property[:path]) || property[:object] }

      unknown.each do |property|
        name = property[:path].join(".")
        if property[:required]
          @report.add_unresolved(:field, name,
                                  "обязательное поле провайдера не описано в config/rules/field_aliases.yml " \
                                  "и не попадёт в запрос")
        else
          @report.add_skipped(:field, name, "поле провайдера не описано в словаре и не отправляется")
        end
      end
    end

    # Обязательное поле без соответствия — проблема; необязательное относится
    # к чужому способу выплаты, его отсутствие ожидаемо и помечается нейтрально
    def match_group(rules, properties, fields, required:)
      rules.each do |canonical, aliases|
        names = Array(aliases).map(&:downcase)
        match = best_match(properties, canonical, names)

        if match
          @report.add_resolved(:field, canonical, "поле #{match[:path].join('.')}")
          fields[canonical] = match
        elsif required
          @report.add_unresolved(:field, canonical, "обязательное поле не найдено в схеме запроса")
        else
          @report.add_skipped(:field, canonical, "не используется этим провайдером")
        end
      end
    end

    # Из нескольких полей с подходящим именем выбирается не первое попавшееся,
    # а самое правдоподобное: поле верхнего уровня важнее вложенного, точное
    # совпадение с каноническим именем важнее синонима. Иначе блок fee { amount }
    # объявленный раньше amount, забирал бы сумму выплаты себе — тихая порча
    # денежных данных, худший класс ошибки для платёжной интеграции.
    def best_match(properties, canonical, names)
      candidates = properties.select { |prop| names.include?(prop[:name].downcase) && !prop[:object] }
      return nil if candidates.empty?

      candidates.min_by do |prop|
        [
          prop[:path].size,
          prop[:name].downcase == canonical.to_s.downcase ? 0 : 1,
          names.index(prop[:name].downcase) || names.size
        ]
      end
    end

    # Хотя бы один реквизит получателя должен быть найден, иначе выплату
    # некуда отправлять — это уже требует ручного решения
    def check_recipient_present(fields)
      return if fields.keys.any? { |canonical| canonical.start_with?("recipient_") }

      @report.add_unresolved(:field, "(реквизиты получателя)",
                              "в схеме запроса не найдено ни одного известного поля реквизитов получателя")
    end

    # Собирает свойства тела запроса с сохранением пути до каждого поля.
    # Глубина ограничена одним уровнем вложенности (например recipient.phone) —
    # этого достаточно для платёжных API и защищает от неограниченной рекурсии.
    def collect_properties(schema, prefix = [])
      return [] unless schema.is_a?(Hash)

      Hash(schema["properties"]).flat_map do |name, prop|
        path = prefix + [name]
        nested = prefix.empty? ? collect_properties(prop, path) : []
        # Узел-контейнер (recipient, destination) сам значением не является:
        # он помечается, чтобы не попасть в список неизвестных полей
        entry = {
          name: name, path: path, schema: prop,
          required: required?(schema, name), object: !nested.empty?
        }
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
      if minor_units?(description)
        @report.add_resolved(:field, "amount.unit", "минорные единицы (копейки/центы) — конвертация ×100")
        { factor: 100, confirmed: true }
      else
        @report.add_unresolved(:field, "amount.unit",
                                "единицы измерения суммы не указаны в description — конвертация не применяется, требуется подтверждение")
        { factor: 1, confirmed: false }
      end
    end

    # Сравнение идёт по границам слов: подстрока «cent» иначе находится
    # внутри «percent» и даёт ложную конвертацию суммы в сто раз
    def minor_units?(description)
      Array(@amount_rules["minor_units"]).any? do |keyword|
        keyword = keyword.to_s.downcase
        keyword.match?(/\A\p{L}+\z/) ? description.match?(/(?<!\p{L})#{Regexp.escape(keyword)}/) : description.include?(keyword)
      end
    end

    # Минимальная сумма операции в единицах Space Payments: minimum из спецификации,
    # приведённый обратно к мажорным единицам. Деление рациональное: при minimum 150
    # и коэффициенте 100 порог равен 1.5, а не 1.
    def detect_min_amount(fields, factor)
      entry = fields["amount"]
      minimum = entry && entry[:schema].is_a?(Hash) ? entry[:schema]["minimum"] : nil
      return nil unless minimum.is_a?(Numeric)

      if factor == 1
        @report.add_unresolved(:field, "amount.minimum",
                                "порог #{minimum} взят из спецификации, но единицы суммы не подтверждены — " \
                                "проверьте, что он в тех же единицах, что operation.amount")
        return minimum
      end

      value = Rational(minimum, factor)
      value.denominator == 1 ? value.numerator : value.to_f
    end

    def detect_currency(fields)
      entry = fields["currency"]
      enum = entry && entry[:schema].is_a?(Hash) ? entry[:schema]["enum"] : nil
      return nil unless enum.is_a?(Array) && !enum.empty?

      if enum.size == 1
        @report.add_resolved(:field, "currency.value", "провайдер принимает только #{enum.first}")
      else
        @report.add_unresolved(:field, "currency.value",
                                "провайдер принимает #{enum.join(', ')} — в конфигурации шлюза указана #{enum.first}, " \
                                "сумма отправляется с operation.currency")
      end
      enum.first
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
