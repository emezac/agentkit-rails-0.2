# frozen_string_literal: true

module Agentkit
  # A2A over HTTP. Thin by design: all the protocol logic lives in
  # Agentkit::A2A so it stays testable without Rails.
  # NOTE the casing: Zeitwerk camelizes `a2a_controller.rb` to `A2aController`.
  # Naming it A2AController raises on eager load and leaves the engine's
  # `a2a#rpc` route pointing at a constant that does not exist.
  class A2aController < ActionController::API
    before_action :ensure_enabled!

    # GET /agentkit/a2a  (and /.well-known/agent.json when the host routes it)
    def card
      render json: Agentkit::A2A.card(base_url: request.base_url)
    end

    # POST /agentkit/a2a/rpc — JSON-RPC 2.0
    def rpc
      envelope = parse_body
      return render(json: Agentkit::A2A.rpc_error(nil, :parse_error, "malformed JSON"),
                    status: :bad_request) if envelope.nil?

      response = Agentkit::A2A.handle(envelope, key: presented_key)
      render json: response, status: Agentkit::A2A.http_status_for(response)
    end

    # POST /agentkit/a2a/:capability — REST alias over the same dispatcher, for
    # peers that do not speak JSON-RPC.
    def invoke
      envelope = {
        "jsonrpc" => "2.0", "id" => request.request_id,
        "method"  => "capabilities.invoke",
        "params"  => { "capability" => params[:capability],
                       "inputs" => (params[:inputs] || {}).to_unsafe_h,
                       "idempotency_key" => request.headers["Idempotency-Key"] }
      }
      response = Agentkit::A2A.handle(envelope, key: presented_key)
      render json: response[:result] || response[:error],
             status: Agentkit::A2A.http_status_for(response)
    end

    # POST /agentkit/a2a/register — self-service key issuing, off by default.
    # `totallook` proved this is what makes onboarding a peer painless; it is
    # opt-in because it creates credentials.
    def register
      unless Agentkit.config.a2a.allow_registration
        return render json: { error: "registration is disabled" }, status: :forbidden
      end

      handler = Agentkit.config.a2a[:registration_handler]
      return render json: { error: "no registration handler configured" }, status: :not_implemented if handler.nil?

      result = handler.call(params.permit!.to_h)
      render json: result.merge(endpoints: endpoints), status: :created
    end

    private

    def ensure_enabled!
      head :not_found unless Agentkit.config.a2a.enabled
    end

    def presented_key = request.headers["X-A2A-Key"]

    def parse_body
      raw = request.raw_post
      return nil if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def endpoints
      base = "#{request.base_url}#{Agentkit.config.a2a.mount_path}"
      { card: base, rpc: "#{base}/rpc", auth: "send the key as the X-A2A-Key header" }
    end
  end
end
