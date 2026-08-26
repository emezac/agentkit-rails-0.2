# frozen_string_literal: true

module Agentkit
  # A2A over HTTP. Thin by design: all the protocol logic lives in
  # Agentkit::A2A so it stays testable without Rails.
  # The engine pins this inflection (see agentkit.inflections) so the constant
  # does not change depending on whether the host app declares an "A2A"
  # acronym. It named the class A2AController before, which broke eager loading
  # in every app that did.
  # Naming it A2AController raises on eager load and leaves the engine's
  # `a2a#rpc` route pointing at a constant that does not exist.
  class A2AController < ActionController::API
    before_action :ensure_enabled!

    # GET /agentkit/a2a  (and /.well-known/agent.json when the host routes it)
    def card
      context = Agentkit::A2A::V1.resolve_context(request)
      render json: Agentkit::A2A::V1.card(base_url: request.base_url, context: context),
             content_type: Agentkit::A2A::V1::MEDIA_TYPE
    end

    def legacy_card
      head :not_found and return unless Agentkit.config.a2a.legacy

      render json: Agentkit::A2A.card(base_url: request.base_url)
    end

    def send_message
      enforce_version!
      render_a2a(task: Agentkit::A2A::V1.send_message(request_parameters, context: a2a_context))
    rescue Agentkit::A2A::V1::ProtocolError => e
      render_problem(e)
    end

    def get_task
      enforce_version!
      render_a2a(task: Agentkit::A2A::V1.get_task(params[:id], context: a2a_context))
    rescue Agentkit::A2A::V1::ProtocolError => e
      render_problem(e)
    end

    def list_tasks
      enforce_version!
      render_a2a(tasks: Agentkit::A2A::V1.list_tasks(context: a2a_context))
    rescue Agentkit::A2A::V1::ProtocolError => e
      render_problem(e)
    end

    def cancel_task
      enforce_version!
      render_a2a(task: Agentkit::A2A::V1.cancel_task(params[:id], context: a2a_context))
    rescue Agentkit::A2A::V1::ProtocolError => e
      render_problem(e)
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

    def presented_key
      bearer = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
      bearer || request.headers["X-A2A-Key"]
    end

    def a2a_context
      @a2a_context ||= Agentkit::A2A.authenticate(presented_key) ||
        raise(Agentkit::A2A::V1::ProtocolError.new("authentication required", status: 401,
                                                   type: "authentication-required"))
    end

    def enforce_version!
      version = request.headers["A2A-Version"].presence || Agentkit::A2A::V1::PROTOCOL_VERSION
      return if version == Agentkit::A2A::V1::PROTOCOL_VERSION

      raise Agentkit::A2A::V1::ProtocolError.new("A2A version #{version} is not supported",
                                                 type: "version-not-supported")
    end

    def request_parameters
      JSON.parse(request.raw_post)
    rescue JSON::ParserError
      raise Agentkit::A2A::V1::ProtocolError, "malformed JSON"
    end

    def render_a2a(body)
      render json: body, content_type: Agentkit::A2A::V1::MEDIA_TYPE
    end

    def render_problem(error)
      render json: error.to_h, status: error.status, content_type: "application/problem+json"
    end

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

  # Host-level well-known routes use the host application's inflector rather
  # than the engine loader's pinned acronym. Keep both constant spellings
  # pointing at the same controller so discovery works with either policy.
  A2aController = A2AController unless const_defined?(:A2aController, false)
end
