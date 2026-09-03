# frozen_string_literal: true

require_relative "../lib/provider_integrator/spec_loader"
require_relative "../lib/provider_integrator/semantic_analyzer"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
end
