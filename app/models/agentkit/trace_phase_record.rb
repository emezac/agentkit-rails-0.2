# frozen_string_literal: true

module Agentkit
  # One phase of a cognitive run: which memories went in, what scores came out.
  # This is what makes an imagined scenario explainable after the fact.
  class TracePhaseRecord < ApplicationRecord
    self.table_name = "agentkit_trace_phases"

    belongs_to :trace, class_name: "Agentkit::TraceRecord", inverse_of: :phases
  end
end
