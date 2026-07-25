# frozen_string_literal: true

# A capability is an executable action with preconditions, cost and risk — not
# a prompt fragment. The proposal engine ranks it, HITL gates it by risk, and
# the factory excludes irreversible ones from experiments.
#
# Registration lives in a method, not at the top level: Zeitwerk only loads a
# file when the constant matching its path is referenced, so a file that just
# runs code would never load — and would fail eager-load in production. The
# installer wires `register_all` into a `to_prepare` hook, which also makes
# capability edits reload in development.
module ExampleCapability
  module_function

  def register_all
    Agentkit::Capability.register :example_action do |c|
      c.title       "Ejemplo: hacer algo útil para una cuenta"
      c.description "Reemplazá esto por una capacidad real de tu dominio"
      c.flow        ExampleFlow
      c.inputs      account_id: :integer
      c.tags        :example

  # Only proposed when the prerequisites actually hold.
      c.preconditions { |setup, _ctx| setup.connected?(:example_provider) }

  # 0..1 — how well it fits the operating profile. Learnable from the ledger.
      c.fit ->(setup, subject) { setup.icp_match(subject).first }

      c.cost ->(_inputs) { 0.01 }
      c.risk :reversible          # :reversible | :costly | :irreversible
      c.hitl :propose
      c.cooldown 7 * 86_400   # do not re-propose the same pair for a week
    end
  end
end
