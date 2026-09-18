# frozen_string_literal: true

namespace :agentkit do
  desc "Verify the tamper-evident audit chain (TENANT=__global__)"
  task audit_verify: :environment do
    report = Agentkit::Audit.verify!(tenant_key: ENV.fetch("TENANT", "__global__"))
    puts JSON.pretty_generate(report)
  end

  desc "Scan AgentKit operational invariants"
  task watchtower: :environment do
    findings = Agentkit::Watchtower.scan!
    puts JSON.pretty_generate(findings.map(&:to_h))
  end

  desc "Dispatch pending governed-action outbox entries (LIMIT=100)"
  task dispatch_actions: :environment do
    Agentkit::Actions.dispatch_pending!(limit: ENV.fetch("LIMIT", 100).to_i)
  end

  desc "Conformance check: what is instrumented, what is missing, what cannot improve yet"
  task doctor: :environment do
    ok    = ->(msg) { puts "\e[32m✓\e[0m #{msg}" }
    bad   = ->(msg) { puts "\e[31m✗\e[0m #{msg}" }
    warn_ = ->(msg) { puts "\e[33m!\e[0m #{msg}" }

    problems = Agentkit.config.validate
    problems.any? ? problems.each { |p| bad.call(p) } : ok.call("Configuration valid")

    events = Agentkit::Telemetry.events(since: 7 * 86_400 == 0 ? nil : Time.now - (7 * 86_400))
    events.any? ? ok.call("Telemetry active (#{events.size} events / 7d)")
                : bad.call("No telemetry in the last 7 days — the factory will have nothing to read")

    decisions = Agentkit::HITL.ledger.entries
    coded = decisions.count { |d| d.rejection_code }
    rejected = decisions.count { |d| d.decision == "rejected" }
    if decisions.any?
      ok.call("Ledger populated (#{decisions.size} decisions, #{rejected.zero? ? 0 : (coded * 100 / rejected)}% of rejections coded)")
    else
      warn_.call("Ledger empty — no human judgements captured yet")
    end

    # An agent with no registered prompt cannot take part in an N2 experiment.
    agents = ObjectSpace.each_object(Class).select { |k| k < Agentkit::Agent }
    without_prompt = agents.reject { |a| a.prompt_id && Agentkit::Prompt.defined?(a.prompt_id) }
    without_prompt.any? ? bad.call("#{without_prompt.size} agents without a registered prompt → cannot enter canary (#{without_prompt.map(&:name).join(', ')})")
                        : ok.call("All agents have registered prompts")

    silent = agents.reject { |a| decisions.any? { |d| d.agent_name == a.name } }
    silent.each { |a| warn_.call("#{a.name}: 0 decisions — do its suggestions reach a human?") }

    unpriced = Agentkit::ModelRouter.unpriced_models
    unpriced.any? ? warn_.call("Models with no price (cost tracking incomplete): #{unpriced.join(', ')}")
                  : ok.call("All routed models are priced")

    no_fit = Agentkit::Capability.all.reject { |c| c.to_h[:has_fit] }
    no_fit.each { |c| warn_.call("Capability #{c.name} has no `fit` → its proposals rank by default") }

    begin
      snapshots = Agentkit::TeamMemory::Graph.store.all
      invalid = snapshots.reject do |snapshot|
        snapshot.active? && snapshot.node_count == snapshot.nodes.size &&
          snapshot.edge_count == snapshot.edges.size && snapshot.digest.start_with?("sha256:")
      end
      if invalid.any?
        bad.call("#{invalid.size} graph snapshots have invalid status, counts or digest")
      elsif snapshots.any?
        ok.call("Graph snapshots valid (#{snapshots.size})")
      elsif Agentkit.config.team_memory.graph_enabled
        bad.call("Graph retrieval enabled but no validated/active snapshot exists")
      else
        warn_.call("Graph retrieval is opt-in and currently disabled")
      end

      if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected? &&
         ActiveRecord::Base.connection.table_exists?(:agentkit_graph_snapshots)
        required = {
          agentkit_graph_snapshots: %w[idx_agentkit_graph_snapshots_digest idx_agentkit_graph_snapshots_scope],
          agentkit_graph_nodes: %w[idx_agentkit_graph_nodes_identity],
          agentkit_graph_edges: %w[idx_agentkit_graph_edges_path]
        }
        missing = required.flat_map do |table, names|
          existing = ActiveRecord::Base.connection.indexes(table).map(&:name)
          names.reject { |name| existing.include?(name) }
        end
        missing.empty? ? ok.call("Graph schema and indexes present") : bad.call("Missing graph indexes: #{missing.join(', ')}")
      end
    rescue StandardError => e
      bad.call("Graph conformance unavailable (#{e.class})")
    end

    ok.call("Memory level: #{Agentkit.config.memory.level}, embedding policy: #{Agentkit.config.memory.embedding.policy}")
    ok.call("Factory mode: #{Agentkit.config.factory.mode}")
  end

  desc "Estimate the embedding bill of a policy before enabling it (POLICY=on_promotion)"
  task estimate_embeddings: :environment do
    policy = ENV["POLICY"]&.to_sym
    puts JSON.pretty_generate(Agentkit::Memory.estimate_embedding_cost(policy: policy))
  end

  desc "Run a cognition processor on demand (PROCESSOR=dreaming DRY_RUN=1)"
  task cognition: :environment do
    processor = ENV.fetch("PROCESSOR", "dreaming").to_sym
    trace = Agentkit::Cognition.run(processor, dry_run: ENV["DRY_RUN"].present?)
    puts JSON.pretty_generate(trace.respond_to?(:to_h) ? trace.to_h : trace)
  end

  desc "Diagnose and print the factory report (WINDOW=7)"
  task factory_report: :environment do
    Agentkit::Factory.capture_golden!
    Agentkit::Factory.diagnose!(window: ENV.fetch("WINDOW", 7).to_i * 86_400)
    puts Agentkit::Factory.report(window: ENV.fetch("WINDOW", 7).to_i * 86_400)
  end

  desc "Validate every registered flow graph"
  task validate_flows: :environment do
    Rails.application.eager_load!
    Agentkit::Flow::Registry.validate_all!
    puts "✓ #{Agentkit::Flow::Registry.all.size} flows valid"
  end

  desc "Evaluate keyword vs graph retrieval on a labeled dataset (DATASET=path.json)"
  task graph_eval: :environment do
    dataset = ENV["DATASET"]
    abort "DATASET is required; no benchmark numbers are fabricated" if dataset.to_s.empty?

    puts JSON.pretty_generate(Agentkit::TeamMemory::Evaluation.run(dataset))
  end

  desc "Drop vectors of archived/superseded memories"
  task gc_embeddings: :environment do
    puts "Released #{Agentkit::Memory.gc!} vectors"
  end
end
