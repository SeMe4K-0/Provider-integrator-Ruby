# frozen_string_literal: true

require_relative "errors"

module ProviderIntegrator
  # Резолвер локальных ссылок $ref (вида "#/components/...") внутри уже загруженного
  # YAML-документа. Поддерживаются только внутренние ссылки на этот же файл — ссылка
  # на внешний файл считается неподдерживаемым элементом спецификации.
  class RefResolver
    attr_reader :notes

    def initialize(root)
      @root = root
      @notes = []
    end

    # Рекурсивно обходит узел и заменяет каждый { "$ref" => "#/..." } на данные,
    # на которые он указывает. active — список ссылок, которые сейчас разрешаются
    # (нужен, чтобы поймать циклическую ссылку и не уйти в бесконечную рекурсию).
    def resolve(node, active = [])
      case node
      when Hash
        node.key?("$ref") ? resolve_ref(node["$ref"], active) : resolve_hash(node, active)
      when Array
        node.map { |item| resolve(item, active) }
      else
        node
      end
    end

    private

    def resolve_hash(node, active)
      node.each_with_object({}) { |(key, value), acc| acc[key] = resolve(value, active) }
    end

    def resolve_ref(ref, active)
      unless ref.start_with?("#/")
        raise SpecLoadError, "Внешние ссылки $ref не поддерживаются: \"#{ref}\""
      end
      return recursive_stub(ref) if active.include?(ref)

      resolve(pointer(ref), active + [ref])
    end

    # Схема, ссылающаяся на саму себя, — законная и нередкая конструкция OpenAPI.
    # Отказываться из-за неё от всей спецификации нельзя: ветка обрывается пустой
    # схемой, а факт обрыва попадает в замечания разбора. Глубже этого уровня
    # генератору всё равно нечего извлечь.
    def recursive_stub(ref)
      @notes << "схема \"#{ref}\" ссылается на саму себя — рекурсивная ветка оборвана, " \
                "вложенные уровни в модель не попали"
      {}
    end

    # Находит узел документа по JSON-указателю вида "#/components/schemas/Recipient"
    def pointer(ref)
      segments = ref.delete_prefix("#/").split("/").map { |segment| unescape(segment) }

      segments.reduce(@root) do |node, segment|
        unless node.is_a?(Hash) && node.key?(segment)
          raise SpecLoadError, "Не удалось разрешить ссылку \"#{ref}\": раздел \"#{segment}\" отсутствует"
        end

        node[segment]
      end
    end

    def unescape(segment)
      segment.gsub("~1", "/").gsub("~0", "~")
    end
  end
end
