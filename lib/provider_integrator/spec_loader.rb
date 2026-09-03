# frozen_string_literal: true

require "date"
require "yaml"

require_relative "errors"
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

      YAML.safe_load_file(@path, permitted_classes: [Date, Time], aliases: true)
    rescue Psych::SyntaxError => e
      raise SpecLoadError, "Некорректный YAML в файле #{@path}: #{e.message}"
    rescue Psych::Exception => e
      raise SpecLoadError, "Не удалось разобрать YAML в файле #{@path}: #{e.message}"
    rescue SystemCallError => e
      raise SpecLoadError, "Не удалось прочитать файл #{@path}: #{e.message}"
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

    def build_servers(servers)
      Array(servers).map { |s| { url: s["url"], description: s["description"] } }
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

    # Тип содержимого выбирается по приоритету, а не жёстко: сначала JSON,
    # затем любой вендорный +json, затем форма, и лишь потом первый доступный.
    # Выбор запоминается — он попадает в отчёт и в документацию.
    CONTENT_PRIORITY = [
      ->(type) { type == "application/json" },
      ->(type) { type.end_with?("+json") },
      ->(type) { type == "application/x-www-form-urlencoded" }
    ].freeze

    def select_media_type(content)
      return nil unless content.is_a?(Hash) && !content.empty?

      types = content.keys
      CONTENT_PRIORITY.each do |matcher|
        found = types.find { |type| matcher.call(type.to_s.downcase) }
        return found if found
      end
      types.first
    end

    def request_body_schema(request_body)
      return nil unless request_body.is_a?(Hash)

      content = request_body["content"]
      media_type = select_media_type(content)
      return nil if media_type.nil?

      @media_types << media_type
      content.dig(media_type, "schema")
    end

    def build_responses(responses)
      Hash(responses).each_with_object({}) do |(status, response), acc|
        next acc[status] = nil unless response.is_a?(Hash)

        media_type = select_media_type(response["content"])
        acc[status] = media_type ? response.dig("content", media_type, "schema") : nil
      end
    end

    # По спецификации параметр операции перекрывает объявленный на уровне пути,
    # если совпадают имя и расположение
    def merge_parameters(path_level, operation_level)
      overridden = operation_level.map { |p| [p.name, p.location] }
      path_level.reject { |p| overridden.include?([p.name, p.location]) } + operation_level
    end

    # Примеры тела запроса: одиночный example сохраняется под ключом "default",
    # именованные examples — под своими именами (нужны для генерации фикстур)
    def build_request_examples(request_body)
      return {} unless request_body.is_a?(Hash)

      media = request_body.dig("content", "application/json")
      named_examples(media)
    end

    # Примеры ответов по HTTP-кодам
    def build_response_examples(responses)
      Hash(responses).each_with_object({}) do |(status, response), acc|
        next unless response.is_a?(Hash)

        examples = named_examples(response.dig("content", "application/json"))
        acc[status] = examples unless examples.empty?
      end
    end

    def named_examples(media)
      return {} unless media.is_a?(Hash)

      result = {}
      result["default"] = media["example"] if media.key?("example")
      Hash(media["examples"]).each do |name, entry|
        result[name] = entry["value"] if entry.is_a?(Hash) && entry.key?("value")
      end
      result
    end

    # Массив SecurityRequirement (например [{"ApiKeyAuth" => []}]) превращается
    # в список имён схем (["ApiKeyAuth"])
    def security_names(security)
      Array(security).flat_map { |requirement| Hash(requirement).keys }
    end
  end
end
