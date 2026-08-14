# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "agentkit-rails entrypoint" do
  it "loads the engine even when the plain-Ruby kernel was cached before Rails" do
    script = <<~'RUBY'
      require "agentkit"
      abort "engine loaded without Rails" if defined?(Agentkit::Engine)

      require "rails"
      require "agentkit-rails"

      puts "engine=#{Agentkit::Engine < Rails::Engine}"
    RUBY

    stdout, stderr, status = Open3.capture3(
      "bundle", "exec", "ruby", "-I#{File.expand_path('../../lib', __dir__)}", "-e", script,
      chdir: File.expand_path("../..", __dir__)
    )

    expect(status).to be_success, stderr
    expect(stdout).to include("engine=true")
  end
end
