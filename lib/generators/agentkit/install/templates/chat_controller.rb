# frozen_string_literal: true

# Proposal-first chat. Opening it with no input still returns proposals; an
# imperative order becomes a confirmable proposal rather than a direct
# execution, so every action stays on the same HITL and telemetry rail.
class AgentChatController < ApplicationController
  def show
    turn = Agentkit::Chat.open(candidates: proposal_candidates, context: agent_context)
    render json: turn.to_h
  end

  def create
    turn = if params[:proposal_id].present?
             accept_or_dismiss
           else
             Agentkit::Chat.say(params.require(:message), context: agent_context)
           end
    render json: turn.respond_to?(:to_h) ? turn.to_h : { ok: true }
  end

  private

  def accept_or_dismiss
    if params[:action_type] == "dismiss"
      Agentkit::Proposals.dismiss!(params[:proposal_id],
                                   code: params.require(:rejection_code),
                                   actor: "human:#{current_user&.id}")
    else
      Agentkit::Proposals.accept!(params[:proposal_id],
                                  inputs: params[:inputs]&.to_unsafe_h,
                                  actor: "human:#{current_user&.id}")
    end
  end

  def agent_context
    Agentkit::Context.new(user: current_user, account: current_account)
  end

  # Replace with the domain objects proposals should be generated about.
  def proposal_candidates
    []
  end
end
