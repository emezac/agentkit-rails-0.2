# frozen_string_literal: true

module Agentkit
  module Harness
    module DeclarativeData
      module_function

      # Ruby's JSON encoder stringifies many arbitrary objects. Harness
      # candidates must be actual JSON-shaped data, not objects with to_json
      # hooks or frozen callables disguised as configuration.
      def normalize(value, label:, error_class: HarnessCandidateInvalid, path: label)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise error_class, "#{path} has a non-string key"
            end
            name = key.to_s
            result[name] = normalize(item, label: label, error_class: error_class,
                                           path: "#{path}.#{name}")
          end
        when Array
          value.map.with_index do |item, index|
            normalize(item, label: label, error_class: error_class,
                                  path: "#{path}[#{index}]")
          end
        when Symbol
          value.to_s
        when String
          value.dup
        when Integer, TrueClass, FalseClass, NilClass
          value
        when Float
          raise error_class, "#{path} must be finite" unless value.finite?

          value
        else
          raise error_class, "#{path} must contain only JSON data, got #{value.class}"
        end
      end
    end

    # Immutable, declarative unit of an execution harness. Components carry
    # configuration only: callables and executable source do not belong in a
    # candidate manifest and therefore cannot cross this boundary.
    class Component
      TYPES = %w[
        system_prompt guardrail memory_policy skill tool_guidance capability
        subagent middleware
      ].freeze
      RISKS = %w[read low high privileged].freeze
      EFFECTS = %w[read_only internal external].freeze

      attr_reader :name, :type, :version, :configuration, :activation,
                  :dependencies, :resources, :permissions, :risk, :effect,
                  :metadata

      def initialize(name:, type:, version: "1", configuration: {}, activation: {},
                     dependencies: [], resources: [], permissions: [], risk: :read,
                     effect: :read_only, metadata: {})
        @name = required_text(name, "component name").freeze
        @type = type.to_s.freeze
        @version = required_text(version, "component version").freeze
        @configuration = frozen_hash(configuration, "component configuration")
        @activation = frozen_hash(activation, "component activation")
        @dependencies = names(dependencies)
        @resources = names(resources)
        @permissions = names(permissions)
        @risk = risk.to_s.freeze
        @effect = effect.to_s.freeze
        @metadata = frozen_hash(metadata, "component metadata")
        validate!
        freeze
      end

      def key = "#{type}:#{name}"
      def context_bytes = JSON.generate([configuration, activation]).bytesize
      def digest = Harness.digest(to_h)

      def to_h
        {
          "name" => name, "type" => type, "version" => version,
          "configuration" => configuration, "activation" => activation,
          "dependencies" => dependencies, "resources" => resources,
          "permissions" => permissions, "risk" => risk, "effect" => effect,
          "metadata" => metadata
        }
      end

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        new(
          name: data.fetch("name"), type: data.fetch("type"),
          version: data.fetch("version", "1"),
          configuration: data["configuration"] || {},
          activation: data["activation"] || {},
          dependencies: data["dependencies"] || [], resources: data["resources"] || [],
          permissions: data["permissions"] || [], risk: data.fetch("risk", "read"),
          effect: data.fetch("effect", "read_only"), metadata: data["metadata"] || {}
        )
      end

      private

      def validate!
        raise HarnessCandidateInvalid, "unknown harness component type #{type.inspect}" unless TYPES.include?(type)
        raise HarnessCandidateInvalid, "unknown component risk #{risk.inspect}" unless RISKS.include?(risk)
        raise HarnessCandidateInvalid, "unknown component effect #{effect.inspect}" unless EFFECTS.include?(effect)

        size = JSON.generate(to_h).bytesize
        limit = Agentkit.config.harness.max_component_bytes
        if size > limit
          raise HarnessCandidateInvalid, "component #{key} is #{size} bytes; limit is #{limit}"
        end
      rescue JSON::GeneratorError, TypeError => e
        raise HarnessCandidateInvalid, "component #{name} must be JSON data: #{e.message}"
      end

      def frozen_hash(value, label)
        raise HarnessCandidateInvalid, "#{label} must be a hash" unless value.respond_to?(:to_h)

        Harness.deep_freeze(DeclarativeData.normalize(value.to_h, label: label))
      end

      def names(values)
        Array(values).map { |value| required_text(value, "component list entry").freeze }.uniq.freeze
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessCandidateInvalid, "#{label} is required" if text.empty?

        text
      end
    end

    # A complete execution-harness definition. The exact output contract is a
    # manifest-level invariant and revisions can only alter components.
    class Manifest
      SCHEMA_VERSION = 1

      attr_reader :id, :version, :components, :output_contract, :metadata,
                  :parent_digest

      def initialize(id:, version:, components:, output_contract:, metadata: {},
                     parent_digest: nil)
        @id = required_text(id, "manifest id").freeze
        @version = required_text(version, "manifest version").freeze
        @components = Array(components).map do |component|
          component.is_a?(Component) ? component : Component.from_h(component)
        end.freeze
        @output_contract = frozen_hash(output_contract, "manifest output_contract")
        @metadata = frozen_hash(metadata, "manifest metadata")
        @parent_digest = parent_digest && Harness.valid_digest!(parent_digest).freeze
        validate!
        freeze
      end

      def component(key)
        token = key.respond_to?(:key) ? key.key : key.to_s
        components.find { |item| item.key == token }
      end

      def component_keys = components.map(&:key).freeze
      def digest = Harness.digest(to_h)

      def to_h
        {
          "schema_version" => SCHEMA_VERSION, "id" => id, "version" => version,
          "components" => components.map(&:to_h), "output_contract" => output_contract,
          "metadata" => metadata, "parent_digest" => parent_digest
        }.compact
      end

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        version = begin
          Integer(data.fetch("schema_version", SCHEMA_VERSION))
        rescue ArgumentError, TypeError
          raise HarnessCandidateInvalid, "manifest schema version is invalid"
        end
        raise HarnessCandidateInvalid, "unsupported manifest schema version" unless version == SCHEMA_VERSION

        new(
          id: data.fetch("id"), version: data.fetch("version"),
          components: data.fetch("components"),
          output_contract: data.fetch("output_contract"),
          metadata: data["metadata"] || {}, parent_digest: data["parent_digest"]
        )
      end

      private

      def validate!
        duplicate_keys = component_keys.group_by(&:itself).select { |_, values| values.size > 1 }.keys
        if duplicate_keys.any?
          raise HarnessCandidateInvalid, "duplicate manifest components: #{duplicate_keys.join(', ')}"
        end
        max_components = Agentkit.config.harness.max_manifest_components
        if components.size > max_components
          raise HarnessCandidateInvalid, "manifest has #{components.size} components; limit is #{max_components}"
        end
        size = JSON.generate(to_h).bytesize
        limit = Agentkit.config.harness.max_manifest_bytes
        raise HarnessCandidateInvalid, "manifest is #{size} bytes; limit is #{limit}" if size > limit
      rescue JSON::GeneratorError, TypeError => e
        raise HarnessCandidateInvalid, "manifest must be JSON data: #{e.message}"
      end

      def frozen_hash(value, label)
        raise HarnessCandidateInvalid, "#{label} must be a hash" unless value.respond_to?(:to_h)

        Harness.deep_freeze(DeclarativeData.normalize(value.to_h, label: label))
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessCandidateInvalid, "#{label} is required" if text.empty?

        text
      end
    end

    class Change
      OPERATIONS = %w[add replace remove].freeze

      attr_reader :id, :operation, :target, :component, :rationale, :evidence_refs

      def initialize(id:, operation:, target: nil, component: nil, rationale:, evidence_refs: [])
        @id = required_text(id, "change id").freeze
        @operation = operation.to_s.freeze
        @component = if component
                       component.is_a?(Component) ? component : Component.from_h(component)
                     end
        @target = (target || @component&.key).to_s.strip.freeze
        @rationale = required_text(rationale, "change rationale").freeze
        @evidence_refs = names(evidence_refs)
        validate!
        freeze
      end

      def to_h
        {
          "id" => id, "operation" => operation, "target" => target,
          "component" => component&.to_h, "rationale" => rationale,
          "evidence_refs" => evidence_refs
        }.compact
      end

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        new(
          id: data.fetch("id"), operation: data.fetch("operation"), target: data["target"],
          component: data["component"], rationale: data.fetch("rationale"),
          evidence_refs: data["evidence_refs"] || []
        )
      end

      private

      def validate!
        raise HarnessCandidateInvalid, "unknown change operation #{operation.inspect}" unless OPERATIONS.include?(operation)
        raise HarnessCandidateInvalid, "change target is required" if target.empty?
        if operation == "remove" && component
          raise HarnessCandidateInvalid, "remove change cannot include a component"
        elsif operation != "remove" && component.nil?
          raise HarnessCandidateInvalid, "#{operation} change requires a component"
        elsif component && component.key != target
          raise HarnessCandidateInvalid, "change component key must match target #{target.inspect}"
        end
      end

      def names(values)
        Array(values).map { |value| required_text(value, "evidence reference").freeze }.uniq.freeze
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessCandidateInvalid, "#{label} is required" if text.empty?

        text
      end
    end

    # A candidate is a typed patch against one immutable base manifest.
    class Revision
      SCOPES = %w[invariant domain].freeze

      attr_reader :id, :base_digest, :scope, :changes, :rationale,
                  :result_version, :metadata

      def initialize(id:, base_digest:, scope:, changes:, rationale:, result_version: nil,
                     metadata: {})
        @id = required_text(id, "revision id").freeze
        @base_digest = Harness.valid_digest!(base_digest).freeze
        @scope = scope.to_s.freeze
        @changes = Array(changes).map do |change|
          change.is_a?(Change) ? change : Change.from_h(change)
        end.freeze
        @rationale = required_text(rationale, "revision rationale").freeze
        @result_version = (result_version || id).to_s.strip.freeze
        @metadata = frozen_hash(metadata)
        validate!
        freeze
      end

      def digest = Harness.digest(to_h)

      def apply_to(base)
        manifest = base.is_a?(Manifest) ? base : Manifest.from_h(base)
        unless Harness.secure_equal?(base_digest, manifest.digest)
          raise HarnessCandidateInvalid, "revision #{id} does not target manifest #{manifest.digest}"
        end

        by_key = manifest.components.to_h { |component| [component.key, component] }
        changes.each do |change|
          case change.operation
          when "add"
            raise HarnessCandidateInvalid, "cannot add existing component #{change.target}" if by_key.key?(change.target)
            by_key[change.target] = change.component
          when "replace"
            raise HarnessCandidateInvalid, "cannot replace missing component #{change.target}" unless by_key.key?(change.target)
            by_key[change.target] = change.component
          when "remove"
            raise HarnessCandidateInvalid, "cannot remove missing component #{change.target}" unless by_key.delete(change.target)
          end
        end

        Manifest.new(
          id: manifest.id, version: result_version, components: by_key.values,
          output_contract: manifest.output_contract, parent_digest: manifest.digest,
          metadata: manifest.metadata.merge(
            "revision_id" => id, "revision_digest" => digest, "revision_scope" => scope
          )
        )
      end

      def to_h
        {
          "id" => id, "base_digest" => base_digest, "scope" => scope,
          "changes" => changes.map(&:to_h), "rationale" => rationale,
          "result_version" => result_version, "metadata" => metadata
        }
      end

      def self.from_h(value)
        data = Harness.stringify_keys(value)
        new(
          id: data.fetch("id"), base_digest: data.fetch("base_digest"),
          scope: data.fetch("scope"), changes: data.fetch("changes"),
          rationale: data.fetch("rationale"), result_version: data["result_version"],
          metadata: data["metadata"] || {}
        )
      end

      private

      def validate!
        raise HarnessCandidateInvalid, "unknown revision scope #{scope.inspect}" unless SCOPES.include?(scope)
        raise HarnessCandidateInvalid, "revision requires at least one change" if changes.empty?
        raise HarnessCandidateInvalid, "revision result_version is required" if result_version.empty?
        duplicate_ids = changes.group_by(&:id).select { |_, values| values.size > 1 }.keys
        duplicate_targets = changes.group_by(&:target).select { |_, values| values.size > 1 }.keys
        raise HarnessCandidateInvalid, "duplicate change ids: #{duplicate_ids.join(', ')}" if duplicate_ids.any?
        if duplicate_targets.any?
          raise HarnessCandidateInvalid, "revision changes a target more than once: #{duplicate_targets.join(', ')}"
        end
      end

      def frozen_hash(value)
        raise HarnessCandidateInvalid, "revision metadata must be a hash" unless value.respond_to?(:to_h)

        Harness.deep_freeze(DeclarativeData.normalize(value.to_h, label: "revision metadata"))
      end

      def required_text(value, label)
        text = value.to_s.strip
        raise HarnessCandidateInvalid, "#{label} is required" if text.empty?

        text
      end
    end

    ValidationIssue = Struct.new(:severity, :code, :path, :message, keyword_init: true) do
      def error? = severity.to_s == "error"
      def to_h = { "severity" => severity.to_s, "code" => code.to_s, "path" => path.to_s,
                   "message" => message.to_s }
    end

    class ValidationReport
      attr_reader :revision, :candidate_manifest, :issues, :id

      def initialize(revision:, candidate_manifest:, issues:)
        @revision = revision
        @candidate_manifest = candidate_manifest
        @issues = Array(issues).freeze
        @id = "validation:#{revision.digest.delete_prefix('sha256:')[0, 20]}".freeze
        freeze
      end

      def valid? = issues.none?(&:error?)
      def evidence_ref = id
      def errors = issues.select(&:error?)

      def to_h
        {
          "id" => id, "revision_id" => revision.id, "revision_digest" => revision.digest,
          "valid" => valid?, "candidate_digest" => candidate_manifest&.digest,
          "issues" => issues.map(&:to_h)
        }.compact
      end
    end

    # Static fail-closed validation before any candidate is executed.
    class CandidateValidator
      EFFECT_RANK = { "read_only" => 0, "internal" => 1, "external" => 2 }.freeze
      RISK_RANK = { "read" => 0, "low" => 1, "high" => 2, "privileged" => 3 }.freeze

      attr_reader :allowed_permissions, :allow_removals

      def initialize(allowed_permissions: [], allow_removals: false)
        @allowed_permissions = Array(allowed_permissions).map(&:to_s).freeze
        @allow_removals = !!allow_removals
      end

      def validate(base:, revision:, goal: nil)
        manifest = base.is_a?(Manifest) ? base : Manifest.from_h(base)
        candidate = revision.is_a?(Revision) ? revision : Revision.from_h(revision)
        issues = []
        result = begin
          candidate.apply_to(manifest)
        rescue HarnessCandidateInvalid, ArgumentError => e
          issues << issue(:structural, "revision", e.message)
          nil
        end

        validate_limits(candidate, issues)
        validate_changes(manifest, candidate, goal, issues)
        validate_result(manifest, result, issues) if result
        ValidationReport.new(revision: candidate, candidate_manifest: result, issues: issues)
      end

      private

      def validate_limits(revision, issues)
        limit = Agentkit.config.harness.max_revision_changes
        return unless revision.changes.size > limit

        issues << issue(:too_many_changes, "changes", "#{revision.changes.size} changes exceed limit #{limit}")
      end

      def validate_changes(base, revision, goal, issues)
        protected = Array(goal&.protected_resources)
        included = Array(goal&.scope&.fetch("include", []))
        excluded = Array(goal&.scope&.fetch("exclude", []))
        revision.changes.each_with_index do |change, index|
          path = "changes[#{index}]"
          prior = base.component(change.target)
          component = change.component || prior
          next unless component

          if change.operation == "remove" && !allow_removals
            issues << issue(:removal_requires_opt_in, "#{path}.operation",
                            "component removal requires explicit validator opt-in")
          end

          if change.operation == "add"
            privilege_increase(component, nil, path, issues)
          elsif change.operation == "replace" && prior
            privilege_increase(component, prior, path, issues)
          end

          forbidden_permissions = component.permissions - allowed_permissions - Array(prior&.permissions)
          if forbidden_permissions.any?
            issues << issue(:permission_expansion, "#{path}.permissions",
                            "new permissions are not allowed: #{forbidden_permissions.join(', ')}")
          end

          boundaries = protected + excluded
          declared_resources = (component.resources + Array(prior&.resources)).uniq
          touched = declared_resources.select do |resource|
            boundaries.any? { |pattern| resource_match?(pattern, resource) }
          end
          if touched.any?
            issues << issue(:protected_resource, "#{path}.resources",
                            "candidate touches protected or excluded resources: #{touched.join(', ')}")
          end

          out_of_scope = if included.empty?
                           []
                         else
                           declared_resources.reject do |resource|
                             included.any? { |pattern| resource_match?(pattern, resource) }
                           end
                         end
          if out_of_scope.any?
            issues << issue(:out_of_scope_resource, "#{path}.resources",
                            "candidate resources are outside goal scope: #{out_of_scope.join(', ')}")
          end

          if component.type == "skill" && component.activation["trigger"].to_s.strip.empty?
            issues << issue(:missing_trigger, "#{path}.activation.trigger",
                            "skill candidates require an explicit activation trigger")
          end
        end
      end

      def privilege_increase(component, prior, path, issues)
        base_effect = prior ? EFFECT_RANK.fetch(prior.effect) : EFFECT_RANK.fetch("read_only")
        base_risk = prior ? RISK_RANK.fetch(prior.risk) : RISK_RANK.fetch("read")
        if EFFECT_RANK.fetch(component.effect) > base_effect
          issues << issue(:effect_expansion, "#{path}.effect",
                          "candidate effect #{component.effect} exceeds #{prior&.effect || 'read_only'}")
        end
        return unless RISK_RANK.fetch(component.risk) > base_risk

        issues << issue(:risk_expansion, "#{path}.risk",
                        "candidate risk #{component.risk} exceeds #{prior&.risk || 'read'}")
      end

      def validate_result(base, result, issues)
        unless Harness.secure_equal?(Harness.digest(base.output_contract), Harness.digest(result.output_contract))
          issues << issue(:output_contract_changed, "output_contract",
                          "candidate changed the task-defined output contract")
        end

        available = result.component_keys
        result.components.each do |component|
          missing = component.dependencies - available
          next if missing.empty?

          issues << issue(:missing_dependency, "components.#{component.key}.dependencies",
                          "missing component dependencies: #{missing.join(', ')}")
        end

        delta = [result.components.sum(&:context_bytes) - base.components.sum(&:context_bytes), 0].max
        limit = Agentkit.config.harness.max_context_delta_bytes
        if delta > limit
          issues << issue(:context_budget, "components", "context delta #{delta} bytes exceeds limit #{limit}")
        end
      end

      def resource_match?(pattern, resource)
        token = pattern.to_s
        token == resource || File.fnmatch?(token, resource, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end

      def issue(code, path, message)
        ValidationIssue.new(severity: "error", code: code.to_s, path: path, message: message).freeze
      end
    end
  end
end
