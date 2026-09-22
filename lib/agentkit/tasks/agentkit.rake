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

  desc "Conformance check (set TENANT and optional ACCOUNT_ID in multi-tenant hosts)"
  task doctor: :environment do
    ok    = ->(msg) { puts "\e[32m✓\e[0m #{msg}" }
    bad   = ->(msg) { puts "\e[31m✗\e[0m #{msg}" }
    warn_ = ->(msg) { puts "\e[33m!\e[0m #{msg}" }

    problems = Agentkit.config.validate
    problems.any? ? problems.each { |p| bad.call(p) } : ok.call("Configuration valid")

    tenant_key = ENV["TENANT"]
    scoped_data = !Agentkit.config.multi_tenant || tenant_key.to_s != ""
    doctor_scope = if scoped_data
                     Agentkit::Scope.resolve(
                       { tenant_key: tenant_key, account_id: ENV["ACCOUNT_ID"] }.compact
                     )
                   end
    unless scoped_data
      warn_.call("Set TENANT (and optional ACCOUNT_ID) to inspect tenant data; running schema-only checks")
    end

    if scoped_data
      events = Agentkit::Telemetry.events(since: Time.now - (7 * 86_400))
      events.any? ? ok.call("Telemetry active (#{events.size} events / 7d)")
                  : bad.call("No telemetry in the last 7 days — the factory will have nothing to read")
    end

    decisions = scoped_data ? Agentkit::HITL.ledger.entries(scope: doctor_scope) : []
    coded = decisions.count { |d| d.rejection_code }
    rejected = decisions.count { |d| d.decision == "rejected" }
    if decisions.any?
      ok.call("Ledger populated (#{decisions.size} decisions, #{rejected.zero? ? 0 : (coded * 100 / rejected)}% of rejections coded)")
    elsif scoped_data
      warn_.call("Ledger empty — no human judgements captured yet")
    end

    # An agent with no registered prompt cannot take part in an N2 experiment.
    agents = ObjectSpace.each_object(Class).select { |k| k < Agentkit::Agent }
    without_prompt = agents.reject { |a| a.prompt_id && Agentkit::Prompt.defined?(a.prompt_id) }
    without_prompt.any? ? bad.call("#{without_prompt.size} agents without a registered prompt → cannot enter canary (#{without_prompt.map(&:name).join(', ')})")
                        : ok.call("All agents have registered prompts")

    if scoped_data
      silent = agents.reject { |a| decisions.any? { |d| d.agent_name == a.name } }
      silent.each { |a| warn_.call("#{a.name}: 0 decisions — do its suggestions reach a human?") }
    end

    unpriced = Agentkit::ModelRouter.unpriced_models
    unpriced.any? ? warn_.call("Models with no price (cost tracking incomplete): #{unpriced.join(', ')}")
                  : ok.call("All routed models are priced")

    no_fit = Agentkit::Capability.all.reject { |c| c.to_h[:has_fit] }
    no_fit.each { |c| warn_.call("Capability #{c.name} has no `fit` → its proposals rank by default") }

    begin
      snapshots = scoped_data ? Agentkit::TeamMemory::Graph.store.all(tenant_key: doctor_scope.tenant_key) : []
      invalid = snapshots.reject do |snapshot|
        snapshot.active? && snapshot.node_count == snapshot.nodes.size &&
          snapshot.edge_count == snapshot.edges.size && snapshot.digest.start_with?("sha256:")
      end
      if invalid.any?
        bad.call("#{invalid.size} graph snapshots have invalid status, counts or digest")
      elsif snapshots.any?
        ok.call("Graph snapshots valid (#{snapshots.size})")
      elsif Agentkit.config.team_memory.graph_enabled && scoped_data
        bad.call("Graph retrieval enabled but no validated/active snapshot exists")
      elsif scoped_data
        warn_.call("Graph retrieval is opt-in and currently disabled")
      end

      if defined?(ActiveRecord::Base) &&
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

    begin
      worlds = scoped_data ? Agentkit::Exploration.store.all(scope: doctor_scope) : []
      all_worlds = if scoped_data
                     Agentkit::Exploration.store.all(scope: doctor_scope,
                                                     include_incomplete: true)
                   else
                     []
                   end
      if Agentkit.config.exploration.enabled && scoped_data
        worlds.any? ? ok.call("Adaptive exploration replay pool valid (#{worlds.size} worlds)")
                    : warn_.call("Adaptive exploration enabled but the replay pool is empty")
      elsif scoped_data
        warn_.call("Adaptive exploration is opt-in and currently disabled")
      end
      if defined?(ActiveRecord::Base) &&
         ActiveRecord::Base.connection.table_exists?(:agentkit_exploration_worlds)
        connection = ActiveRecord::Base.connection
        world_indexes = connection.indexes(:agentkit_exploration_worlds).map(&:name)
        required_world_indexes = %w[index_agentkit_exploration_worlds_on_world_id
                                    idx_agentkit_exploration_worlds_scope
                                    idx_agentkit_exploration_worlds_policy
                                    idx_agentkit_exploration_worlds_lease
                                    idx_agentkit_exploration_worlds_operations]
        missing = required_world_indexes - world_indexes
        if connection.table_exists?(:agentkit_exploration_attempts)
          attempt_indexes = connection.indexes(:agentkit_exploration_attempts).map(&:name)
          required_attempt_indexes = %w[idx_agentkit_exploration_attempts_slot
                                        idx_agentkit_exploration_attempts_idempotency
                                        idx_agentkit_exploration_attempts_status]
          missing.concat(required_attempt_indexes - attempt_indexes)
        else
          missing << "agentkit_exploration_attempts table"
        end
        quota_schema = {
          agentkit_exploration_quota_usages: "idx_agentkit_exploration_quota_usage",
          agentkit_exploration_quota_reservations: "idx_agentkit_exploration_quota_reservation",
          agentkit_exploration_reviews: "idx_agentkit_exploration_review_evidence",
          agentkit_exploration_policy_bindings: "idx_agentkit_exploration_policy_binding"
        }
        quota_schema.each do |table, index_name|
          if connection.table_exists?(table)
            missing << index_name unless connection.indexes(table).map(&:name).include?(index_name)
          else
            missing << "#{table} table"
          end
        end
        missing.empty? ? ok.call("Adaptive exploration schema, leases, quotas and promotion governance present")
                       : bad.call("Missing exploration schema: #{missing.join(', ')}")
      end

      running = all_worlds.count { |world| world.status == "running" }
      queued = all_worlds.count { |world| world.status == "queued" }
      unknown = all_worlds.sum do |world|
        Agentkit::Exploration.store.attempts(world.id, scope: doctor_scope)
                             .count(&:ambiguous?)
      end
      warn_.call("Adaptive exploration needs attention (#{queued} queued, #{running} running worlds, #{unknown} unknown attempts)") if
        queued.positive? || running.positive? || unknown.positive?
      if Agentkit.config.exploration.enabled && scoped_data
        quotas = Agentkit::Exploration::Quota.snapshots(scope: doctor_scope)
        summary = quotas.values.map do |quota|
          "#{quota.resource}=#{quota.used}/#{quota.limit || 'unlimited'}"
        end.join(", ")
        ok.call("Adaptive exploration daily quotas (#{summary})")
      end
      if scoped_data
        pending_reviews = Agentkit::Exploration.reviews(scope: doctor_scope, status: :pending).size
        bindings = Agentkit::Exploration.policy_bindings(scope: doctor_scope).size
        pending_reviews.positive? ? warn_.call("Adaptive exploration has #{pending_reviews} pending promotion reviews")
                                  : ok.call("Adaptive exploration promotion review queue clear")
        ok.call("Adaptive exploration active policy bindings: #{bindings}")
      end
      if Agentkit.config.exploration.enabled && scoped_data && worlds.any?
        minimum_training = [Agentkit.config.exploration.min_replay_worlds.to_i,
                            Agentkit.config.exploration.min_training_worlds.to_i].max
        minimum_holdout = Agentkit.config.exploration.min_holdout_worlds.to_i
        ready = worlds.group_by(&:evaluator_digest).count do |_, evaluator_worlds|
          split = Agentkit::Exploration.split_holdout(worlds: evaluator_worlds)
          split.training_worlds.size >= minimum_training &&
            split.holdout_worlds.size >= minimum_holdout
        end
        ready.positive? ? ok.call("Adaptive exploration statistical holdout ready (#{ready} evaluator pools)")
                        : warn_.call("Adaptive exploration has no evaluator pool with enough training/holdout worlds")
      end
    rescue StandardError => e
      bad.call("Adaptive exploration conformance unavailable (#{e.class})")
    end

    ok.call("Memory level: #{Agentkit.config.memory.level}, embedding policy: #{Agentkit.config.memory.embedding.policy}")
    ok.call("Factory mode: #{Agentkit.config.factory.mode}")
  end

  desc "Inspect readiness and prune expired exploration quota ledgers (DRY_RUN=1 by default)"
  task exploration_maintenance: :environment do
    if Agentkit.config.multi_tenant && ENV["TENANT"].to_s.empty?
      abort "TENANT is required for exploration maintenance in multi-tenant mode"
    end
    scope = Agentkit::Scope.resolve(
      { tenant_key: ENV["TENANT"], account_id: ENV["ACCOUNT_ID"] }.compact
    )
    dry_run = ENV.fetch("DRY_RUN", "1") != "0"
    puts JSON.pretty_generate(Agentkit::Exploration.maintain!(scope: scope, dry_run: dry_run).to_h)
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
