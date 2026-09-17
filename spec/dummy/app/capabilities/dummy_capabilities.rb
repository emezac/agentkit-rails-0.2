# frozen_string_literal: true

# Registration lives in a method called from `to_prepare`, not at the top level.
# A file that merely runs code is never loaded by Zeitwerk and blows up on
# eager-load in production — the trap that left the A2A card empty during the
# totallook pilot.
module DummyCapabilities
  module_function

  def register_all
    Agentkit::Capability.register :echo do |c|
      c.title "Echo something"
      c.agent EchoAgent
      c.inputs text: :string
      c.risk :reversible
      c.hitl :auto
      c.preconditions { |_setup, ctx| ctx.account.present? }
      c.expose :a2a
    end

    Agentkit::Capability.register :dangerous do |c|
      c.title "Irreversible thing"
      c.agent EchoAgent
      c.inputs text: :string
      c.risk :irreversible
      c.preconditions { |_setup, ctx| ctx.account.present? }
      c.expose :a2a, mode: :propose
    end
  end
end
