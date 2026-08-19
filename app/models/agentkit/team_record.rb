# frozen_string_literal: true

module Agentkit
  class TeamRecord < ApplicationRecord
    self.table_name = "agentkit_teams"

    has_many :assets, class_name: "Agentkit::MemoryAssetRecord", foreign_key: "team_id", dependent: :destroy

    validates :tenant_key, presence: true
    validates :name, presence: true, uniqueness: { scope: :tenant_key }
  end
end
