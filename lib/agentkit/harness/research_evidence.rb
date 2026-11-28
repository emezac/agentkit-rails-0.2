# frozen_string_literal: true

module Agentkit
  module Harness
    # Exact, bounded extraction of source-backed passages. This is a literal
    # evidence gate, not semantic entailment or an authorization to act.
    class ResearchEvidence
      K = Knowledge
      B = K::Boundary
      MAX_QUESTIONS = 32
      MAX_SOURCES = 16
      MAX_SOURCE_BYTES = 65_536
      MAX_QUOTE_BYTES = 4_096
      SOURCE_KINDS = %w[primary secondary].freeze

      def initialize(loader:, authorize:)
        unless loader.respond_to?(:call) && authorize.respond_to?(:call)
          raise K::InvalidContract, "source loader and authorizer required"
        end
        @loader, @authorize = loader, authorize
      end

      def build(questions:, sources:, context:)
        extract(questions: questions, sources: sources, context: context, action: "build")
      end

      # A separate principal reloads every source and recomputes the exact
      # report. Missing, changed or unauthorized sources fail closed.
      def verify(report:, questions:, sources:, context:)
        expected = extract(questions: questions, sources: sources, context: context, action: "verify")
        actual = B.data(report)
        valid = actual.is_a?(Hash) && actual == expected
        Harness.deep_freeze("verified" => valid,
          "issues" => valid ? [] : ["evidence_mismatch"], "authorizes" => false)
      end

      private

      def extract(questions:, sources:, context:, action:)
        B.identity(context)
        questions = normalize_questions(questions)
        refs = normalize_sources(sources)
        loaded = refs.map { |ref| load_source(ref, context, action) }
        claims, unresolved = [], []

        questions.each do |question|
          matches = loaded.select { |source| source.fetch("kind") == "primary" }.flat_map do |source|
            source.fetch("content").each_line.filter_map do |line|
              quote = line.strip
              next if quote.empty? || !quote.downcase.include?(question.fetch("needle").downcase)
              raise K::InvalidContract, "matching quote exceeds byte limit" if quote.bytesize > MAX_QUOTE_BYTES

              { "question_id" => question.fetch("id"), "text" => quote, "quote" => quote,
                "source_id" => source.fetch("id"), "source_reference" => source.fetch("reference"),
                "source_version" => source.fetch("version"), "source_digest" => source.fetch("digest") }
            end
          end
          unique = matches.map { |claim| claim.fetch("quote") }.uniq
          if unique.size == 1
            claims << matches.first
          else
            unresolved << { "question_id" => question.fetch("id"),
              "reason" => unique.empty? ? "no_matching_primary_source" : "conflicting_sources",
              "source_ids" => matches.map { |claim| claim.fetch("source_id") }.uniq }
          end
        end

        Harness.deep_freeze(B.data(schema: "agentkit.research_evidence.v1",
          source_snapshot_digest: K.digest(refs), claims: claims,
          unresolved: unresolved, authorizes: false))
      end

      def normalize_questions(value)
        data = B.data(value)
        unless data.is_a?(Array) && data.size.between?(1, MAX_QUESTIONS)
          raise K::InvalidContract, "bounded nonempty questions required"
        end
        data.each do |item|
          K::Snapshot.exact_keys!(item, %w[id needle])
          identifier(item.fetch("id"))
          bounded(item.fetch("needle"), 512)
        end
        raise K::InvalidContract, "duplicate question ID" unless data.map { |item| item.fetch("id") }.uniq.size == data.size
        data
      end

      def normalize_sources(value)
        data = B.data(value)
        unless data.is_a?(Array) && data.size.between?(1, MAX_SOURCES)
          raise K::InvalidContract, "bounded nonempty sources required"
        end
        data.each do |item|
          K::Snapshot.exact_keys!(item, %w[id reference version kind digest])
          identifier(item.fetch("id"))
          bounded(item.fetch("reference"), 512)
          bounded(item.fetch("version"), 128)
          unless SOURCE_KINDS.include?(item.fetch("kind")) && item.fetch("digest").is_a?(String) &&
              item.fetch("digest").match?(/\A[0-9a-f]{64}\z/)
            raise K::InvalidContract, "invalid source kind or digest"
          end
        end
        raise K::InvalidContract, "duplicate source ID" unless data.map { |item| item.fetch("id") }.uniq.size == data.size
        data
      end

      def load_source(ref, context, action)
        raise K::AccessDenied, "research source denied" unless @authorize.call(action, ref, context) == true
        row = B.data(@loader.call(ref, context))
        K::Snapshot.exact_keys!(row, %w[id reference version kind scope content])
        content = row.fetch("content")
        unless content.is_a?(String) && content.bytesize.between?(1, MAX_SOURCE_BYTES) &&
            row.fetch("scope") == B.scope(context) &&
            %w[id reference version kind].all? { |field| row.fetch(field) == ref.fetch(field) } &&
            K.digest(content) == ref.fetch("digest")
          raise K::IntegrityError, "research source changed or outside scope"
        end
        ref.merge("content" => content)
      end

      def identifier(value)
        unless value.is_a?(String) && value.bytesize.between?(1, 128) && value.match?(/\A[a-zA-Z0-9:._-]+\z/)
          raise K::InvalidContract, "bounded identifier required"
        end
        value
      end

      def bounded(value, max_bytes)
        unless value.is_a?(String) && value.bytesize.between?(1, max_bytes)
          raise K::InvalidContract, "bounded text required"
        end
        value
      end
    end
  end
end
