# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Минимальная заглушка контракта Space Payments. В основном приложении эти классы
# уже существуют; здесь они нужны, чтобы сгенерированный сервис можно было
# запустить и проверить тестами вне приложения.
class Provider
  class Error < StandardError; end
  class RateLimitError < Error; end
  class UnauthorizedError < Error; end

  # Результат работы метода сервиса
  class Result
    attr_reader :code, :message, :payload

    def initialize(state, code: nil, message: nil, payload: {})
      @state = state
      @code = code
      @message = message
      @payload = payload
    end

    def success?
      @state == :success
    end

    def failed?
      @state == :failure
    end
  end

  # HTTP-клиент поверх Net::HTTP. Коды 401 и 429 поднимаются исключениями,
  # потому что обрабатываются одинаково для любого запроса; остальные коды
  # возвращаются вызывающему коду как обычный ответ.
  class HttpClient
    class Response
      attr_reader :code, :body

      def initialize(code, body)
        @code = code
        @body = body
      end

      def success?
        @code.between?(200, 299)
      end
    end

    def post(url, json:, headers: {})
      request(Net::HTTP::Post, url, headers, JSON.generate(json))
    end

    def get(url, headers: {})
      request(Net::HTTP::Get, url, headers, nil)
    end

    private

    def request(request_class, url, headers, body)
      uri = URI.parse(url)
      http_request = request_class.new(uri, headers.merge("Content-Type" => "application/json"))
      http_request.body = body if body

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(http_request)
      end

      raise UnauthorizedError if response.code.to_i == 401
      raise RateLimitError if response.code.to_i == 429

      Response.new(response.code.to_i, parse_body(response.body))
    end

    def parse_body(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end
  end

  # Базовый сервис провайдера: контракт из четырёх методов, которые переопределяет
  # каждая конкретная интеграция, плюс общие помощники для ответов и операций.
  class BaseService
    attr_reader :credentials

    def initialize(credentials: {}, client: HttpClient.new)
      @credentials = credentials
      @client = client
    end

    def check_conditions(_operation, _request_method = "create")
      success
    end

    def create_request(_operation, _request_method = "create")
      not_implemented
    end

    def fetch_status(_operation)
      not_implemented
    end

    def process_callback(_payload, signature: nil, raw_body: nil)
      not_implemented
    end

    private

    attr_reader :client

    def success(payload = {})
      Result.new(:success, payload: payload)
    end

    def failure(code, message)
      Result.new(:failure, code: code, message: message)
    end

    def approve_operation(provider_operation_id)
      success(operation_id: provider_operation_id, status: "approved")
    end

    def reject_operation(provider_operation_id, reason = nil)
      success(operation_id: provider_operation_id, status: "rejected", reason: reason)
    end

    def progress_operation(provider_operation_id)
      success(operation_id: provider_operation_id, status: "in_progress")
    end

    def not_implemented
      failure(:not_implemented, "provider.not_implemented")
    end
  end
end
