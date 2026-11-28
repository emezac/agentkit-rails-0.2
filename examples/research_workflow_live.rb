# frozen_string_literal: true

require "json"
require "agentkit"
require "ruby_llm"
require_relative "research_workflow"

module LiveResearchComparison
  R = ResearchWorkflowExample
  K = Agentkit::Knowledge
  # USD per 1M tokens; recheck the provider price before using cost estimates.
  PRICE_IN = 0.15
  PRICE_OUT = 0.60

  class Track
    def initialize(context:)
      @context = context
    end

    def call(track)
      sources = track.fetch("source_ids").map { |id| R::REPOSITORY.fetch(id, context: @context) }
      prompt = JSON.generate(
        questions: track.fetch("questions"),
        sources: sources.map { |s| { id: s.fetch("id"), content: s.fetch("content") } }
      )
      messages = [
        { "role" => "system", "content" => "You extract literal evidence from the supplied sources only. Check EVERY (question, source) pair independently. If a source sentence contains that question's needle as a case-insensitive substring, you MUST emit one claim for that pair with question_id, source_id, and the complete exact sentence as quote. Emit separate claims when multiple sources match the same question, even if their statements disagree. Omit only pairs with no substring match. Return ONLY a JSON object with a claims array; do not infer facts, invent sources, or add commentary." },
        { "role" => "user", "content" => prompt }
      ]
      turn = Agentkit.with_context(@context) do
        Agentkit::LLM.turn(messages: messages, tools: [], model: :research_live,
          max_tokens: 250, temperature: 0, agent: "LiveResearchTrack")
      end
      errors = []
      data = if turn.stop_reason == "answered"
               begin
                 JSON.parse(turn.message.fetch("content"))
               rescue JSON::ParserError
                 errors << "invalid_json"
                 nil
               end
             else
               errors << "model_stop:#{turn.stop_reason}"
               nil
             end
      unless data.is_a?(Hash) && data["claims"].is_a?(Array)
        errors << "invalid_claims" if data
        data = { "claims" => [] }
      end
      claims = data.fetch("claims").filter_map do |item|
        unless item.is_a?(Hash) && %w[question_id source_id quote].all? { |key| item[key].is_a?(String) }
          errors << "invalid_claim_shape"
          next
        end
        source = sources.find { |s| s.fetch("id") == item.fetch("source_id") }
        unless source
          errors << "unapproved_model_source"
          next
        end
        { "question_id" => item.fetch("question_id"), "source_id" => source.fetch("id"),
          "text" => item.fetch("quote"), "quote" => item.fetch("quote"),
          "source_reference" => source.fetch("reference"),
          "source_version" => source.fetch("version"),
          "source_digest" => K.digest(source.fetch("content")) }
      end
      { "claims" => claims, "input_tokens" => turn.usage.input_tokens,
        "output_tokens" => turn.usage.output_tokens, "cost_usd" => turn.usage.cost_usd,
        "protocol_errors" => errors.uniq }
    end
  end

  class Single < Agentkit::Flow
    input :case_contract
    step(:research) { |ctx| Track.new(context: ctx.context).call(ctx.input.fetch(:case_contract)) }
    step(:report) do |ctx|
      work = ctx[:research].value
      { "report" => R.assemble(ctx.input.fetch(:case_contract), work.fetch("claims")),
        "usage" => work.slice("input_tokens", "output_tokens", "cost_usd"),
        "protocol_errors" => work.fetch("protocol_errors") }
    end
  end

  class Split < Agentkit::Flow
    input :case_contract, :tracks
    map :research, over: ->(ctx) { ctx.input.fetch(:tracks) }, agent: Track
    join :research, on: :all_complete
    step(:report) do |ctx|
      work = ctx[:research].values
      { "report" => R.assemble(ctx.input.fetch(:case_contract), work.flat_map { |row| row.fetch("claims") }),
        "protocol_errors" => work.flat_map { |row| row.fetch("protocol_errors") }.uniq,
        "usage" => {
          "input_tokens" => work.sum { |row| row.fetch("input_tokens") },
          "output_tokens" => work.sum { |row| row.fetch("output_tokens") },
          "cost_usd" => work.sum { |row| row.fetch("cost_usd") }
        } }
    end
  end

  def self.run(repetitions: 3)
    raise "repetitions must be 1..3" unless repetitions.is_a?(Integer) && repetitions.between?(1, 3)
    env_file = File.expand_path("../.env", __dir__)
    line = File.file?(env_file) ? File.binread(env_file).lines.find { |row| row.start_with?("OPENAI_API_KEY=") } : nil
    key = ENV["OPENAI_API_KEY"] || line&.split("=", 2)&.last&.strip
    raise "OPENAI_API_KEY missing" unless key
    key = key[1...-1] if [34, 39].include?(key.getbyte(0)) && key.getbyte(0) == key.getbyte(-1)
    raise "OPENAI_API_KEY empty" if key.empty?

    Agentkit::Flow.test_mode!
    Agentkit.config.llm.adapter = :ruby_llm
    Agentkit::LLM.reset!
    Agentkit::ModelRouter.register(:research_live, model: "gpt-4o-mini", provider: :ruby_llm,
      api_key: key, price_in: PRICE_IN, price_out: PRICE_OUT, timeout: 30)
    max_calls = repetitions * R::CASES.sum { |item| 1 + item.fetch("source_ids").size }
    budget = Agentkit::ExecutionBudget.new(max_turns: max_calls, max_tokens: 100_000, max_cost_usd: 0.10)
    context = Agentkit::Context.new(tenant_key: "demo", principal: "researcher", budget: budget)
    verifier_context = context.derive(principal: "verifier")
    verifier = R::ReportVerifier.new
    cases = []
    observations = []
    runs = []

    R::CASES.each do |fixture|
      repetitions.times do |index|
        raw = fixture.merge("id" => "#{fixture.fetch('id')}-r#{index + 1}")
        test_case = R.bind_sources(raw, context: context)
        cases << { id: test_case.fetch("id"), phase: fixture.fetch("phase"),
          category: "literal_policy_research", input_digest: K.digest(test_case) }
        tracks = test_case.fetch("source_ids").map do |id|
          { "questions" => test_case.fetch("questions"), "source_ids" => [id] }
        end
        arms = index.even? ? [["baseline", Single], ["candidate", Split]] : [["candidate", Split], ["baseline", Single]]
        arms.each do |arm, flow|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          input = { case_contract: test_case }
          input[:tracks] = tracks if arm == "candidate"
          result = flow.call(**input, context: context)
          raise "#{arm} flow failed: #{result.error.class}" if result.err?
          output = result.value
          report = output.fetch("report")
          verdict = verifier.verify(report: report, case_contract: test_case, context: verifier_context)
          issues = (verdict.fetch("issues") + output.fetch("protocol_errors")).uniq
          verified = verdict.fetch("verified") && issues.empty?
          usage = output.fetch("usage")
          latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round
          cost = (usage.fetch("cost_usd") * 1_000_000).round
          observations << { case_id: test_case.fetch("id"), arm: arm,
            input_digest: K.digest(test_case), evidence_digest: K.digest([test_case.fetch("id"), arm, report, verdict, issues,
              usage.fetch("input_tokens"), usage.fetch("output_tokens"), cost]),
            verified: verified, safety_failures: issues,
            cost_microusd: cost, latency_ms: latency, human_seconds: 0,
            tokens: usage.fetch("input_tokens") + usage.fetch("output_tokens") }
          runs << { case_id: test_case.fetch("id"), arm: arm, verified: verified,
            issues: issues, claims: report.fetch("claims").size,
            unresolved: report.fetch("unresolved"), input_tokens: usage.fetch("input_tokens"),
            output_tokens: usage.fetch("output_tokens"), cost_microusd: cost, latency_ms: latency }
        end
      end
    end
    { model: "gpt-4o-mini", repetitions: repetitions, provider_calls: budget.snapshot.fetch(:usage).fetch(:calls),
      runs: runs, evaluation: Agentkit::Harness::BusinessValueEvaluation.new(
        id: "live-research-pilot", version: "1", cases: cases, observations: observations).to_h }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.pretty_generate(LiveResearchComparison.run(repetitions: Integer(ENV.fetch("RESEARCH_REPETITIONS", "3"))))
  rescue StandardError => error
    warn "live_research_error=#{error.class} message=#{error.message.gsub(/sk-[A-Za-z0-9_-]+/, '[REDACTED]').byteslice(0, 300)}"
    exit 1
  end
end
