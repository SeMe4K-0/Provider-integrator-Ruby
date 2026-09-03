# frozen_string_literal: true

require "yaml"
require_relative "fixtures_builder"

module ProviderIntegrator
  # Готовит все значения, которые нужны шаблонам: имя класса, адреса эндпоинтов,
  # таблицы статусов и ошибок, исходный код сборки тела запроса, схему подписи.
  # Шаблоны не содержат логики — вся она собрана здесь.
  class GenerationContext
    DEFAULT_RULES_DIR = File.expand_path("../../config/rules", __dir__)

    attr_reader :provider, :spec, :analysis, :mapping

    def initialize(provider:, spec:, analysis:, mapping:, rules_dir: DEFAULT_RULES_DIR)
      @provider = provider
      @spec = spec
      @analysis = analysis
      @mapping = mapping
      @sources = YAML.load_file(File.join(rules_dir, "operation_sources.yml"))
      @payload_todos = []
    end

    def get_binding
      binding
    end

    def class_name
      "#{provider.split(/[_\-\s]+/).map(&:capitalize).join}Service"
    end

    def env_var_name
      "#{provider.upcase.gsub(/[^A-Z0-9]/, '_')}_BASE_URL"
    end

    def default_base_url
      spec.servers.first&.fetch(:url, nil) || "https://api.example.com"
    end

    def spec_title
      spec.title.to_s
    end

    def spec_version
      spec.version.to_s
    end

    def status_map
      mapping.status_map
    end

    # Имя поля, из которого читается статус операции у этого провайдера
    def status_field
      mapping.status_field || "status"
    end

    # Поля структуры операции для самотеста: собираются из выражений вида
    # operation.<поле>, которые реально попали в сгенерированный код
    def operation_attributes
      expressions = mapping.fields.keys.filter_map { |canonical| @sources[canonical] }
      expressions.join(" ").scan(/operation\.([a-z_]+)/).flatten.uniq
    end

    def operation_struct_members
      (operation_attributes + ["provider_operation_id"]).map { |name| ":#{name}" }.join(", ")
    end

    # Значения этих полей в самотесте
    def operation_sample_values
      operation_attributes.map do |name|
        case name
        when "id" then %(id: "op_test_1")
        when "amount" then "amount: #{sample_amount}"
        when "currency" then %(currency: "#{mapping.currency || 'RUB'}")
        when "payout_requisite" then "payout_requisite: #{sample_requisite_literal}"
        else %(#{name}: "test_value")
        end
      end
    end

    def sample_requisite_literal
      <<~REQUISITE.strip
        {
          "type" => "#{sample_requisite_type}",
          "sbp" => { "phone" => "79001234567", "bank_code" => "044525225", "bank_name" => "Тестбанк" },
          "card" => { "number" => "4111111111111111" }
        }
      REQUISITE
    end

    def error_map
      mapping.error_map
    end

    def min_amount
      mapping.min_amount
    end

    def signature
      mapping.signature
    end

    # Только реальные значения статусов; служебные пометки вида "(поле status)"
    # в код не попадают — для них шаблон печатает отдельное пояснение
    def unresolved_statuses
      mapping.report.unresolved
             .select { |e| e.category == :status }
             .map(&:key)
             .reject { |key| key.to_s.start_with?("(") }
    end

    def create_endpoint
      analysis.by_role(:create).first
    end

    def status_endpoint
      analysis.by_role(:status).first
    end

    def cancel_endpoint
      analysis.by_role(:cancel).first
    end

    def webhook_endpoint
      analysis.by_role(:webhook).first
    end

    def create_path
      create_endpoint&.path
    end

    # Путь статуса с подставленным идентификатором операции вместо {параметра}
    def status_path
      substitute_path(status_endpoint)
    end

    def cancel_path
      substitute_path(cancel_endpoint)
    end

    # Выражение, формирующее заголовки авторизации в сгенерированном сервисе
    def auth_headers_expression
      scheme = spec.security_schemes.values.first
      return "{}" if scheme.nil?

      case scheme.type
      when "apiKey"
        %({ "#{scheme.header_name}" => credentials.fetch(:api_key) })
      when "http"
        scheme.scheme == "bearer" ? bearer_expression : basic_expression
      else
        "{}"
      end
    end

    # Ключи credentials, которые действительно читает сгенерированный сервис
    def credential_keys
      scheme = spec.security_schemes.values.first
      keys = case scheme&.type
             when "http"
               scheme.scheme == "bearer" ? { "token" => "Bearer-токен" } : { "basic_token" => "Basic-токен" }
             when "apiKey"
               { "api_key" => "ключ API, заголовок #{scheme.header_name}" }
             else
               {}
             end
      keys["callback_secret"] = "секрет для проверки подписи уведомлений" if signature
      keys
    end

    def auth_comment
      scheme = spec.security_schemes.values.first
      return "авторизация в спецификации не описана" if scheme.nil?

      "#{scheme.name} (#{scheme.type}#{scheme.header_name ? ", заголовок #{scheme.header_name}" : ''})"
    end

    def provider_id_field
      mapping.provider_id_field || "id"
    end

    def webhook_id_field
      mapping.webhook_id_field || provider_id_field
    end

    # Исходный код тела запроса: восстанавливает вложенность из путей полей
    def payload_source(tree = payload_tree, indent = 8)
      pad = " " * indent
      tree.map do |key, value|
        if value.is_a?(Hash)
          "#{pad}#{key}: {\n#{payload_source(value, indent + 2)}\n#{pad}}.compact"
        else
          "#{pad}#{key}: #{value}"
        end
      end.join(",\n")
    end

    def payload_todos
      payload_tree
      @payload_todos
    end

    # Имена файлов результата генерации
    def service_file_base
      "#{provider}_service"
    end

    def service_file_name
      "#{service_file_base}.rb"
    end

    def docs_file_name
      "INTEGRATION.md"
    end

    def fixtures_file_name
      "fixtures.json"
    end

    def self_test_file_name
      "#{provider}_integration_self_test_spec.rb"
    end

    def fixtures
      @fixtures ||= FixturesBuilder.new(analysis: analysis, mapping: mapping).build
    end

    # Строки таблицы методов для документации
    def method_rows
      labels = { create: "создание", status: "статус", cancel: "отмена", webhook: "webhook", other: "прочее" }

      analysis.endpoints.map do |endpoint|
        {
          role: labels.fetch(endpoint.role, endpoint.role.to_s),
          endpoint: "#{endpoint.http_method.upcase} #{endpoint.path}",
          summary: endpoint.summary.to_s.empty? ? "—" : endpoint.summary,
          idempotency: idempotency_header(endpoint) || "—"
        }
      end
    end

    def unresolved_entries
      mapping.report.unresolved
    end

    def payload_tree_for_docs
      payload_tree
    end

    # Конфигурация ProviderGateway: способ и шлюз собираются из валюты
    # и типа реквизитов, найденных в спецификации
    def gateway_external_method
      type = requisite_type || "payout"
      "#{type}_payout"
    end

    def gateway_name
      currency = mapping.currency || "RUB"
      type = (requisite_type || "generic").upcase
      "#{currency}_#{type}_WITHDRAW"
    end

    # Значения для самотеста
    def sample_amount
      mapping.min_amount ? (mapping.min_amount * 10) : 1000
    end

    def sample_requisite_type
      requisite_type || "sbp"
    end

    def credentials_literal
      scheme = spec.security_schemes.values.first
      secret = mapping.signature ? ", callback_secret: callback_secret" : ""

      case scheme&.type
      when "http"
        scheme.scheme == "bearer" ? "{ token: \"test_token\"#{secret} }" : "{ basic_token: \"test_token\"#{secret} }"
      else
        "{ api_key: \"test_api_key\"#{secret} }"
      end
    end

    def auth_header_assertion
      scheme = spec.security_schemes.values.first
      case scheme&.type
      when "apiKey"
        %("#{scheme.header_name.downcase}" => "test_api_key")
      when "http"
        scheme.scheme == "bearer" ? %("authorization" => "Bearer test_token") : %("authorization" => "Basic test_token")
      else
        %("content-type" => "application/json")
      end
    end

    # Регулярные выражения для мока: спецсимволы пути экранируются, чтобы точка
    # или плюс в адресе не превратились в шаблон
    def create_path_pattern
      return nil if create_path.nil?

      "#{Regexp.escape(create_path)}\\z"
    end

    def status_path_pattern
      return nil if status_endpoint.nil?

      escaped = status_endpoint.path.split(/(\{[^}]+\})/).map do |part|
        part.start_with?("{") ? "[^/]+" : Regexp.escape(part)
      end.join
      "#{escaped}\\z"
    end

    # Код успешного ответа на создание берётся из спецификации, а не из литерала:
    # провайдер может отвечать и 200, и 202
    def create_success_code
      key = fixtures.dig("create_request")&.keys&.find { |k| k.match?(/\Aresponse_2\d\d\z/) }
      key ? key.sub("response_", "") : nil
    end

    def create_success_fixture
      code = create_success_code
      code ? "response_#{code}" : nil
    end

    def status_success_fixture
      fixtures["fetch_status"]&.keys&.first
    end

    # Обращение к телефону получателя в теле запроса: у одного провайдера он
    # лежит во вложенном объекте реквизитов, у другого — прямо в корне
    def recipient_phone_access
      entry = mapping.fields["recipient_phone"]
      return nil if entry.nil?

      entry[:path].size > 1 ? %(body.dig("#{entry[:path].first}", "#{entry[:name]}")) : %(body["#{entry[:name]}"])
    end

    # Ожидаемый статус для самотеста берётся из той же фикстуры, что отдаёт мок.
    # Если из примера ответа статус не выводится, проверка не генерируется —
    # заведомо падающий тест хуже отсутствующего.
    def expected_fetch_status
      body = fixtures.dig("fetch_status")&.values&.first
      status = body.is_a?(Hash) ? body[status_field] : nil
      mapping.status_map[status.to_s]
    end

    def has_failed_callback_fixture
      !fixtures["callback_failed"].nil?
    end

    private

    def requisite_type
      entry = mapping.fields["recipient_type"]
      enum = entry && entry[:schema].is_a?(Hash) ? entry[:schema]["enum"] : nil
      enum.is_a?(Array) ? enum.first : nil
    end

    def idempotency_header(endpoint)
      header = endpoint.parameters.find do |parameter|
        parameter.location == "header" && parameter.name.to_s.downcase.include?("idempotency")
      end
      header && "`#{header.name}`"
    end

    def payload_tree
      @payload_todos = []
      mapping.fields.each_with_object({}) do |(canonical, entry), tree|
        insert_by_path(tree, entry[:path], value_expression(canonical, entry))
      end
    end

    # Путь поля может конфликтовать с уже занятым: например, amount записан
    # скаляром, а следом приходит amount.currency из вложенного объекта суммы.
    # В таком случае поле пропускается с пометкой, а не роняет генерацию.
    def insert_by_path(tree, path, value)
      *parents, leaf = path
      node = tree

      parents.each do |key|
        unless node[key].nil? || node[key].is_a?(Hash)
          @payload_todos << "поле #{path.join('.')} пропущено: \"#{key}\" уже занято значением — проверьте вложенность вручную"
          return nil
        end

        node[key] ||= {}
        node = node[key]
      end

      node[leaf] = value unless node[leaf].is_a?(Hash)
    end

    # Значение поля выбирается по трём правилам:
    #   enum из одного значения — подставляется литерал, вариантов нет;
    #   enum из нескольких значений — берётся выражение Space Payments, если оно
    #     задано, иначе первый вариант с пометкой TODO;
    #   без enum — выражение из operation_sources.yml, при его отсутствии nil и TODO.
    def value_expression(canonical, entry)
      enum = entry[:schema].is_a?(Hash) ? entry[:schema]["enum"] : nil
      enum = nil unless enum.is_a?(Array) && !enum.empty?
      source = @sources[canonical]

      return %("#{enum.first}") if enum && enum.size == 1
      return literal_from_enum(entry, enum) if enum && source.nil?

      if source.nil?
        @payload_todos << "поле #{entry[:path].join('.')}: источник значения не задан в config/rules/operation_sources.yml"
        return "nil"
      end

      canonical == "amount" && mapping.amount_conversion? ? "(#{source} * #{mapping.amount_factor}).to_i" : source
    end

    def literal_from_enum(entry, enum)
      @payload_todos << "поле #{entry[:path].join('.')}: выбрано \"#{enum.first}\" из вариантов #{enum.join(', ')} — проверьте, что это соответствует шлюзу"
      %("#{enum.first}")
    end

    def substitute_path(endpoint)
      return nil if endpoint.nil?

      endpoint.path.gsub(/\{[^}]+\}/, '#{operation.provider_operation_id}')
    end

    def bearer_expression
      '{ "Authorization" => "Bearer #{credentials.fetch(:token)}" }'
    end

    def basic_expression
      '{ "Authorization" => "Basic #{credentials.fetch(:basic_token)}" }'
    end
  end
end
