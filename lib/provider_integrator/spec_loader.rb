# frozen_string_literal: true

require "yaml"

require_relative "errors"
require_relative "ref_resolver"
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
    end

    def load
      raw = read_yaml
      check_openapi_version!(raw)
      check_required_sections!(raw)

      resolved = RefResolver.new(raw).resolve(raw)
      build_spec_model(resolved)
    end

    private

    def read_yaml
      raise SpecLoadError, "Файл не найден: #{@path}" unless File.exist?(@path)

      YAML.safe_load_file(@path, aliases: true)
    rescue Psych::SyntaxError => e
      raise SpecLoadError, "Некорректный YAML в файле #{@path}: #{e.message}"
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

    def check_required_sections!(raw)
      unless raw["info"].is_a?(Hash)
        raise SpecLoadError, 'В спецификации отсутствует обязательный раздел "info"'
      end

      return if raw["paths"].is_a?(Hash) && !raw["paths"].empty?

      raise SpecLoadError, 'В спецификации отсутствует обязательный раздел "paths" с эндпоинтами'
    end

    def build_spec_model(raw)
      components = raw.fetch("components", {})

      IR::SpecModel.new(
        title: raw.dig("info", "title"),
        version: raw.dig("info", "version"),
        servers: build_servers(raw["servers"]),
        security_schemes: build_security_schemes(components["securitySchemes"]),
        global_security: security_names(raw["security"]),
        endpoints: build_endpoints(raw["paths"], raw["security"]),
        schemas: components.fetch("schemas", {}),
        raw_webhooks: raw.fetch("webhooks", {})
      )
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

        shared_params = build_parameters(path_item["parameters"])

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
        parameters: shared_params + build_parameters(operation["parameters"]),
        request_body_schema: request_body_schema(operation["requestBody"]),
        responses: build_responses(operation["responses"]),
        security_names: security_names(security)
      )
    end

    def build_parameters(params)
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

      request_body.dig("content", "application/json", "schema")
    end

    def build_responses(responses)
      Hash(responses).each_with_object({}) do |(status, response), acc|
        acc[status] = response.is_a?(Hash) ? response.dig("content", "application/json", "schema") : nil
      end
    end

    # Массив SecurityRequirement (например [{"ApiKeyAuth" => []}]) превращается
    # в список имён схем (["ApiKeyAuth"])
    def security_names(security)
      Array(security).flat_map { |requirement| Hash(requirement).keys }
    end
  end
end
