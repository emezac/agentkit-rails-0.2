# frozen_string_literal: true

require "rails_helper"

# Gaps #2, #3 and #4 from the totallook pilot. Every defect here passed the unit
# suite because the in-memory stores are more forgiving than Postgres: they
# accept nil in a NOT NULL column, they register steps on the Run for free, and
# they never lose state on restart.
RSpec.describe "ActiveRecord adapters", :integration do
  describe "memory store" do
    it "persists a row and keeps it out of the vector index under :on_promotion" do
      account = account!

      record = with_account(account) do
        Agentkit::Memory.store("consumer 9 warm undertone autumn palette",
                               source_agent: "SkinAgent", tags: %w[skin])
      end

      row = Agentkit::MemoryRecord.find(record.id)
      expect(row.content).to include("warm undertone")
      expect(row.embedding_status).to eq("none")   # stored, not vectorised
      expect(row.embedding).to be_nil
      expect(row.tenant_key).to eq(account.tenant_key)
      expect(row.content_hash).to be_present
    end

    it "retrieves through tsvector with zero provider calls" do
      account = account!
      with_account(account) do
        Agentkit::Memory.store("Acme pays invoices late every quarter", tags: %w[payment])
        Agentkit::Memory.store("Sunrise renewed the annual contract", tags: %w[contract])
      end
      before_calls = fake_llm.embed_count

      results = with_account(account) { Agentkit::Memory.recall("invoices late", mode: :keyword) }

      expect(results.map(&:content).join).to include("Acme")
      expect(fake_llm.embed_count).to eq(before_calls)
    end

    it "writes a real pgvector column and searches it" do
      account = account!
      Agentkit.config.memory.embedding.policy = :immediate

      with_account(account) do
        Agentkit::Memory.store("coral dress spring palette", type: "insight")
      end

      row = Agentkit::MemoryRecord.last
      expect(row.embedding_status).to eq("embedded")
      expect(row.embedding).to be_present

      # Assert the store's contract, not ActiveRecord's raw column: the vector
      # comes back as a Float array whether or not the pgvector OID happens to
      # be registered on this connection.
      expect(Agentkit::Memory.find(row.id).embedding.size).to eq(1536)

      hits = with_account(account) { Agentkit::Memory.recall("coral dress spring palette", mode: :semantic) }
      expect(hits.size).to eq(1)
    ensure
      Agentkit.config.memory.embedding.policy = :on_promotion
    end

    it "excludes imagined scenarios from a normal recall at the SQL level" do
      account = account!
      with_account(account) do
        Agentkit::Memory.store("verified fact about checkout", tags: %w[checkout])
        Agentkit::Memory.store("hypothesis about checkout", ontological_type: "imagined")
      end

      plain   = with_account(account) { Agentkit::Memory.recall("checkout", mode: :keyword) }
      opted   = with_account(account) { Agentkit::Memory.recall("checkout", mode: :keyword, include: :imagined) }

      expect(plain.map(&:ontological_type).uniq).to eq(["real"])
      expect(opted.map(&:ontological_type)).to include("imagined")
    end

    it "supersedes non-destructively and rolls back" do
      account = account!
      sources = with_account(account) { 2.times.map { |i| Agentkit::Memory.store("obs #{i}") } }
      insight = with_account(account) { Agentkit::Memory.store("the insight", type: "insight") }

      Agentkit::Memory.supersede!(sources, by: insight)
      expect(Agentkit::MemoryRecord.where(superseded_by_id: insight.id).count).to eq(2)

      restored = Agentkit::Memory.rollback_supersede!(insight.id)
      expect(restored).to eq(2)
      expect(Agentkit::MemoryRecord.where(superseded_by_id: insight.id).count).to eq(0)
    end
  end

  describe "flow store" do
    # This is the defect the whole async engine rested on: the ActiveRecord
    # store created step rows but never registered them on the in-memory Run,
    # so `run.step(...)`, `children_of` and the fan-out replay all saw nothing.
    it "registers created steps on the Run object, not only in the table" do
      flow = Class.new(Agentkit::Flow) do
        def self.name = "ARSeqFlow"
        step(:one) { 1 }
        step(:two) { |ctx| ctx[:one].value + 1 }
      end

      result = flow.call

      expect(result).to be_ok
      expect(result.run.steps.map(&:step_name)).to eq(%w[one two])
      expect(result.run.step(:two).result).to eq(2)
      expect(Agentkit::RunStepRecord.where(run_id: result.run.id).count).to eq(2)
    end

    # A step that never calls the LLM has no usage; writing nil into a NOT NULL
    # jsonb column is only an error in Postgres.
    it "writes an empty usage hash rather than NULL" do
      flow = Class.new(Agentkit::Flow) do
        def self.name = "ARNoLLMFlow"
        step(:plain) { "no model was called here" }
      end

      expect { flow.call }.not_to raise_error
      expect(Agentkit::RunStepRecord.last.usage).to eq({})
    end

    it "enforces (run_id, step_key) uniqueness in the database" do
      flow = Class.new(Agentkit::Flow) do
        def self.name = "ARUniqueFlow"
        step(:only) { 1 }
      end
      run = flow.call.run

      expect {
        Agentkit::RunStepRecord.create!(run_id: run.id, step_key: "only",
                                        step_name: "only", kind: "step")
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "runs a fan-out through the barrier and reaches zero" do
      account = account!
      widget  = Widget.create!(account: account, name: "w1")

      result = with_account(account) { DummyFlow.call(widget: widget) }

      expect(result).to be_ok
      barrier = Agentkit::RunStepRecord.find_by(run_id: result.run.id, kind: "parallel")
      expect(barrier.pending_count).to eq(0)
      expect(Agentkit::RunStepRecord.where(parent_step_id: barrier.id).count).to eq(3)
      expect(result.value).to eq("echo:w1|echo:w1|echo:w1")
    end

    it "decrements the barrier atomically and refuses a second close" do
      account = account!
      widget  = Widget.create!(account: account, name: "w2")
      run     = with_account(account) { DummyFlow.call(widget: widget) }.run

      barrier = Agentkit::RunStepRecord.find_by(run_id: run.id, kind: "parallel")
      child   = Agentkit::RunStepRecord.where(parent_step_id: barrier.id).first
      store   = Agentkit::Flow.shared_store

      # A redelivered branch job: the row is already completed, so nothing is
      # decremented and the counter cannot go negative.
      remaining = store.close_and_decrement(
        Agentkit::Flow::RunStep.new(id: child.id, status: "completed"), nil, status: "completed"
      )
      expect(remaining).to be_nil
      expect(barrier.reload.pending_count).to eq(0)
    end

    it "round-trips a domain record between steps by reference" do
      account = account!
      widget  = Widget.create!(account: account, name: "coder-check")

      flow = Class.new(Agentkit::Flow) do
        def self.name = "ARCoderFlow"
        input :widget
        step(:emit)    { |ctx| ctx.input[:widget] }
        step(:consume) { |ctx| ctx[:emit].value.name }
      end

      result = flow.call(widget: widget)

      expect(result.value).to eq("coder-check")
      stored = Agentkit::RunStepRecord.find_by(run_id: result.run.id, step_key: "emit")
      # The record travelled as a reference, not as a copy of its attributes.
      expect(stored.output.dig("result", "value")).to include("$record" => "Widget")
    end
  end

  describe "HITL store" do
    # In-process suggestions vanish on restart and two web workers disagree
    # about what is pending — the defect the pilot surfaced.
    it "survives a store instance being replaced (as a restart would)" do
      account = account!
      suggestion = with_account(account) do
        Agentkit::HITL.suggest!(type: "review", title: "Check this",
                                source_agent: "EchoAgent", payload: { "a" => 1 })
      end

      Agentkit::HITL.store = Agentkit::HITL::Stores::ActiveRecordStore.new

      found = Agentkit::HITL.find(suggestion.id)
      expect(found).not_to be_nil
      expect(found.title).to eq("Check this")
      expect(Agentkit::HITL.pending.map(&:id)).to include(suggestion.id)
    end

    it "lets the database assign the id instead of a process-local sequence" do
      account = account!
      s = with_account(account) { Agentkit::HITL.suggest!(type: "review", title: "t", source_agent: "A") }

      expect(s.id).to eq(Agentkit::SuggestionRecord.last.id)
    end

    it "writes a decision through to the ledger table" do
      account = account!
      s = with_account(account) do
        Agentkit::HITL.suggest!(type: "review", title: "t", source_agent: "EchoAgent",
                                payload: { "body" => "original" })
      end

      Agentkit::HITL.approve(s.id, actor: "human:1", final_payload: { "body" => "edited by a human" })

      row = Agentkit::DecisionRecord.last
      expect(row.decision).to eq("edited")
      expect(row.mode).to eq("human")
      expect(row.edit_distance).to be > 0
      expect(Agentkit::SuggestionRecord.find(s.id).status).to eq("executed")
    end

    it "enforces durable idempotency in PostgreSQL" do
      account = account!
      first = with_account(account) do
        Agentkit::HITL.suggest!(type: "review", title: "same", idempotency_key: "durable-1")
      end
      duplicate = with_account(account) do
        Agentkit::HITL.suggest!(type: "review", title: "same", idempotency_key: "durable-1")
      end

      expect(duplicate.id).to eq(first.id)
      expect do
        with_account(account) do
          Agentkit::HITL.suggest!(type: "review", title: "changed", idempotency_key: "durable-1")
        end
      end.to raise_error(Agentkit::IdempotencyConflict)

      index = ActiveRecord::Base.connection.indexes(:agentkit_suggestions)
                          .find { |item| item.name == "idx_agentkit_suggestions_durable_idempotency" }
      expect(index.unique).to be(true)
      expect(index.columns).to eq(%w[tenant_key operation_namespace idempotency_key])
    end

    it "allows only one of two simultaneous approvals", :real_concurrency do
      account = account!
      suggestion = with_account(account) do
        Agentkit::HITL.suggest!(type: "review", title: "race")
      end
      scope = { tenant_key: account.tenant_key, account_id: account.id }
      ready = Queue.new
      start = Queue.new
      outcomes = Queue.new

      threads = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            outcomes << Agentkit::HITL.approve(suggestion.id, actor: "human:#{index}", scope: scope)
          rescue StandardError => e
            outcomes << e
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)
      results = 2.times.map { outcomes.pop }

      expect(results.count { |item| item.is_a?(Agentkit::DecisionConflict) }).to eq(1)
      expect(Agentkit::DecisionRecord.where(suggestion_id: suggestion.id).count).to eq(1)
      expect(Agentkit::SuggestionRecord.find(suggestion.id).status).to eq("executed")
    end

    it "returns one durable response for concurrent idempotent redelivery", :real_concurrency do
      account = account!
      ready = Queue.new
      start = Queue.new
      outcomes = Queue.new

      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            context = Agentkit::Context.new(account: account)
            outcomes << Agentkit::HITL.suggest!(
              type: "review", title: "same request", idempotency_key: "race-key",
              context: context
            )
          rescue StandardError => e
            outcomes << e
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)
      results = 2.times.map { outcomes.pop }

      expect(results).to all(be_a(Agentkit::HITL::Suggestion))
      expect(results.map(&:id).uniq.size).to eq(1)
      expect(Agentkit::SuggestionRecord.where(tenant_key: account.tenant_key,
                                               idempotency_key: "race-key").count).to eq(1)
    end

    it "allows only one winner in an approve/reject race", :real_concurrency do
      account = account!
      suggestion = with_account(account) do
        Agentkit::HITL.suggest!(type: "review", title: "race")
      end
      scope = { tenant_key: account.tenant_key, account_id: account.id }
      ready = Queue.new
      start = Queue.new
      outcomes = Queue.new
      actions = [
        -> { Agentkit::HITL.approve(suggestion.id, actor: "human:approve", scope: scope) },
        -> { Agentkit::HITL.reject(suggestion.id, actor: "human:reject", code: :too_risky, scope: scope) }
      ]

      threads = actions.map do |action|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            outcomes << action.call
          rescue StandardError => e
            outcomes << e
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)
      results = 2.times.map { outcomes.pop }

      expect(results.count { |item| item.is_a?(Agentkit::DecisionConflict) }).to eq(1)
      expect(Agentkit::DecisionRecord.where(suggestion_id: suggestion.id).count).to eq(1)
      expect(Agentkit::SuggestionRecord.find(suggestion.id).status).to be_in(%w[executed rejected])
    end

    it "computes ledger metrics from the table" do
      account = account!
      with_account(account) do
        2.times do
          s = Agentkit::HITL.suggest!(type: "review", title: "t", source_agent: "EchoAgent")
          Agentkit::HITL.approve(s.id, actor: "human:1")
        end
        s = Agentkit::HITL.suggest!(type: "review", title: "t", source_agent: "EchoAgent")
        Agentkit::HITL.reject(s.id, actor: "human:1", code: :not_valuable)
        # An advisory timeout must not count as a validation.
        s2 = Agentkit::HITL.suggest!(type: "review", title: "t", source_agent: "EchoAgent")
        Agentkit::HITL.approve(s2.id, actor: "auto:timeout", mode: "auto")
      end

      ledger = Agentkit::HITL.ledger
      expect(ledger).to be_a(Agentkit::HITL::Stores::ActiveRecordLedger)
      expect(ledger.acceptance_rate(agent: "EchoAgent")).to eq(0.6667)
      expect(ledger.rejection_profile(agent: "EchoAgent")).to eq({ "not_valuable" => 1.0 })
    end

    it "resumes a suspended flow when its gate is approved" do
      run = GatedFlow.perform_later
      expect(Agentkit::RunRecord.find(run.id).status).to eq("waiting_human")

      suggestion = Agentkit::HITL.pending.find { |s| s.gate_key&.include?("approve") }
      expect(suggestion).not_to be_nil

      Agentkit::HITL.approve(suggestion.id, actor: "human:1")
      Agentkit::Flow::Worker.advance(run.run_id)

      expect(Agentkit::RunRecord.find(run.id).status).to eq("completed")
    end
  end

  describe "audit store" do
    it "persists the immutable trail and refuses to update a row" do
      account = account!
      with_account(account) { EchoAgent.new.call("hello") }

      row = Agentkit::AuditRecord.order(:id).last
      expect(row).not_to be_nil
      expect(row.payload).to be_a(Hash)
      expect { row.update!(status: "tampered") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end
end

# Both telemetry backends sit behind one port, so a caller must not be able to
# tell them apart. This pair caught a real defect: the ActiveRecord scope had no
# ORDER BY, so `events(...).last` returned whatever Postgres felt like while the
# in-memory backend preserved insertion order. Unit specs ran on :memory and
# stayed green for months.
RSpec.describe "Telemetry backend equivalence", :integration do
  def emit_sequence(backend)
    Agentkit.config.telemetry.backends = [backend]
    Agentkit::Telemetry.reset!

    5.times { |i| Agentkit::Telemetry.emit("order.probe", dims: { step: i }, measures: { n: i }) }
    Agentkit::Telemetry.flush!
    Agentkit::Telemetry.events(name: "order.probe").map { |e| e.dims[:step].to_i }
  end

  it "returns events in emission order, whichever backend is configured" do
    in_memory = emit_sequence(:memory)
    persisted = emit_sequence(:db)

    expect(in_memory).to eq([0, 1, 2, 3, 4])
    expect(persisted).to eq(in_memory)
  end

  # Asserted on the query rather than on returned rows, deliberately.
  #
  # A small, freshly-inserted table comes back in insertion order anyway, so the
  # sequence assertions above pass with AND without the ORDER BY — they did not
  # catch the original defect and cannot be trusted to catch a regression. An
  # unordered scan is only *permitted* to reorder, and provoking it on demand is
  # not something a spec can do reliably.
  #
  # So the invariant is stated where it is actually decidable: the SQL must ask
  # for an order. Ties matter too — events written in one batch share
  # occurred_at, so the primary key has to break them.
  it "asks the database for an order rather than relying on scan luck" do
    sql = Agentkit::EventRecord.all.order(:occurred_at, :id).to_sql
    generated = Agentkit::Telemetry::Backends::ActiveRecordBackend
                .new.send(:base_scope).to_sql

    expect(generated).to eq(sql)
    expect(generated).to match(/ORDER BY.*occurred_at.*,.*id/i)
  end

  # The obvious way to read "what just happened", and the one the ordering bug
  # silently broke.
  it "agrees on which event is the most recent" do
    expect(emit_sequence(:db).last).to eq(emit_sequence(:memory).last)
  end
end

# Added because a controller called Agentkit::Memory.count and it did not
# exist. Both adapters implement it, so both are checked: the last time a
# method existed on only one of them in spirit, an unordered SQL scope shipped
# for months behind a green in-memory suite.
RSpec.describe "Memory.count across backends", :integration do
  def seed(store)
    Agentkit.config.memory.store = store
    Agentkit::Memory.reset!
    Agentkit::Memory.store_backend.delete_all

    3.times { |i| Agentkit::Memory.store("note #{i}", tags: %w[alpha], type: "observation") }
    2.times { |i| Agentkit::Memory.store("other #{i}", tags: %w[beta], type: "insight") }
  end

  %i[memory active_record].each do |backend|
    context "with the #{backend} store" do
      before { seed(backend) }

      it "counts everything" do
        expect(Agentkit::Memory.count).to eq(5)
      end

      it "honours a scope" do
        expect(Agentkit::Memory.count(types: "insight")).to eq(2)
        expect(Agentkit::Memory.count(tags: %w[alpha])).to eq(3)
      end

      it "agrees with all(...).size" do
        expect(Agentkit::Memory.count).to eq(Agentkit::Memory.all.size)
        expect(Agentkit::Memory.count(types: "insight"))
          .to eq(Agentkit::Memory.all(types: "insight").size)
      end

      # Both stores ignore a key they do not recognise. That is a footgun —
      # count(memory_type: "insight") quietly counts everything — but they are
      # at least consistent about it, and pinning that is what stops one
      # adapter from drifting into raising while the other stays silent.
      it "treats an unknown scope key the same way in both stores" do
        expect(Agentkit::Memory.count(memory_type: "insight")).to eq(5)
      end
    end
  end

  # The reason count exists rather than all(...).size at the call site: one
  # integer must not cost the whole table.
  it "does not load rows to produce a number" do
    seed(:active_record)
    expect(Agentkit::Memory.store_backend).not_to receive(:wrap)

    expect(Agentkit::Memory.count).to eq(5)
  end
end

# The improvement cycle only works if what it finds outlives the process that
# found it. The diagnose cron runs in a worker and the console renders in a web
# process; a finding kept in a class-level array is invisible to the person who
# has to approve it, and gone by the next deploy.
#
# agentkit_findings and agentkit_experiments existed as models and tables with
# nothing writing to them.
RSpec.describe "Factory persistence", :integration do
  before do
    Agentkit::FindingRecord.delete_all
    Agentkit::ExperimentRecord.delete_all
  end

  def a_finding(detector: :cost_spike, subject: "BillingAgent")
    Agentkit::Factory::Finding.new(
      id: SecureRandom.uuid, detector: detector, severity: "high", subject: subject,
      summary: "El costo por sugerencia aceptada se triplicó", evidence: { "ratio" => 3.1 },
      suggested_level: "n1", status: "open", created_at: Time.now
    )
  end

  it "escribe los hallazgos en la base, no en memoria del proceso" do
    Agentkit::Factory.record_finding(a_finding)

    expect(Agentkit::FindingRecord.count).to eq(1)
    expect(Agentkit::Factory.findings.map(&:subject)).to eq(["BillingAgent"])
  end

  # The proof: a second "process" with no in-memory state still sees it.
  it "los ve un proceso que no fue el que los encontró" do
    Agentkit::Factory.record_finding(a_finding)
    Agentkit::Factory.instance_variable_set(:@findings, nil)

    expect(Agentkit::Factory.findings.map(&:subject)).to eq(["BillingAgent"])
  end

  it "guarda la evidencia, que es lo que sostiene la decisión" do
    Agentkit::Factory.record_finding(a_finding)

    expect(Agentkit::Factory.findings.first.evidence).to eq({ ratio: 3.1 })
  end

  describe "resolverlos" do
    it "registra que una persona decidió" do
      Agentkit::Factory.record_finding(a_finding)
      id = Agentkit::FindingRecord.first.id

      Agentkit::Factory.resolve_finding!(id, "accepted")

      expect(Agentkit::FindingRecord.find(id).status).to eq("accepted")
      expect(Agentkit::Factory.findings.first.status).to eq("accepted")
    end

    it "rechaza un estado que no existe en vez de guardarlo" do
      Agentkit::Factory.record_finding(a_finding)
      id = Agentkit::FindingRecord.first.id

      expect { Agentkit::Factory.resolve_finding!(id, "aprobadisimo") }
        .to raise_error(Agentkit::ConfigurationError)
    end
  end

  # The same detector firing every Monday on the same subject is one finding
  # still open, not a new one each week.
  it "no duplica un hallazgo que sigue abierto" do
    Agentkit::Factory.record_finding(a_finding)
    allow(Agentkit::Factory::Detectors).to receive(:run_all).and_return([a_finding])

    Agentkit::Factory.diagnose!

    expect(Agentkit::FindingRecord.count).to eq(1)
  end

  it "vuelve a abrirlo si el anterior ya se resolvió" do
    Agentkit.config.factory.finding_cooldown = 0
    Agentkit::Factory.record_finding(a_finding)
    Agentkit::Factory.resolve_finding!(Agentkit::FindingRecord.first.id, "dismissed")
    allow(Agentkit::Factory::Detectors).to receive(:run_all).and_return([a_finding])

    Agentkit::Factory.diagnose!

    expect(Agentkit::FindingRecord.count).to eq(2)
    expect(Agentkit::FindingRecord.where(status: "open").count).to eq(1)
  end
end
