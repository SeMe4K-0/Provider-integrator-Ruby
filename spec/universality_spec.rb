# frozen_string_literal: true

require "tmpdir"

# Проверка главного свойства решения: одна и та же логика без правок кода
# отрабатывает на спецификациях, различающихся авторизацией, именами полей
# и статусов, наличием вебхука и алгоритмом подписи.
RSpec.describe "универсальность генератора" do
  def analyze(file_name)
    path = File.expand_path("../specs_examples/#{file_name}", __dir__)
    spec = ProviderIntegrator::SpecLoader.load(path)
    analysis = ProviderIntegrator::SemanticAnalyzer.analyze(spec)
    [spec, analysis, ProviderIntegrator::DataMapper.map(spec, analysis)]
  end

  describe "CardPay: Bearer-токен, суммы в центах, подпись SHA512 в base64" do
    subject(:mapping) { analyze("cardpay_api.yaml").last }

    it "определяет Bearer-авторизацию" do
      spec = analyze("cardpay_api.yaml").first
      scheme = spec.security_schemes["BearerAuth"]
      expect([scheme.type, scheme.scheme]).to eq(%w[http bearer])
    end

    it "читает статус из поля state, а не status" do
      expect(mapping.status_field).to eq("state")
    end

    it "распознаёт минорные единицы по английскому описанию cents" do
      expect(mapping.amount_factor).to eq(100)
      expect(mapping.min_amount).to eq(500)
    end

    it "определяет алгоритм и кодировку подписи из описания заголовка" do
      expect(mapping.signature.algorithm).to eq("SHA512")
      expect(mapping.signature.encoding).to eq("base64")
    end

    it "сопоставляет order_id с external_id по словарю синонимов" do
      expect(mapping.fields.dig("external_id", :name)).to eq("order_id")
    end

    it "не додумывает неоднозначный статус manual_review" do
      expect(mapping.status_map).not_to have_key("manual_review")
      expect(mapping.report.unresolved.map(&:key)).to include("manual_review")
    end

    it "помечает поля СБП как неприменимые, а не как проблему" do
      skipped = mapping.report.skipped.map(&:key)
      expect(skipped).to include("recipient_phone", "recipient_bank_code")
      expect(mapping.report.unresolved.map(&:key)).not_to include("recipient_phone")
    end
  end

  describe "Bankex: нестандартный заголовок ключа, другие имена полей, без вебхука" do
    subject(:mapping) { analyze("bankex_api.yaml").last }

    it "определяет нестандартное имя заголовка авторизации" do
      spec = analyze("bankex_api.yaml").first
      expect(spec.security_schemes["ApiKeyAuth"].header_name).to eq("Authorization-Token")
    end

    it "сообщает, что вебхук отсутствует" do
      analysis = analyze("bankex_api.yaml")[1]
      expect(analysis.webhook_found).to be false
      expect(mapping.signature).to be_nil
    end

    it "сопоставляет sum, msisdn и bic по словарю синонимов" do
      expect(mapping.fields.dig("amount", :name)).to eq("sum")
      expect(mapping.fields.dig("recipient_phone", :name)).to eq("msisdn")
      expect(mapping.fields.dig("recipient_bank_code", :name)).to eq("bic")
    end

    it "не применяет конвертацию суммы, когда единицы не указаны явно" do
      expect(mapping.amount_factor).to eq(1)
      expect(mapping.amount_confirmed).to be false
    end
  end

  describe "сравнение трёх провайдеров" do
    it "даёт разные наборы ролей эндпоинтов без правок кода генератора" do
      roles = %w[provider_api.yaml cardpay_api.yaml bankex_api.yaml].map do |file|
        analyze(file)[1].endpoints.map(&:role).uniq.sort
      end

      expect(roles[0]).to eq(%i[cancel create other status webhook].sort)
      expect(roles[1]).to eq(%i[create status webhook].sort)
      expect(roles[2]).to eq(%i[create status].sort)
    end
  end
end
