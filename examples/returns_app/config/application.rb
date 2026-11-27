# frozen_string_literal: true
require "bundler/setup"
require "active_record/railtie"
require "active_job/railtie"
require "agentkit"
require "agentkit/engine"

module ReturnsReference
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "local-reference-only-not-for-production")
    config.active_job.queue_adapter = :async
  end
end
