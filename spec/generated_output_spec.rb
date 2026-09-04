# frozen_string_literal: true

require "english"
require "tmpdir"

# Самое важное свойство генератора нельзя проверить, читая его код: результат
# должен запускаться. Здесь каждая спецификация проходит полный путь — генерация,
# проверка синтаксиса и реальный прогон сгенерированного самотеста в отдельном
# процессе. Именно отсутствие такой проверки прятало ошибки в шаблонах.
RSpec.describe "сгенерированные интеграции" do
  SPECS = {
    "novapay" => "specs_examples/provider_api.yaml",
    "cardpay" => "specs_examples/cardpay_api.yaml",
    "bankex" => "specs_examples/bankex_api.yaml",
    "inline200" => "spec/fixtures/status_200_provider.yaml",
    "implicit" => "spec/fixtures/implicit_webhook_provider.yaml",
    "nosecurity" => "spec/fixtures/no_security_provider.yaml",
    "queryauth" => "spec/fixtures/query_auth_provider.yaml",
    "composed" => "spec/fixtures/composed_schema_provider.yaml"
  }.freeze

  ROOT = File.expand_path("..", __dir__)
  NL = "
"

  def generate(provider, relative_spec, dir)
    ProviderIntegrator::Pipeline.new(
      spec_path: File.join(ROOT, relative_spec), provider: provider, output_dir: dir
    ).run
  end

  # Вывод команды не глушится, а возвращается вместе с результатом: при падении
  # сгенерированного самотеста без него виден только «expected true, got false»,
  # и причина остаётся неизвестной.
  def run_command(*command)
    output = IO.popen(command, err: %i[child out], &:read)
    [$CHILD_STATUS.success?, output.to_s]
  end

  SPECS.each do |provider, relative_spec|
    context "провайдер #{provider}" do
      around do |example|
        Dir.mktmpdir("generated-#{provider}") do |dir|
          @dir = dir
          example.run
        end
      end

      it "генерирует синтаксически корректный Ruby" do
        generate(provider, relative_spec, @dir)

        success, output = run_command(RbConfig.ruby, "-c", File.join(@dir, "#{provider}_service.rb"))

        expect(success).to be(true), "сгенерированный сервис не компилируется:#{NL}#{output}"
      end

      it "сгенерированный самотест проходит" do
        generate(provider, relative_spec, @dir)
        self_test = File.join(@dir, "#{provider}_integration_self_test_spec.rb")

        success, output = run_command(RbConfig.ruby, "-S", "rspec", self_test, "--options", File::NULL)

        expect(success).to be(true), "сгенерированный самотест не прошёл:#{NL}#{output}"
      end
    end
  end

  describe "провайдер, отвечающий на создание кодом 200" do
    around do |example|
      Dir.mktmpdir("generated-200") do |dir|
        @dir = dir
        example.run
      end
    end

    it "берёт код успешного ответа из спецификации, а не из литерала 201" do
      generate("inline200", SPECS.fetch("inline200"), @dir)
      self_test = File.read(File.join(@dir, "inline200_integration_self_test_spec.rb"))

      expect(self_test).to include("status: 200")
      expect(self_test).to include("response_200")
      expect(self_test).not_to include("response_201")
    end
  end

  describe "провайдер без эндпоинта создания" do
    around do |example|
      Dir.mktmpdir("generated-nocreate") do |dir|
        @dir = dir
        example.run
      end
    end

    it "не генерирует заведомо падающий тест создания" do
      generate("webhookonly", "spec/fixtures/webhooks_section_provider.yaml", @dir)
      self_test = File.read(File.join(@dir, "webhookonly_integration_self_test_spec.rb"))

      expect(self_test).not_to include('describe "создание операции"')
    end
  end
end
