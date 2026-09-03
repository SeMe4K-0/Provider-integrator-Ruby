# frozen_string_literal: true

require "tmpdir"

RSpec.describe ProviderIntegrator::Pipeline do
  let(:novapay_spec) { File.expand_path("../specs_examples/provider_api.yaml", __dir__) }

  around do |example|
    Dir.mktmpdir("provider-integrator-spec") do |dir|
      @output_dir = dir
      example.run
    end
  end

  def generate(spec_path: novapay_spec, provider: "novapay")
    described_class.new(spec_path: spec_path, provider: provider, output_dir: @output_dir).run
  end

  describe "полный прогон на спецификации NovaPay" do
    it "создаёт полный комплект файлов интеграции" do
      generate

      expect(Dir.children(@output_dir)).to contain_exactly(
        "novapay_service.rb", "INTEGRATION.md", "fixtures.json",
        "novapay_integration_self_test_spec.rb", "provider_base_service.rb", "mock_provider_server.rb"
      )
    end

    it "генерирует синтаксически корректный Ruby" do
      generate
      service_path = File.join(@output_dir, "novapay_service.rb")

      expect(system(RbConfig.ruby, "-c", service_path, out: File::NULL, err: File::NULL)).to be true
    end

    it "переносит в сервис таблицы статусов и ошибок из спецификации" do
      generate
      service = File.read(File.join(@output_dir, "novapay_service.rb"))

      expect(service).to include('"completed" => "approved"')
      expect(service).to include('429 => { code: "rate_limit", action: "retry_backoff" }')
    end

    it "собирает тело запроса с конвертацией суммы и вложенными реквизитами" do
      generate
      service = File.read(File.join(@output_dir, "novapay_service.rb"))

      expect(service).to include("amount: (operation.amount * 100).to_i")
      expect(service).to include('phone: operation.payout_requisite.dig("sbp", "phone")')
    end

    it "генерирует проверку подписи с определённым из спецификации алгоритмом" do
      generate
      service = File.read(File.join(@output_dir, "novapay_service.rb"))

      expect(service).to include('SIGNATURE_HEADER = "X-NovaPay-Signature"')
      expect(service).to include('OpenSSL::HMAC.hexdigest("SHA256"')
    end

    it "кладёт в фикстуры примеры из спецификации и ожидаемые статусы операции" do
      generate
      fixtures = JSON.parse(File.read(File.join(@output_dir, "fixtures.json")))

      expect(fixtures.dig("create_request", "response_201", "id")).to eq("np_7f3a9b2c")
      expect(fixtures.dig("callback", "expected_operation_status")).to eq("approved")
      expect(fixtures.dig("callback_failed", "expected_operation_status")).to eq("rejected")
      expect(fixtures.dig("edge_cases", "amount_below_minimum", "amount")).to eq(999)
    end

    it "описывает в документации авторизацию, статусы и подпись" do
      generate
      docs = File.read(File.join(@output_dir, "INTEGRATION.md"))

      expect(docs).to include("X-API-Key")
      expect(docs).to include("| completed | approved |")
      expect(docs).to include("HMAC-SHA256")
      expect(docs).to include("Нераспознанных элементов нет")
    end
  end

  describe "провайдер без вебхука" do
    let(:no_webhook_spec) { File.expand_path("fixtures/no_webhook_provider.yaml", __dir__) }

    it "не генерирует обработку уведомлений и честно пишет об этом в документации" do
      generate(spec_path: no_webhook_spec, provider: "bankex")
      service = File.read(File.join(@output_dir, "bankex_service.rb"))
      docs = File.read(File.join(@output_dir, "INTEGRATION.md"))

      expect(service).not_to include("def process_callback")
      expect(docs).to include("не найден заголовок с подписью")
    end

    it "сообщает в документации о том, что осталось нераспознанным" do
      generate(spec_path: no_webhook_spec, provider: "bankex")
      docs = File.read(File.join(@output_dir, "INTEGRATION.md"))

      expect(docs).to include("Требует ручного решения")
      expect(docs).to include("не найден заголовок с подписью")
    end
  end

  describe "обработка ошибок" do
    it "сообщает понятной ошибкой о некорректной спецификации" do
      broken = File.expand_path("fixtures/broken/swagger2.yaml", __dir__)

      expect { generate(spec_path: broken) }
        .to raise_error(ProviderIntegrator::SpecLoadError, /Swagger/)
    end
  end
end
