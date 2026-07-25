# frozen_string_literal: true

module Agentkit
  # agentkit_memories. Mapped 1:1 to Agentkit::Memory::Record so the pure-Ruby
  # core and the Rails layer share one contract.
  class MemoryRecord < ApplicationRecord
    self.table_name = "agentkit_memories"

    has_neighbors :embedding if respond_to?(:has_neighbors)

    belongs_to :superseded_by, class_name: "Agentkit::MemoryRecord", optional: true
    belongs_to :derived_from,  class_name: "Agentkit::MemoryRecord",
                               foreign_key: :derived_from_memory_id, optional: true
    belongs_to :canonical,     class_name: "Agentkit::MemoryRecord",
                               foreign_key: :canonical_memory_id, optional: true
    has_many   :derived_memories, class_name: "Agentkit::MemoryRecord",
                                  foreign_key: :derived_from_memory_id, dependent: :nullify

    validates :content, presence: true
    validates :memory_type, presence: true
    validates :ontological_type, inclusion: { in: %w[real imagined summary] }

    scope :active,       -> { where(status: %w[raw embedded consolidated]) }
    scope :real,         -> { where(ontological_type: "real") }
    scope :imagined,     -> { where(ontological_type: "imagined") }
    scope :embedded,     -> { where(embedding_status: "embedded") }
    scope :pending_embedding, -> { where(embedding_status: "pending") }
    scope :perspectives_of, ->(m) { where(derived_from_memory_id: m.id) }
    scope :for_tenant,   ->(key) { key ? where(tenant_key: key) : all }
  end
end
