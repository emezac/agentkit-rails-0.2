# frozen_string_literal: true

class DummyFlow < Agentkit::Flow
  input :widget

  step(:prepare)  { |ctx| ctx.input[:widget] }
  parallel :fan, over: [EchoAgent, EchoAgent, EchoAgent], with: ->(ctx) { ctx[:prepare].value.name }
  join :fan, on: :all_complete, timeout: 60
  step(:collect) { |ctx| ctx[:fan].values.sort.join("|") }
end
