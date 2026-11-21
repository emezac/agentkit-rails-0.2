# frozen_string_literal: true

module Agentkit
  module Harness
    module Organization
      # Immutable onboarding contract for designing an agent team before any
      # agent is instantiated. It records bounded references, digests, budgets
      # and review gates; it never executes, grants authority or activates a
      # topology.
      class TeamBlueprint
        SCHEMA_VERSION = 1
        MAX_AGENTS = MAX_MEMBERS + 1
        MAX_TOOLS = 64
        MAX_STEPS = 64
        MAX_DEFERRED_USE_CASES = 16
        MAX_LIST_ENTRIES = 64
        MAX_DELEGATION_DEPTH = 8
        MAX_MODEL_CALLS = 1_024
        MAX_SUBCALLS = 256
        MAX_SCHEMA_DEPTH = 8
        RISKS = %w[read reversible sensitive irreversible privileged].freeze
        EFFECTS = %w[read_only internal external].freeze
        SEPARATION_REASONS = %w[
          baseline user_interface specialized_capability permission_boundary
          independent_verification context_isolation parallel_latency
        ].freeze
        WORKFLOW_KINDS = %w[intake work verification assembly human_gate decision].freeze
        FAILURE_POLICIES = %w[return_to_coordinator human_attention stop].freeze
        LAUNCH_KINDS_WITH_CANDIDATE = %w[
          contracts fixtures baseline candidate holdout review pilot_decision
        ].freeze
        LAUNCH_KINDS_BASELINE_ONLY = %w[
          contracts fixtures baseline candidate_decision holdout review pilot_decision
        ].freeze
        QUESTIONS = [
          { "id" => "business_domain", "answer" => "bounded_identifier" },
          { "id" => "desired_outcome", "answer" => "bounded_identifier" },
          { "id" => "operator_strengths", "answer" => "bounded_identifier_list" },
          { "id" => "weekly_hours", "answer" => "number_0_to_168" },
          { "id" => "first_delegation", "answer" => "bounded_identifier" }
        ].map { |entry| entry.freeze }.freeze

        attr_reader :id, :version, :intake, :goal, :selected_use_case,
                    :deferred_use_cases, :workload, :baseline, :candidate,
                    :agents, :tools, :handoffs, :workflow, :quality, :budget,
                    :launch_plan, :output_contract, :metadata

        def initialize(id:, intake:, goal:, selected_use_case:, workload:, baseline:,
                       agents:, workflow:, quality:, budget:, launch_plan:,
                       output_contract:, version: "1", candidate: nil,
                       deferred_use_cases: [], tools: [], handoffs: [], metadata: {})
          @id = Organization.identifier!(id, "team blueprint id").freeze
          @version = Organization.identifier!(version, "team blueprint version").freeze
          @intake = normalize_intake(intake)
          @goal = contract!(goal, Goal, "goal")
          @selected_use_case = normalize_use_case(selected_use_case)
          @deferred_use_cases = normalize_deferred_use_cases(deferred_use_cases)
          @workload = contract!(workload, WorkloadContract, "workload")
          @baseline = contract!(baseline, Topology, "baseline")
          @candidate = candidate && contract!(candidate, Topology, "candidate")
          @agents = normalize_agents(agents)
          @tools = normalize_tools(tools)
          @handoffs = normalize_handoffs(handoffs)
          @workflow = normalize_workflow(workflow)
          @quality = normalize_quality(quality)
          @budget = normalize_budget(budget)
          @launch_plan = normalize_launch_plan(launch_plan)
          @output_contract = normalize_output_contract(output_contract)
          @metadata = normalize_metadata(metadata)
          validate!
          validate_size!
          freeze
        end

        def self.questions = QUESTIONS

        def status = candidate ? "ready_for_evaluation" : "baseline_ready"
        def ready_for_evaluation? = !candidate.nil?
        def authorizes? = false
        def auto_activates? = false
        def requires_review? = true
        def baseline_required? = true
        def holdout_required? = true
        def digest = Harness.digest(to_h)

        def to_h
          Harness.deep_freeze(
            "schema_version" => SCHEMA_VERSION,
            "kind" => "organization_team_blueprint",
            "id" => id,
            "version" => version,
            "intake" => intake,
            "goal" => goal.to_h,
            "selected_use_case" => selected_use_case,
            "deferred_use_cases" => deferred_use_cases,
            "workload" => workload.to_h,
            "baseline" => baseline.to_h,
            "candidate" => candidate&.to_h,
            "agents" => agents,
            "tools" => tools,
            "handoffs" => handoffs,
            "workflow" => workflow,
            "quality" => quality,
            "budget" => budget,
            "launch_plan" => launch_plan,
            "output_contract" => output_contract,
            "metadata" => metadata,
            "status" => status,
            "authorizes" => authorizes?,
            "auto_activates" => auto_activates?,
            "requires_review" => requires_review?,
            "baseline_required" => baseline_required?,
            "holdout_required" => holdout_required?
          )
        end

        # Produces a declarative candidate only. No executable adapter, Agent,
        # Flow, AgentTool, TaskMandate or Capability crosses this boundary.
        def to_manifest(topology:)
          selected_topology, topology_name = manifest_topology!(topology)
          selected_names = member_names(selected_topology)
          selected_agents = agents.select do |agent|
            selected_names.include?(agent.fetch("agent"))
          end
          selected_tools = tools.filter_map do |tool|
            owners = tool.fetch("owners") & selected_names
            tool.merge("owners" => owners) if owners.any?
          end
          components = selected_agents.map do |agent|
            Component.new(
              name: "agent/#{agent.fetch('agent')}", type: :subagent,
              configuration: agent,
              activation: { "mode" => "host_only", "authorizes" => false },
              metadata: { "blueprint_digest" => digest }
            )
          end
          components.concat(selected_tools.map do |tool|
            Component.new(
              name: "tool/#{tool.fetch('name')}", type: :tool_guidance,
              configuration: tool,
              activation: { "mode" => "host_only", "authorizes" => false },
              risk: manifest_risk(tool.fetch("risk")), effect: tool.fetch("effect"),
              metadata: { "blueprint_digest" => digest }
            )
          end)
          components << Component.new(
            name: "team-blueprint/#{id}", type: :guardrail,
            configuration: {
              "goal_digest" => goal.digest,
              "workload_digest" => workload.digest,
              "topology" => topology_name,
              "topology_digest" => selected_topology.digest,
              "quality_digest" => Harness.digest(quality),
              "budget" => budget,
              "authorizes" => false,
              "auto_activates" => false,
              "requires_review" => true
            }.compact,
            activation: { "mode" => "host_only", "authorizes" => false },
            metadata: { "blueprint_digest" => digest }
          )
          Manifest.new(
            id: "#{id}-#{topology_name}-manifest", version: version,
            components: components.sort_by(&:key), output_contract: output_contract,
            metadata: {
              "kind" => "organization_team_blueprint",
              "blueprint_digest" => digest,
              "topology" => topology_name,
              "topology_digest" => selected_topology.digest,
              "authorizes" => false,
              "auto_activates" => false,
              "requires_review" => true
            }
          )
        end

        def to_manifests
          result = { "baseline" => to_manifest(topology: :baseline) }
          result["candidate"] = to_manifest(topology: :candidate) if candidate
          result.freeze
        end

        def self.from_h(value)
          data = strict_serialized_object(value)
          blueprint = new(
            id: data.fetch("id"), version: data.fetch("version"),
            intake: data.fetch("intake"), goal: build_goal(data.fetch("goal")),
            selected_use_case: data.fetch("selected_use_case"),
            deferred_use_cases: data.fetch("deferred_use_cases"),
            workload: build_workload(data.fetch("workload")),
            baseline: build_topology(data.fetch("baseline"), "baseline"),
            candidate: data["candidate"] && build_topology(data.fetch("candidate"), "candidate"),
            agents: data.fetch("agents"), tools: data.fetch("tools"),
            handoffs: data.fetch("handoffs"), workflow: data.fetch("workflow"),
            quality: data.fetch("quality"), budget: data.fetch("budget"),
            launch_plan: data.fetch("launch_plan"),
            output_contract: data.fetch("output_contract"), metadata: data.fetch("metadata")
          )
          expected = {
            "kind" => "organization_team_blueprint", "status" => blueprint.status,
            "authorizes" => false, "auto_activates" => false,
            "requires_review" => true, "baseline_required" => true,
            "holdout_required" => true
          }
          unless expected.all? { |key, expected_value| data.fetch(key) == expected_value }
            raise HarnessExperimentError, "team blueprint safety flags are invalid"
          end
          blueprint
        rescue KeyError => error
          raise HarnessExperimentError, "team blueprint is missing #{error.key}"
        end

        class << self
          private

          def strict_serialized_object(value)
            data = Organization.json_hash!(value, "team blueprint")
            required = %w[
              schema_version kind id version intake goal selected_use_case
              deferred_use_cases workload baseline candidate agents tools handoffs
              workflow quality budget launch_plan output_contract metadata status
              authorizes auto_activates requires_review baseline_required holdout_required
            ]
            strict_keys!(data, required, [], "team blueprint")
            unless data.fetch("schema_version") == SCHEMA_VERSION
              raise HarnessExperimentError, "unsupported team blueprint schema version"
            end
            data
          end

          def build_goal(value)
            data = Organization.json_hash!(value, "team blueprint goal")
            strict_keys!(data,
              %w[id objective criteria constraints scope protected_resources
                 required_approvals required_outputs max_steps metadata],
              ["require_verification"], "team blueprint goal")
            Goal.from_h(data)
          end

          def build_workload(value)
            data = Organization.json_hash!(value, "team blueprint workload")
            strict_keys!(data,
              %w[schema_version id capabilities required_checks bounds metadata], [],
              "team blueprint workload")
            unless data.fetch("schema_version") == 1
              raise HarnessExperimentError, "unsupported workload schema version"
            end
            bounds = Organization.json_hash!(data.fetch("bounds"), "workload bounds")
            strict_keys!(bounds,
              %w[max_agents max_cost_usd max_latency_ms max_human_minutes minimum_samples], [],
              "workload bounds")
            WorkloadContract.new(
              id: data.fetch("id"), capabilities: data.fetch("capabilities"),
              required_checks: data.fetch("required_checks"),
              max_agents: bounds.fetch("max_agents"),
              max_cost_usd: bounds.fetch("max_cost_usd"),
              max_latency_ms: bounds.fetch("max_latency_ms"),
              max_human_minutes: bounds.fetch("max_human_minutes"),
              minimum_samples: bounds.fetch("minimum_samples"),
              metadata: data.fetch("metadata")
            )
          end

          def build_topology(value, label)
            data = Organization.json_hash!(value, "team blueprint #{label}")
            strict_keys!(data, %w[schema_version id pattern members edges metadata], [],
              "team blueprint #{label}")
            unless data.fetch("schema_version") == 1
              raise HarnessExperimentError, "unsupported topology schema version"
            end
            unless data.fetch("members").is_a?(Array) && data.fetch("edges").is_a?(Array)
              raise HarnessExperimentError,
                "team blueprint #{label} members and edges must be arrays"
            end
            members = data.fetch("members").map do |member|
              row = Organization.json_hash!(member, "#{label} member")
              strict_keys!(row,
                %w[agent role capabilities independent_context permission_boundary],
                %w[model_profile toolset_digest skills_digest policy_digest], "#{label} member")
              row
            end
            edges = data.fetch("edges").map do |edge|
              row = Organization.json_hash!(edge, "#{label} edge")
              strict_keys!(row, %w[from to kind], [], "#{label} edge")
              row
            end
            Topology.new(id: data.fetch("id"), pattern: data.fetch("pattern"),
              members: members, edges: edges, metadata: data.fetch("metadata"))
          end

          def strict_keys!(data, required, optional, label)
            missing = required - data.keys
            unknown = data.keys - required - optional
            raise HarnessExperimentError, "#{label} is missing #{missing.join(', ')}" if missing.any?
            raise HarnessExperimentError, "#{label} has unknown fields: #{unknown.join(', ')}" if unknown.any?

            data
          end
        end

        private

        def normalize_intake(value)
          data = strict_object(value,
            %w[business_domain desired_outcome operator_strengths weekly_hours first_delegation],
            [], "team blueprint intake")
          Harness.deep_freeze(
            "business_domain" => Organization.identifier!(data.fetch("business_domain"), "business domain"),
            "desired_outcome" => Organization.identifier!(data.fetch("desired_outcome"), "desired outcome"),
            "operator_strengths" => identifiers(data.fetch("operator_strengths"),
              "operator strength", minimum: 1),
            "weekly_hours" => Organization.number!(data.fetch("weekly_hours"),
              "weekly hours", maximum: 168.0),
            "first_delegation" => Organization.identifier!(data.fetch("first_delegation"),
              "first delegation")
          )
        rescue KeyError => error
          raise HarnessExperimentError, "team blueprint intake is missing #{error.key}"
        end

        def normalize_use_case(value)
          data = strict_object(value,
            %w[id objective rationale first_metric expected_hours_saved evidence_digest capabilities],
            [], "selected use case")
          Harness.deep_freeze(
            "id" => Organization.identifier!(data.fetch("id"), "use case id"),
            "objective" => Organization.identifier!(data.fetch("objective"), "use case objective"),
            "rationale" => Organization.identifier!(data.fetch("rationale"), "use case rationale"),
            "first_metric" => Organization.identifier!(data.fetch("first_metric"), "use case metric"),
            "expected_hours_saved" => Organization.number!(data.fetch("expected_hours_saved"),
              "expected hours saved", maximum: intake.fetch("weekly_hours")),
            "evidence_digest" => Organization.digest!(data.fetch("evidence_digest"),
              "use case evidence"),
            "capabilities" => identifiers(data.fetch("capabilities"),
              "use case capability", minimum: 1)
          )
        rescue KeyError => error
          raise HarnessExperimentError, "selected use case is missing #{error.key}"
        end

        def normalize_deferred_use_cases(values)
          list = Array(values)
          raise HarnessExperimentError, "deferred use cases exceed bound" if list.size > MAX_DEFERRED_USE_CASES

          normalized = list.map do |value|
            data = strict_object(value, %w[id reason], [], "deferred use case")
            {
              "id" => Organization.identifier!(data.fetch("id"), "deferred use case id"),
              "reason" => Organization.identifier!(data.fetch("reason"), "deferred use case reason")
            }
          rescue KeyError => error
            raise HarnessExperimentError, "deferred use case is missing #{error.key}"
          end.sort_by { |entry| entry.fetch("id") }
          duplicate!(normalized.map { |entry| entry.fetch("id") }, "deferred use case ids")
          Harness.deep_freeze(normalized)
        end

        def normalize_agents(values)
          list = Array(values)
          unless list.size.between?(1, MAX_AGENTS)
            raise HarnessExperimentError, "team blueprint requires 1..#{MAX_AGENTS} agent contracts"
          end
          normalized = list.map do |value|
            data = strict_object(value,
              %w[agent responsibility purpose does_not input_schema_digest output_schema_digest
                 done_checks tools prompt_reference prompt_digest separation_reason],
              [], "agent contract")
            reason = data.fetch("separation_reason").to_s
            raise HarnessExperimentError, "unknown agent separation reason" unless SEPARATION_REASONS.include?(reason)
            {
              "agent" => Organization.identifier!(data.fetch("agent"), "agent contract name"),
              "responsibility" => Organization.identifier!(data.fetch("responsibility"), "agent responsibility"),
              "purpose" => Organization.identifier!(data.fetch("purpose"), "agent purpose"),
              "does_not" => identifiers(data.fetch("does_not"), "agent exclusion"),
              "input_schema_digest" => Organization.digest!(data.fetch("input_schema_digest"),
                "agent input schema"),
              "output_schema_digest" => Organization.digest!(data.fetch("output_schema_digest"),
                "agent output schema"),
              "done_checks" => identifiers(data.fetch("done_checks"), "agent done check"),
              "tools" => identifiers(data.fetch("tools"), "agent tool"),
              "prompt_reference" => Organization.identifier!(data.fetch("prompt_reference"),
                "agent prompt reference"),
              "prompt_digest" => Organization.digest!(data.fetch("prompt_digest"), "agent prompt"),
              "separation_reason" => reason
            }
          rescue KeyError => error
            raise HarnessExperimentError, "agent contract is missing #{error.key}"
          end.sort_by { |entry| entry.fetch("agent") }
          duplicate!(normalized.map { |entry| entry.fetch("agent") }, "agent contract names")
          duplicate!(normalized.map { |entry| entry.fetch("responsibility") }, "agent responsibilities")
          Harness.deep_freeze(normalized)
        end

        def normalize_tools(values)
          list = Array(values)
          raise HarnessExperimentError, "team blueprint tools exceed bound" if list.size > MAX_TOOLS

          normalized = list.map do |value|
            data = strict_object(value,
              %w[name purpose owners effect risk contract_digest approval_gate], [],
              "tool declaration")
            effect = data.fetch("effect").to_s
            risk = data.fetch("risk").to_s
            raise HarnessExperimentError, "unknown tool effect" unless EFFECTS.include?(effect)
            raise HarnessExperimentError, "unknown tool risk" unless RISKS.include?(risk)
            {
              "name" => Organization.identifier!(data.fetch("name"), "tool name"),
              "purpose" => Organization.identifier!(data.fetch("purpose"), "tool purpose"),
              "owners" => identifiers(data.fetch("owners"), "tool owner", minimum: 1),
              "effect" => effect,
              "risk" => risk,
              "contract_digest" => Organization.digest!(data.fetch("contract_digest"),
                "tool contract"),
              "approval_gate" => data["approval_gate"] &&
                Organization.identifier!(data.fetch("approval_gate"), "tool approval gate")
            }
          rescue KeyError => error
            raise HarnessExperimentError, "tool declaration is missing #{error.key}"
          end.sort_by { |entry| entry.fetch("name") }
          duplicate!(normalized.map { |entry| entry.fetch("name") }, "tool names")
          Harness.deep_freeze(normalized)
        end

        def normalize_handoffs(values)
          list = Array(values)
          raise HarnessExperimentError, "team blueprint handoffs exceed bound" if list.size > MAX_EDGES

          normalized = list.map do |value|
            data = strict_object(value,
              %w[from to kind contract_digest required_checks on_failure], [],
              "handoff contract")
            policy = data.fetch("on_failure").to_s
            raise HarnessExperimentError, "unknown handoff failure policy" unless FAILURE_POLICIES.include?(policy)
            kind = data.fetch("kind").to_s
            raise HarnessExperimentError, "unknown handoff kind" unless EDGE_KINDS.include?(kind)
            {
              "from" => Organization.identifier!(data.fetch("from"), "handoff source"),
              "to" => Organization.identifier!(data.fetch("to"), "handoff target"),
              "kind" => kind,
              "contract_digest" => Organization.digest!(data.fetch("contract_digest"),
                "handoff contract"),
              "required_checks" => identifiers(data.fetch("required_checks"), "handoff check"),
              "on_failure" => policy
            }
          rescue KeyError => error
            raise HarnessExperimentError, "handoff contract is missing #{error.key}"
          end.sort_by { |entry| [entry.fetch("from"), entry.fetch("to"), entry.fetch("kind")] }
          duplicate!(normalized.map { |entry| entry.values_at("from", "to", "kind") }, "handoffs")
          Harness.deep_freeze(normalized)
        end

        def normalize_workflow(values)
          list = Array(values)
          unless list.size.between?(1, MAX_STEPS)
            raise HarnessExperimentError, "team blueprint workflow requires 1..#{MAX_STEPS} steps"
          end
          normalized = list.map do |value|
            data = strict_object(value,
              %w[id owner kind depends_on done_checks effect approval_gate], [],
              "workflow step")
            kind = data.fetch("kind").to_s
            effect = data.fetch("effect").to_s
            raise HarnessExperimentError, "unknown workflow kind" unless WORKFLOW_KINDS.include?(kind)
            raise HarnessExperimentError, "unknown workflow effect" unless EFFECTS.include?(effect)
            {
              "id" => Organization.identifier!(data.fetch("id"), "workflow step id"),
              "owner" => Organization.identifier!(data.fetch("owner"), "workflow owner"),
              "kind" => kind,
              "depends_on" => identifiers(data.fetch("depends_on"), "workflow dependency"),
              "done_checks" => identifiers(data.fetch("done_checks"), "workflow done check"),
              "effect" => effect,
              "approval_gate" => data["approval_gate"] &&
                Organization.identifier!(data.fetch("approval_gate"), "workflow approval gate")
            }
          rescue KeyError => error
            raise HarnessExperimentError, "workflow step is missing #{error.key}"
          end.sort_by { |entry| entry.fetch("id") }
          duplicate!(normalized.map { |entry| entry.fetch("id") }, "workflow step ids")
          Harness.deep_freeze(normalized)
        end

        def normalize_quality(value)
          data = strict_object(value,
            %w[required_checks minimum_success_rate verifier external_gate training_set_digest
               holdout_set_digest grader_digest human_review rollback_required], [],
            "quality contract")
          Harness.deep_freeze(
            "required_checks" => identifiers(data.fetch("required_checks"),
              "quality check", minimum: 1),
            "minimum_success_rate" => positive_rate!(data.fetch("minimum_success_rate")),
            "verifier" => data["verifier"] &&
              Organization.identifier!(data.fetch("verifier"), "quality verifier"),
            "external_gate" => data["external_gate"] &&
              Organization.identifier!(data.fetch("external_gate"), "external quality gate"),
            "training_set_digest" => Organization.digest!(data.fetch("training_set_digest"),
              "training set"),
            "holdout_set_digest" => Organization.digest!(data.fetch("holdout_set_digest"),
              "holdout set"),
            "grader_digest" => Organization.digest!(data.fetch("grader_digest"), "grader"),
            "human_review" => Organization.boolean!(data.fetch("human_review"),
              "quality human review"),
            "rollback_required" => Organization.boolean!(data.fetch("rollback_required"),
              "quality rollback requirement")
          )
        rescue KeyError => error
          raise HarnessExperimentError, "quality contract is missing #{error.key}"
        end

        def normalize_budget(value)
          data = strict_object(value,
            %w[max_turns max_model_calls max_subcalls max_delegation_depth max_cost_usd
               max_latency_ms max_human_minutes], [], "team budget")
          Harness.deep_freeze(
            "max_turns" => Organization.integer!(data.fetch("max_turns"),
              "max turns", minimum: 1),
            "max_model_calls" => Organization.integer!(data.fetch("max_model_calls"),
              "max model calls", minimum: 1, maximum: MAX_MODEL_CALLS),
            "max_subcalls" => Organization.integer!(data.fetch("max_subcalls"),
              "max subcalls", minimum: 0, maximum: MAX_SUBCALLS),
            "max_delegation_depth" => Organization.integer!(data.fetch("max_delegation_depth"),
              "max delegation depth", minimum: 0, maximum: MAX_DELEGATION_DEPTH),
            "max_cost_usd" => Organization.number!(data.fetch("max_cost_usd"), "team max cost"),
            "max_latency_ms" => Organization.number!(data.fetch("max_latency_ms"),
              "team max latency"),
            "max_human_minutes" => Organization.number!(data.fetch("max_human_minutes"),
              "team max human minutes")
          )
        rescue KeyError => error
          raise HarnessExperimentError, "team budget is missing #{error.key}"
        end

        def normalize_launch_plan(values)
          list = Array(values)
          unless list.size == 7
            raise HarnessExperimentError, "team launch plan requires exactly seven days"
          end
          normalized = list.map do |value|
            data = strict_object(value,
              %w[day kind owner deliverable_reference deliverable_digest requires_approval],
              [], "launch plan day")
            {
              "day" => Organization.integer!(data.fetch("day"), "launch day",
                minimum: 1, maximum: 7),
              "kind" => data.fetch("kind").to_s,
              "owner" => Organization.identifier!(data.fetch("owner"), "launch owner"),
              "deliverable_reference" => Organization.identifier!(
                data.fetch("deliverable_reference"), "launch deliverable reference"
              ),
              "deliverable_digest" => Organization.digest!(data.fetch("deliverable_digest"),
                "launch deliverable"),
              "requires_approval" => Organization.boolean!(data.fetch("requires_approval"),
                "launch approval requirement")
            }
          rescue KeyError => error
            raise HarnessExperimentError, "launch plan day is missing #{error.key}"
          end.sort_by { |entry| entry.fetch("day") }
          Harness.deep_freeze(normalized)
        end

        def normalize_output_contract(value)
          data = Organization.json_hash!(value, "team output contract")
          unless data["type"] == "object"
            raise HarnessExperimentError,
              "team output contract must be a closed JSON object schema"
          end
          validate_schema_node!(data, path: "output", depth: 0)
          Harness.deep_freeze(data)
        end

        def validate_schema_node!(schema, path:, depth:)
          unless schema.is_a?(Hash) && depth <= MAX_SCHEMA_DEPTH
            raise HarnessExperimentError, "#{path} schema is invalid or too deep"
          end
          type = schema["type"]
          unless type.is_a?(String) && Schema::TYPE_CLASSES.key?(type)
            raise HarnessExperimentError, "#{path} schema type is invalid"
          end
          allowed = case type
                    when "object" then %w[type properties required additionalProperties enum]
                    when "array" then %w[type items enum]
                    else %w[type enum]
                    end
          unknown = schema.keys - allowed
          raise HarnessExperimentError, "#{path} schema has unknown fields" if unknown.any?
          validate_schema_enum!(schema, path)
          case type
          when "object"
            validate_object_schema!(schema, path: path, depth: depth)
          when "array"
            unless schema["items"].is_a?(Hash)
              raise HarnessExperimentError, "#{path} array schema requires items"
            end
            validate_schema_node!(schema.fetch("items"), path: "#{path}[]", depth: depth + 1)
          end
        end

        def validate_object_schema!(schema, path:, depth:)
          properties = schema["properties"]
          unless properties.is_a?(Hash) && properties.size <= MAX_LIST_ENTRIES &&
                 schema["additionalProperties"] == false
            raise HarnessExperimentError, "#{path} schema must be a bounded closed object"
          end
          required = schema.fetch("required", [])
          unless required.is_a?(Array) && required.uniq.size == required.size &&
                 required.all? { |name| name.is_a?(String) && properties.key?(name) }
            raise HarnessExperimentError, "#{path} schema required fields are invalid"
          end
          properties.each do |name, child|
            Organization.identifier!(name, "output property")
            validate_schema_node!(child, path: "#{path}.#{name}", depth: depth + 1)
          end
        end

        def validate_schema_enum!(schema, path)
          return unless schema.key?("enum")

          values = schema.fetch("enum")
          unless values.is_a?(Array) && values.size.between?(1, MAX_LIST_ENTRIES) &&
                 values.uniq.size == values.size
            raise HarnessExperimentError, "#{path} schema enum is invalid"
          end
        end

        def normalize_metadata(value)
          data = strict_object(value, [], %w[source_reference source_digest labels],
            "team blueprint metadata")
          result = {}
          if data["source_reference"]
            result["source_reference"] = Organization.identifier!(
              data.fetch("source_reference"), "team blueprint source reference"
            )
          end
          if data["source_digest"]
            result["source_digest"] = Organization.digest!(
              data.fetch("source_digest"), "team blueprint source"
            )
          end
          if data.key?("labels")
            result["labels"] = identifiers(data.fetch("labels"),
              "team blueprint label")
          end
          Harness.deep_freeze(result)
        end

        def validate!
          validate_use_case!
          validate_embedded_reference_data!
          validate_topologies!
          validate_agent_contracts!
          validate_tools!
          validate_handoffs!
          validate_workflow!
          validate_quality!
          validate_budget!
          validate_launch_plan!
        end

        def validate_embedded_reference_data!
          {
            "goal scope" => goal.scope,
            "goal metadata" => goal.metadata,
            "workload metadata" => workload.metadata,
            "baseline metadata" => baseline.metadata,
            "candidate metadata" => candidate&.metadata
          }.each do |label, value|
            validate_reference_data!(value, label: label, depth: 0) if value
          end
        end

        def validate_reference_data!(value, label:, depth:)
          if depth > MAX_SCHEMA_DEPTH
            raise HarnessExperimentError, "#{label} exceeds reference depth"
          end
          case value
          when Hash
            raise HarnessExperimentError, "#{label} exceeds reference bound" if value.size > MAX_LIST_ENTRIES
            value.each do |key, item|
              Organization.identifier!(key, "#{label} key")
              validate_reference_data!(item, label: label, depth: depth + 1)
            end
          when Array
            raise HarnessExperimentError, "#{label} exceeds reference bound" if value.size > MAX_LIST_ENTRIES
            value.each { |item| validate_reference_data!(item, label: label, depth: depth + 1) }
          when String, Symbol
            Organization.identifier!(value, label)
          when Integer, TrueClass, FalseClass, NilClass
            true
          when Float
            raise HarnessExperimentError, "#{label} must be finite" unless value.finite?
          else
            raise HarnessExperimentError,
              "#{label} must contain only bounded references and scalar values"
          end
        end

        def validate_use_case!
          unless selected_use_case.fetch("capabilities") == workload.capabilities
            raise HarnessExperimentError,
              "selected use case capabilities must match the workload"
          end
          ids = deferred_use_cases.map { |entry| entry.fetch("id") }
          if ids.include?(selected_use_case.fetch("id"))
            raise HarnessExperimentError, "selected use case cannot also be deferred"
          end
        end

        def validate_topologies!
          unless baseline.pattern == "single" && baseline.size == 1 && baseline.edges.empty?
            raise HarnessExperimentError,
              "team blueprint baseline must be a single agent without edges"
          end
          validate_member_roles!(baseline, "baseline")
          require_capability_coverage!(baseline, "baseline")
          return unless candidate

          if Harness.secure_equal?(candidate.digest, baseline.digest) || candidate.size < 2
            raise HarnessExperimentError,
              "team candidate must be a distinct multi-agent topology"
          end
          if candidate.pattern == "single"
            raise HarnessExperimentError,
              "multi-agent candidate cannot use the single topology pattern"
          end
          if candidate.size > workload.max_agents
            raise HarnessExperimentError, "team candidate exceeds workload max agents"
          end
          validate_member_roles!(candidate, "candidate")
          require_capability_coverage!(candidate, "candidate")
          coordinators = candidate.members.count do |member|
            member.fetch("role") == "coordinator"
          end
          unless coordinators == 1
            raise HarnessExperimentError, "team candidate requires exactly one coordinator"
          end
        end

        def validate_member_roles!(topology, label)
          invalid = topology.members.select do |member|
            %w[human tool unknown].include?(member.fetch("role"))
          end
          raise HarnessExperimentError, "#{label} contains non-agent members" if invalid.any?
        end

        def require_capability_coverage!(topology, label)
          declared = topology.members.flat_map { |member| member.fetch("capabilities") }.uniq
          missing = workload.capabilities - declared
          if missing.any?
            raise HarnessExperimentError,
              "#{label} is missing workload capabilities: #{missing.join(', ')}"
          end
        end

        def validate_agent_contracts!
          expected = (member_names(baseline) + (candidate ? member_names(candidate) : [])).uniq.sort
          actual = agents.map { |agent| agent.fetch("agent") }
          unless actual == expected
            raise HarnessExperimentError,
              "agent contracts must exactly match baseline and candidate members"
          end
          baseline_name = member_names(baseline).first
          agents.each do |agent|
            name = agent.fetch("agent")
            baseline_reason = agent.fetch("separation_reason") == "baseline"
            unless baseline_reason == (name == baseline_name)
              raise HarnessExperimentError,
                "only the baseline agent may use the baseline separation reason"
            end
            if agent.fetch("does_not").include?(agent.fetch("responsibility"))
              raise HarnessExperimentError,
                "agent responsibility conflicts with its exclusions"
            end
            validate_separation_reason!(agent) unless name == baseline_name
          end
          validate_check_ownership!(baseline)
          validate_check_ownership!(candidate) if candidate
        end

        def validate_separation_reason!(agent)
          return unless candidate

          member = candidate.members.find do |entry|
            entry.fetch("agent") == agent.fetch("agent")
          end
          return unless member

          reason = agent.fetch("separation_reason")
          valid = case reason
                  when "user_interface"
                    member.fetch("role") == "coordinator"
                  when "independent_verification"
                    member.fetch("role") == "verifier" &&
                      (member.fetch("independent_context") || member.fetch("permission_boundary"))
                  when "permission_boundary"
                    member.fetch("permission_boundary")
                  when "context_isolation"
                    member.fetch("independent_context")
                  when "specialized_capability"
                    specialized_capability?(member)
                  when "parallel_latency"
                    candidate.pattern == "parallel" || candidate.edges.any? do |edge|
                      edge.fetch("kind") == "parallel" &&
                        [edge.fetch("from"), edge.fetch("to")].include?(member.fetch("agent"))
                    end
                  else
                    false
                  end
          unless valid
            raise HarnessExperimentError,
              "agent separation reason is not supported by its topology role or boundary"
          end
        end

        def specialized_capability?(member)
          others = candidate.members.reject do |entry|
            entry.fetch("agent") == member.fetch("agent")
          end.flat_map { |entry| entry.fetch("capabilities") }.uniq
          (member.fetch("capabilities") - others).any?
        end

        def validate_check_ownership!(topology)
          assigned = contracts_for(topology).flat_map do |agent|
            agent.fetch("done_checks")
          end.uniq
          missing = workload.required_checks - assigned
          if missing.any?
            raise HarnessExperimentError,
              "#{topology.id} agent contracts are missing workload checks: #{missing.join(', ')}"
          end
        end

        def validate_tools!
          names = agents.map { |agent| agent.fetch("agent") }
          declared = tools.map { |tool| tool.fetch("name") }
          references = agents.flat_map do |agent|
            agent.fetch("tools").map { |tool| [tool, agent.fetch("agent")] }
          end
          unknown = references.map(&:first).uniq - declared
          if unknown.any?
            raise HarnessExperimentError,
              "agent contracts reference unknown tools: #{unknown.join(', ')}"
          end

          tools.each do |tool|
            owners = tool.fetch("owners")
            unless (owners - names).empty?
              raise HarnessExperimentError,
                "tool #{tool.fetch('name')} references unknown owners"
            end
            actual_owners = references.select do |name, _|
              name == tool.fetch("name")
            end.map(&:last).sort
            unless actual_owners == owners
              raise HarnessExperimentError,
                "tool #{tool.fetch('name')} owners do not match agent contracts"
            end
            gated = tool.fetch("effect") != "read_only" ||
              %w[sensitive irreversible privileged].include?(tool.fetch("risk"))
            if gated && tool["approval_gate"].nil?
              raise HarnessExperimentError,
                "effectful or risky tools require an approval gate"
            end
            if tool["approval_gate"]
              validate_approval_gate!(tool["approval_gate"], "tool #{tool.fetch('name')}")
            end
          end
        end

        def validate_handoffs!
          expected = if candidate
                       candidate.edges.map do |edge|
                         edge.values_at("from", "to", "kind")
                       end.sort
                     else
                       []
                     end
          actual = handoffs.map do |handoff|
            handoff.values_at("from", "to", "kind")
          end.sort
          unless actual == expected
            raise HarnessExperimentError,
              "handoff contracts must exactly match candidate topology edges"
          end
        end

        def validate_workflow!
          topology = candidate || baseline
          owners = member_names(topology)
          ids = workflow.map { |step| step.fetch("id") }
          workflow.each do |step|
            unless owners.include?(step.fetch("owner"))
              raise HarnessExperimentError,
                "workflow step references an inactive owner"
            end
            dependencies = step.fetch("depends_on")
            if dependencies.include?(step.fetch("id")) || (dependencies - ids).any?
              raise HarnessExperimentError, "workflow contains invalid dependencies"
            end
            if step.fetch("effect") != "read_only" && step["approval_gate"].nil?
              raise HarnessExperimentError,
                "effectful workflow steps require an approval gate"
            end
            if step["approval_gate"]
              validate_approval_gate!(step["approval_gate"],
                "workflow step #{step.fetch('id')}")
            end
          end
          detect_workflow_cycle!
          validate_workflow_handoffs!(topology)
          missing_owners = owners - workflow.map { |step| step.fetch("owner") }.uniq
          if missing_owners.any?
            raise HarnessExperimentError,
              "workflow leaves agents without work: #{missing_owners.join(', ')}"
          end

          depended_on = workflow.flat_map { |step| step.fetch("depends_on") }.uniq
          terminals = workflow.reject { |step| depended_on.include?(step.fetch("id")) }
          coordinator = if candidate
                          candidate.members.find do |member|
                            member.fetch("role") == "coordinator"
                          end.fetch("agent")
                        else
                          member_names(baseline).first
                        end
          unless terminals.size == 1 && terminals.first.fetch("kind") == "decision" &&
                 terminals.first.fetch("owner") == coordinator
            raise HarnessExperimentError,
              "workflow requires one coordinator-owned terminal decision"
          end
          covered = workflow.flat_map { |step| step.fetch("done_checks") }.uniq
          missing = workload.required_checks - covered
          if missing.any?
            raise HarnessExperimentError,
              "workflow is missing workload checks: #{missing.join(', ')}"
          end
        end

        def validate_workflow_handoffs!(topology)
          return if topology == baseline

          by_id = workflow.to_h { |step| [step.fetch("id"), step] }
          used_pairs = []
          workflow.each do |step|
            step.fetch("depends_on").each do |dependency_id|
              source = by_id.fetch(dependency_id)
              source_owner = source.fetch("owner")
              target_owner = step.fetch("owner")
              next if source_owner == target_owner

              matches = topology.edges.select do |edge|
                edge.fetch("from") == source_owner && edge.fetch("to") == target_owner
              end
              if step.fetch("kind") == "verification"
                matches = matches.select { |edge| edge.fetch("kind") == "verification" }
              end
              if matches.empty?
                raise HarnessExperimentError,
                  "cross-agent workflow dependency lacks a matching topology handoff"
              end
              used_pairs << [source_owner, target_owner, step.fetch("kind")]
            end
          end
          unused = topology.edges.reject do |edge|
            used_pairs.any? do |source, target, target_kind|
              edge.fetch("from") == source && edge.fetch("to") == target &&
                (edge.fetch("kind") != "verification" || target_kind == "verification")
            end
          end
          if unused.any?
            raise HarnessExperimentError,
              "candidate topology handoffs must be exercised by the workflow"
          end
        end

        def detect_workflow_cycle!
          dependencies = workflow.to_h do |step|
            [step.fetch("id"), step.fetch("depends_on")]
          end
          visiting = {}
          visited = {}
          visit = lambda do |id|
            raise HarnessExperimentError, "workflow contains a cycle" if visiting[id]
            return if visited[id]

            visiting[id] = true
            dependencies.fetch(id).each { |dependency| visit.call(dependency) }
            visiting.delete(id)
            visited[id] = true
          end
          dependencies.each_key { |id| visit.call(id) }
        end

        def validate_quality!
          missing = workload.required_checks - quality.fetch("required_checks")
          if missing.any?
            raise HarnessExperimentError,
              "quality contract is missing workload checks: #{missing.join(', ')}"
          end
          if Harness.secure_equal?(quality.fetch("training_set_digest"),
                                   quality.fetch("holdout_set_digest"))
            raise HarnessIntegrityError, "training and holdout sets must be distinct"
          end
          unless quality.fetch("human_review") && quality.fetch("rollback_required")
            raise HarnessExperimentError,
              "team blueprint requires human review and rollback"
          end
          verifier = quality["verifier"]
          external_gate = quality["external_gate"]
          if verifier.nil? && external_gate.nil?
            raise HarnessExperimentError,
              "quality contract requires an isolated verifier or external gate"
          end
          if verifier
            unless candidate
              raise HarnessExperimentError,
                "a team verifier requires a candidate topology"
            end
            member = candidate.members.find do |entry|
              entry.fetch("agent") == verifier
            end
            unless member && member.fetch("role") == "verifier"
              raise HarnessExperimentError,
                "quality verifier must be the candidate verifier member"
            end
          end
          declared_verifiers = if candidate
                                 candidate.members.select do |member|
                                   member.fetch("role") == "verifier"
                                 end.map { |member| member.fetch("agent") }
                               else
                                 []
                               end
          if declared_verifiers.any? && declared_verifiers != [verifier]
            raise HarnessExperimentError,
              "candidate verifier must own the quality verification contract"
          end
          validate_verifier_duties!(declared_verifiers)
          validate_approval_gate!(external_gate, "external quality gate") if external_gate
        end

        def validate_verifier_duties!(verifiers)
          verifiers.each do |name|
            verification_steps = workflow.select do |step|
              step.fetch("owner") == name && step.fetch("kind") == "verification"
            end
            unless verification_steps.any? do |step|
              (step.fetch("done_checks") & quality.fetch("required_checks")).any?
            end
              raise HarnessExperimentError,
                "verifier requires a verification step with quality checks"
            end
            unless candidate.edges.any? do |edge|
              edge.fetch("to") == name && edge.fetch("kind") == "verification"
            end
              raise HarnessExperimentError,
                "verifier requires an incoming verification handoff"
            end
            unsafe = tools.select { |tool| tool.fetch("owners").include?(name) }.any? do |tool|
              tool.fetch("effect") != "read_only" ||
                %w[irreversible privileged].include?(tool.fetch("risk"))
            end
            if unsafe
              raise HarnessExperimentError,
                "verifier cannot own effectful, irreversible or privileged tools"
            end
          end
        end

        def validate_budget!
          if budget.fetch("max_turns") > goal.max_steps
            raise HarnessExperimentError, "team budget exceeds goal max steps"
          end
          unless workload.within_bounds?(
            team_size: candidate&.size || baseline.size,
            cost_usd: budget.fetch("max_cost_usd"),
            latency_ms: budget.fetch("max_latency_ms"),
            human_minutes: budget.fetch("max_human_minutes")
          )
            raise HarnessExperimentError, "team budget exceeds workload bounds"
          end
          if candidate
            if budget.fetch("max_subcalls").zero? ||
               budget.fetch("max_delegation_depth").zero?
              raise HarnessExperimentError,
                "team candidate requires bounded delegation budget"
            end
          elsif budget.fetch("max_subcalls").positive? ||
                budget.fetch("max_delegation_depth").positive?
            raise HarnessExperimentError,
              "baseline-only blueprint cannot budget delegation"
          end
        end

        def validate_launch_plan!
          unless launch_plan.map { |entry| entry.fetch("day") } == (1..7).to_a
            raise HarnessExperimentError,
              "launch plan days must be unique and sequential"
          end
          expected = candidate ? LAUNCH_KINDS_WITH_CANDIDATE : LAUNCH_KINDS_BASELINE_ONLY
          unless launch_plan.map { |entry| entry.fetch("kind") } == expected
            raise HarnessExperimentError,
              "launch plan does not match blueprint evaluation stages"
          end
          allowed_owners = agents.map { |agent| agent.fetch("agent") } + ["human_operator"]
          unless launch_plan.all? { |entry| allowed_owners.include?(entry.fetch("owner")) }
            raise HarnessExperimentError, "launch plan references an unknown owner"
          end
          review_days = launch_plan.select do |entry|
            %w[review pilot_decision].include?(entry.fetch("kind"))
          end
          unless review_days.all? { |entry| entry.fetch("requires_approval") } &&
                 launch_plan.last.fetch("owner") == "human_operator"
            raise HarnessExperimentError,
              "review and pilot decision require human approval"
          end
        end

        def validate_approval_gate!(gate, label)
          unless goal.approval_required_for?(gate)
            raise HarnessExperimentError,
              "#{label} gate is not required by the goal"
          end
        end

        def validate_size!
          size = JSON.generate(to_h).bytesize
          limit = Context.resolve.config.harness.max_checkpoint_bytes
          if size > limit
            raise HarnessPersistenceError,
              "team blueprint exceeds checkpoint byte limit"
          end
        rescue JSON::GeneratorError, TypeError => error
          raise HarnessExperimentError,
            "team blueprint must be JSON data: #{error.message}"
        end

        def contracts_for(topology)
          names = member_names(topology)
          agents.select { |agent| names.include?(agent.fetch("agent")) }
        end

        def member_names(topology)
          topology.members.map { |member| member.fetch("agent") }.sort
        end

        def identifiers(values, label, minimum: 0)
          unless values.is_a?(Array) && values.size.between?(minimum, MAX_LIST_ENTRIES)
            raise HarnessExperimentError,
              "#{label} values must be a bounded array"
          end
          values.map { |value| Organization.identifier!(value, label) }.uniq.sort.freeze
        end

        def positive_rate!(value)
          rate = Organization.number!(value, "minimum success rate", maximum: 1.0)
          raise HarnessExperimentError, "minimum success rate must be positive" unless rate.positive?

          rate
        end

        def strict_object(value, required, optional, label)
          data = Organization.json_hash!(value, label)
          self.class.send(:strict_keys!, data, required, optional, label)
        end

        def duplicate!(values, label)
          unless values.uniq.size == values.size
            raise HarnessExperimentError, "#{label} must be unique"
          end
        end

        def contract!(value, type, label)
          return value if value.is_a?(type)

          raise HarnessExperimentError,
            "team blueprint #{label} must be a #{type.name.split('::').last}"
        end

        def manifest_topology!(value)
          case value.to_s
          when "baseline"
            [baseline, "baseline"]
          when "candidate"
            unless candidate
              raise HarnessExperimentError,
                "candidate manifest requires a candidate topology"
            end
            [candidate, "candidate"]
          else
            raise HarnessExperimentError,
              "manifest topology must be baseline or candidate"
          end
        end

        def manifest_risk(risk)
          {
            "read" => "read", "reversible" => "low",
            "sensitive" => "high", "irreversible" => "high",
            "privileged" => "privileged"
          }.fetch(risk)
        end
      end
    end
  end
end
