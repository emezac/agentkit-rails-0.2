# frozen_string_literal: true

class GatedFlow < Agentkit::Flow
  step(:prepare) { "draft" }
  human_gate :approve, type: "dummy_gate"
  step(:apply, if: ->(ctx) { ctx[:approve].approved? }) { "applied" }
end
