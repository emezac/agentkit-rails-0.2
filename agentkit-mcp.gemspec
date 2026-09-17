# frozen_string_literal: true

require_relative "lib/agentkit/version"

Gem::Specification.new do |spec|
  spec.name = "agentkit-mcp"
  spec.version = Agentkit::VERSION
  spec.authors = ["AgentKit Team"]
  spec.summary = "Optional MCP transport for AgentKit Rails governed capabilities"
  spec.homepage = "https://github.com/agentkit/agentkit-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/agentkit/mcp.rb", "lib/agentkit/mcp/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_dependency "agentkit-rails", "= #{Agentkit::VERSION}"
  spec.add_dependency "mcp", "~> 1.5"
end
