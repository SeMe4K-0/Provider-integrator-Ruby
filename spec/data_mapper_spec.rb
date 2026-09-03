# frozen_string_literal: true

RSpec.describe ProviderIntegrator::DataMapper do
  let(:novapay_spec) do
    ProviderIntegrator::SpecLoader.load(File.expand_path("../specs_examples/provider_api.yaml", __dir__))
  end
  let(:novapay_analysis) { ProviderIntegrator::SemanticAnalyzer.analyze(novapay_spec) }

  describe "спецификация NovaPay" do
    subject(:report) { described_class.map(novapay_spec, novapay_analysis) }

    it "распознаёт все 5 статусов провайдера" do
      resolved_statuses = report.resolved.select { |e| e.category == :status }.map(&:key)
      expect(resolved_statuses).to contain_exactly("pending", "processing", "completed", "failed", "cancelled")
    end

    it "не оставляет нераспознанных статусов" do
      expect(report.unresolved.select { |e| e.category == :status }).to be_empty
    end

    it "распознаёт все встречающиеся HTTP-коды ошибок" do
      resolved_errors = report.resolved.select { |e| e.category == :error }.map(&:key)
      expect(resolved_errors).to include(400, 401, 402, 404, 409, 422, 429, 500)
    end

    it "распознаёт поле amount и определяет минорные единицы" do
      unit_entry = report.entries.find { |e| e.category == :field && e.key == "amount.unit" }
      expect(unit_entry.status).to eq(:resolved)
      expect(unit_entry.detail).to include("×100")
    end

    it "распознаёт вложенные поля получателя" do
      resolved_fields = report.resolved.select { |e| e.category == :field }.map(&:key)
      expect(resolved_fields).to include("recipient_phone", "recipient_bank_code", "recipient_bank_name")
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

      report = described_class.map(spec, analysis)
      unresolved_statuses = report.unresolved.select { |e| e.category == :status }

      expect(unresolved_statuses.map(&:key)).to eq(["provider_custom_status_xyz"])
    end
  end
end
