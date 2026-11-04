# frozen_string_literal: true
require "spec_helper"

RSpec.describe Agentkit::Memory::Continuity do
  let(:account) { Struct.new(:id).new(7) }
  let(:user_a) { Struct.new(:id).new(11) }
  let(:user_b) { Struct.new(:id).new(12) }
  let(:context_a) { Agentkit::Context.new(tenant_key: "team:7", account: account, user: user_a, principal: "user:11") }
  let(:context_b) { Agentkit::Context.new(tenant_key: "team:7", account: account, user: user_b, principal: "user:12") }
  let(:other_tenant) { Agentkit::Context.new(tenant_key: "team:8", user: user_a, principal: "user:11") }

  it "replaces user facts by key without exposing them to another user or tenant" do
    described_class.remember_fact(subject: :user, key: "editor", content: "Uses Vim", context: context_a)
    described_class.remember_fact(subject: :user, key: "editor", content: "Uses Neovim", context: context_a)
    expect(described_class.facts(subject: :user, query: "editor", context: context_a).map(&:content)).to eq(["Uses Neovim"])
    expect(described_class.facts(subject: :user, context: context_b)).to be_empty
    expect(described_class.facts(subject: :user, context: other_tenant)).to be_empty
    expect(embedding_calls).to eq(0)
  end

  it "shares project facts within an account and isolates task notes by principal" do
    described_class.remember_fact(subject: :project, key: "repo", content: "Rails monolith", context: context_a)
    expect(described_class.facts(subject: :project, query: "Rails", context: context_b).map(&:content)).to eq(["Rails monolith"])
    described_class.checkpoint(task_id: "deploy-42", summary: "Run tests", turn: 1,
      transcript_digest: "sha256:one", context: context_a)
    expect(described_class.latest(task_id: "deploy-42", context: context_a).content).to eq("Run tests")
    expect(described_class.latest(task_id: "deploy-42", context: context_b)).to be_nil
  end

  it "refuses task and project reads without an authenticated scope" do
    anonymous = Agentkit::Context.new
    expect { described_class.latest(task_id: "deploy-42", context: anonymous) }
      .to raise_error(Agentkit::ConfigurationError)
    expect { described_class.search_episodes("deploy", context: anonymous) }
      .to raise_error(Agentkit::ConfigurationError)
    expect { described_class.facts(subject: :project, context: anonymous) }
      .to raise_error(Agentkit::ConfigurationError)
  end
end
