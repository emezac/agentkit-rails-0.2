# frozen_string_literal: true

class EchoAgent < ApplicationAgent
  def call(input)
    agent_log(event: :started, payload: { "input" => input.to_s })
    memorize!("echoed #{input}", tags: %w[echo], type: "observation")
    "echo:#{input}"
  end
end
