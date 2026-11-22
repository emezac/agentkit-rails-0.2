# frozen_string_literal: true

# Reference Rails host adapter connecting Agentkit::Harness::UnattendedRun to
# isolated sandboxes (Docker, E2B, Fly Machines, etc.) without putting shell
# execution, container management, or deployment authority inside AgentKit.
#
# Load inside a Rails app with migrations 024, 026 and 031 installed.
# Supply real role-based authorization callbacks, a durable lease deduplication
# store (e.g. Redis/PostgreSQL unique index), and separate worker/verifier
# credentials and sandboxes.
require "agentkit"
require "digest"
require "open3"
require "timeout"

module RailsUnattendedSandboxExample
  # Host-owned sandbox port. Implement this interface for Docker, E2B, Modal,
  # Fly Machines, or a local isolated runner. AgentKit never invokes it.
  class DockerSandbox
    def initialize(image:, workspace_root:, read_only_paths: %w[tests/ ci/])
      @image = image
      @workspace_root = workspace_root
      @read_only_paths = read_only_paths
    end

    # Runs a single bounded attempt inside a fresh container with no network
    # and an OS-enforced timeout tied to the lease expiration.
    def execute(command:, lease:, env: {}, writable: true)
      remaining = [(Time.iso8601(lease.fetch("expires_at")) - Time.now.utc).floor, 1].max
      args = [
        "docker", "run", "--rm",
        "--network=none",
        "--read-only",
        "--pids-limit=128",
        "--memory=512m",
        "-v", "#{@workspace_root}:/workspace:#{writable ? 'rw' : 'ro'}"
      ]
      @read_only_paths.each do |rel|
        args += ["-v", "#{File.join(@workspace_root, rel)}:/workspace/#{rel}:ro"]
      end
      env.each { |k, v| args += ["-e", "#{k}=#{v}"] }
      args += ["-w", "/workspace", @image, *command]

      stdout, stderr, status = Timeout.timeout(remaining) { Open3.capture3(*args) }
      { exit_code: status.exitstatus, stdout: stdout, stderr: stderr }
    end
  end

  # Coordinates UnattendedRun leases with an isolated worker sandbox and an
  # independent verifier sandbox. Neither principal can impersonate the other.
  class Coordinator
    def initialize(journal:, escalations:, authorize:, worker_sandbox:, verifier_sandbox:,
                   lease_store:, clock: -> { Time.now.utc })
      @run = Agentkit::Harness::UnattendedRun.new(
        journal: journal,
        escalations: escalations,
        authorize: authorize,
        clock: clock
      )
      @worker_sandbox = worker_sandbox
      @verifier_sandbox = verifier_sandbox
      @lease_store = lease_store # responds to #claim_once?(token) -> Boolean
      @clock = clock
    end

    attr_reader :run

    def start!(id:, goal:, gates:, initial_artifact:, limits:, primary:, fallback:, operator_ctx:)
      @run.start(
        id: id,
        goal: goal,
        gates: gates,
        artifact: initial_artifact,
        allowed_resources: ["src/"],
        protected_resources: goal.protected_resources,
        executor_version: "docker-sandbox:1",
        limits: limits,
        primary: primary,
        fallback: fallback,
        context: operator_ctx
      )
    end

    # Runs one bounded worker attempt outside any DB transaction.
    # Deduplicates by lease token so duplicate job deliveries never re-run.
    def run_worker_attempt(id:, request_id:, worker_ctx:, worker_command:, measure_usage:, inspect_artifact:)
      grant = @run.claim(id: id, role: "worker", request_id: request_id, context: worker_ctx)
      lease = grant["lease"]
      return grant unless lease
      return grant unless @lease_store.claim_once?(lease.fetch("token"))

      contract = @run.contract(id: id, context: worker_ctx)
      exec_result = @worker_sandbox.execute(
        command: worker_command.call(contract),
        lease: lease,
        writable: true
      )

      observed_artifact = inspect_artifact.call
      usage = measure_usage.call(exec_result) # nil if provider billing/usage could not be measured
      claim_text = "exit=#{exec_result[:exit_code]} (untrusted worker summary)"

      @run.report_work(
        id: id,
        token: lease.fetch("token"),
        artifact: observed_artifact,
        worker_claim: claim_text,
        usage: usage,
        context: worker_ctx
      )
    end

    # Runs independent verification in a separate read-only sandbox under a
    # distinct verifier principal. Never trusts worker claims or manifests.
    def run_verification(id:, request_id:, verifier_ctx:, gates:, verify_command:,
                         inspect_artifact:, parse_checks:, measure_usage:)
      grant = @run.claim(id: id, role: "verifier", request_id: request_id, context: verifier_ctx)
      lease = grant["lease"]
      return grant unless lease
      return grant unless @lease_store.claim_once?(lease.fetch("token"))

      exec_result = @verifier_sandbox.execute(
        command: verify_command,
        lease: lease,
        writable: false
      )

      # Independently hash actual bytes on disk; mismatches become policy_violation.
      observed = inspect_artifact.call
      checked_at = @clock.call
      parsed = parse_checks.call(exec_result)

      results = gates.map do |gate|
        check = parsed.fetch(:gates).fetch(gate.id)
        gate.record(
          status: check.fetch(:status),
          commit_sha: observed.fetch("commit_sha"),
          source: "verifier-sandbox:#{request_id}",
          configuration_digest: observed.fetch("configuration_digest"),
          dependencies_digest: observed.fetch("dependencies_digest"),
          checked_at: checked_at,
          value: check[:value]
        )
      end

      @run.report_verification(
        id: id,
        token: lease.fetch("token"),
        artifact: observed,
        results: results,
        failures: parsed.fetch(:failures),
        progress_digest: parsed.fetch(:progress_digest),
        usage: measure_usage.call(exec_result),
        context: verifier_ctx
      )
    end
  end

  # Minimal in-memory lease deduplicator for local testing.
  # In production, use a unique DB constraint or Redis SET NX EX.
  class MemoryLeaseStore
    def initialize
      @seen = {}
      @mutex = Mutex.new
    end

    def claim_once?(token)
      @mutex.synchronize do
        return false if @seen.key?(token)

        @seen[token] = true
      end
    end
  end

  # Builds a role-separated authorizer suitable for UnattendedRun.
  def self.default_authorizer(operator_id:, worker_id:, verifier_id:)
    lambda do |action, ctx|
      case action
      when "start", "cancel", "expire" then ctx.principal == operator_id
      when "work"                      then ctx.principal == worker_id
      when "verify"                    then ctx.principal == verifier_id
      when "read", "read_history"      then [operator_id, worker_id, verifier_id].include?(ctx.principal)
      else false
      end
    end
  end
end
