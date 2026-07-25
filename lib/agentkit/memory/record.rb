# frozen_string_literal: true

module Agentkit
  module Memory
    # Storage-agnostic representation of one memory. The ActiveRecord model in
    # the engine maps 1:1 to these attributes, so the pure-Ruby core and the
    # Rails layer share one contract.
    class Record
      ATTRIBUTES = %i[
        id content memory_type status confidence importance tags role
        source_agent user_id account_id tenant_key
        embedding embedding_status embedding_model embedding_dims
        content_hash duplicate_of_id
        recall_count last_recalled_at promoted_at
        derived_from_memory_id canonical_memory_id superseded_by_id
        ontological_type run_id expires_at created_at updated_at metadata
      ].freeze

      attr_accessor(*ATTRIBUTES)

      # Lifecycle: raw → embedded → consolidated → superseded/archived.
      # `superseded` replaces v0.1's destructive `update_all(status: "archived")`
      # so a consolidation can be audited and rolled back.
      STATUSES     = %w[raw embedded consolidated superseded archived].freeze
      EMBED_STATES = %w[none pending embedded skipped failed gc].freeze
      ONTOLOGIES   = %w[real imagined summary].freeze

      def initialize(**attrs)
        ATTRIBUTES.each { |a| instance_variable_set(:"@#{a}", attrs[a]) }
        @memory_type      ||= "observation"
        @status           ||= "raw"
        @embedding_status ||= "none"
        @ontological_type ||= "real"
        @confidence       ||= 0.7
        @importance       ||= 0.5
        @recall_count     ||= 0
        @tags             = Array(@tags)
        @metadata         ||= {}
        @created_at       ||= Time.now
        @content_hash     ||= self.class.hash_for(@content)
      end

      def self.hash_for(content)
        Digest::SHA256.hexdigest(content.to_s.strip.downcase)[0, 32]
      end

      def embedded?    = embedding_status.to_s == "embedded" && !embedding.nil?
      def pending?     = embedding_status.to_s == "pending"
      def imagined?    = ontological_type.to_s == "imagined"
      def real?        = ontological_type.to_s == "real"
      def active?      = %w[raw embedded consolidated].include?(status.to_s)
      def superseded?  = !superseded_by_id.nil?
      def expired?(now = Time.now) = !expires_at.nil? && expires_at < now

      def derived_from?(other_id) = derived_from_memory_id == other_id

      def touch_recall!
        @recall_count = recall_count.to_i + 1
        @last_recalled_at = Time.now
        self
      end

      def to_h
        ATTRIBUTES.to_h { |a| [a, public_send(a)] }
      end

      # Vector payload is noisy in logs and huge in JSON — never include it.
      def to_summary
        to_h.except(:embedding).merge(embedded: embedded?)
      end

      def inspect
        "#<Agentkit::Memory::Record id=#{id.inspect} type=#{memory_type} " \
          "status=#{status} embed=#{embedding_status} content=#{content.to_s.slice(0, 40).inspect}>"
      end
    end
  end
end
