# frozen_string_literal: true

require "rails_helper"
require_relative "../support/harness_experience_fixture"

RSpec.describe "Experience library persistence", :integration do
  include HarnessExperienceFixture
  it "reloads JSON snapshots and transitions through the ActiveRecord memory port" do
    context = Agentkit::Context.new(tenant_key: "experience-acme")
    library = Agentkit::Harness::ExperienceLibrary.new(domain: "support", context: context)
    entry = capture(library, experiment_result(context: context))
    library.transition!(entry.id, to: :active, actor: "human:1", reason: "reviewed")
    Agentkit::Memory.reset!
    restored = Agentkit::Harness::ExperienceLibrary.new(domain: "support", context: context)
    expect(restored.find(entry.id).status).to eq("active")
    expect(restored.retrieve(query: "citations").evidence.size).to eq(1)
    expect(Agentkit::Harness::ExperienceLibrary.new(domain: "support", context: Agentkit::Context.new(tenant_key: "other")).entries).to be_empty
  end
end
