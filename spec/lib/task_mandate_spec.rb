# frozen_string_literal: true
require "spec_helper"

RSpec.describe Agentkit::TaskMandate do
  let(:context) { Agentkit::Context.new(tenant_key: "team:7", principal: "user:42") }

  after { described_class.authorizer = nil }

  it "requires host authorization to issue and to use an allowed tool" do
    expect { described_class.issue(flow: "ReviewFlow", source: "github", resource: "org/repo",
      thread: "issue:42", policy_version: "v1", context: context) }.to raise_error(Agentkit::PolicyDenied)
    allowed = true
    described_class.authorizer = ->(_data, _phase, _ctx) { allowed }
    mandate = described_class.issue(flow: "ReviewFlow", source: "github", resource: "org/repo",
      thread: "issue:42", policy_version: "v1", context: context, allowed_tools: ["lookup"])
    scoped = context.derive(metadata: { task_mandate: mandate.to_h })
    read = Agentkit::ToolContract.new(name: :lookup, callable: -> { "found" })
    other = Agentkit::ToolContract.new(name: :other, callable: -> { "private" })
    expect(read.invoke(context: scoped).result).to eq("found")
    expect { other.invoke(context: scoped) }.to raise_error(Agentkit::ToolExecutionDenied)
    allowed = false
    expect { read.invoke(context: scoped) }.to raise_error(Agentkit::ToolExecutionDenied)
    described_class.authorizer = ->(*) { raise "policy backend down" }
    expect { read.invoke(context: scoped) }.to raise_error(Agentkit::ToolExecutionDenied)
  end
end
