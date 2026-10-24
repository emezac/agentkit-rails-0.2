# frozen_string_literal: true

module Agentkit
  module Harness
    # Fixed candidates and disjoint tasks. Workers register the same study and
    # executor at boot; jobs contain only world IDs and explicit scope.
    class GovernedStudy
      Evaluation = Struct.new(:policy_name, :policy_version, :policy_digest,
                              :history_digest, :world_count, :mean_quality,
                              :mean_cost, :mean_latency, :task_scores, :world_digests,
                              keyword_init: true) do
        def to_h = members.to_h { |key| [key, public_send(key)] }
      end
      Selection = Struct.new(:study_digest, :selected, :training_world_ids,
                             :evidence_digest, keyword_init: true)
      Settings = Struct.new(:bootstrap_samples, :confidence_level, :min_score_improvement,
                            :min_holdout_worlds, :min_training_worlds, :pareto_epsilon,
                            keyword_init: true)
      attr_reader :id, :digest, :base, :manifests, :context, :repetitions, :settings

      def initialize(id:, base:, revisions:, training_tasks:, holdout_tasks:,
                     executor:, executor_digest:, repetitions: 2, context: Context.resolve, goal: nil)
        @id = id.to_s.freeze
        raise HarnessExperimentError, "study id is required" if @id.empty?
        @base, @context, @executor = base, context, executor
        @scope = Scope.resolve(context: context)
        @executor_digest = Harness.valid_digest!(executor_digest)
        @repetitions = Integer(repetitions)
        @tasks = { "training" => Array(training_tasks).dup.freeze,
                   "holdout" => Array(holdout_tasks).dup.freeze }.freeze
        revisions = Array(revisions)
        if revisions.empty? || revisions.size > context.config.harness.max_experiment_candidates ||
           revisions.map(&:id).uniq.size != revisions.size || revisions.any? { |r| r.id == "baseline" }
          raise HarnessExperimentError, "study requires unique bounded candidates"
        end
        @manifests = { "baseline" => base }
        revisions.each do |revision|
          report = CandidateValidator.new.validate(base: base, revision: revision, goal: goal)
          raise HarnessCandidateInvalid, "study candidate failed validation: #{revision.id}" unless report.valid?
          @manifests[revision.id] = report.candidate_manifest
        end
        @manifests.freeze
        @settings = Settings.new(**Settings.members.to_h { |key| [key, context.config.exploration.public_send(key)] }).freeze
        validate!
        @digest = Harness.digest(
          id: id, scope: scope_data, manifests: manifests.transform_values(&:digest),
          tasks: @tasks.transform_values { |list| list.map(&:digest) },
          repetitions: repetitions, executor: @executor_digest, settings: settings.to_h,
          goal_digest: goal&.digest
        ).freeze
      end

      # Register on every worker, including all possible frozen holdout pairs.
      # No Procs or raw task inputs are serialized into jobs or worlds.
      def register!
        @tasks.each do |phase, tasks|
          sets = phase == "training" ? [manifests.keys] :
                 manifests.keys.reject { |key| key == "baseline" }.map { |key| ["baseline", key] }
          tasks.each do |task|
            sets.each do |variants|
              name = generator_name(phase, task, variants)
              Exploration.generators.register(name, version: digest,
                source_digest: Harness.digest(study: digest, generator: name),
                generator: lambda { |parent:, view:|
                  execute(task, schedule(task, variants).fetch(view.round))
                })
            end
          end
        end
        Exploration.evaluators.register(evaluator_name, version: digest,
          source_digest: Harness.digest(study: digest, evaluator: "probe-metrics-v1"),
          evaluator: ->(probe) { { score: probe.fetch("quality"), metadata: { "probe" => probe } } })
        self
      end

      def run_training(distributed: false)
        launch("training", manifests.keys, distributed: distributed)
      end

      def select(training_worlds:)
        evaluations = evaluate_worlds(training_worlds, "training", manifests.keys)
        frontier = pareto(evaluations)
        incumbent = evaluations.first
        best = frontier.sort_by { |e| [-e.mean_quality, e.mean_cost, e.mean_latency, e.policy_name] }.first
        selected = best.mean_quality > incumbent.mean_quality + settings.min_score_improvement ? best.policy_name : "baseline"
        Selection.new(study_digest: digest, selected: selected,
                      training_world_ids: world_ids(training_worlds).freeze,
                      evidence_digest: Harness.digest(evaluations.map(&:to_h))).freeze
      end

      def run_holdout(selection:, distributed: false)
        verified_selection!(selection)
        raise HarnessExperimentError, "training retained the baseline" if selection.selected == "baseline"
        launch("holdout", ["baseline", selection.selected], distributed: distributed)
      end

      def recommend(selection:, holdout_worlds:)
        verified_selection!(selection)
        raise HarnessExperimentError, "training retained the baseline" if selection.selected == "baseline"
        training = evaluate_worlds(selection.training_world_ids, "training", manifests.keys)
        holdout = evaluate_worlds(holdout_worlds, "holdout", ["baseline", selection.selected])
        incumbent, candidate = holdout
        comparison = Exploration.compare_paired_scores(
          incumbent_scores: incumbent.task_scores, candidate_scores: candidate.task_scores,
          history_digest: incumbent.history_digest, incumbent_digest: incumbent.policy_digest,
          candidate_digest: candidate.policy_digest, metric: "harness_quality_per_task",
          settings: settings
        )
        eligible = pareto(holdout).include?(candidate) && comparison.significant
        recommendation = Exploration::Recommendation.new(
          status: eligible ? "recommend_review" : "retain", level: "harness",
          incumbent: "baseline", selected: selection.selected,
          evaluations: training, holdout_evaluations: holdout,
          pareto_frontier: pareto(training).map(&:policy_name),
          holdout: {
            "kind" => "harness_study", "study_id" => id, "study_digest" => digest,
            "scope" => scope_data, "selection_digest" => selection.evidence_digest,
            "training_task_digests" => @tasks.fetch("training").map(&:digest),
            "holdout_task_digests" => @tasks.fetch("holdout").map(&:digest),
            "repetitions" => repetitions, "executor_digest" => @executor_digest,
            "base_manifest" => base.to_h,
            "candidate_manifest" => manifests.fetch(selection.selected).to_h,
            "objectives" => { "quality" => "maximize", "cost" => "minimize", "latency" => "minimize" }
          },
          comparison: comparison, requires_review: true, auto_promoted: false,
          reason: eligible ? "statistically_significant_holdout_improvement" : "holdout_gate_failed"
        )
        recommendation.each_pair { |_, value| Harness.deep_freeze(value) }
        recommendation.freeze
      end

      def submit!(target:, selection:, holdout_worlds:)
        recommendation = recommend(selection: selection, holdout_worlds: holdout_worlds)
        payload = recommendation.to_h.merge(
          evaluations: recommendation.evaluations.map(&:to_h),
          holdout_evaluations: recommendation.holdout_evaluations.map(&:to_h),
          comparison: recommendation.comparison.to_h
        )
        if JSON.generate(payload).bytesize > context.config.harness.max_checkpoint_bytes
          raise HarnessPersistenceError, "study dossier exceeds checkpoint byte limit"
        end
        Agentkit.with_context(context) do
          Exploration::Governance.submit!(target: target, recommendation: recommendation, scope: @scope)
        end
      end

      # Host opt-in: resolve only an approved digest against this validated
      # manifest set. Never silently run an unknown or stale binding.
      def active_manifest(target:)
        binding = Exploration::Governance.binding(target, scope: @scope)
        return base unless binding
        manifests.values.find { |manifest| manifest.digest == binding.policy_digest } ||
          raise(HarnessIntegrityError, "active binding is not a manifest in this study")
      end

      private

      def scope_data
        { "tenant_key" => @scope.tenant_key || "__global__", "account_id" => @scope.account_id }
      end

      def validate!
        unless @executor.respond_to?(:call) && repetitions >= 2 &&
               repetitions <= context.config.harness.max_probe_repetitions
          raise HarnessExperimentError, "study needs an executor and bounded repeated probes (at least two)"
        end
        all = @tasks.values.flatten
        if all.size > context.config.harness.max_study_tasks
          raise HarnessExperimentError, "study exceeds task limit"
        end
        if all.map(&:id).uniq.size != all.size || all.map(&:input_digest).uniq.size != all.size
          raise HarnessExperimentError, "training and holdout tasks must have unique ids and input digests"
        end
        if all.map(&:model_digest).uniq.size != 1 || all.map(&:environment_digest).uniq.size != 1 ||
           all.any? { |task| !task.safe_for_probe? || Harness.digest(task.output_contract) != Harness.digest(base.output_contract) }
          raise HarnessExperimentError, "study tasks require fixed model/environment and matching sandboxed contracts"
        end
        if @tasks["training"].size < settings.min_training_worlds ||
           @tasks["holdout"].size < [2, settings.min_holdout_worlds].max
          raise HarnessExperimentError, "insufficient independent training or holdout tasks"
        end
        rounds = repetitions * manifests.size
        if rounds > context.config.exploration.max_rounds || rounds > context.config.exploration.max_nodes
          raise HarnessExperimentError, "study probe schedule exceeds exploration round/node limits"
        end
        unless context.config.exploration.validate.empty?
          raise HarnessExperimentError, "invalid exploration settings"
        end
      end

      def generator_name(phase, task, variants)
        "harness-study:#{Harness.digest([digest, phase, task.digest, variants]).delete_prefix('sha256:')}"
      end

      def evaluator_name = "harness-study:#{digest.delete_prefix('sha256:')}"

      # Rotate the first variant across repetitions to reduce order effects.
      def schedule(task, variants)
        repetitions.times.flat_map do |index|
          variants.rotate((task.digest[-4, 4].to_i(16) + index) % variants.size).map { |key| [key, index + 1] }
        end
      end

      def launch(phase, variants, distributed:)
        register!
        @tasks.fetch(phase).map do |task|
          args = {
            objective: digest, generator: generator_name(phase, task, variants),
            generator_version: digest, evaluator: evaluator_name, evaluator_version: digest,
            max_rounds: repetitions * variants.size, max_nodes: repetitions * variants.size,
            max_parallelism: 1, scope: @scope,
            metadata: { study_digest: digest, phase: phase, task_digest: task.digest, variants: variants }
          }
          Agentkit.with_context(context) do
            distributed ? Exploration.enqueue(**args) : Exploration.run(**args)
          end
        end.freeze
      end

      def execute(task, slot)
        key, repetition = slot
        manifest = manifests.fetch(key)
        request = Harness.deep_freeze(
          "probe_id" => Harness.digest([digest, task.digest, key, repetition]),
          "role" => key == "baseline" ? "baseline" : "candidate",
          "revision_id" => key == "baseline" ? nil : key,
          "repetition" => repetition, "manifest" => manifest.to_h,
          "manifest_digest" => manifest.digest, "task" => task.to_h
        )
        raw = Agentkit.with_context(context) { @executor.call(request) }
        data = Harness.stringify_keys(raw.to_h)
        metrics = data.fetch("metrics")
        probe = {
          "id" => request.fetch("probe_id"), "variant" => key, "repetition" => repetition,
          "manifest_digest" => manifest.digest, "task_digest" => task.digest,
          "output_digest" => Harness.valid_digest!(data.fetch("output_digest"))
        }
        %w[quality cost latency].each do |metric|
          number = Float(metrics.fetch(metric) { metrics.fetch(metric.to_sym) })
          raise HarnessExperimentError, "probe metrics must be finite and nonnegative" unless number.finite? && number >= 0
          probe[metric] = number
        end
        # No raw output, observations, error text or user supplied references.
        Harness.deep_freeze(probe)
      end

      def world_ids(worlds)
        Array(worlds).map { |world| world.respond_to?(:id) ? world.id : world.to_s }
      end

      def evaluate_worlds(values, phase, variants)
        ids = world_ids(values)
        tasks = @tasks.fetch(phase)
        unless ids.size == tasks.size && ids.uniq.size == ids.size
          raise HarnessIntegrityError, "study requires exactly one world per task"
        end
        worlds = ids.map do |world_id|
          world = Exploration.store.find(world_id, scope: @scope, include_incomplete: true)
          unless world && world.tenant_key == scope_data["tenant_key"] &&
                 world.account_id.to_s == @scope.account_id.to_s && world.status == "completed"
            raise HarnessIntegrityError, "study world missing, incomplete or outside scope"
          end
          world
        end
        unless worlds.map { |w| w.metadata["task_digest"] }.sort == tasks.map(&:digest).sort
          raise HarnessIntegrityError, "study task assignments mismatch"
        end
        rows = []
        worlds.each do |world|
          task = tasks.find { |item| item.digest == world.metadata["task_digest"] }
          generator = Exploration.generators.fetch(generator_name(phase, task, variants), version: digest)
          evaluator = Exploration.evaluators.fetch(evaluator_name, version: digest)
          unless world.metadata["study_digest"] == digest && world.metadata["phase"] == phase &&
                 world.metadata["variants"] == variants && world.generator_digest == generator.digest &&
                 world.evaluator_digest == evaluator.digest && world.node_count == repetitions * variants.size
            raise HarnessIntegrityError, "study world provenance or probe count mismatch"
          end
          nodes = world.nodes.reject(&:root?)
          expected = schedule(task, variants)
          nodes.each_with_index do |node, index|
            key, repetition = expected.fetch(index)
            probe = node.metadata["probe"]
            unless node.successful? && probe && probe["variant"] == key && probe["repetition"] == repetition &&
                   probe["manifest_digest"] == manifests.fetch(key).digest && probe["task_digest"] == task.digest &&
                   probe["id"] == Harness.digest([digest, task.digest, key, repetition])
              raise HarnessIntegrityError, "failed or mismatched study probe"
            end
            %w[quality cost latency].each do |metric|
              value = probe[metric]
              unless value.is_a?(Numeric) && value.finite? && value >= 0
                raise HarnessIntegrityError, "invalid stored study metrics"
              end
            end
            Harness.valid_digest!(probe["output_digest"])
            rows << probe
          end
        end
        history = Harness.digest(worlds.sort_by(&:id).map(&:digest))
        variants.map do |key|
          samples = rows.select { |row| row["variant"] == key }
          scores = samples.group_by { |row| row["task_digest"] }.transform_values { |group| mean(group.map { |r| r["quality"] }) }
          Evaluation.new(
            policy_name: key, policy_version: manifests.fetch(key).version,
            policy_digest: manifests.fetch(key).digest, history_digest: history,
            world_count: tasks.size, mean_quality: mean(scores.values),
            mean_cost: mean(samples.map { |r| r["cost"] }),
            mean_latency: mean(samples.map { |r| r["latency"] }),
            task_scores: scores.freeze, world_digests: worlds.to_h { |w| [w.id, w.digest] }.freeze
          ).freeze
        end.freeze
      end

      def verified_selection!(selection)
        register!
        unless selection.is_a?(Selection) && selection.study_digest == digest &&
               select(training_worlds: selection.training_world_ids) == selection
          raise HarnessIntegrityError, "selection does not match frozen training evidence"
        end
      end

      def pareto(evaluations)
        epsilon = settings.pareto_epsilon
        evaluations.reject do |candidate|
          evaluations.any? do |other|
            next false if other.equal?(candidate)
            deltas = [other.mean_quality - candidate.mean_quality,
                      candidate.mean_cost - other.mean_cost, candidate.mean_latency - other.mean_latency]
            deltas.all? { |d| d >= -epsilon } && deltas.any? { |d| d > epsilon }
          end
        end
      end

      def mean(values) = values.sum.to_f / values.size
    end
  end
end
