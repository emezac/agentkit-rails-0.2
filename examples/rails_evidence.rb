# frozen_string_literal: true

# Load inside a Rails app. The model needs account_id, status and updated_at.
# Supply real authorization callbacks and a persisted approval date/identity.
require "agentkit"

module RailsEvidenceExample
  def self.build(model:, authorize_record:, authorize_decision:, authorize_journal:,
                 execution_context:, approved_by:, approved_at:, eligible_status: "ready")
    k = Agentkit::Knowledge
    ontology = k::Ontology.new(name: "Review", version: "1", entities: ["Subject"],
      relations: { "Ready" => ["Subject"], "EligibleForReview" => ["Subject"] })
    x = k.var("subject")
    rules = [k::Rule.new(id: "review_ready", version: "1", approved_by: approved_by, approved_at: approved_at,
      head: k::Atom.new(relation: "EligibleForReview", terms: [x]),
      body: [k::Atom.new(relation: "Ready", terms: [x])])]
    journal = k::Journal.new(authorize: authorize_journal)
    source = k::ActiveRecordSource.new(name: "review_source", version: "1/#{eligible_status}", ontology: ontology, rules: rules,
      relation: ->(ctx) { model.where(account_id: ctx.account.id) }, authorize: authorize_record,
      extract: lambda do |record, ctx, at|
        next [] unless record.status == eligible_status
        [k::Assertion.new(id: "subject:#{record.id}:ready", scope: k::Boundary.scope(ctx),
          relation: "Ready", values: ["subject:#{record.id}"], source: "#{model.table_name}/#{record.id}",
          source_version: record.updated_at.utc.iso8601(6), observed_at: at, valid_from: at)]
      end)
    k::DecisionGate.new(name: "review_gate", version: "1", source: source, journal: journal,
      queries: ->(args, _ctx) { [{ "relation" => "EligibleForReview", "values" => ["subject:#{args.fetch('id')}"] }] },
      authorize: authorize_decision, execution_context: execution_context)
  end
end
