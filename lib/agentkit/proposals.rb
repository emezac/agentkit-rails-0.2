# frozen_string_literal: true

module Agentkit
  # Proposal-first interaction: the assistant opens with what it suggests doing,
  # instead of waiting for an imperative order.
  #
  # Not a prompt trick — it needs Setup (what the business wants), Capability
  # (what the app can do), memory and signals. And it is the main producer of
  # the signal the factory consumes: every generated, surfaced, accepted,
  # modified or dismissed proposal is a labelled data point.
  class Proposal
    attr_reader :id, :capability, :subject, :headline, :why, :inputs, :score,
                :cost_usd, :risk, :setup_version, :created_at
    attr_accessor :status, :suggestion_id

    def initialize(capability:, subject: nil, headline:, why:, inputs: {}, score: 0.0,
                   cost_usd: 0.0, risk: :reversible, setup_version: nil)
      @id            = SecureRandom.uuid
      @capability    = capability
      @subject       = subject
      @headline      = headline
      @why           = Array(why)
      @inputs        = inputs
      @score         = score
      @cost_usd      = cost_usd
      @risk          = risk
      @setup_version = setup_version
      @status        = "generated"
      @created_at    = Time.now
    end

    def subject_key
      return nil if subject.nil?
      return "#{subject.class.name}##{subject.id}" if subject.respond_to?(:id)

      subject.to_s
    end

    def dedupe_key = "#{capability.name}:#{subject_key}"

    def to_h
      { id: id, capability: capability.name, headline: headline, why: why,
        subject: subject_key, inputs: inputs, score: score.round(3),
        cost_usd: cost_usd.round(4), risk: risk, status: status,
        actions: %i[accept modify dismiss] }
    end
  end

  module Proposals
    class << self
      # Ranked proposals for a surface. Returns at most `max`, each with a
      # traceable `why` — no `why`, no proposal.
      def generate(setup: nil, scope: {}, surface: :chat, context: nil, max: nil, min_score: nil,
                   candidates: nil)
        ctx    = context || Context.resolve
        setup  ||= Setup.current || Setup.build
        cfg    = ctx.config.chat
        max    ||= cfg.max_proposals
        min_score ||= cfg.min_score

        proposals = Capability.eligible(setup, ctx).flat_map do |capability|
          build_for(capability, setup, scope, candidates, ctx)
        end.compact

        ranked = proposals
                 .reject { |p| suppressed?(p, ctx) }
                 .reject { |p| cfg.require_why && p.why.empty? }
                 .select { |p| p.score >= min_score }
                 .sort_by { |p| -p.score }
                 .first(max)

        ranked.each do |p|
          store[p.id] = p
          Telemetry.emit("proposal.generated",
                         dims: { capability: p.capability.name, surface: surface, risk: p.risk },
                         measures: { score: p.score, cost_usd: p.cost_usd })
        end
        ranked
      end

      def surfaced!(proposals, surface: :chat)
        Array(proposals).each do |p|
          p.status = "surfaced"
          Telemetry.emit("proposal.surfaced",
                         dims: { capability: p.capability.name, surface: surface })
        end
        proposals
      end

      # Accepting executes the capability's flow through HITL — the chat never
      # performs an action itself.
      def accept!(proposal_id, inputs: nil, actor: "human", context: nil)
        proposal = fetch!(proposal_id)
        ctx      = context || Context.resolve
        modified = !inputs.nil? && inputs != proposal.inputs

        proposal.status = modified ? "modified" : "accepted"
        Telemetry.emit("proposal.#{proposal.status}",
                       dims: { capability: proposal.capability.name, actor: actor },
                       measures: { score: proposal.score })

        suggestion = HITL.suggest!(
          type: "proposal:#{proposal.capability.name}",
          title: proposal.headline,
          description: proposal.why.join(" · "),
          priority: proposal.risk == :irreversible ? "high" : "medium",
          source_agent: "Agentkit::Proposals",
          # The suggestion carries what the agent PROPOSED; the human's version
          # arrives as final_payload, so the ledger can measure the edit.
          payload: proposal.inputs.merge("proposal_id" => proposal.id),
          idempotency_key: proposal.dedupe_key,
          context: ctx
        )
        proposal.suggestion_id = suggestion.id
        final = modified ? inputs.merge("proposal_id" => proposal.id) : nil
        HITL.approve(suggestion.id, actor: actor, final_payload: final)

        proposal.capability.execute(inputs || proposal.inputs, context: ctx)
      end

      def dismiss!(proposal_id, code:, note: nil, actor: "human", context: nil)
        proposal = fetch!(proposal_id)
        proposal.status = "dismissed"

        suggestion = HITL.suggest!(
          type: "proposal:#{proposal.capability.name}", title: proposal.headline,
          source_agent: "Agentkit::Proposals", payload: proposal.inputs,
          context: context || Context.resolve
        )
        HITL.reject(suggestion.id, actor: actor, code: code, note: note)
        record_rejection(proposal, code)

        Telemetry.emit("proposal.dismissed",
                       dims: { capability: proposal.capability.name, rejection_code: code })
        proposal
      end

      def store       = @store ||= {}
      def fetch!(id)  = store[id] || raise(CapabilityError, "Unknown proposal #{id}")
      def rejections  = @rejections ||= Hash.new(0)

      def reset!
        @store      = {}
        @rejections = Hash.new(0)
        @gaps       = []
        self
      end

      # Intentions with no capability behind them. Arguably the most valuable
      # finding the system can produce: "users ask for this 14 times a week and
      # we cannot do it".
      def gaps = @gaps ||= []

      def record_gap(text, context: nil)
        gaps << { text: text, at: Time.now, tenant: (context || Context.resolve).tenant_key }
        Telemetry.emit("proposal.capability_gap", dims: { tenant: (context || Context.resolve).tenant_key })
        gaps.last
      end

      private

      def build_for(capability, setup, scope, candidates, ctx)
        subjects = candidates ? Array(candidates) : [nil]
        subjects.filter_map do |subject|
          fit, reasons = fit_for(capability, setup, subject)
          next if fit <= 0

          signals = signal_reasons(capability, subject, ctx)
          why     = (reasons + signals).uniq
          cost    = capability.cost_for(default_inputs(capability, subject))

          Proposal.new(
            capability: capability, subject: subject,
            headline: headline_for(capability, subject),
            why: why, inputs: default_inputs(capability, subject),
            score: expected_value(fit: fit, signals: signals.size, cost: cost),
            cost_usd: cost, risk: capability.risk, setup_version: setup.version
          )
        end
      end

      def fit_for(capability, setup, subject)
        return [capability.fit_for(setup, subject), []] if capability.instance_variable_get(:@fit_fn)

        setup.icp_match(subject)
      end

      # Evidence from memory: recent observations mentioning this subject.
      def signal_reasons(_capability, subject, ctx)
        return [] if subject.nil?

        label = subject.respond_to?(:name) ? subject.name.to_s : subject.to_s
        Memory.recall(label, k: 2, mode: :keyword, context: ctx)
              .map { |m| m.content.to_s[0, 90] }
      rescue StandardError
        []
      end

      # expected_value = fit × confidence × impact × freshness / cost.
      # Every term is measured, so the factory can tune the weights from the
      # acceptance data instead of a developer guessing.
      def expected_value(fit:, signals:, cost:)
        # Absence of a live signal lowers confidence once — not twice. A perfect
        # ICP match with no recent event should still clear the bar; a mediocre
        # match should not.
        confidence = signals.positive? ? 0.95 : 0.75
        impact     = 1.0
        freshness  = 1.0
        raw = fit * confidence * impact * freshness
        cost.positive? ? (raw / (1 + cost)).round(4) : raw.round(4)
      end

      def headline_for(capability, subject)
        label = subject.respond_to?(:name) ? subject.name : subject
        label ? "#{capability.title} — #{label}" : capability.title
      end

      def default_inputs(capability, subject)
        return {} if subject.nil?

        key = capability.inputs.keys.first
        key ? { key => (subject.respond_to?(:id) ? subject.id : subject) } : {}
      end

      # Learned suppression: two rejections with the same code for the same
      # capability push it down. This is an N1 intervention — a reversible
      # parameter, so the factory may apply it automatically.
      def suppressed?(proposal, ctx)
        cfg = ctx.config.chat
        return true if within_cooldown?(proposal, ctx)

        rejections[proposal.dedupe_key] >= cfg.suppress_after_rejections
      end

      def within_cooldown?(proposal, ctx)
        window = proposal.capability.cooldown || ctx.config.chat.cooldown
        return false if window.nil?

        last = store.values.select { |p| p.dedupe_key == proposal.dedupe_key && p.status != "generated" }
                    .max_by(&:created_at)
        last && (Time.now - last.created_at) < window
      end

      def record_rejection(proposal, _code)
        rejections[proposal.dedupe_key] += 1
      end
    end
  end

  # The conversational surface. A turn is structured data, not a string: the
  # assistant's message plus the proposals it stands behind.
  module Chat
    Turn = Struct.new(:message, :proposals, :clarifications, :state, keyword_init: true) do
      def to_h
        { message: message, proposals: proposals.map(&:to_h),
          clarifications: clarifications, state: state }
      end
    end

    class << self
      # Opening the chat with no user input still produces proposals.
      def open(setup: nil, scope: {}, candidates: nil, context: nil)
        ctx       = context || Context.resolve
        setup     ||= Setup.current || Setup.build
        proposals = Proposals.generate(setup: setup, scope: scope, candidates: candidates,
                                       surface: :chat, context: ctx)
        Proposals.surfaced!(proposals)

        Turn.new(
          message: opening_message(proposals),
          proposals: proposals,
          clarifications: [],
          state: { setup_version: setup.version, proposals: proposals.size }
        )
      end

      # An imperative order becomes a confirmable proposal, never a direct
      # execution. Keeping 100% of actions on one rail is what stops the
      # statistics from being corrupted by a back door.
      def say(text, setup: nil, candidates: nil, context: nil)
        ctx   = context || Context.resolve
        setup ||= Setup.current || Setup.build
        match = IntentResolver.resolve(text, setup, ctx)

        if match.nil?
          Proposals.record_gap(text, context: ctx)
          return Turn.new(
            message: "No tengo una capacidad que cubra eso todavía. Lo registré como " \
                     "hueco de capacidad para revisarlo.",
            proposals: [], clarifications: [], state: { capability_gap: true }
          )
        end

        proposal = Proposal.new(
          capability: match[:capability], subject: match[:subject],
          headline: match[:capability].title,
          why: ["lo pediste explícitamente"] + match[:reasons],
          inputs: match[:inputs], score: 1.0,
          cost_usd: match[:capability].cost_for(match[:inputs]),
          risk: match[:capability].risk, setup_version: setup.version
        )
        Proposals.store[proposal.id] = proposal
        Proposals.surfaced!([proposal])

        Turn.new(
          message: "Puedo hacerlo. Confirmá y lo ejecuto:",
          proposals: [proposal],
          clarifications: match[:missing].map { |f| { question: "¿Qué valor uso para #{f}?", field: f.to_s } },
          state: { setup_version: setup.version, imperative: true }
        )
      end

      private

      def opening_message(proposals)
        return "No veo nada que proponerte ahora mismo." if proposals.empty?

        "Según tu setup, te propongo #{proposals.size == 1 ? 'esta acción' : "estas #{proposals.size} acciones"}:"
      end
    end

    # Maps free text to a registered capability. Lexical first (cheap and
    # deterministic); the LLM is only consulted when that is ambiguous.
    module IntentResolver
      module_function

      def resolve(text, setup, context)
        candidates = Capability.eligible(setup, context)
        return nil if candidates.empty?

        scored = candidates.map { |c| [c, lexical_score(text, c)] }.reject { |(_, s)| s.zero? }
        best = scored.max_by { |(_, s)| s }
        best ||= llm_match(text, candidates)
        return nil if best.nil?

        capability = best.first
        { capability: capability, subject: nil, inputs: {},
          missing: capability.inputs.keys,
          reasons: [] }
      end

      def lexical_score(text, capability)
        words = text.to_s.downcase.scan(/[[:alnum:]]{4,}/)
        haystack = "#{capability.name} #{capability.title} #{capability.description} #{capability.tags.join(' ')}".downcase
        words.count { |w| haystack.include?(w) }
      end

      def llm_match(text, candidates)
        schema = LLM::Schema.define { string :capability }
        listing = candidates.map { |c| "- #{c.name}: #{c.title}" }.join("\n")
        response = LLM.complete(<<~PROMPT, model: :fast, schema: schema, agent: "IntentResolver")
          Which capability does this request map to? Answer with its exact name,
          or "none" if nothing fits.

          Request: #{text}

          Capabilities:
          #{listing}
        PROMPT
        name = response.parsed&.dig(:capability)
        found = candidates.find { |c| c.name.to_s == name.to_s }
        found ? [found, 1] : nil
      rescue StandardError
        nil
      end
    end
  end
end
