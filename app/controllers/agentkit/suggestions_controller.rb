# frozen_string_literal: true

module Agentkit
  # The HITL inbox. Two things v0.1's version could not do:
  #   * approving actually runs the registered handler and resumes a suspended
  #     flow, instead of only flipping a status column;
  #   * rejecting requires a code from the closed taxonomy, which is what turns
  #     a rejection into an improvement signal instead of a dead string.
  class SuggestionsController < ApplicationController
    def index
      @scope       = { tenant_key: agentkit_context.tenant_key }.compact
      @suggestions = Agentkit::HITL.pending(@scope)
      @ledger      = Agentkit::HITL.ledger.summary(since: Time.now - window, scope: suggestion_scope)
      @codes       = Agentkit.config.hitl.rejection_codes
    end

    def show
      @suggestion = Agentkit::HITL.fetch!(params[:id].to_i, scope: @scope || suggestion_scope)
      @provenance = provenance_for(@suggestion)
    end

    def approve
      final = params[:payload].present? ? params[:payload].to_unsafe_h : nil
      @suggestion = Agentkit::HITL.approve(params[:id].to_i, actor: actor, final_payload: final,
                                           scope: suggestion_scope)
      respond_with_suggestion("Aprobada")
    end

    def reject
      @suggestion = Agentkit::HITL.reject(params[:id].to_i, actor: actor,
                                          code: params.require(:code),
                                          note: params[:note], scope: suggestion_scope)
      respond_with_suggestion("Rechazada")
    rescue Agentkit::UnknownRejectionCode => e
      redirect_to suggestions_path, alert: e.message
    end

    def snooze
      @suggestion = Agentkit::HITL.snooze(params[:id].to_i, actor: actor,
                                           scope: suggestion_scope)
      respond_with_suggestion("Pospuesta")
    end

    private

    def suggestion_scope = Agentkit::Scope.resolve(context: agentkit_context)

    def respond_with_suggestion(message)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.remove("suggestion_#{@suggestion.id}"),
            turbo_stream.replace("agentkit-flash", partial: "agentkit/shared/flash",
                                                   locals: { message: message })
          ]
        end
        format.html { redirect_to suggestions_path, notice: message }
      end
    end

    # Where did this proposal come from? Joins the audit trail and, for an
    # imagined scenario, the XAI trace of the three phases that produced it.
    def provenance_for(suggestion)
      memory_id = suggestion.payload["memory_id"]
      memory    = memory_id && Agentkit::Memory.find(memory_id)
      {
        audit: Agentkit::Audit.entries(run_id: suggestion.run_id).last(20),
        memory: memory && Agentkit::Audit.provenance(memory)
      }
    end
  end
end
