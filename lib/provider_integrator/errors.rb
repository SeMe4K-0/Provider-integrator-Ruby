# frozen_string_literal: true

module ProviderIntegrator
  # Базовый класс всех ошибок генератора
  class Error < StandardError; end

  # Спецификация не может быть загружена или не проходит базовую проверку структуры
  class SpecLoadError < Error; end

  # Сбой на этапе генерации файлов: отсутствует шаблон, ошибка внутри шаблона,
  # нет прав на запись в каталог результата
  class GenerationError < Error; end
end
