# frozen_string_literal: true

# Run: ruby -Ilib examples/research_workflow.rb
# Offline fixture: replace the source adapter and researcher in a Rails host.
require "agentkit"
require "json"

module ResearchWorkflowExample
  K = Agentkit::Knowledge
  H = Agentkit::Harness

  SOURCES = H.deep_freeze([
    { "id" => "returns-v2", "tenant" => "demo", "reference" => "policy/returns",
      "version" => "2", "kind" => "primary", "content" => "Standard returns are accepted within 30 days." },
    { "id" => "exceptions-v1", "tenant" => "demo", "reference" => "policy/exceptions",
      "version" => "1", "kind" => "primary", "content" => "Return exceptions require a manager's approval." },
    { "id" => "refunds-v3", "tenant" => "demo", "reference" => "policy/refunds",
      "version" => "3", "kind" => "primary", "content" => "Approved refunds are issued within five business days." },
    { "id" => "damage-v1", "tenant" => "demo", "reference" => "policy/damage",
      "version" => "1", "kind" => "primary", "content" => "Damaged items require manual review." }
  ])

  CASES = H.deep_freeze([
    { "id" => "returns", "phase" => "training", "source_ids" => %w[returns-v2 exceptions-v1],
      "questions" => [{ "id" => "window", "needle" => "within 30 days" },
                       { "id" => "exception", "needle" => "manager's approval" }] },
    { "id" => "refunds", "phase" => "holdout", "source_ids" => %w[refunds-v3 damage-v1],
      "questions" => [{ "id" => "timing", "needle" => "five business days" },
                       { "id" => "damage", "needle" => "manual review" },
                       { "id" => "missing", "needle" => "international returns" }] }
  ])

  # The host owns source authorization and immutable versions. No model-supplied
  # URL, digest or excerpt is accepted as a source of truth by the verifier.
  class SourceRepository
    def initialize(sources = SOURCES)
      @sources = H.deep_freeze(sources.to_h { |source| [source.fetch("id"), source] })
    end

    def fetch(id, context:)
      source = @sources.fetch(id) { raise K::AccessDenied, "unknown source" }
      raise K::AccessDenied, "source scope mismatch" unless source.fetch("tenant") == context.tenant_key
      raise K::AccessDenied, "source reader denied" unless %w[researcher verifier].include?(context.principal)

      source
    end
  end

  REPOSITORY = SourceRepository.new

  def self.bind_sources(case_contract, context:, repository: REPOSITORY)
    manifest = case_contract.fetch("source_ids").map do |id|
      source = repository.fetch(id, context: context)
      [id, source.fetch("version"), K.digest(source.fetch("content"))]
    end
    case_contract.merge("source_snapshot_digest" => K.digest(manifest))
  end

  # A deterministic stand-in for an LLM/search worker. The only claims it can
  # return are literal excerpts from host-authorized source content.
  class ResearchTrack
    def initialize(context:, repository: REPOSITORY)
      @context, @repository = context, repository
    end

    def call(track)
      track.fetch("questions").filter_map do |question|
        source = track.fetch("source_ids").filter_map do |id|
          candidate = @repository.fetch(id, context: @context)
          candidate if candidate.fetch("content").downcase.include?(question.fetch("needle").downcase)
        end.first
        next unless source

        { "question_id" => question.fetch("id"), "text" => source.fetch("content"),
          "source_id" => source.fetch("id"), "source_reference" => source.fetch("reference"),
          "source_version" => source.fetch("version"),
          "source_digest" => K.digest(source.fetch("content")), "quote" => source.fetch("content") }
      end
    end
  end

  def self.assemble(case_contract, claims)
    grouped = claims.compact.group_by { |claim| claim.fetch("question_id") }
    resolved = case_contract.fetch("questions").filter_map do |question|
      matches = grouped.fetch(question.fetch("id"), [])
      matches.first if matches.map { |claim| claim.fetch("text") }.uniq.size == 1
    end
    { "case_id" => case_contract.fetch("id"),
      "source_snapshot_digest" => case_contract.fetch("source_snapshot_digest"), "claims" => resolved,
      "unresolved" => case_contract.fetch("questions").reject { |q| resolved.any? { |claim| claim.fetch("question_id") == q.fetch("id") } }
        .map do |q|
          matches = grouped.fetch(q.fetch("id"), [])
          { "question_id" => q.fetch("id"), "reason" =>
            matches.map { |claim| claim.fetch("text") }.uniq.size > 1 ? "conflicting_sources" : "no_matching_primary_source" }
        end,
      "authorizes" => false }
  end

  class SingleResearch < Agentkit::Flow
    input :case_contract
    step(:research) do |ctx|
      ResearchTrack.new(context: ctx.context).call(ctx.input.fetch(:case_contract))
    end
    step(:report) { |ctx| ResearchWorkflowExample.assemble(ctx.input.fetch(:case_contract), ctx[:research].value) }
  end

  class SplitResearch < Agentkit::Flow
    input :case_contract, :tracks
    map :research, over: ->(ctx) { ctx.input.fetch(:tracks) }, agent: ResearchTrack
    join :research, on: :all_complete
    step(:report) do |ctx|
      ResearchWorkflowExample.assemble(ctx.input.fetch(:case_contract), ctx[:research].values.flatten)
    end
  end

  # Verifies provenance and coverage against the trusted repository. Literal
  # quotes are checked; broader interpretations need an independent domain grader.
  class ReportVerifier
    def initialize(repository: REPOSITORY)
      @repository = repository
    end

    def verify(report:, case_contract:, context:)
      raise K::AccessDenied, "independent verifier required" unless context.principal == "verifier"

      questions = case_contract.fetch("questions").to_h { |q| [q.fetch("id"), q] }
      allowed_sources = case_contract.fetch("source_ids")
      issues = []
      issues << "case_mismatch" unless report["case_id"] == case_contract.fetch("id")
      current_snapshot = ResearchWorkflowExample.bind_sources(case_contract, context: context,
        repository: @repository).fetch("source_snapshot_digest")
      unless report["source_snapshot_digest"] == case_contract.fetch("source_snapshot_digest") &&
          current_snapshot == case_contract.fetch("source_snapshot_digest")
        issues << "source_snapshot_changed"
      end
      issues << "authority_claim" unless report["authorizes"] == false
      claims = report.fetch("claims")
      unresolved = report.fetch("unresolved")
      ids = claims.map { |row| row.fetch("question_id") } + unresolved.map { |row| row.fetch("question_id") }
      issues << "question_coverage" unless ids.sort == questions.keys.sort

      claims.each do |claim|
        question = questions[claim.fetch("question_id")]
        unless question && allowed_sources.include?(claim.fetch("source_id"))
          issues << "unapproved_claim_source"
          next
        end
        source = @repository.fetch(claim.fetch("source_id"), context: context)
        fields_match = claim.fetch("source_reference") == source.fetch("reference") &&
          claim.fetch("source_version") == source.fetch("version") &&
          claim.fetch("source_digest") == K.digest(source.fetch("content")) &&
          claim.fetch("quote") == claim.fetch("text") &&
          source.fetch("content").include?(claim.fetch("quote")) &&
          claim.fetch("quote").downcase.include?(question.fetch("needle").downcase) &&
          source.fetch("kind") == "primary"
        issues << "unsupported_claim" unless fields_match
        issues << "conflicting_sources" if matching_contents(question, allowed_sources, context).size > 1
      end

      unresolved.each do |row|
        question = questions[row.fetch("question_id")]
        contents = question ? matching_contents(question, allowed_sources, context) : []
        valid = case row.fetch("reason")
                when "no_matching_primary_source" then contents.empty?
                when "conflicting_sources" then contents.size > 1
                else false
                end
        if !question || !valid
          issues << "false_unresolved"
        end
      end
      { "verified" => issues.empty?, "issues" => issues.uniq, "authorizes" => false }
    end

    private

    def matching_contents(question, source_ids, context)
      source_ids.filter_map do |id|
        source = @repository.fetch(id, context: context)
        content = source.fetch("content")
        content if source.fetch("kind") == "primary" && content.downcase.include?(question.fetch("needle").downcase)
      end.uniq
    end
  end

  def self.compare(context: Agentkit::Context.new(tenant_key: "demo", principal: "researcher"),
                   verifier_context: nil)
    verifier_context ||= context.derive(principal: "verifier")
    verifier = ReportVerifier.new
    observations = []
    reports = {}
    bound_cases = CASES.map { |item| bind_sources(item, context: context) }
    bound_cases.each do |case_contract|
      tracks = case_contract.fetch("source_ids").map do |id|
        { "questions" => case_contract.fetch("questions"), "source_ids" => [id] }
      end
      { "baseline" => SingleResearch, "candidate" => SplitResearch }.each do |arm, flow|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        input = { case_contract: case_contract }
        input[:tracks] = tracks if arm == "candidate"
        result = flow.call(**input, context: context)
        raise result.error if result.err?

        report = result.value
        verdict = verifier.verify(report: report, case_contract: case_contract, context: verifier_context)
        (reports[case_contract.fetch("id")] ||= {})[arm] = report
        observations << { case_id: case_contract.fetch("id"), arm: arm,
          input_digest: K.digest(case_contract), evidence_digest: K.digest([case_contract.fetch("id"), arm, report, verdict]),
          verified: verdict.fetch("verified"), safety_failures: verdict.fetch("issues"),
          cost_microusd: 0, tokens: 0, human_seconds: 0,
          latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round }
      end
    end
    cases = bound_cases.map do |item|
      { id: item.fetch("id"), phase: item.fetch("phase"), category: "policy_research",
        input_digest: K.digest(item) }
    end
    { "reports" => reports, "evaluation" => H::BusinessValueEvaluation.new(
      id: "research-demo", version: "1", cases: cases, observations: observations).to_h }
  end
end

if $PROGRAM_NAME == __FILE__
  Agentkit::Flow.test_mode!
  puts JSON.pretty_generate(ResearchWorkflowExample.compare)
end
