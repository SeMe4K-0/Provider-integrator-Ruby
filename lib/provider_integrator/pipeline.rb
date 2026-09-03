# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "errors"
require_relative "spec_loader"
require_relative "semantic_analyzer"
require_relative "data_mapper"
require_relative "generation_context"
require_relative "generators/renderer"

module ProviderIntegrator
  # Сквозной конвейер: спецификация на входе — готовый комплект файлов на выходе.
  # Загрузка → смысловой анализ → сопоставление данных → генерация файлов.
  class Pipeline
    STUBS_DIR = File.expand_path("../../stubs", __dir__)

    Result = Struct.new(:spec, :analysis, :mapping, :context, :written_files, keyword_init: true)

    # Имя провайдера попадает и в имя класса, и в путь файла, поэтому проверяется
    # на входе: иначе генератор молча создаст файл с невалидным Ruby внутри
    PROVIDER_NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/

    def initialize(spec_path:, provider:, output_dir:, rules_dir: DataMapper::DEFAULT_RULES_DIR)
      @spec_path = spec_path
      @provider = validate_provider(provider)
      @output_dir = output_dir
      @rules_dir = rules_dir
    end

    def run
      result = analyze_only
      result.written_files = write_files(result.context)
      result
    end

    # Разбор и сопоставление без записи файлов — режим --dry-run
    def analyze_only
      spec = SpecLoader.load(@spec_path)
      analysis = SemanticAnalyzer.analyze(spec)
      mapping = DataMapper.map(spec, analysis, rules_dir: @rules_dir)
      context = GenerationContext.new(provider: @provider, spec: spec, analysis: analysis,
                                      mapping: mapping, rules_dir: @rules_dir)

      Result.new(spec: spec, analysis: analysis, mapping: mapping, context: context, written_files: nil)
    end

    private

    def validate_provider(provider)
      name = provider.to_s.downcase
      return name if name.match?(PROVIDER_NAME_FORMAT)

      raise GenerationError,
            "Недопустимое имя провайдера: #{provider.inspect}. Ожидается имя из латинских букв, " \
            "цифр и подчёркиваний, начинающееся с буквы, например: novapay"
    end

    def write_files(context)
      prepare_output_dir
      renderer = Generators::Renderer.new(context)

      files = {
        context.service_file_name => renderer.render("service.rb.erb"),
        context.docs_file_name => renderer.render("integration.md.erb"),
        context.fixtures_file_name => "#{JSON.pretty_generate(context.fixtures)}\n",
        context.self_test_file_name => renderer.render("self_test_spec.rb.erb")
      }

      written = files.map { |name, content| write_file(name, content) }
      written + copy_stubs
    end

    def prepare_output_dir
      FileUtils.mkdir_p(@output_dir)
    rescue SystemCallError => e
      raise GenerationError, "Не удалось создать каталог результата #{@output_dir}: #{e.message}"
    end

    def write_file(name, content)
      path = File.join(@output_dir, name)
      File.write(path, content)
      path
    rescue SystemCallError => e
      raise GenerationError, "Не удалось записать файл #{path}: #{e.message}"
    end

    # Заглушки контракта и мок провайдера кладутся рядом с результатом,
    # чтобы сгенерированный самотест запускался без остальной части репозитория
    def copy_stubs
      %w[provider_base_service.rb mock_provider_server.rb].map do |name|
        write_file(name, File.read(File.join(STUBS_DIR, name)))
      end
    end
  end
end
