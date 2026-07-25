# frozen_string_literal: true

module Agentkit
  module HITL
    # The decision ledger: every proposal an agent makes and every human answer,
    # stored as a comparable pair.
    #
    # v0.1 had this data and threw it away. `AgentSuggestion` recorded
    # accepted/rejected plus a free-text `rejection_reason` in a JSON blob, and
    # the improvement loop read neither — it only counted *pending* ones. Six
    # projects accumulated months of human judgements about AI output, the
    # single most valuable asset an AI-first company builds, and discarded it.
    #
    # Two design rules learned from that failure:
    #   1. `mode` distinguishes human decisions from timeouts. v0.1 marked
    #      advisory timeouts as `auto_applied`, indistinguishable from approval,
    #      so any acceptance metric built on it was optimistically wrong.
    #   2. Rejection reasons are a closed taxonomy. Prose cannot be aggregated,
    #      and each code maps to a different fix.
    class Ledger
      Entry = Struct.new(
        :id, :suggestion_id, :agent_name, :suggestion_type, :prompt_id, :prompt_version,
        :model, :decision, :actor, :mode, :rejection_code, :rejection_note,
        :proposed_payload, :final_payload, :edit_distance, :time_to_decision_s,
        :outcome, :outcome_value, :outcome_at, :tenant_key, :created_at,
        keyword_init: true
      )

      DECISIONS = %w[accepted rejected edited ignored expired].freeze
      MODES     = %w[human auto policy].freeze

      def initialize
        @entries = []
        @seq     = 0
      end

      def record(suggestion, decision:, actor:, mode: "human", rejection_code: nil,
                 rejection_note: nil, final_payload: nil)
        entry = Entry.new(
          id: (@seq += 1),
          suggestion_id: suggestion.id, agent_name: suggestion.source_agent,
          suggestion_type: suggestion.suggestion_type,
          prompt_id: suggestion.prompt_id, prompt_version: suggestion.prompt_version,
          model: suggestion.model, decision: decision.to_s, actor: actor.to_s, mode: mode.to_s,
          rejection_code: rejection_code&.to_s, rejection_note: rejection_note,
          proposed_payload: suggestion.payload, final_payload: final_payload,
          edit_distance: distance(suggestion.payload, final_payload),
          time_to_decision_s: (Time.now - suggestion.created_at).round,
          tenant_key: suggestion.tenant_key, created_at: Time.now
        )
        @entries << entry

        Telemetry.emit(
          "hitl.decide",
          dims: { agent: entry.agent_name, type: entry.suggestion_type, decision: entry.decision,
                  mode: entry.mode, rejection_code: entry.rejection_code,
                  prompt_id: entry.prompt_id, prompt_version: entry.prompt_version },
          measures: { time_to_decision_s: entry.time_to_decision_s,
                      edit_distance: entry.edit_distance || 0.0 }
        )
        entry
      end

      def record_outcome(suggestion_id, name:, value: nil)
        entry = @entries.find { |e| e.suggestion_id == suggestion_id }
        return nil unless entry

        entry.outcome       = name.to_s
        entry.outcome_value = value
        entry.outcome_at    = Time.now
        entry
      end

      def entries(agent: nil, type: nil, since: nil, mode: nil)
        @entries.select do |e|
          (agent.nil? || e.agent_name == agent.to_s) &&
            (type.nil?  || e.suggestion_type == type.to_s) &&
            (since.nil? || e.created_at >= since) &&
            (mode.nil?  || e.mode == mode.to_s)
        end
      end

      # ─── Quality metrics ─────────────────────────────────────────────────────

      # Acceptance excluding `mode: auto` — a timeout is not a validation.
      def acceptance_rate(agent: nil, type: nil, since: nil, prompt_version: nil)
        judged = human_entries(agent: agent, type: type, since: since, prompt_version: prompt_version)
        return nil if judged.empty?

        accepted = judged.count { |e| %w[accepted edited].include?(e.decision) }
        (accepted.to_f / judged.size).round(4)
      end

      # Accepted with no edits at all — the honest quality number.
      def clean_acceptance_rate(agent: nil, type: nil, since: nil, prompt_version: nil)
        judged = human_entries(agent: agent, type: type, since: since, prompt_version: prompt_version)
        return nil if judged.empty?

        clean = judged.count { |e| e.decision == "accepted" && e.edit_distance.to_f.zero? }
        (clean.to_f / judged.size).round(4)
      end

      def edit_magnitude(agent: nil, since: nil)
        values = entries(agent: agent, since: since).filter_map { |e| e.edit_distance if e.decision == "edited" }
        Telemetry::Stats.from(values)
      end

      # Where an agent fails, not just how often.
      def rejection_profile(agent: nil, since: nil)
        rejected = entries(agent: agent, since: since).select { |e| e.decision == "rejected" }
        return {} if rejected.empty?

        rejected.group_by(&:rejection_code)
                .transform_values { |list| (list.size.to_f / rejected.size).round(4) }
      end

      def ignore_rate(agent: nil, since: nil)
        all = entries(agent: agent, since: since)
        return nil if all.empty?

        (all.count { |e| %w[ignored expired].include?(e.decision) }.to_f / all.size).round(4)
      end

      def time_to_decision(agent: nil, since: nil)
        Telemetry::Stats.from(human_entries(agent: agent, since: since).map(&:time_to_decision_s))
      end

      # The number a founder actually cares about: what one useful proposal costs.
      def cost_per_accepted(agent: nil, since: nil)
        accepted = human_entries(agent: agent, since: since).count { |e| %w[accepted edited].include?(e.decision) }
        return nil if accepted.zero?

        spend = Telemetry.events(name: "llm.call", since: since)
                         .select { |e| agent.nil? || e.dims[:agent] == agent.to_s }
                         .sum { |e| e.measures[:cost_usd].to_f }
        (spend / accepted).round(6)
      end

      def outcome_lift(agent: nil, since: nil)
        list = entries(agent: agent, since: since).select { |e| e.outcome_value }
        return nil if list.empty?

        accepted = list.select { |e| %w[accepted edited].include?(e.decision) }.map { |e| e.outcome_value.to_f }
        rejected = list.select { |e| e.decision == "rejected" }.map { |e| e.outcome_value.to_f }
        return nil if accepted.empty?

        base = rejected.empty? ? 0.0 : rejected.sum / rejected.size
        { accepted_mean: (accepted.sum / accepted.size).round(4), baseline_mean: base.round(4) }
      end

      def summary(agent: nil, since: nil)
        {
          n: entries(agent: agent, since: since).size,
          acceptance_rate: acceptance_rate(agent: agent, since: since),
          clean_acceptance_rate: clean_acceptance_rate(agent: agent, since: since),
          ignore_rate: ignore_rate(agent: agent, since: since),
          rejection_profile: rejection_profile(agent: agent, since: since),
          time_to_decision: time_to_decision(agent: agent, since: since).to_h,
          cost_per_accepted: cost_per_accepted(agent: agent, since: since)
        }
      end

      def clear = @entries = []
      def size  = @entries.size

      private

      def human_entries(agent: nil, type: nil, since: nil, prompt_version: nil)
        entries(agent: agent, type: type, since: since)
          .select { |e| e.mode == "human" }
          .select { |e| prompt_version.nil? || e.prompt_version == prompt_version }
      end

      # Normalised payload distance in 0..1. 0.0 means the human changed nothing.
      def distance(proposed, final)
        return nil if final.nil?
        return 0.0 if proposed == final

        a = normalize(proposed)
        b = normalize(final)
        keys = (a.keys | b.keys)
        return 0.0 if keys.empty?

        changed = keys.count { |k| a[k].to_s.strip != b[k].to_s.strip }
        (changed.to_f / keys.size).round(4)
      end

      def normalize(payload)
        return {} if payload.nil?
        return payload.transform_keys(&:to_s) if payload.is_a?(Hash)

        { "value" => payload.to_s }
      end
    end
  end
end
