# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agentkit::Memory::Consolidation, :integration do
  let(:k) { Agentkit::Knowledge }
  let(:account) { Account.create!(name: "Memory", plan: "pro") }
  let(:context) { Agentkit::Context.new(account: account, principal: "agent") }
  let(:reviewer) { Agentkit::Context.new(account: account, principal: "human") }
  let(:base) { Time.now.utc }
  let(:clock) { { now: base } }
  let(:policy) { { rollback: false, read: true } }
  let(:journal) { k::Journal.new(authorize: ->(*) { raise ActiveRecord::Rollback if policy[:rollback]; true }) }
  let(:document) { { reference: "policy/returns", version: "1", kind: "document", content: "Returns require an invoice. No automatic refunds.", observed_at: base.iso8601(6) } }
  let(:loader) { ->(_source, ctx) { document.merge(scope: k::Boundary.scope(ctx)) } }
  let(:authorize) { ->(action, ctx) { action == "read" ? policy[:read] : (!%w[publish revoke].include?(action) || ctx.principal == "human") } }
  let(:options) { { journal: journal, authorize: authorize, loader: loader, verifier: ->(*) { { accepted: true, reasons: [] } }, verifier_version: "1", clock: -> { clock[:now] } } }
  subject(:library) { described_class.new(**options) }
  let(:source) { { id: "returns", reference: document[:reference], version: "1", kind: "document", digest: k.digest(document[:content]), max_age_seconds: 300 } }
  let(:claims) { [{ text: "Returns require an invoice", kind: "assertion", evidence: [{ source_id: "returns", quote: "Returns require an invoice." }] }] }
  let(:proposal) { { id: "draft-1", topic: "returns", sources: [source], claims: claims, context: context } }

  def publish(id = "draft-1", expected = 0)
    library.publish(id: id, expected_revision: expected, reason: "Reviewed against policy", context: reviewer)
  end

  it "keeps proposals separate from independently reviewed, source-linked representations" do
    draft = library.propose(**proposal)
    expect(draft["status"]).to eq("candidate")
    expect(library.current(topic: "returns", context: context)).to be_nil
    active = publish
    expect(active.values_at("status", "revision", "authorizes", "causal_proof")).to eq(["active", 1, false, false])
    expect(library.current(topic: "returns", context: context)).to eq(active)
    expect(library.candidate(id: "draft-1", context: context)["status"]).to eq("candidate")
    expect(library.propose(**proposal)).to eq(draft)
    expect(publish).to eq(active)
  end

  it "rejects invented quotes, duplicate source IDs, and model statements promoted into facts" do
    claims[0][:evidence][0][:quote] = "Refund everything"
    expect { library.propose(**proposal) }.to raise_error(k::InvalidContract, /quote/)
    claims[0][:evidence][0][:quote] = "Returns require an invoice."
    expect { library.propose(**proposal.merge(sources: [source, source])) }.to raise_error(k::InvalidContract, /duplicate/)
    document[:kind] = source[:kind] = "model_output"
    expect { library.propose(**proposal) }.to raise_error(k::InvalidContract, /statements alone/)
    claims[0][:kind] = "reported"
    expect(library.propose(**proposal)["status"]).to eq("candidate")
  end

  it "requires exact source bytes/version/classification, freshness and tenant scope" do
    source
    document[:content] = "Changed"
    expect { library.propose(**proposal) }.to raise_error(k::IntegrityError)
    document[:content] = "Returns require an invoice. No automatic refunds."
    document[:version] = "2"
    expect { library.propose(**proposal) }.to raise_error(k::IntegrityError)
    document[:version] = "1"
    document[:observed_at] = (base + 1).iso8601(6)
    expect { library.propose(**proposal) }.to raise_error(k::IntegrityError)
    wrong = described_class.new(**options.merge(loader: ->(*) { document.merge(scope: "different") }))
    expect { wrong.propose(**proposal) }.to raise_error(k::AccessDenied)
  end

  it "denies unauthorized and self review even if a host policy is too permissive" do
    library.propose(**proposal)
    expect { library.publish(id: "draft-1", expected_revision: 0, reason: "self", context: context) }.to raise_error(k::AccessDenied)
    permissive = described_class.new(**options.merge(authorize: ->(*) { true }))
    expect { permissive.publish(id: "draft-1", expected_revision: 0, reason: "self", context: context) }.to raise_error(k::AccessDenied, /independent/)
  end

  it "gives the verifier full checked source context and persists rejection without replacing a head" do
    library.propose(**proposal)
    verifier = ->(item, _) do
      expect(item.dig("source_contents", "returns", "content")).to eq(document[:content])
      { accepted: false, reasons: ["Missing exception in interpretation"] }
    end
    rejected = described_class.new(**options.merge(verifier: verifier)).publish(id: "draft-1", expected_revision: 0, reason: "check", context: reviewer)
    expect(rejected["status"]).to eq("rejected")
    expect(library.head(topic: "returns", context: context)).to be_nil
  end

  it "fails closed on verifier outages and changed evidence between proposal and publication" do
    library.propose(**proposal)
    failed = described_class.new(**options.merge(verifier: ->(*) { raise "secret key" }))
    verdict = failed.publish(id: "draft-1", expected_revision: 0, reason: "review", context: reviewer)
    expect(verdict["reasons"]).to include("verifier_unavailable:RuntimeError")
    expect(verdict.to_s).not_to include("secret key")
    library.propose(**proposal.merge(id: "draft-2"))
    document[:version] = "2"
    expect(publish("draft-2")["status"]).to eq("rejected")
  end

  it "invalidates on changed content even when the provider reuses its version" do
    library.propose(**proposal)
    original = publish
    document[:content] = "Invoices are no longer required."
    expect(library.current(topic: "returns", context: context)).to be_nil
    expect(library.head(topic: "returns", context: context).values_at("status", "revision")).to eq(["stale", 2])
    expect(library.revision(topic: "returns", number: 1, context: context)).to eq(original)
  end

  it "rechecks freshness and verifier version at retrieval rather than treating a receipt as clearance" do
    library.propose(**proposal)
    publish
    changed = described_class.new(**options.merge(verifier_version: "2"))
    expect(changed.current(topic: "returns", context: context)).to be_nil
    library.propose(**proposal.merge(id: "fresh", topic: "fresh"))
    publish("fresh")
    clock[:now] = base + 301
    expect(library.current(topic: "fresh", context: context)).to be_nil
    expect { changed.publish(id: "draft-1", expected_revision: 0, reason: "check", context: reviewer) }.to raise_error(k::IntegrityError)
  end

  it "applies event-driven invalidation only to affected scoped heads" do
    library.propose(**proposal)
    publish
    changes = library.invalidate(reference: "policy/returns", reason: "policy replaced", context: reviewer)
    expect(changes).to eq([{ "topic" => "returns", "revision" => 2 }])
    expect(library.invalidate(reference: "policy/returns", reason: "retry", context: reviewer)).to be_empty
    expect(library.current(topic: "returns", context: context)).to be_nil
  end

  it "preserves concurrent publication expectations and supports revocation without deleting history" do
    library.propose(**proposal)
    publish
    library.propose(**proposal.merge(id: "draft-2", kind: "wiki"))
    expect { publish("draft-2", 0) }.to raise_error(k::IntegrityError, /revision conflict/)
    expect(publish("draft-2", 1)["revision"]).to eq(2)
    revoked = library.revoke(topic: "returns", expected_revision: 2, reason: "unsafe interpretation", context: reviewer)
    expect(revoked["status"]).to eq("revoked")
    expect(library.current(topic: "returns", context: context)).to be_nil
    expect(library.revision(topic: "returns", number: 1, context: context)["status"]).to eq("active")
  end

  it "enforces account isolation and read revocation before returning memory" do
    library.propose(**proposal)
    publish
    other = Agentkit::Context.new(account: Account.create!(name: "Other"), principal: "human")
    expect(library.candidate(id: "draft-1", context: other)).to be_nil
    expect(library.current(topic: "returns", context: other)).to be_nil
    expect(library.invalidate(reference: "policy/returns", reason: "not mine", context: other)).to be_empty
    policy[:read] = false
    expect { library.current(topic: "returns", context: context) }.to raise_error(k::AccessDenied)
  end

  it "separates historical quote access from fresh source-authorized retrieval" do
    library.propose(**proposal)
    publish
    reader = described_class.new(**options.merge(authorize: ->(action, _) { action == "read" }))
    expect(reader.current(topic: "returns", context: context)["status"]).to eq("active")
    expect { reader.candidate(id: "draft-1", context: context) }.to raise_error(k::AccessDenied)
    expect { reader.head(topic: "returns", context: context) }.to raise_error(k::AccessDenied)
    expect { reader.revision(topic: "returns", number: 1, context: context) }.to raise_error(k::AccessDenied)
    denied_source = described_class.new(**options.merge(loader: ->(*) { raise k::AccessDenied, "source permission revoked" }))
    expect { denied_source.current(topic: "returns", context: context) }.to raise_error(k::AccessDenied)
  end

  it "rolls back publication and its head when the required journal write fails" do
    library.propose(**proposal)
    verifier = ->(*) { policy[:rollback] = true; { accepted: true, reasons: [] } }
    failed = described_class.new(**options.merge(verifier: verifier))
    expect { failed.publish(id: "draft-1", expected_revision: 0, reason: "review", context: reviewer) }.to raise_error(k::IntegrityError)
    policy[:rollback] = false
    expect(library.head(topic: "returns", context: context)).to be_nil
    expect(publish["revision"]).to eq(1)
  end

  it "builds only a bounded pointer index, never truncated claims or automatic instructions" do
    library.propose(**proposal)
    publish
    result = library.compile_index(topics: ["returns"], context: context)
    expect(result[:compilation].fragment).to include("Topic: returns", "untrusted data")
    expect(result[:compilation].fragment).not_to include("Returns require an invoice")
    expect(result[:compilation].fragment.bytesize).to be <= 4096
    small = library.compile_index(topics: ["returns"], context: context, max_bytes: 256)
    expect(small[:omitted_topics]).to eq(["returns"])
    document[:version] = "2"
    expect(library.compile_index(topics: ["returns"], context: context)[:compilation].evidence).to be_empty
  end

  it "serializes two workers publishing to the same expected revision", :real_concurrency do
    library.propose(**proposal)
    library.propose(**proposal.merge(id: "draft-2"))
    reviewer
    start = Queue.new
    workers = %w[draft-1 draft-2].map do |id|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          begin
            publish(id)["status"]
          rescue k::IntegrityError
            "conflict"
          end
        end
      end
    end
    2.times { start << true }
    expect(workers.map(&:value).sort).to eq(%w[active conflict])
    expect(library.head(topic: "returns", context: context)["revision"]).to eq(1)
  end
end
