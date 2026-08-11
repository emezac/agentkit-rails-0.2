# frozen_string_literal: true

# Conventional Bundler entrypoint for `gem "agentkit-rails"`.
#
# The plain-Ruby kernel remains available through `require "agentkit"`. Rails
# hosts load this file automatically from the gem name, after Rails itself has
# been required by config/application.rb, so the engine joins the railtie set
# before initializers, routes, autoload paths and rake tasks are collected.
require_relative "agentkit"
require_relative "agentkit/engine" if defined?(::Rails)
