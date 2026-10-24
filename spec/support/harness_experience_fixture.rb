# frozen_string_literal: true

module HarnessExperienceFixture
  def experiment_result(context:, repetitions: 2, verdict: "helped", failure: false, id: "test-exp")
    h = Agentkit::Harness
    component = h::Component.new(name: "planner", type: :system_prompt, configuration: { text: "verify" })
    base = h::Manifest.new(id: "support", version: "1", components: [component], output_contract: {})
    replacement = h::Component.new(name: "planner", type: :system_prompt, configuration: { text: "verify citations" })
    revision = h::Revision.new(id: "citations", scope: :invariant, base_digest: base.digest,
                              rationale: "citation checks", changes: [
                                { id: "edit", operation: :replace, component: replacement, rationale: "check citations" }
                              ])
    task = h::ExperimentTask.new(id: "task", input_reference: "task:1", input_digest: h.digest("secret task"),
                                model: "test", output_contract: {})
    h::Experiment.new(
      id: id, base: base, task: task, repetitions: repetitions, context: context,
      proposer: ->(_) { [revision] },
      executor: lambda { |request|
        raise "secret failure" if failure
        { output: "secret output", output_reference: "artifact:#{request.fetch('probe_id')}" }
      },
      contrastor: lambda { |request|
        refs = (request.fetch("baseline_probes") + request.fetch("candidate_probes")).map { |p| p.fetch("evidence_refs").first }
        { summary: "citation difference", attributions: [
          { change_id: "edit", verdict: verdict, observation: "citations checked", evidence_refs: refs, confidence: 0.8 }
        ] }
      },
      composer: ->(request) {
        { action: "KEEP_BASE", reasons: [
          { summary: "retain for later review", evidence_refs: ["contrast:#{request.fetch('contrasts').first.fetch('id')}"] }
        ] }
      }
    ).run
  end

  def capture(library, result, **options)
    library.capture!(result: result, revision_id: "citations", cue: "support citations",
                     lesson: "Check citations before answering", applicability: "support answers",
                     topics: %w[support citations], **options)
  end
end
