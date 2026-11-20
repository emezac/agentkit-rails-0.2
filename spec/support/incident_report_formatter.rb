# frozen_string_literal: true

require "json"

# Export only case identifiers, outcomes and timings. Exception text and
# backtraces belong in the ordinary RSpec output, not in incident reports.
class IncidentReportFormatter
  RSpec::Core::Formatters.register self, :example_finished, :dump_summary

  def initialize(output)
    @output = output
    @examples = []
  end

  def example_finished(notification)
    example = notification.example
    @examples << {
      id: example.metadata[:incident], file: example.metadata[:file_path],
      line: example.metadata[:line_number], status: example.execution_result.status.to_s,
      latency_ms: example.execution_result.run_time.to_f * 1_000
    }
  end

  def dump_summary(summary)
    @output.puts JSON.generate(examples: @examples, errors: summary.errors_outside_of_examples_count)
  end
end
