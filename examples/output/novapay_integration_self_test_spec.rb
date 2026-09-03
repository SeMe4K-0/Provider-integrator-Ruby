# frozen_string_literal: true

require "json"
require "openssl"
require_relative "provider_base_service"
require_relative "mock_provider_server"
require_relative "novapay_service"

# Операция Space Payments в том виде, в каком её видит сервис провайдера:
# поля собраны из выражений, которые попали в сгенерированный build_payload
NovapayServiceOperation = Struct.new(:amount, :currency, :id, :payout_requisite, :provider_operation_id, keyword_init: true)

# Самотест сгенерированной интеграции: поднимает локальный мок провайдера на данных
# из fixtures.json и прогоняет полный цикл — создание операции, запрос статуса
# и обработку входящего уведомления с реально вычисленной подписью.
RSpec.describe Provider::NovapayService do
  let(:fixtures) { JSON.parse(File.read(File.expand_path("fixtures.json", __dir__))) }
  let(:callback_secret) { "test_callback_secret" }
  let(:service) { described_class.new(credentials: { api_key: "test_api_key", callback_secret: callback_secret }) }
  let(:operation) do
    NovapayServiceOperation.new(
      amount: 10000,
      currency: "RUB",
      id: "op_test_1",
      payout_requisite: {
  "type" => "sbp",
  "sbp" => { "phone" => "79001234567", "bank_code" => "044525225", "bank_name" => "Тестбанк" },
  "card" => { "number" => "4111111111111111" }
},
    )
  end

  before do
    @server = MockProviderServer.new(routes).start
    ENV["NOVAPAY_BASE_URL"] = @server.base_url
  end

  after do
    @server.stop
    ENV.delete("NOVAPAY_BASE_URL")
  end

  def routes
    [
      { method: "POST", path: %r{/payouts\z}, status: 201,
        body: fixtures.dig("create_request", "response_201") },
      { method: "GET", path: %r{/payouts/[^/]+\z}, status: 200,
        body: fixtures.dig("fetch_status", "response_200") }
    ]
  end

  describe "создание операции" do
    it "отправляет запрос и сохраняет идентификатор операции провайдера" do
      result = service.create_request(operation)

      expect(result).to be_success
      expect(operation.provider_operation_id)
        .to eq(fixtures.dig("create_request", "response_201", "id"))
    end

    it "конвертирует сумму в минорные единицы" do
      service.create_request(operation)

      body = JSON.parse(@server.requests.last.body)
      expect(body["amount"]).to eq(operation.amount * 100)
    end

    it "собирает реквизиты получателя" do
      service.create_request(operation)

      body = JSON.parse(@server.requests.last.body)
      expect(body.dig("recipient", "phone")).to eq(operation.payout_requisite.dig("sbp", "phone"))
    end

    it "передаёт заголовок авторизации" do
      service.create_request(operation)

      expect(@server.requests.last.headers).to include("x-api-key" => "test_api_key")
    end
  end

  describe "запрос статуса" do
    it "приводит статус провайдера к каноническому" do
      operation.provider_operation_id =
        fixtures.dig("create_request", "response_201", "id")

      result = service.fetch_status(operation)

      expect(result).to be_success
      expect(result.payload[:status]).to eq("in_progress")
    end
  end

  describe "обработка входящего уведомления" do
    def sign(raw_body)
      OpenSSL::HMAC.hexdigest("SHA256", callback_secret, raw_body)
    end

    # Конверт уведомления в том виде, в каком его передаёт платформа
    def envelope(body, signature: nil)
      raw_body = JSON.generate(body)
      {
        "body" => body,
        "raw_body" => raw_body,
        "headers" => { "X-NovaPay-Signature" => signature || sign(raw_body) }
      }
    end

    it "подтверждает операцию по уведомлению с корректной подписью" do
      result = service.process_callback(envelope(fixtures.dig("callback", "payload")))

      expect(result).to be_success
      expect(result.payload[:status]).to eq(fixtures.dig("callback", "expected_operation_status"))
    end

    it "принимает тело уведомления и без конверта, если платформа передала его напрямую" do
      body = fixtures.dig("callback", "payload")
      payload = body.merge("raw_body" => JSON.generate(body),
                            "headers" => { "X-NovaPay-Signature" => sign(JSON.generate(body)) })

      expect(service.process_callback(payload)).to be_success
    end

    it "отклоняет уведомление с неверной подписью" do
      result = service.process_callback(envelope(fixtures.dig("callback", "payload"), signature: "0" * 64))

      expect(result).to be_failed
      expect(result.message).to eq("provider.invalid_signature")
    end

    it "отклоняет уведомление без подписи" do
      result = service.process_callback(fixtures.dig("callback", "payload"))

      expect(result).to be_failed
      expect(result.message).to eq("provider.missing_signature")
    end

    it "отклоняет операцию по уведомлению об ошибке" do
      result = service.process_callback(envelope(fixtures.dig("callback_failed", "payload")))

      expect(result).to be_success
      expect(result.payload[:status]).to eq(fixtures.dig("callback_failed", "expected_operation_status"))
    end
  end
end
