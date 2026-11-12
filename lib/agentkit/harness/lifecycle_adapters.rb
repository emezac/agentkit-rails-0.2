# frozen_string_literal: true

module Agentkit
  module Harness
    # Optional host-owned ports for Git, CI and deployment systems. These
    # adapters validate and normalize evidence; they contain no provider SDK,
    # credential handling or deployment method.
    module LifecycleAdapters
      MAX_REQUEST_BYTES = 32_768
      MAX_RESPONSE_BYTES = 131_072

      class Base
        attr_reader :name

        def initialize(name:, loader:, authorize:)
          @name = safe_text(name, "adapter name")
          @loader = loader
          @authorize = authorize
          unless @loader.respond_to?(:call) && @authorize.respond_to?(:call)
            raise ArgumentError, "lifecycle adapter requires loader and authorizer callbacks"
          end
        end

        private

        def load(operation, request, context)
          ctx = context || Context.resolve
          raise ConfigurationError, "lifecycle adapters require an authenticated principal" if ctx.principal.to_s.empty?

          normalized = normalize(request, "adapter request", MAX_REQUEST_BYTES)
          frozen_request = Harness.deep_freeze(normalized)
          allowed = begin
            @authorize.call(operation.to_s, frozen_request, ctx)
          rescue StandardError
            false
          end
          raise PolicyDenied, "lifecycle adapter access denied" unless allowed == true

          response = begin
            @loader.call(operation.to_s, frozen_request, ctx)
          rescue StandardError => error
            raise HarnessError, "lifecycle adapter #{name} unavailable (#{error.class.name})"
          end
          normalize(response, "adapter response", MAX_RESPONSE_BYTES)
        end

        def normalize(value, label, limit)
          data = DeclarativeData.normalize(value, label: label, error_class: HarnessError)
          raise ArgumentError, "#{label} must be an object" unless data.is_a?(Hash)
          raise ArgumentError, "#{label} exceeds #{limit} bytes" if JSON.generate(data).bytesize > limit

          data
        end

        def exact_keys!(value, keys, label)
          actual = value.keys.sort
          expected = keys.sort
          raise HarnessIntegrityError, "#{label} fields do not match contract" unless actual == expected
        end

        def safe_text(value, label, maximum: 2_000)
          text = value.to_s.strip
          unless text.bytesize.between?(1, maximum) && !text.match?(/[[:cntrl:]]/)
            raise ArgumentError, "#{label} must contain 1..#{maximum} safe bytes"
          end

          text.freeze
        end

      end

      class RepositorySnapshot
        attr_reader :repository, :requested_reference, :commit_sha, :tree_digest,
                    :dirty, :observed_at

        def initialize(repository:, requested_reference:, commit_sha:, tree_digest:,
                       dirty:, observed_at:)
          @repository = repository.to_s.freeze
          @requested_reference = requested_reference.to_s.freeze
          @commit_sha = VerificationResult.normalize_commit_sha(commit_sha)
          @tree_digest = Harness.valid_digest!(tree_digest).freeze
          raise ArgumentError, "repository dirty must be boolean" unless [true, false].include?(dirty)

          @dirty = dirty
          @observed_at = Harness.time(observed_at)
          raise ArgumentError, "repository snapshot cannot be in the future" if @observed_at > Time.now.utc + 5
          freeze
        end

        def releasable? = !dirty
        def digest = Harness.digest(to_h)
        def to_h
          {
            "repository" => repository, "requested_reference" => requested_reference,
            "commit_sha" => commit_sha, "tree_digest" => tree_digest,
            "dirty" => dirty, "observed_at" => observed_at.iso8601(6)
          }
        end
      end

      class RepositoryDiff
        MAX_PATHS = 2_000
        attr_reader :repository, :base_sha, :head_sha, :reference, :digest,
                    :changed_paths, :observed_at

        def initialize(repository:, base_sha:, head_sha:, reference:, digest:,
                       changed_paths:, observed_at:)
          @repository = repository.to_s.freeze
          @base_sha = VerificationResult.normalize_commit_sha(base_sha)
          @head_sha = VerificationResult.normalize_commit_sha(head_sha)
          @reference = reference.to_s.freeze
          raise ArgumentError, "diff reference is required" if @reference.empty?
          @digest = Harness.valid_digest!(digest).freeze
          paths = Array(changed_paths).map do |path|
            value = path.to_s
            raise ArgumentError, "invalid changed path" if value.empty? || value.bytesize > 1_024 || value.include?("\0")

            value.freeze
          end
          raise ArgumentError, "too many changed paths" if paths.size > MAX_PATHS
          @changed_paths = paths.uniq.freeze
          @observed_at = Harness.time(observed_at)
          raise ArgumentError, "repository diff cannot be in the future" if @observed_at > Time.now.utc + 5
          freeze
        end

        def to_h
          {
            "repository" => repository, "base_sha" => base_sha, "head_sha" => head_sha,
            "reference" => reference, "digest" => digest,
            "changed_paths" => changed_paths, "observed_at" => observed_at.iso8601(6)
          }
        end
      end

      class Repository < Base
        def snapshot(repository:, reference:, context: nil)
          request = {
            "repository" => safe_text(repository, "repository"),
            "reference" => safe_text(reference, "repository reference")
          }
          response = load("repository.snapshot", request, context)
          exact_keys!(response, %w[repository requested_reference commit_sha tree_digest dirty observed_at], "repository snapshot")
          unless response["repository"] == request["repository"] && response["requested_reference"] == request["reference"]
            raise HarnessIntegrityError, "repository snapshot identity mismatch"
          end

          RepositorySnapshot.new(**symbolize(response))
        end

        def compare(repository:, base_sha:, head_sha:, context: nil)
          request = {
            "repository" => safe_text(repository, "repository"),
            "base_sha" => VerificationResult.normalize_commit_sha(base_sha),
            "head_sha" => VerificationResult.normalize_commit_sha(head_sha)
          }
          response = load("repository.compare", request, context)
          exact_keys!(response, %w[repository base_sha head_sha reference digest changed_paths observed_at], "repository diff")
          unless %w[repository base_sha head_sha].all? { |key| response[key] == request[key] }
            raise HarnessIntegrityError, "repository diff identity mismatch"
          end

          RepositoryDiff.new(**symbolize(response))
        end

        private

        def symbolize(value) = value.to_h { |key, item| [key.to_sym, item] }
      end

      class ContinuousIntegration < Base
        def results(commit_sha:, gates:, context: nil)
          sha = VerificationResult.normalize_commit_sha(commit_sha)
          definitions = Array(gates)
          unless definitions.any? && definitions.all? { |gate| gate.is_a?(VerificationGate) }
            raise ArgumentError, "CI results require at least one VerificationGate"
          end
          duplicate_ids = definitions.group_by(&:id).select { |_, values| values.size > 1 }.keys
          raise ArgumentError, "duplicate verification gate ids: #{duplicate_ids.join(', ')}" if duplicate_ids.any?

          request = {
            "commit_sha" => sha,
            "gates" => definitions.map { |gate| { "id" => gate.id, "digest" => gate.digest } }
          }
          response = load("ci.results", request, context)
          exact_keys!(response, %w[commit_sha results], "CI response")
          raise HarnessIntegrityError, "CI response commit mismatch" unless response["commit_sha"] == sha
          rows = response["results"]
          raise HarnessIntegrityError, "CI results must be an array" unless rows.is_a?(Array)
          raise HarnessIntegrityError, "CI returned too many results" if rows.size > definitions.size

          known = definitions.to_h { |gate| [gate.id, gate] }
          seen = {}
          rows.map do |row|
            unless row.is_a?(Hash)
              raise HarnessIntegrityError, "CI result must be an object"
            end
            exact_keys!(
              row, %w[gate_id gate_digest status commit_sha source evidence_digest configuration_digest dependencies_digest checked_at],
              "CI result"
            )
            gate = known[row["gate_id"]] || raise(HarnessIntegrityError, "CI returned an unknown gate")
            raise HarnessIntegrityError, "CI returned a duplicate gate" if seen[row["gate_id"]]
            seen[row["gate_id"]] = true
            unless row["commit_sha"] == sha && row["gate_digest"] == gate.digest
              raise HarnessIntegrityError, "CI result binding mismatch"
            end

            VerificationResult.new(**row.to_h { |key, item| [key.to_sym, item] })
          end
        end
      end

      class DeploymentPlan
        attr_reader :environment, :commit_sha, :deployment_reference,
                    :deployment_digest, :rollback_reference, :rollback_digest,
                    :observed_at

        def initialize(environment:, commit_sha:, deployment_reference:, deployment_digest:,
                       rollback_reference:, rollback_digest:, observed_at:)
          @environment = environment.to_s.freeze
          @commit_sha = VerificationResult.normalize_commit_sha(commit_sha)
          @deployment_reference = deployment_reference.to_s.freeze
          @rollback_reference = rollback_reference.to_s.freeze
          if @environment.empty? || @deployment_reference.empty? || @rollback_reference.empty?
            raise ArgumentError, "deployment environment and plan references are required"
          end
          @deployment_digest = Harness.valid_digest!(deployment_digest).freeze
          @rollback_digest = Harness.valid_digest!(rollback_digest).freeze
          @observed_at = Harness.time(observed_at)
          raise ArgumentError, "deployment plan cannot be in the future" if @observed_at > Time.now.utc + 5
          freeze
        end

        def receipt_arguments
          {
            deployment_plan_reference: deployment_reference,
            deployment_plan_digest: deployment_digest,
            rollback_plan_reference: rollback_reference,
            rollback_plan_digest: rollback_digest
          }
        end

        def to_h
          {
            "environment" => environment, "commit_sha" => commit_sha,
            "deployment_reference" => deployment_reference,
            "deployment_digest" => deployment_digest,
            "rollback_reference" => rollback_reference,
            "rollback_digest" => rollback_digest,
            "observed_at" => observed_at.iso8601(6), "authorizes" => false
          }
        end
      end

      class DeploymentObservation
        STATUSES = %w[planned running succeeded failed unknown].freeze
        attr_reader :release_id, :environment, :commit_sha, :status,
                    :provider_reference, :evidence_digest, :observed_at

        def initialize(release_id:, environment:, commit_sha:, status:,
                       provider_reference:, evidence_digest:, observed_at:)
          @release_id = release_id.to_s.freeze
          @environment = environment.to_s.freeze
          @commit_sha = VerificationResult.normalize_commit_sha(commit_sha)
          @status = status.to_s
          raise ArgumentError, "unknown deployment status: #{@status.inspect}" unless STATUSES.include?(@status)
          @provider_reference = provider_reference.to_s.freeze
          if @release_id.empty? || @environment.empty? || @provider_reference.empty?
            raise ArgumentError, "deployment observation identity is required"
          end
          @evidence_digest = Harness.valid_digest!(evidence_digest).freeze
          @observed_at = Harness.time(observed_at)
          raise ArgumentError, "deployment observation cannot be in the future" if @observed_at > Time.now.utc + 5
          freeze
        end

        def to_h
          {
            "release_id" => release_id, "environment" => environment,
            "commit_sha" => commit_sha, "status" => status,
            "provider_reference" => provider_reference,
            "evidence_digest" => evidence_digest,
            "observed_at" => observed_at.iso8601(6)
          }
        end
      end

      class Deployment < Base
        def plan(commit_sha:, environment:, context: nil)
          request = {
            "commit_sha" => VerificationResult.normalize_commit_sha(commit_sha),
            "environment" => safe_text(environment, "deployment environment")
          }
          response = load("deployment.plan", request, context)
          exact_keys!(
            response,
            %w[environment commit_sha deployment_reference deployment_digest rollback_reference rollback_digest observed_at],
            "deployment plan"
          )
          unless response["commit_sha"] == request["commit_sha"] && response["environment"] == request["environment"]
            raise HarnessIntegrityError, "deployment plan identity mismatch"
          end

          DeploymentPlan.new(**response.to_h { |key, item| [key.to_sym, item] })
        end

        def observe(release_id:, environment:, context: nil)
          request = {
            "release_id" => safe_text(release_id, "release id"),
            "environment" => safe_text(environment, "deployment environment")
          }
          response = load("deployment.observe", request, context)
          exact_keys!(
            response,
            %w[release_id environment commit_sha status provider_reference evidence_digest observed_at],
            "deployment observation"
          )
          unless response["release_id"] == request["release_id"] && response["environment"] == request["environment"]
            raise HarnessIntegrityError, "deployment observation identity mismatch"
          end

          DeploymentObservation.new(**response.to_h { |key, item| [key.to_sym, item] })
        end
      end
    end
  end
end
