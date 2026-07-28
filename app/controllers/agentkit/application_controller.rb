# frozen_string_literal: true

module Agentkit
  class ApplicationController < ActionController::Base
    layout "agentkit/application"

    protect_from_forgery with: :exception

    before_action :require_agentkit_access!

    # The factory view reads it to label the reporting period. Without this it
    # is a private controller method and the panel raises NameError on render —
    # the console was unreachable in any app that actually opened it.
    helper_method :window

    private

    # The host app decides who may see the console. Default: anyone in
    # development, nobody in production until it is configured.
    def require_agentkit_access!
      guard = Agentkit.config[:console_guard]
      return instance_exec(&guard) if guard.respond_to?(:call)
      return true if Rails.env.development? || Rails.env.test?

      head :forbidden
    end

    def agentkit_context
      Agentkit::Context.new(user: try(:current_user), account: try(:current_account))
    end

    def actor
      user = try(:current_user)
      user ? "human:#{user.id}" : "human:console"
    end

    def window
      (params[:days].presence || 7).to_i * 86_400
    end
  end
end
