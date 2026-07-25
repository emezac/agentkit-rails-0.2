# frozen_string_literal: true

require "active_record/railtie"
# Registers the `vector` column type with the Postgres adapter. Without it the
# migration cannot declare the embedding column and AR reads it back as a String.
require "pgvector"
require "action_controller/railtie"
require "active_job/railtie"

require "agentkit"
# `require "agentkit"` only pulls in the engine when Rails is already defined.
# If anything loaded the gem first — the unit spec_helper, an initializer, a
# script — that hook was skipped and the engine would never register. Requiring
# it explicitly is idempotent and removes the load-order dependency.
require "agentkit/engine"

module Dummy
  # Minimal host application for the gem's integration specs.
  #
  # It exists because five real defects shipped past a green unit suite and were
  # only caught by piloting the gem on an actual Rails app: the rake task path,
  # a NOT NULL violation on run steps, the ActiveRecord flow store not
  # registering steps on the Run, a process-local HITL store, and a Zeitwerk
  # trap in the capability template. All of those need a booted engine and a
  # real database to surface.
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.load_defaults 7.1 if config.respond_to?(:load_defaults)

    config.secret_key_base = "dummy-secret-key-base-for-integration-specs"
    config.logger = Logger.new(File.expand_path("../log/test.log", __dir__))
    config.log_level = :warn
    config.active_support.to_time_preserves_timezone = :zone

    config.autoload_paths << File.expand_path("../app/capabilities", __dir__)
    config.autoload_paths << File.expand_path("../app/flows", __dir__)
    config.autoload_paths << File.expand_path("../app/agents", __dir__)

    config.active_record.maintain_test_schema = false
    config.action_controller.allow_forgery_protection = false
    # perform_later runs immediately, so the async path is exercised end to end
    # instead of enqueueing into a queue nothing drains.
    config.active_job.queue_adapter = :inline
  end
end
