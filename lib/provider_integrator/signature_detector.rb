# frozen_string_literal: true

require "yaml"

module ProviderIntegrator
  # Определяет заголовок и алгоритм подписи входящего уведомления.
  # OpenAPI не описывает криптосхемы формально: единственный доступный источник —
  # текст description у заголовка подписи. Поэтому разбор ключевых слов вынесен
  # в config/rules/signature_schemes.yml, а когда алгоритм определить не удалось,
  # берётся безопасный дефолт с пометкой confirmed: false — вместо тихой догадки.
  class SignatureDetector
    Scheme = Struct.new(:header_name, :algorithm, :encoding, :confirmed, keyword_init: true)

    def self.detect(analysis, rules_dir:, report:)
      new(analysis, rules_dir, report).detect
    end

    def initialize(analysis, rules_dir, report)
      @analysis = analysis
      @rules = YAML.load_file(File.join(rules_dir, "signature_schemes.yml"))
      @header_keywords = Array(YAML.load_file(File.join(rules_dir, "heuristics.yml"))["signature_header_keywords"])
      @report = report
    end

    def detect
      webhook = @analysis.by_role(:webhook).first
      return nil if webhook.nil?

      header = webhook.parameters.find { |p| p.location == "header" && signature_like?(p) }
      if header.nil?
        @report.add_unresolved(:signature, "(заголовок подписи)",
                                "у webhook-эндпоинта не найден заголовок с подписью — проверка подписи не генерируется")
        return nil
      end

      build_scheme(header)
    end

    private

    def signature_like?(parameter)
      text = "#{parameter.name} #{parameter.description}".downcase
      @header_keywords.any? { |keyword| text.include?(keyword.to_s.downcase) }
    end

    def build_scheme(header)
      description = header.description.to_s.downcase
      rule = Array(@rules["rules"]).find { |r| Array(r["keywords"]).any? { |kw| description.include?(kw) } }
      encoding = base64?(description) ? "base64" : @rules.dig("default", "encoding")

      scheme = Scheme.new(
        header_name: header.name,
        algorithm: rule ? rule["algorithm"] : @rules.dig("default", "algorithm"),
        encoding: encoding,
        confirmed: !rule.nil?
      )
      add_report_entry(scheme)
      scheme
    end

    def base64?(description)
      Array(@rules["base64_keywords"]).any? { |kw| description.include?(kw) }
    end

    def add_report_entry(scheme)
      detail = "#{scheme.header_name}: HMAC-#{scheme.algorithm}, #{scheme.encoding}"
      if scheme.confirmed
        @report.add_resolved(:signature, "webhook", "→ #{detail}")
      else
        @report.add_unresolved(:signature, "webhook",
                                "алгоритм не указан в описании заголовка — принят дефолт (#{detail}), требуется подтверждение")
      end
    end
  end
end
