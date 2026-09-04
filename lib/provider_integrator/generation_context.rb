# frozen_string_literal: true

require "yaml"
require_relative "fixtures_builder"

module ProviderIntegrator
  # Готовит все значения, которые нужны шаблонам: имя класса, адреса эндпоинтов,
  # таблицы статусов и ошибок, исходный код сборки тела запроса, схему подписи.
  # Шаблоны не содержат логики — вся она собрана здесь.
  class GenerationContext
    DEFAULT_RULES_DIR = File.expand_path("../../config/rules", __dir__)

    # Конец пути в маршруте мока: либо конец строки, либо начало query-строки
    PATH_TAIL = '(?:\?|\z)'

    attr_reader :provider, :spec, :analysis, :mapping

    def initialize(provider:, spec:, analysis:, mapping:, rules_dir: DEFAULT_RULES_DIR)
      @provider = provider
      @spec = spec
      @analysis = analysis
      @mapping = mapping
      @sources = YAML.load_file(File.join(rules_dir, "operation_sources.yml"))
      @heuristics = YAML.load_file(File.join(rules_dir, "heuristics.yml"))
      @payload_todos = []
      @path_credentials = []
    end

    def get_binding
      binding
    end

    # Любое значение из спецификации, попадающее в Ruby-исходник, проходит через
    # этот хелпер. Спецификация приходит от стороннего провайдера, то есть это
    # недоверенный ввод: строка вида "https://x/#{`whoami`}" внутри обычного
    # литерала выполнилась бы при загрузке сгенерированного файла, а кавычка
    # в имени заголовка просто сломала бы синтаксис. dump закрывает оба случая.
    def rb(value)
      value.to_s.dump
    end

    # То же для текста, попадающего в комментарий: перевод строки разорвал бы
    # комментарий и вынес остаток строки в код
    def rb_comment(value)
      value.to_s.gsub(/\s*\R\s*/, " ").strip
    end

    # Текст из спецификации внутри таблицы Markdown: вертикальная черта
    # разорвала бы строку таблицы, перевод строки — саму таблицу
    def md(value)
      value.to_s.gsub(/\s*\R\s*/, " ").gsub("|", %q{\|}).strip
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

    # Путь собирается конкатенацией, а не интерполяцией: литеральные куски
    # приходят из чужой спецификации и вставляются экранированными, а на месте
    # {параметров} стоят выражения. У эндпоинта создания идентификатора операции
    # ещё нет, поэтому все его параметры пути берутся из credentials.
    def create_path_expression
      path_expression(create_endpoint, use_operation_id: false)
    end

    def status_path_expression
      path_expression(status_endpoint, use_operation_id: true)
    end

    def cancel_path_expression
      path_expression(cancel_endpoint, use_operation_id: true)
    end

    def path_expression(endpoint, use_operation_id:)
      return nil if endpoint.nil?

      names = endpoint.path.scan(/\{([^}]+)\}/).flatten
      operation_param = use_operation_id ? names.last : nil

      pieces = endpoint.path.split(/(\{[^}]+\})/).reject(&:empty?).map do |part|
        next rb(part) unless part.start_with?("{")

        name = part[1..-2]
        name == operation_param ? "operation.provider_operation_id.to_s" : credential_path_expression(name)
      end
      pieces.join(" + ")
    end

    # Параметр пути, не являющийся идентификатором операции, — это почти всегда
    # идентификатор уровня аккаунта (merchant_id, shop_id): его место в
    # credentials, а не в теле операции
    def credential_path_expression(name)
      key = name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
      @path_credentials << key
      "credentials.fetch(:#{key}).to_s"
    end

    def path_credentials
      create_path_expression
      status_path_expression
      cancel_path_expression
      @path_credentials.uniq
    end

    # Путь статуса с подставленным идентификатором операции вместо {параметра}
    def status_path
      substitute_path(status_endpoint)
    end

    def cancel_path
      substitute_path(cancel_endpoint)
    end

    # Схема авторизации берётся та, которую требует эндпоинт создания, а не
    # первая объявленная: у провайдера их может быть несколько
    def auth_scheme
      return @auth_scheme if defined?(@auth_scheme)

      required = Array(create_endpoint&.security_names).first || Array(status_endpoint&.security_names).first
      @auth_scheme = spec.security_schemes[required] || spec.security_schemes.values.first
    end

    # Выражение, формирующее заголовки авторизации в сгенерированном сервисе
    def auth_headers_expression
      scheme = auth_scheme
      return "{}" if scheme.nil?

      case scheme.type
      when "apiKey"
        scheme.location == "header" ? "{ #{rb(scheme.header_name)} => credentials.fetch(:api_key) }" : "{}"
      when "http"
        scheme.scheme == "bearer" ? bearer_expression : basic_expression
      else
        "{}"
      end
    end

    # Ключ, объявленный с in: query, заголовком не передать — он добавляется
    # к адресу запроса
    def auth_query_parameter
      scheme = auth_scheme
      scheme && scheme.type == "apiKey" && scheme.location == "query" ? scheme.header_name : nil
    end

    # Схемы, для которых генератор не умеет собрать авторизацию (oauth2,
    # openIdConnect, http digest): запрос ушёл бы без неё, поэтому в коде
    # остаётся явный TODO, а не молчаливый пустой хеш
    def unsupported_auth
      scheme = auth_scheme
      return nil if scheme.nil?
      return nil if scheme.type == "apiKey"
      return nil if scheme.type == "http" && %w[bearer basic].include?(scheme.scheme.to_s)

      "#{scheme.name} (#{scheme.type}#{scheme.scheme ? "/#{scheme.scheme}" : ''})"
    end

    # Ключи credentials, которые действительно читает сгенерированный сервис
    def credential_keys
      scheme = auth_scheme
      keys = case scheme&.type
             when "http"
               scheme.scheme == "bearer" ? { "token" => "Bearer-токен" } : { "basic_token" => "Basic-токен" }
             when "apiKey"
               { "api_key" => "ключ API, #{scheme.location == 'query' ? 'параметр' : 'заголовок'} #{scheme.header_name}" }
             else
               {}
             end
      keys["callback_secret"] = "секрет для проверки подписи уведомлений" if signature
      keys
    end

    def auth_comment
      scheme = auth_scheme
      return "авторизация в спецификации не описана" if scheme.nil?

      place = scheme.type == "apiKey" ? ", #{scheme.location == 'query' ? 'параметр запроса' : 'заголовок'} #{scheme.header_name}" : ""
      "#{scheme.name} (#{scheme.type}#{place})"
    end

    def provider_id_field
      mapping.provider_id_field || "id"
    end

    # Заголовок идемпотентности, если провайдер его принимает: без него повтор
    # запроса создаст вторую выплату
    def idempotency_header_name
      header = create_endpoint&.parameters&.find do |parameter|
        parameter.location == "header" && parameter.name.to_s.downcase.include?("idempotency")
      end
      header&.name
    end

    # Прочие обязательные заголовки эндпоинта создания: их отсутствие —
    # гарантированный отказ провайдера, поэтому они попадают в код с TODO
    def required_header_params
      Array(create_endpoint&.parameters).select do |parameter|
        parameter.location == "header" && parameter.required? &&
          parameter.name != idempotency_header_name && !auth_header_names.include?(parameter.name)
      end
    end

    def auth_header_names
      spec.security_schemes.values.filter_map(&:header_name)
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

    # Ключи для самотеста берутся из той же схемы, что и auth_headers: иначе
    # сервис читает credentials.fetch(:token), а тест передаёт basic_token,
    # и прогон падает с KeyError на ровном месте
    def credentials_literal
      parts = case auth_scheme&.type
              when "http"
                auth_scheme.scheme == "bearer" ? ['token: "test_token"'] : ['basic_token: "test_token"']
              else
                ['api_key: "test_api_key"']
              end
      parts += path_credentials.map { |key| "#{key}: \"test_#{key}\"" }
      parts << "callback_secret: callback_secret" if mapping.signature
      "{ #{parts.join(', ')} }"
    end

    # Проверка авторизации в самотесте зависит от того, куда уходит ключ:
    # заголовком его ищут в headers, параметром запроса — в адресе
    def auth_assertion
      scheme = auth_scheme
      return %(expect(@server.requests.last.path).to include(#{rb("#{auth_query_parameter}=test_api_key")})) if auth_query_parameter

      case scheme&.type
      when "apiKey"
        %(expect(@server.requests.last.headers).to include(#{rb(scheme.header_name.downcase)} => "test_api_key"))
      when "http"
        value = scheme.scheme == "bearer" ? "Bearer test_token" : "Basic test_token"
        %(expect(@server.requests.last.headers).to include("authorization" => "#{value}"))
      else
        %(expect(@server.requests.last.headers).to include("content-type" => "application/json"))
      end
    end

    # Регулярные выражения для мока: спецсимволы пути экранируются, чтобы точка
    # или плюс в адресе не превратились в шаблон. Хвост допускает query-строку —
    # при авторизации ключом в параметре запроса она есть всегда.
    def create_path_pattern
      return nil if create_path.nil?

      "#{Regexp.escape(create_path)}#{PATH_TAIL}"
    end

    def cancel_path_pattern
      return nil if cancel_endpoint.nil?

      escaped = cancel_endpoint.path.split(/(\{[^}]+\})/).map do |part|
        part.start_with?("{") ? "[^/]+" : Regexp.escape(part)
      end.join
      "#{escaped}#{PATH_TAIL}"
    end

    def status_path_pattern
      return nil if status_endpoint.nil?

      escaped = status_endpoint.path.split(/(\{[^}]+\})/).map do |part|
        part.start_with?("{") ? "[^/]+" : Regexp.escape(part)
      end.join
      "#{escaped}#{PATH_TAIL}"
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

    # Для проверки обработки ошибок берётся код, который клиент возвращает
    # обычным ответом: 401 и 429 поднимаются исключениями и проверяются иначе
    def testable_error
      error_map.find { |code, _| ![401, 429].include?(code) }
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
        next if foreign_method_field?(entry)

        insert_by_path(tree, entry[:path], value_expression(canonical, entry))
      end
    end

    # Реквизиты разных способов выплаты нельзя отправлять одним запросом:
    # если выбран СБП, номер карты в теле запроса приведёт к отказу провайдера.
    # Принадлежность поля определяется по его описанию (config/rules/heuristics.yml).
    def foreign_method_field?(entry)
      method = requisite_type
      return false if method.nil?

      owner = field_method(entry)
      return false if owner.nil? || owner == method

      @payload_todos << "поле #{entry[:path].join('.')} относится к способу выплаты \"#{owner}\", " \
                        "а выбран \"#{method}\" — в запрос не включено"
      true
    end

    def field_method(entry)
      text = entry[:schema].is_a?(Hash) ? "#{entry[:name]} #{entry[:schema]['description']}".downcase : ""

      Hash(@heuristics["payout_methods"]).each do |method, keywords|
        return method if Array(keywords).any? { |keyword| text.include?(keyword.to_s.downcase) }
      end
      nil
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

      return rb(enum.first) if enum && enum.size == 1
      return literal_from_enum(entry, enum) if enum && source.nil?

      if source.nil?
        @payload_todos << "поле #{entry[:path].join('.')}: источник значения не задан в config/rules/operation_sources.yml"
        return "nil"
      end

      canonical == "amount" && mapping.amount_conversion? ? "(#{source} * #{mapping.amount_factor}).to_i" : source
    end

    def literal_from_enum(entry, enum)
      @payload_todos << "поле #{entry[:path].join('.')}: выбрано \"#{enum.first}\" из вариантов #{enum.join(', ')} — проверьте, что это соответствует шлюзу"
      rb(enum.first)
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
