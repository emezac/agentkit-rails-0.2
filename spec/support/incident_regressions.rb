# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require_relative "../../lib/agentkit"

module IncidentRegressions
  # Keep an explicit inventory so a missing tag or a removed spec cannot turn
  # into a green run. Each case is required in each fresh process.
  FIXTURES = {
    "harness.rejected_review" => "spec/lib/harness_engineering_spec.rb",
    "harness.stale_review" => "spec/lib/harness_engineering_spec.rb",
    "flow.stale_acceptance" => "spec/flow/flow_spec.rb",
    "flow.loop_limit" => "spec/flow/flow_spec.rb",
    "flow.iteration_replay" => "spec/flow/flow_spec.rb",
    "llm.repair_usage" => "spec/lib/llm_spec.rb",
    "llm.exhausted_budget_usage" => "spec/lib/llm_spec.rb"
  }.freeze
  SEEDS = [581, 739, 967].freeze
  FORMATTER = File.expand_path("incident_report_formatter.rb", __dir__)
  Task = Struct.new(:metadata)

  module_function

  def run
    attempts = SEEDS.map { |seed| run_examples(seed) }
    evaluator = Agentkit::Harness::ArchitectureEvaluation.new(minimum_success_rate: 1.0)
    task = Task.new({ "architecture" => { "critical" => true, "required_checks" => ["spec_passed"] } })
    cases = FIXTURES.map do |id, file|
      probes = attempts.map do |entry|
        result = entry.fetch(:cases).fetch(id)
        passed = result.fetch(:status) == "passed"
        {
          "evaluation" => { "success" => passed, "checks" => { "spec_passed" => passed } },
          "quality" => passed ? 1.0 : 0.0, "cost" => 0.0,
          "latency" => result.fetch(:latency_ms)
        }
      end
      summary = evaluator.summarize(probes, task: task)
      { id: id, file: file, passed: summary.fetch("success_rate") >= evaluator.minimum_success_rate,
        summary: summary }
    end
    {
      schema_version: 1, passed: attempts.all? { |attempt| attempt.fetch(:passed) } &&
        cases.all? { |entry| entry.fetch(:passed) },
      repetitions: SEEDS.size, cost_unit: "USD (no paid provider calls)", latency_unit: "ms",
      cases: cases, attempts: attempts
    }
  end

  def run_examples(seed)
    Dir.mktmpdir("agentkit-incidents") do |dir|
      report_path = File.join(dir, "results.json")
      _, _, process = Open3.capture3({ "SPEC_OPTS" => nil, "RSPEC_OPTS" => nil },
        RbConfig.ruby, "-S", "rspec", "--options", File::NULL, "--seed", seed.to_s,
        "--require", FORMATTER, "--format", "IncidentReportFormatter", "--out", report_path,
        "--tag", "incident", *FIXTURES.values.uniq)
      report = read_report(report_path)
      examples = report.fetch("examples", []).group_by { |example| example.fetch("id") }
      cases = FIXTURES.to_h do |id, file|
        rows = examples.fetch(id, [])
        row = rows.first
        result = if rows.size == 1 && File.expand_path(row.fetch("file")) == File.expand_path(file)
                   { status: row.fetch("status"), line: row.fetch("line"),
                     latency_ms: row.fetch("latency_ms"), cost_usd: 0.0 }
                 else
                   reason = rows.empty? ? "not_run" : "identity_mismatch"
                   { status: reason, latency_ms: 0.0, cost_usd: 0.0 }
                 end
        [id, result]
      end
      inventory_ok = examples.size == FIXTURES.size && FIXTURES.keys.all? { |id| examples.key?(id) }
      clean_run = process.success? && inventory_ok && report["errors"] == 0
      { seed: seed, exit_code: process.exitstatus, inventory_ok: inventory_ok,
        errors_outside_examples: report["errors"],
        passed: clean_run && cases.values.all? { |result| result.fetch(:status) == "passed" },
        cases: cases }
    end
  end

  def read_report(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end
end
