# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "rails/generators"
require "generators/agentkit/install/install_generator"

RSpec.describe Agentkit::Generators::InstallGenerator do
  let(:root) { Dir.mktmpdir("agentkit-install-generator") }
  let(:application_path) { File.join(root, "config/application.rb") }

  before do
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config/boot.rb"), "# generated host boot\n")
    File.write(application_path, <<~RUBY)
      require_relative "boot"
      require "rails"
      require "rails/application"
      require "rake"

      module GeneratedHost
        class Application < Rails::Application
          config.root = #{root.inspect}
          config.eager_load = false
          config.secret_key_base = "generated-host-test"

          # This is the broken installation from BUG.md: the engine is first
          # required while Rails is already executing application initializers.
          initializer("host.loads_agentkit_late") { require "agentkit" }
        end
      end

      GeneratedHost::Application.initialize!
      GeneratedHost::Application.load_tasks

      engine_models = File.expand_path("app/models", #{File.expand_path('../..', __dir__).inspect})
      puts "migration_task=\#{Rake::Task.task_defined?("agentkit:install:migrations")}"
      puts "models_path=\#{ActiveSupport::Dependencies.autoload_paths.map(&:to_s).include?(engine_models)}"
    RUBY
  end

  after { FileUtils.remove_entry(root) }

  it "moves engine loading from a late initializer into application boot" do
    expect(run_host).to include("migration_task=false", "models_path=false")

    generator.install_engine_boot

    source = File.read(application_path)
    expect(source.index('require "rails/application"')).to be < source.index('require "agentkit"')
    expect(source.index('require "agentkit/engine"')).to be < source.index("module GeneratedHost")
    expect(run_host).to include("migration_task=true", "models_path=true")
  end

  it "is idempotent" do
    2.times { generator.install_engine_boot }

    source = File.read(application_path)
    expect(source.scan(/^require "agentkit"$/).size).to eq(1)
    expect(source.scan(/^require "agentkit\/engine"$/).size).to eq(1)
  end

  private

  def generator
    @generator ||= described_class.new([], {}, destination_root: root)
  end

  def run_host
    stdout, stderr, status = Open3.capture3(
      "bundle", "exec", "ruby",
      "-I#{File.expand_path('../../lib', __dir__)}", application_path,
      chdir: File.expand_path("../..", __dir__)
    )
    raise "host failed: #{stderr}" unless status.success?

    stdout
  end
end
