# frozen_string_literal: true

require "erb"
require_relative "../errors"

module ProviderIntegrator
  module Generators
    # Рендерит ERB-шаблон из каталога templates в строку.
    # Ошибка внутри шаблона превращается в GenerationError с именем шаблона,
    # чтобы падение было понятным, а не безымянным трейсом ERB.
    class Renderer
      TEMPLATES_DIR = File.expand_path("../../../templates", __dir__)

      def initialize(context)
        @context = context
      end

      def render(template_name)
        path = File.join(TEMPLATES_DIR, template_name)
        raise GenerationError, "Не найден шаблон #{template_name}" unless File.exist?(path)

        ERB.new(File.read(path), trim_mode: "-").result(@context.get_binding)
      rescue StandardError => e
        raise GenerationError, "Ошибка в шаблоне #{template_name}: #{e.class} — #{e.message}"
      end
    end
  end
end
