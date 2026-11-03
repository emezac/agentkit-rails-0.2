# frozen_string_literal: true

module Agentkit
  # Classifies the provenance supplied by the host application. References
  # are identifiers, not proof that a claim is true or a business is viable.
  # Never accept model-generated references as independently verified outcomes.
  class EvidenceAssessment
    attr_reader :source_refs, :outcome_refs, :status

    def initialize(source_refs: [], outcome_refs: [])
      @source_refs = normalize(source_refs)
      @outcome_refs = normalize(outcome_refs)
      @status = if @outcome_refs.any?
                  "outcome_recorded"
                elsif @source_refs.any?
                  "sources_found"
                else
                  "hypothesis_only"
                end
      freeze
    end

    def to_h
      { "status" => status, "source_refs" => source_refs, "outcome_refs" => outcome_refs }
    end

    private

    def normalize(refs)
      raise ArgumentError, "evidence references must be an array" unless refs.is_a?(Array)

      refs.map do |ref|
        raise ArgumentError, "evidence reference must be a nonempty string" unless ref.is_a?(String) && !ref.strip.empty?

        ref.strip.freeze
      end.uniq.freeze
    end
  end
end
