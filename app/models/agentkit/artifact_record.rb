# frozen_string_literal: true

module Agentkit
  # Large step outputs live here instead of in a JSONB column, so a 200KB
  # screenplay never travels through job arguments.
  class ArtifactRecord < ApplicationRecord
    self.table_name = "agentkit_artifacts"
  end
end
