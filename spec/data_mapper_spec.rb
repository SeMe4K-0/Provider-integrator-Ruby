# frozen_string_literal: true

RSpec.describe ProviderIntegrator::DataMapper do
  let(:novapay_spec) do
    ProviderIntegrator::SpecLoader.load(File.expand_path("../specs_examples/provider_api.yaml", __dir__))
  end
  let(:novapay_analysis) { ProviderIntegrator::SemanticAnalyzer.analyze(novapay_spec) }

  describe "спецификация NovaPay" do
    subject(:result) { described_class.map(novapay_spec, novapay_analysis) }

    it "строит таблицу статусов для генерации" do
      expect(result.status_map).to eq(
        "pending" => "in_progress",
        "processing" => "in_progress",
        "completed" => "approved",
        "failed" => "rejected",
        "cancelled" => "rejected"
      )
    end

    it "не оставляет нераспознанных статусов" do
      expect(result.report.unresolved.select { |e| e.category == :status }).to be_empty
    end

    it "строит таблицу ошибок с кодом и действием" do
      expect(result.error_map[429]).to eq(code: "rate_limit", action: "retry_backoff")
      expect(result.error_map.keys).to include(400, 401, 402, 404, 409, 422, 500)
    end

    it "определяет минорные единицы суммы и коэффициент конвертации" do
      expect(result.amount_factor).to eq(100)
      expect(result.amount_confirmed).to be true
    end

    it "приводит минимальную сумму к единицам Space Payments" do
      expect(result.min_amount).to eq(1000)
    end

    it "определяет валюту из enum спецификации" do
      expect(result.currency).to eq("RUB")
    end

    it "сохраняет путь до вложенных полей получателя" do
      expect(result.fields.dig("recipient_phone", :path)).to eq(%w[recipient phone])
      expect(result.fields.dig("recipient_bank_code", :path)).to eq(%w[recipient bank_code])
    end

    it "находит поле идентификатора операции в ответе и в уведомлении" do
      expect(result.provider_id_field).to eq("id")
      expect(result.webhook_id_field).to eq("payout_id")
    end

    it "определяет схему подписи webhook по описанию заголовка" do
      expect(result.signature.header_name).to eq("X-NovaPay-Signature")
      expect(result.signature.algorithm).to eq("SHA256")
      expect(result.signature.encoding).to eq("hex")
      expect(result.signature.confirmed).to be true
    end
  end

  describe "провайдер с незнакомым статусом" do
    it "не додумывает соответствие, а помечает статус как unresolved" do
      schemas = {
        "Foo" => { "properties" => { "status" => { "type" => "string", "enum" => ["provider_custom_status_xyz"] } } }
      }
      spec = ProviderIntegrator::IR::SpecModel.new(
        title: "Foo", version: "1.0", servers: [], security_schemes: {}, global_security: [],
        endpoints: [], schemas: schemas, raw_webhooks: {}
      )
      analysis = ProviderIntegrator::AnalysisResult.new(endpoints: [], webhook_found: false, webhook_source: nil)

      result = described_class.map(spec, analysis)
      unresolved_statuses = result.report.unresolved.select { |e| e.category == :status }

      expect(result.status_map).to be_empty
      expect(unresolved_statuses.map(&:key)).to eq(["provider_custom_status_xyz"])
    end
  end
end
