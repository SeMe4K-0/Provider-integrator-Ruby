# frozen_string_literal: true

RSpec.describe ProviderIntegrator::IR::Parameter do
  it "required? отражает переданный флаг" do
    param = described_class.new(name: "id", location: "path", required: true, schema_type: "string")
    expect(param.required?).to be true
  end
end

RSpec.describe ProviderIntegrator::IR::Endpoint do
  let(:webhook) do
    described_class.new(
      path: "/webhooks/payout", http_method: "post", operation_id: "payoutWebhook",
      summary: nil, parameters: [], request_body_schema: nil, responses: {}, security_names: []
    )
  end
  let(:create_payout) do
    described_class.new(
      path: "/payouts", http_method: "post", operation_id: "createPayout",
      summary: nil, parameters: [], request_body_schema: nil, responses: {}, security_names: ["ApiKeyAuth"]
    )
  end

  it "public? истинно, когда список схем авторизации пуст" do
    expect(webhook.public?).to be true
  end

  it "public? ложно, когда требуется авторизация" do
    expect(create_payout.public?).to be false
  end

  it "to_s печатает HTTP-метод в верхнем регистре и путь" do
    expect(create_payout.to_s).to eq("POST /payouts")
  end

  it "role по умолчанию не определена — её выставляет SemanticAnalyzer во второй части" do
    expect(create_payout.role).to be_nil
  end
end
