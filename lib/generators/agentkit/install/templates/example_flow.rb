# frozen_string_literal: true

class ExampleFlow < Agentkit::Flow
  input :account_id

  step :prepare do |ctx|
    { account_id: ctx.input[:account_id], prepared_at: Time.current }
  end

  # Suspends the run until a human approves, then resumes at :execute.
  human_gate :approve, timeout: 48 * 3600, on_timeout: :auto_reject

  step :execute, if: ->(ctx) { ctx[:approve].approved? } do |ctx|
    "done for account #{ctx[:prepare].value[:account_id]}"
  end

  compensate :execute, with: ->(_ctx) { Rails.logger.info("[ExampleFlow] compensated") }
end
