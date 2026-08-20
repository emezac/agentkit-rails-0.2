# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Run the reproducible AgentKit verification suite"
task verify: :spec do
  ruby_files = Dir["{app,lib,spec,db}/**/*.rb"]
  failures = ruby_files.reject { |file| system(RbConfig.ruby, "-c", file, out: File::NULL) }
  abort "Syntax failures: #{failures.join(', ')}" if failures.any?
end

task default: :spec
