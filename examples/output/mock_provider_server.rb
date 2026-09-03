# frozen_string_literal: true

require "json"
require "socket"

# Локальный мок API провайдера для самотеста сгенерированной интеграции.
# Отвечает заранее заданными ответами из fixtures.json и записывает полученные
# запросы, чтобы тест мог проверить фактически отправленное тело.
#
# Написан на TCPServer из stdlib: WEBrick исключён из стандартной библиотеки
# начиная с новых версий Ruby, а тянуть внешний гем ради теста не нужно.
class MockProviderServer
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true)

  attr_reader :requests

  # routes — массив вида { method: "POST", path: %r{/payouts\z}, status: 201, body: {...} }
  def initialize(routes)
    @routes = routes
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
  end

  def base_url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def start
    @thread = Thread.new do
      loop do
        session = @server.accept
        handle(session)
      rescue IOError, Errno::EBADF, Errno::ECONNRESET
        break
      end
    end
    self
  end

  def stop
    @thread&.kill
    @server.close unless @server.closed?
  end

  private

  def handle(session)
    request = read_request(session)
    @requests << request
    route = @routes.find { |r| r[:method] == request.method && request.path.match?(r[:path]) }
    write_response(session, route)
  ensure
    session.close
  end

  def read_request(session)
    method, path = session.gets.to_s.split(" ")
    headers = read_headers(session)
    length = headers["content-length"].to_i
    body = length.positive? ? session.read(length).to_s.force_encoding("UTF-8") : nil

    Request.new(method: method, path: path, headers: headers, body: body)
  end

  def read_headers(session)
    headers = {}
    while (line = session.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.to_s.strip.downcase] = value.to_s.strip
    end
    headers
  end

  def write_response(session, route)
    status = route ? route[:status] : 404
    payload = JSON.generate(route ? route[:body] : { "error" => { "code" => "not_found" } })

    session.print("HTTP/1.1 #{status} #{status == 404 ? 'Not Found' : 'OK'}\r\n")
    session.print("Content-Type: application/json\r\n")
    session.print("Content-Length: #{payload.bytesize}\r\n")
    session.print("Connection: close\r\n\r\n")
    session.print(payload)
  end
end
