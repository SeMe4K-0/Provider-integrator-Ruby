# frozen_string_literal: true

RSpec.describe ProviderIntegrator::SpecLoader do
  let(:fixtures) { File.expand_path("fixtures/broken", __dir__) }
  let(:novapay_spec) { File.expand_path("../specs_examples/provider_api.yaml", __dir__) }

  describe "успешный разбор спецификации NovaPay" do
    subject(:spec) { described_class.load(novapay_spec) }

    it "определяет все 5 эндпоинтов" do
      expect(spec.endpoints.size).to eq(5)
    end

    it "определяет метод и путь каждого эндпоинта" do
      pairs = spec.endpoints.map { |e| [e.http_method, e.path] }
      expect(pairs).to contain_exactly(
        ["post", "/payouts"],
        ["get", "/payouts/{payout_id}"],
        ["post", "/payouts/{payout_id}/cancel"],
        ["post", "/webhooks/payout"],
        ["get", "/balance"]
      )
    end

    it "определяет схему авторизации ApiKeyAuth" do
      scheme = spec.security_schemes["ApiKeyAuth"]
      expect(scheme.type).to eq("apiKey")
      expect(scheme.header_name).to eq("X-API-Key")
    end

    it "помечает webhook-эндпоинт как публичный (security: [])" do
      webhook = spec.endpoints.find { |e| e.path == "/webhooks/payout" }
      expect(webhook.public?).to be true
    end

    it "помечает остальные эндпоинты как требующие авторизации" do
      create_payout = spec.endpoints.find { |e| e.operation_id == "createPayout" }
      expect(create_payout.security_names).to eq(["ApiKeyAuth"])
    end

    it "разрешает $ref на вложенные схемы (Recipient внутри CreatePayoutRequest)" do
      create_payout = spec.endpoints.find { |e| e.operation_id == "createPayout" }
      recipient_schema = create_payout.request_body_schema.dig("properties", "recipient")
      expect(recipient_schema["properties"]).to have_key("phone")
    end

    it "разрешает $ref на переиспользуемый параметр Idempotency-Key" do
      create_payout = spec.endpoints.find { |e| e.operation_id == "createPayout" }
      idempotency = create_payout.parameters.find { |p| p.name == "Idempotency-Key" }
      expect(idempotency).not_to be_nil
      expect(idempotency.required?).to be false
    end

    it "разрешает $ref в ответах (400 → BadRequest → ErrorResponse)" do
      create_payout = spec.endpoints.find { |e| e.operation_id == "createPayout" }
      error_schema = create_payout.responses["400"]
      expect(error_schema.dig("properties", "error", "$ref")).to be_nil
      expect(error_schema.dig("properties")).to have_key("error")
    end
  end

  describe "обработка некорректного входа" do
    it "сообщает о ненайденном файле" do
      expect { described_class.load("no_such_file.yaml") }
        .to raise_error(ProviderIntegrator::SpecLoadError, /Файл не найден/)
    end

    it "сообщает о синтаксической ошибке YAML" do
      expect { described_class.load(File.join(fixtures, "invalid_syntax.yaml")) }
        .to raise_error(ProviderIntegrator::SpecLoadError, /YAML/)
    end

    it "отклоняет пустой файл как невалидный документ" do
      expect { described_class.load(File.join(fixtures, "empty.yaml")) }
        .to raise_error(ProviderIntegrator::SpecLoadError)
    end

    it "отклоняет Swagger 2.0 с понятным сообщением" do
      expect { described_class.load(File.join(fixtures, "swagger2.yaml")) }
        .to raise_error(ProviderIntegrator::SpecLoadError, /Swagger/)
    end

    it "сообщает об отсутствии раздела paths" do
      expect { described_class.load(File.join(fixtures, "missing_paths.yaml")) }
        .to raise_error(ProviderIntegrator::SpecLoadError, /paths/)
    end
  end
end
