# frozen_string_literal: true

module ProviderIntegrator
  # Отчёт о сопоставлении данных провайдера с каноническими значениями Space Payments.
  # Каждая запись — либо resolved (нашли соответствие), либо unresolved (не нашли,
  # додумывать не стали). category различает статусы/ошибки/поля.
  class MappingReport
    Entry = Struct.new(:category, :key, :status, :detail, keyword_init: true)

    def initialize
      @entries = []
    end

    def add_resolved(category, key, detail)
      @entries << Entry.new(category: category, key: key, status: :resolved, detail: detail)
    end

    def add_unresolved(category, key, detail)
      @entries << Entry.new(category: category, key: key, status: :unresolved, detail: detail)
    end

    def entries
      @entries
    end

    def resolved
      @entries.select { |e| e.status == :resolved }
    end

    def unresolved
      @entries.select { |e| e.status == :unresolved }
    end
  end
end
