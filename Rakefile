# frozen_string_literal: true

require "rspec/core/rake_task"
require "digest"
require "fileutils"
require "json"
require "rubygems/installer"
require "tmpdir"

RSpec::Core::RakeTask.new(:spec)

# Make engine diagnostics/evaluation runnable from this repository as well as
# from a host application's `rails` command.
task :environment do
  ENV["RAILS_ENV"] ||= "test"
  require_relative "spec/dummy/config/environment"
end
load File.expand_path("lib/agentkit/tasks/agentkit.rake", __dir__)

desc "Run the reproducible AgentKit verification suite"
task verify: :spec do
  ruby_files = Dir["{app,lib,spec,db}/**/*.rb"]
  failures = ruby_files.reject { |file| system(RbConfig.ruby, "-c", file, out: File::NULL) }
  abort "Syntax failures: #{failures.join(', ')}" if failures.any?
end

namespace :release do
  desc "Build the gem, SHA-256 checksum and SPDX SBOM, then verify local installation"
  task :artifacts do
    FileUtils.mkdir_p("pkg")
    %w[agentkit-rails agentkit-mcp].each do |name|
      gemspec = "#{name}.gemspec"
      spec = Gem::Specification.load(gemspec)
      abort "Cannot load #{gemspec}" unless spec

      artifact = File.expand_path("pkg/#{spec.full_name}.gem")
      sh "gem", "build", gemspec, "--output", artifact
      checksum = Digest::SHA256.file(artifact).hexdigest
      File.write("#{artifact}.sha256", "#{checksum}  #{File.basename(artifact)}\n")
      sbom = {
        spdxVersion: "SPDX-2.3", dataLicense: "CC0-1.0", SPDXID: "SPDXRef-DOCUMENT",
        name: spec.full_name,
        documentNamespace: "https://github.com/agentkit/agentkit-rails/sbom/#{spec.name}/#{spec.version}/#{checksum}",
        creationInfo: { created: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
                        creators: ["Tool: agentkit-rails release:artifacts"] },
        packages: [{ SPDXID: "SPDXRef-Package-#{spec.name}", name: spec.name,
                     versionInfo: spec.version.to_s, downloadLocation: "NOASSERTION",
                     filesAnalyzed: false, licenseConcluded: spec.license || "NOASSERTION",
                     checksums: [{ algorithm: "SHA256", checksumValue: checksum }],
                     externalRefs: [{ referenceCategory: "PACKAGE-MANAGER",
                                      referenceType: "purl",
                                      referenceLocator: "pkg:gem/#{spec.name}@#{spec.version}" }] }]
      }
      File.write(File.expand_path("pkg/#{spec.full_name}.spdx.json"), JSON.pretty_generate(sbom) + "\n")

      Dir.mktmpdir("#{name}-release-install") do |install_dir|
        installed = Gem::Installer.at(artifact, install_dir: install_dir,
                                                ignore_dependencies: true,
                                                wrappers: false).install
        abort "Installed artifact version mismatch" unless installed.version == spec.version
      end
      puts "Built and verified #{artifact}"
      puts "SHA256 #{checksum}"
    end
  end

  desc "Run the suite before producing verified release artifacts"
  task :verify do
    Rake::Task["verify"].invoke
    Rake::Task["release:artifacts"].invoke
  end
end

task default: :spec
