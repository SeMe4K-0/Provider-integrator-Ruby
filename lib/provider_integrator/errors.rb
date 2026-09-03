# frozen_string_literal: true

module ProviderIntegrator
  # Базовый класс всех ошибок генератора
  class Error < StandardError; end

  # Спецификация не может быть загружена или не проходит базовую проверку структуры
  class SpecLoadError < Error; end
end
