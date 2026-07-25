# frozen_string_literal: true

# A domain record, so the flow Coder can be exercised on something that has to
# survive a round trip through a job argument.
class Widget < ApplicationRecord
  include Agentkit::Triggerable

  belongs_to :account
end
