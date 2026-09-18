# frozen_string_literal: true

module Agentkit
  class TeamMemoryController < ApplicationController
    def index
      scope = tenant_scope
      @team_name = params[:team] || "default"
      @team      = Agentkit::TeamMemory.find_team(@team_name, **scope)
      @assets    = Agentkit::TeamMemory.load_assets(team: @team_name, **scope)
      @skills    = @assets.select { |a| a.asset_type == "skill" }
      @wikis     = @assets.select { |a| a.asset_type == "wiki" }
      @graphs    = @assets.select { |a| a.asset_type == "code_graph" }
      @memories  = @assets.select { |a| a.asset_type == "chat_memory" }
    end

    def create_asset
      scope = tenant_scope
      asset = Agentkit::TeamMemory.create_asset(
        asset_type: params[:asset_type],
        name: params[:name],
        team_id: params[:team_id],
        visibility: params[:visibility] || "team",
        content: { "description" => params[:description] },
        **scope
      )
      redirect_to team_memory_index_path(team: params[:team]), notice: "Asset #{asset.name} creado."
    end

    def activation
      @trace = Agentkit::TeamMemory::Visualization.fetch(params[:id], context: agentkit_context)
      return head(:not_found) unless @trace

      @wave = Agentkit.config.feature?(:graph_wave_visualization)
      respond_to do |format|
        format.html
        format.json { render json: @trace.to_h }
      end
    end

    private

    def tenant_scope
      context = agentkit_context
      {
        tenant_key: context.tenant_key,
        account_id: context.account.respond_to?(:id) ? context.account.id : context.account
      }
    end
  end
end
