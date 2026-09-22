# frozen_string_literal: true

module Agentkit
  class ExplorationController < ApplicationController
    def index
      scope = review_scope
      @snapshot = Agentkit::Exploration.operations(scope: scope, limit: 100)
      @reviews = Agentkit::Exploration.reviews(scope: scope, limit: 100)
      @bindings = Agentkit::Exploration.policy_bindings(scope: scope).index_by(&:target)
    end

    def approve
      Agentkit::Exploration.approve_recommendation!(
        params[:id], actor: actor, reason: params[:reason], scope: review_scope
      )
      redirect_to exploration_path, notice: "Recomendación aprobada; binding declarativo actualizado."
    rescue Agentkit::Error => e
      redirect_to exploration_path, alert: e.message
    end

    def reject
      Agentkit::Exploration.reject_recommendation!(
        params[:id], actor: actor, reason: params[:reason], scope: review_scope
      )
      redirect_to exploration_path, notice: "Recomendación rechazada."
    rescue Agentkit::Error => e
      redirect_to exploration_path, alert: e.message
    end

    def rollback
      Agentkit::Exploration.rollback_recommendation!(
        params[:id], actor: actor, reason: params[:reason], scope: review_scope
      )
      redirect_to exploration_path, notice: "Binding revertido al estado anterior."
    rescue Agentkit::Error => e
      redirect_to exploration_path, alert: e.message
    end

    private

    def review_scope
      Agentkit::Scope.resolve(context: agentkit_context)
    end
  end
end
