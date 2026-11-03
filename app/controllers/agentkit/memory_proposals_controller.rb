# frozen_string_literal: true

module Agentkit
  class MemoryProposalsController < ApplicationController
    def index
      @proposals = Agentkit::MemoryReviews.scoped(context: agentkit_context)
                                          .order(created_at: :desc).limit(100)
      render template: "agentkit/memory_proposals_index"
    end

    def approve
      Agentkit::MemoryReviews.approve!(params[:id], actor: actor, context: agentkit_context)
      redirect_to memory_proposals_path, notice: "Memoria aprobada"
    rescue Agentkit::ConfigurationError => e
      redirect_to memory_proposals_path, alert: e.message
    end

    def reject
      Agentkit::MemoryReviews.reject!(params[:id], actor: actor, context: agentkit_context)
      redirect_to memory_proposals_path, notice: "Propuesta rechazada"
    rescue Agentkit::ConfigurationError => e
      redirect_to memory_proposals_path, alert: e.message
    end

    def undo
      Agentkit::MemoryReviews.undo!(params[:id], actor: actor, context: agentkit_context)
      redirect_to memory_proposals_path, notice: "Memoria archivada; revisión registrada"
    rescue Agentkit::ConfigurationError => e
      redirect_to memory_proposals_path, alert: e.message
    end
  end
end
