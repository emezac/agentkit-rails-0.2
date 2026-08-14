# frozen_string_literal: true

module Agentkit
  class TeamMemoryController < ApplicationController
    def index
      @team_name = params[:team] || "default"
      @team      = Agentkit::TeamMemory.find_team(@team_name)
      @assets    = Agentkit::TeamMemory.load_assets(team: @team_name)
      @skills    = @assets.select { |a| a.asset_type == "skill" }
      @wikis     = @assets.select { |a| a.asset_type == "wiki" }
      @graphs    = @assets.select { |a| a.asset_type == "code_graph" }
      @memories  = @assets.select { |a| a.asset_type == "chat_memory" }
    end

    def create_asset
      asset = Agentkit::TeamMemory.create_asset(
        asset_type: params[:asset_type],
        name: params[:name],
        team_id: params[:team_id],
        visibility: params[:visibility] || "team",
        content: { "description" => params[:description] }
      )
      redirect_to team_memory_index_path(team: params[:team]), notice: "Asset #{asset.name} creado."
    end
  end
end
