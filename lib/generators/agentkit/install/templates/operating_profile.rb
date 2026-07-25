# frozen_string_literal: true

# The structured answer to "according to your setup". A proposal may only say
# that if the setup is data it can cite — not prose inside a prompt.
Agentkit::Setup.define do
  field :objective, type: :enum, values: %i[growth retention efficiency], required: true

  field :icp, type: :struct do
    field :sectors,      type: :array
    field :geos,         type: :array
    field :company_size, type: :range
  end

  field :constraints, type: :struct do
    field :budget_monthly_usd, type: :integer
    field :tone,               type: :enum, values: %i[formal cercano tecnico]
    field :forbidden_actions,  type: :array
  end

  field :autonomy,  type: :enum, values: %i[propose_only propose_and_do full],
                    default: :propose_only
  field :connected, type: :array   # capabilities whose credentials are wired up
end
