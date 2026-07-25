# frozen_string_literal: true

module Agentkit
  module ApplicationHelper
    def pct(value)
      value.nil? ? "—" : "#{(value * 100).round}%"
    end
  end
end
