# frozen_string_literal: true

require "rails_helper"

RSpec.describe "RAG and Team Memory tenant isolation", :integration do
  it "isolates identically named RAG corpora in ActiveRecord" do
    account_a = account!(name: "RAG tenant A")
    account_b = account!(name: "RAG tenant B")

    with_account(account_a) do
      Agentkit::RAG.index(corpus_name: "shared", source: "alpha confidential handbook")
    end
    with_account(account_b) do
      Agentkit::RAG.index(corpus_name: "shared", source: "beta confidential handbook")
    end

    results_a = with_account(account_a) { Agentkit::RAG.retrieve("confidential", corpus_name: "shared") }
    results_b = with_account(account_b) { Agentkit::RAG.retrieve("confidential", corpus_name: "shared") }

    expect(results_a.map { |row| row["text"] }).to all(include("alpha"))
    expect(results_b.map { |row| row["text"] }).to all(include("beta"))
  end

  it "isolates identically named teams and assets in ActiveRecord" do
    account_a = account!(name: "Team tenant A")
    account_b = account!(name: "Team tenant B")

    team_a = with_account(account_a) { Agentkit::TeamMemory.create_team(name: "Operations") }
    team_b = with_account(account_b) { Agentkit::TeamMemory.create_team(name: "Operations") }
    with_account(account_a) do
      Agentkit::TeamMemory.create_asset(asset_type: "skill", name: "Deploy", team_id: team_a.id)
    end
    with_account(account_b) do
      Agentkit::TeamMemory.create_asset(asset_type: "skill", name: "Deploy", team_id: team_b.id)
    end

    assets_a = with_account(account_a) { Agentkit::TeamMemory.load_assets(team: "Operations") }
    assets_b = with_account(account_b) { Agentkit::TeamMemory.load_assets(team: "Operations") }

    expect(assets_a.map(&:account_id)).to contain_exactly(account_a.id)
    expect(assets_b.map(&:account_id)).to contain_exactly(account_b.id)
  end
end
