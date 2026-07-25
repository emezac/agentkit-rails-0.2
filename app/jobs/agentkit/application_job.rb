# frozen_string_literal: true

module Agentkit
  class ApplicationJob < ::ActiveJob::Base
    queue_as :agentkit
  end
end
