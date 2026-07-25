# frozen_string_literal: true

class ApplicationAgent < Agentkit::Agent
  def domain_context
    current_account ? "Account: #{current_account.name}." : ""
  end
end
