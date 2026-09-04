# frozen_string_literal: true

require "date"
require "yaml"

require_relative "errors"
require_relative "content"
require_relative "ref_resolver"
require_relative "schema_normalizer"
require_relative "ir/parameter"
require_relative "ir/security_scheme"
require_relative "ir/endpoint"
require_relative "ir/spec_model"

module ProviderIntegrator
  # Загружает файл спецификации OpenAPI 3.x и строит из него провайдеро-агностичную
  # модель IR::SpecModel. Любая проблема со входным файлом превращается в понятную
  # SpecLoadError на русском языке, а не в необработанное исключение Ruby.
  class SpecLoader
    HTTP_METHODS = %w[get put post delete options head patch trace].freeze

    def self.load(path)
      new(path).load
    end

    def initialize(path)
      @path = path
      @notes = []
      @media_types = []
    end

    def load
      raw = read_yaml
      check_openapi_version!(raw)
      check_required_sections!(raw)

      resolver = RefResolver.new(raw)
      resolved = resolver.resolve(raw)
      normalized, normalizer_notes = SchemaNormalizer.normalize(resolved)
      @notes = resolver.notes.uniq + normalizer_notes
      build_spec_model(normalized)
    end

    private

    # Даты в спецификациях встречаются постоянно (version: 2024-01-01, примеры
    # с датами), поэтому Date и Time разрешены явно: иначе Psych поднимает
    # DisallowedClass на совершенно нормальном документе.
    def read_yaml
      raise SpecLoadError, "Файл не найден: #{@path}" unless File.exist?(@path)
      raise SpecLoadError, "Ожидается файл спецификации, а указан каталог: #{@path}" unless File.file?(@path)

      check_alias_bomb!
      YAML.safe_load_file(@path, permitted_classes: [Date, Time], aliases: true)
    rescue Psych::SyntaxError => e
      raise SpecLoadError, "Некорректный YAML в файле #{@path}: #{e.message}"
    rescue Psych::Exception => e
      raise SpecLoadError, "Не удалось разобрать YAML в файле #{@path}: #{e.message}"
    rescue SystemCallError => e
      raise SpecLoadError, "Не удалось прочитать файл #{@path}: #{e.message}"
    end

    # YAML-якоря позволяют собрать «алиасную бомбу»: файл в несколько сотен байт
    # разворачивается в миллиарды узлов и вешает процесс ещё на стадии загрузки.
    # Спецификации платёжных провайдеров якорями почти не пользуются, поэтому
    # достаточно ограничить их число и размер файла.
    MAX_FILE_SIZE = 5 * 1024 * 1024
    MAX_ALIASES = 100

    def check_alias_bomb!
      size = File.size(@path)
      if size > MAX_FILE_SIZE
        raise SpecLoadError,
              "Файл слишком велик (#{size / 1024} КБ, допустимо #{MAX_FILE_SIZE / 1024} КБ)"
      end

      text = File.read(@path, encoding: "UTF-8")
      anchors = text.scan(/(?<![\w*])&[\w-]+/).size
      aliases = text.scan(/(?<![\w*])\*[\w-]+/).size
      return if aliases <= MAX_ALIASES && anchors <= MAX_ALIASES

      raise SpecLoadError,
            "В файле #{aliases} YAML-ссылок и #{anchors} якорей — больше допустимого " +
            "(#{MAX_ALIASES}). Такая структура разворачивается лавинообразно, " +
            "разверните ссылки в исходном файле."
    end

    def check_openapi_version!(raw)
      unless raw.is_a?(Hash)
        raise SpecLoadError, "Файл должен описывать объект спецификации, а не #{raw.class}"
      end

      if raw.key?("swagger")
        raise SpecLoadError, "Обнаружена версия Swagger #{raw['swagger']} — поддерживается только OpenAPI 3.x"
      end

      version = raw["openapi"]
      raise SpecLoadError, 'В файле отсутствует обязательное поле "openapi"' unless version
      return if version.to_s.start_with?("3.")

      raise SpecLoadError, "Поддерживается только OpenAPI 3.x, обнаружена версия #{version}"
    end

    # В OpenAPI 3.1 paths необязателен: документ, описывающий только входящие
    # уведомления, состоит из одного раздела webhooks и полностью валиден
    def check_required_sections!(raw)
      unless raw["info"].is_a?(Hash)
        raise SpecLoadError, 'В спецификации отсутствует обязательный раздел "info"'
      end
      return if raw["paths"].is_a?(Hash) && !raw["paths"].empty?
      return if raw["webhooks"].is_a?(Hash) && !raw["webhooks"].empty?

      raise SpecLoadError,
            'В спецификации нет ни одного эндпоинта: отсутствуют разделы "paths" и "webhooks"'
    end

    def build_spec_model(raw)
      components = raw.fetch("components", {})

      endpoints = build_endpoints(raw["paths"], raw["security"])

      IR::SpecModel.new(
        title: raw.dig("info", "title"),
        version: raw.dig("info", "version"),
        servers: build_servers(raw["servers"]),
        security_schemes: build_security_schemes(components["securitySchemes"]),
        global_security: security_names(raw["security"]),
        endpoints: endpoints,
        schemas: components.fetch("schemas", {}),
        raw_webhooks: raw.fetch("webhooks", {}),
        raw_callbacks: collect_callbacks(raw["paths"]),
        notes: @notes + media_type_notes
      )
    end

    # Использование не-JSON содержимого — не ошибка, но о нём нужно знать:
    # сгенерированный клиент отправляет тело как JSON
    def media_type_notes
      other = @media_types.uniq.reject { |type| type == "application/json" }
      return [] if other.empty?

      ["тело запроса описано типом #{other.join(', ')} — сгенерированный сервис отправляет JSON, проверьте совместимость"]
    end

    # Шаблон адреса с переменными (https://{environment}.acme.example/{basePath})
    # раскрывается по default из спецификации: иначе фигурные скобки уезжают
    # прямо в BASE_URL сгенерированного сервиса и он падает в рантайме
    def build_servers(servers)
      Array(servers).map do |server|
        { url: expand_server_url(server), description: server["description"] }
      end
    end

    def expand_server_url(server)
      url = server["url"].to_s
      variables = server["variables"]
      return url unless variables.is_a?(Hash)

      url.gsub(/\{([^}]+)\}/) do
        name = Regexp.last_match(1)
        value = variables.dig(name, "default")
        if value.nil?
          @notes << "у переменной \"#{name}\" в адресе сервера нет default — подставьте значение вручную"
          Regexp.last_match(0)
        else
          value.to_s
        end
      end
    end

    def build_security_schemes(schemes)
      Hash(schemes).each_with_object({}) do |(name, scheme), acc|
        acc[name] = IR::SecurityScheme.new(
          name: name,
          type: scheme["type"],
          scheme: scheme["scheme"],
          location: scheme["in"],
          header_name: scheme["name"],
          description: scheme["description"]
        )
      end
    end

    def build_endpoints(paths, global_security)
      Hash(paths).each_with_object([]) do |(path, path_item), acc|
        next unless path_item.is_a?(Hash)

        shared_params = self.class.build_parameters(path_item["parameters"])

        HTTP_METHODS.each do |method|
          operation = path_item[method]
          next unless operation.is_a?(Hash)

          acc << build_endpoint(path, method, operation, shared_params, global_security)
        end
      end
    end

    def build_endpoint(path, method, operation, shared_params, global_security)
      # Если операция не указывает свой security — действует глобальный;
      # если указывает (в том числе пустой массив) — глобальный не применяется
      security = operation.key?("security") ? operation["security"] : global_security

      IR::Endpoint.new(
        path: path,
        http_method: method,
        operation_id: operation["operationId"],
        summary: operation["summary"],
        parameters: merge_parameters(shared_params, self.class.build_parameters(operation["parameters"])),
        request_body_schema: request_body_schema(operation["requestBody"]),
        responses: build_responses(operation["responses"]),
        security_names: security_names(security),
        request_examples: build_request_examples(operation["requestBody"]),
        response_examples: build_response_examples(operation["responses"])
      )
    end

    # В OpenAPI 3.0 входящее уведомление описывают разделом callbacks внутри
    # операции — это штатный способ, не менее частый, чем webhooks: из 3.1.
    # Собранные сюда операции превращаются в вебхук-эндпоинты в SemanticAnalyzer.
    def collect_callbacks(paths)
      Hash(paths).each_with_object({}) do |(_path, path_item), acc|
        next unless path_item.is_a?(Hash)

        HTTP_METHODS.each do |method|
          callbacks = path_item.dig(method, "callbacks")
          next unless callbacks.is_a?(Hash)

          callbacks.each { |name, definition| acc[name] = definition if definition.is_a?(Hash) }
        end
      end
    end

    # Вызывается и снаружи: SemanticAnalyzer разбирает этим же кодом параметры
    # операций из раздела webhooks: (OpenAPI 3.1)
    def self.build_parameters(params)
      Array(params).map do |p|
        schema = p.fetch("schema", {})
        IR::Parameter.new(
          name: p["name"],
          location: p["in"],
          required: p["required"] == true,
          schema_type: schema["type"],
          format: schema["format"],
          pattern: schema["pattern"],
          description: p["description"]
        )
      end
    end

    def request_body_schema(request_body)
      return nil unless request_body.is_a?(Hash)

      media_type = Content.select_media_type(request_body["content"])
      @media_types << media_type if media_type
      Content.schema(request_body)
    end

    def build_responses(responses)
      Content.responses(responses)
    end

    def build_request_examples(request_body)
      request_body.is_a?(Hash) ? Content.examples(request_body) : {}
    end

    # По спецификации параметр операции перекрывает объявленный на уровне пути,
    # если совпадают имя и расположение
    def merge_parameters(path_level, operation_level)
      overridden = operation_level.map { |p| [p.name, p.location] }
      path_level.reject { |p| overridden.include?([p.name, p.location]) } + operation_level
    end

    def build_response_examples(responses)
      Content.response_examples(responses)
    end

    # Массив SecurityRequirement (например [{"ApiKeyAuth" => []}]) превращается
    # в список имён схем (["ApiKeyAuth"])
    def security_names(security)
      Array(security).flat_map { |requirement| Hash(requirement).keys }
    end
  end
end
