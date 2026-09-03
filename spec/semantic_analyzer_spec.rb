# frozen_string_literal: true

RSpec.describe ProviderIntegrator::SemanticAnalyzer do
  let(:fixtures) { File.expand_path("fixtures", __dir__) }
  let(:novapay) do
    ProviderIntegrator::SpecLoader.load(File.expand_path("../specs_examples/provider_api.yaml", __dir__))
  end

  describe "спецификация NovaPay (webhook как обычный path)" do
    subject(:analysis) { described_class.analyze(novapay) }

    it "определяет роль create для POST /payouts" do
      endpoint = analysis.endpoints.find { |e| e.path == "/payouts" && e.http_method == "post" }
      expect(endpoint.role).to eq(:create)
    end

    it "определяет роль status для GET /payouts/{payout_id}" do
      endpoint = analysis.endpoints.find { |e| e.path == "/payouts/{payout_id}" && e.http_method == "get" }
      expect(endpoint.role).to eq(:status)
    end

    it "определяет роль cancel для POST /payouts/{payout_id}/cancel" do
      endpoint = analysis.endpoints.find { |e| e.path == "/payouts/{payout_id}/cancel" }
      expect(endpoint.role).to eq(:cancel)
    end

    it "определяет роль webhook для POST /webhooks/payout" do
      endpoint = analysis.endpoints.find { |e| e.path == "/webhooks/payout" }
      expect(endpoint.role).to eq(:webhook)
    end

    it "определяет роль other для GET /balance" do
      endpoint = analysis.endpoints.find { |e| e.path == "/balance" }
      expect(endpoint.role).to eq(:other)
    end

    it "сообщает, что webhook найден через path" do
      expect(analysis.webhook_found).to be true
      expect(analysis.webhook_source).to eq(:path)
    end
  end

  describe "провайдер с разделом webhooks: верхнего уровня (OpenAPI 3.1)" do
    subject(:analysis) do
      spec = ProviderIntegrator::SpecLoader.load(File.join(fixtures, "webhooks_section_provider.yaml"))
      described_class.analyze(spec)
    end

    it "находит webhook и указывает источник webhooks_section" do
      expect(analysis.webhook_found).to be true
      expect(analysis.webhook_source).to eq(:webhooks_section)
    end

    it "синтезирует псевдо-эндпоинт для операции из webhooks:" do
      webhook = analysis.by_role(:webhook).first
      expect(webhook.path).to eq("webhook:transferUpdated")
    end
  end

  describe "провайдер, не описавший авторизацию" do
    subject(:analysis) do
      spec = ProviderIntegrator::SpecLoader.load(File.join(fixtures, "no_security_provider.yaml"))
      described_class.analyze(spec)
    end

    it "не принимает создание операции за входящее уведомление" do
      endpoint = analysis.endpoints.find { |e| e.path == "/payouts" && e.http_method == "post" }
      expect(endpoint.role).to eq(:create)
    end

    it "не находит webhook там, где его нет" do
      expect(analysis.webhook_found).to be false
    end
  end

  describe "webhook без характерного имени пути" do
    subject(:analysis) do
      spec = ProviderIntegrator::SpecLoader.load(File.join(fixtures, "implicit_webhook_provider.yaml"))
      described_class.analyze(spec)
    end

    it "опознаёт публичный POST с телом как уведомление, когда авторизация где-то требуется" do
      endpoint = analysis.endpoints.find { |e| e.path == "/events" }
      expect(endpoint.role).to eq(:webhook)
    end

    it "помечает такое определение как косвенное" do
      expect(analysis.webhook_source).to eq(:heuristic)
    end
  end

  describe "провайдер без webhook (ни path, ни webhooks:)" do
    subject(:analysis) do
      spec = ProviderIntegrator::SpecLoader.load(File.join(fixtures, "no_webhook_provider.yaml"))
      described_class.analyze(spec)
    end

    it "явно сообщает, что webhook не найден, а не пропускает молча" do
      expect(analysis.webhook_found).to be false
      expect(analysis.webhook_source).to be_nil
    end
  end
end
