# frozen_string_literal: true

require "spec_helper"

RSpec.describe Agentkit::SkillExport do
  def skill(name: "review-contract", description: "Reviews a contract: use for red flags, not legal advice.")
    Agentkit::Skill.new(name).tap do |value|
      value.description(description)
      value.version("2.3.0")
      value.prompt("Read the agreement, list risks, then check every citation.")
    end
  end

  it "exports the real routable description and version without calling a model" do
    bundle = described_class.export(skill(description: 'Reviews terms: use for "check this contract"; not tax advice.'))
    frontmatter = YAML.safe_load(bundle.fetch("SKILL.md").split("---", 3).fetch(1))

    expect(frontmatter.fetch("name")).to eq("review-contract")
    expect(frontmatter.fetch("description")).to eq('Reviews terms: use for "check this contract"; not tax advice.')
    expect(frontmatter.dig("metadata", "agentkit-version")).to eq("2.3.0")
    expect(frontmatter.dig("metadata", "agentkit-schema-version")).to eq("1")
    expect(frontmatter.keys).to match_array(%w[name description metadata])
    expect(fake_llm.call_count).to eq(0)
  end

  it "rejects names or descriptions that cannot form a portable skill" do
    expect { described_class.validate!(skill(name: "Review_Contract")) }
      .to raise_error(Agentkit::ConfigurationError, /name/)
    expect { described_class.validate!(skill(name: "review--contract")) }
      .to raise_error(Agentkit::ConfigurationError, /name/)
    expect { described_class.validate!(skill(description: " ")) }
      .to raise_error(Agentkit::ConfigurationError, /description/)
    expect { described_class.validate!(skill(description: "a" * 1_025)) }
      .to raise_error(Agentkit::ConfigurationError, /description/)
  end

  it "rejects imported frontmatter without a routable description before storing anything" do
    bundle = described_class.export(skill)
    bundle["SKILL.md"] = bundle.fetch("SKILL.md").sub(/^description:.*\n/, "")

    expect { described_class.import(bundle) }
      .to raise_error(Agentkit::ConfigurationError, /description/)
    expect(fake_llm.call_count).to eq(0)
  end
end
