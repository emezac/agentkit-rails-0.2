# frozen_string_literal: true

require_relative "lib/agentkit/version"

Gem::Specification.new do |spec|
  spec.name          = "agentkit-rails"
  spec.version       = Agentkit::VERSION
  spec.authors       = ["AgentKit Team"]
  spec.email         = ["hello@agentkit.dev"]

  spec.summary       = "Agent kernel for Rails: flows, on-demand memory, HITL and a continuous-improvement factory"
  spec.description   = <<~DESC
    AgentKit Rails provides the agent-first backbone for domain applications:
    a flow engine with real fan-out/fan-in, semantic memory whose embedding
    policy is configurable per call, human-in-the-loop with a decision ledger,
    on-demand cognition (dreaming, summarizing, imagination), replay-first
    adaptive exploration, proposal-first chat, and a software factory that
    turns telemetry into safe, reversible improvements. The core is plain Ruby;
    the Rails engine adds persistence.
  DESC
  spec.homepage      = "https://github.com/agentkit/agentkit-rails"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri"    => spec.homepage,
    "changelog_uri"   => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir[
    "lib/**/*", "app/**/*", "db/migrate/**/*", "config/**/*",
    "agentkit-rails.gemspec", "README.md", "CHANGELOG.md", "UPGRADING.md", "LICENSE"
  ].reject { |path| path == "lib/agentkit/mcp.rb" || path.start_with?("lib/agentkit/mcp/") }
  spec.require_paths = ["lib"]

  # The core has no runtime dependencies on purpose: `require "agentkit"` works
  # in a plain Ruby process. Rails, pg, pgvector and a provider SDK are only
  # needed by the adapters that use them, and each one degrades to a no-op or a
  # clear ConfigurationError when absent.
  spec.add_development_dependency "rspec", "~> 3.13"
end
