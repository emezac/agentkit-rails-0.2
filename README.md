# AgentKit Rails v1.6.0

**Kernel de agentes para aplicaciones Rails** — orquestación real, RAG nativo, Team Memory Hub (TencentDB Agent Memory), memoria on-demand, HITL con ledger de decisiones y una fábrica de mejora continua desde el día 0.

```ruby
gem "agentkit-rails", "~> 1.6.0"
```

```bash
rails g agentkit:install --with-chat
rails g agentkit:rag
rails g agentkit:team_memory
rails db:migrate
rails agentkit:doctor
```

## Progressive Agent Loop en 1.6.0

`Agent#run_loop` mantiene una conversación durante la tarea y controla cada
turno del modelo. Inicialmente ofrece un catálogo breve de skills y las
herramientas `load_skill` / `search_tools`; los procedimientos, proveedores de
contexto y esquemas completos se cargan cuando se solicitan.

```ruby
Agentkit::Skill.define(:support_lookup) do |skill|
  skill.description("Consultar tickets del tenant y verificar su estado")
  skill.trigger("preguntas sobre tickets")
  skill.version("1")
  skill.owner("support")
  skill.prompt("Consulta el ticket antes de afirmar su estado. Cita su referencia.")
  skill.tool(:ticket_status, description: "Consultar el estado de un ticket",
             params: { id: :integer }) do |id:|
    ctx = Agentkit::Context.current
    ticket = Ticket.where(account_id: ctx.to_h.fetch(:account_id)).find(id)
    { status: ticket.status, reference: "ticket:#{ticket.id}" }
  end
end

class SupportAgent < Agentkit::Agent
  uses_skills :support_lookup
  allow_tools :ticket_status
end

ctx = Agentkit::Context.new(account: current_account, principal: current_user.id.to_s)
outcome = SupportAgent.new(context: ctx).run_loop(
  "¿Cuál es el estado del ticket 42?",
  authorize: ->(tool, context) { permitted_tool?(context.principal, tool.name) }
)
if outcome.answered?
  outcome.content
else
  outcome.stop_reason # budget_exhausted, context_limit, verification_failed, etc.
end
outcome.usage.to_h
outcome.budget
```

Las skills declaradas se fotografían por ejecución y sus proveedores se evalúan
una vez al cargar. `authorize_skill: ->(skill, context) { ... }` controla tanto
el catálogo visible como la carga y las herramientas pertenecientes a esa skill.
La búsqueda sólo revela herramientas autorizadas. El permiso se revisa de nuevo
al ejecutar, junto con el allow/deny del agente y las restricciones heredadas.
Un esquema descubierto en un lote sólo se puede llamar a partir del siguiente
turno. `tools:` declara contratos adicionales y `eager_tools:` permite ofrecer
algunos desde el inicio. Se rechazan nombres ambiguos o reservados.

Las herramientas mantienen ToolContract: input/output, precondiciones, evidencia
y timeouts. Las de efecto internal/external no se ejecutan directamente:
expón las propuestas/operaciones gobernadas de Actions/HITL que ya use tu host.
Las lecturas con `metadata: { parallel_safe: true }` pueden ejecutarse en paralelo,
hasta el límite configurado; el host declara su independencia. Los resultados
conservan el orden solicitado. Carga de skills, descubrimiento y delegación son
secuenciales. Los errores enviados al modelo incluyen códigos, sin texto bruto
de excepciones.

### Delegación y validación final

```ruby
class ResearchAgent < Agentkit::Agent
  uses_skills :support_lookup
  allow_tools :ticket_status
end
class SupportCoordinator < Agentkit::Agent
  uses_skills :support_lookup
  allow_tools :research, :ticket_status
end
delegate = Agentkit::AgentTool.new(
  name: :research, agent: ResearchAgent,
  description: "Investigar un tema con contexto separado",
  system: "Investiga con fuentes y deja explícito lo pendiente."
)
# El padre debe permitir también los nombres de herramientas que autorice al
# hijo; las políticas y authorizers de ambos se intersectan.
result = SupportCoordinator.new(context: ctx).run_loop(
  "Investiga este caso", tools: [delegate], eager_tools: [:research]
)

schema = { type: "object", properties: { answer: { type: "string" } },
           required: ["answer"], additionalProperties: false }
result = SupportAgent.new(context: ctx).run_loop(
  "Responde con evidencia", schema: schema,
  verifier: ->(request, context) {
    { accepted: independently_verified?(request, context), reasons: [] }
  }
)
result.parsed if result.answered?
```

AgentTool invoca `agent.new(context: child_context).run_loop`; un override antiguo
de `#call` no se ejecuta por esta vía. Usa `system:`, skills y herramientas para
definir la tarea delegada. Devuelve un contrato común con answer/status,
evidence_refs, unresolved y usage. Conserva tenant, cuenta y principal y crea
una vista hija del presupuesto. El padre mantiene la conversación con el usuario.

El schema final usa el subconjunto JSON Schema del kernel y admite también
`LLM::Schema`. Sus errores y los rechazos del verificador consumen turnos;
tras dos rechazos por defecto, la respuesta queda retenida. El callback de
verificación recibe un snapshot inmutable con answer, evidence_refs y digest
del transcript, además del contexto. No recibe ni persiste razonamiento privado.
El loop respeta `default_model`/`default_schema` del agente; una skill cargada no
cambia por sí sola el modelo o schema final.

### Presupuesto y adaptadores

```ruby
Agentkit.configure do |config|
  config.agent_loop.max_turns = 20
  config.agent_loop.max_tokens = 100_000
  config.agent_loop.max_cost_usd = 1.0
  config.agent_loop.max_output_tokens = 2_048
  config.agent_loop.max_batch = 8
  config.agent_loop.max_parallel_tools = 4
  config.agent_loop.max_tools = 16
  config.agent_loop.max_delegation_depth = 3
end
budget = Agentkit::ExecutionBudget.new(max_turns: 30, max_tokens: 80_000, max_cost_usd: 0.5)
outcome = SupportAgent.new(context: ctx).run_loop("Consulta el caso", budget: budget)
```

El presupuesto compartido cuenta admisiones de llamadas al modelo, tokens de
input+output (incluida caché) y costo calculado con las tarifas configuradas.
Las vistas hijas atribuyen consumo a cada subárbol sin sumarlo dos veces al padre.
Outcome.usage corresponde al loop actual y sus hijos; budget[:usage] muestra el
total del presupuesto compartido, incluso si se reutiliza en varios loops.
El límite local de turnos sigue aplicando aunque se pase un presupuesto mayor.
También se contabilizan llamadas LLM tradicionales y reparaciones de schema
hechas dentro de herramientas. Con presupuesto compartido se rechaza el uso de
`LLM.complete(tools: ...)`: ese ciclo recursivo del SDK ocultaría llamadas.

Se comprueba capacidad antes de llamar y consumo medido después de responder.
Una respuesta o un lote ya en vuelo puede superar el remanente; entonces se
detienen los siguientes pasos. El costo es una estimación por tarifas, sin
descuentos de caché ni conciliación de factura. Con límite monetario se exigen
precios de input/output. Al desactivarlo (`max_cost_usd: nil`), los modelos sin
precio quedan declarados en `budget[:unpriced_models]`. Los intentos sin uso
reportado figuran en `budget[:unmeasured_calls]`.

`LLM.turn` ejecuta una sola petición nativa y devuelve propuestas de herramientas;
el SDK no ejecuta código. Requiere ruby_llm >= 1.15 y < 2 en producción, además
de la configuración de credenciales del proveedor. Usa copias de configuración
por llamada y respeta credenciales de ModelProfile. El adaptador
openai_compatible usa también api_base/openai_api_key de AgentKit. Puede
configurarse `ModelProfile.thinking` con las opciones nativas del SDK. Se han
probado OpenAI-compatible y Anthropic con el SDK real y HTTP simulado, incluidas
firmas de razonamiento, caché, rechazos y truncamiento. Otros adaptadores deben
implementar el puerto `turn`; el adaptador base falla explícitamente.

```ruby
# Pruebas sin red:
Agentkit.config.llm.adapter = :fake
Agentkit::LLM::Adapters::Fake.respond_with_turns(
  { tool_calls: [{ id: "search-1", name: "search_tools", arguments: { query: "ticket" } }] },
  { content: "No se encontró información suficiente." }
)
```

Este API es opt-in: `chat`, `complete` y Flow siguen disponibles. Cada AgentLoop
es de un solo uso; el transcript y el presupuesto compartido viven en el proceso
durante la tarea. No se guardan automáticamente ni se trasladan a Active Job.
Los eventos llm.turn, agent_loop.skill_loaded, tools_discovered y completed
permiten medir selección, uso y finalización; el Audit propio del loop almacena
digests y métricas, no prompts, argumentos, outputs o bloques privados.
GovernedStudy y ArchitectureEvaluation pueden evaluar este runtime mediante su
executor, manteniendo holdout, revisión humana y rollback de bindings.

## Architecture Evaluation en 1.5.1

Añade una compuerta opcional de éxito por tarea, checks obligatorios y cobertura
de cadenas. Un candidato puede mejorar calidad/costo/latencia y aun así quedar
bloqueado por una regresión de fiabilidad o un requisito incumplido.

```ruby
architecture = Agentkit::Harness::ArchitectureEvaluation.new(
  minimum_success_rate: 1.0, max_regressions: 0,
  required_chains: [["orders", "shipping"]]
)
# Al construir cada ExperimentTask, declara la cobertura y sus requisitos:
task = Agentkit::Harness::ExperimentTask.new(
  id: "shipping-case-1", input_reference: "case:1",
  input_digest: Agentkit::Harness.digest(case_body), model: "fixed-model",
  output_contract: manifest.output_contract,
  metadata: { architecture: {
    chain: ["orders", "shipping"], critical: true,
    required_checks: ["delivery_date_verified"]
  } }
)
# Crea cohortes independientes; cada cadena requerida debe tener al menos un
# caso declarado tanto en entrenamiento como en holdout.
study = Agentkit::Harness::GovernedStudy.new(
  id: "fold-shipping", base: manifest, revisions: candidate_revisions,
  training_tasks: training_tasks, holdout_tasks: holdout_tasks,
  executor: run_measured_probe,
  executor_digest: Agentkit::Harness.digest("runner-and-judge-v4"),
  architecture_evaluation: architecture
)
# El executor devuelve métricas y una evaluación booleana por repetición:
# { output_digest: "...", metrics: { quality: 0.9, cost: 0.01, latency: 80 },
#   evaluation: { success: true, checks: { delivery_date_verified: true } } }

training = study.run_training
study.record_training_architecture_reports!(training_worlds: training)
selection = study.select(training_worlds: training)
unless selection.selected == "baseline"
  holdout = study.run_holdout(selection: selection)
  report = study.record_architecture_report!(selection: selection, holdout_worlds: holdout)
  report.dig("architecture_evaluation", "holdout", "pass_to_fail")
  # Sólo submit! si recommend devuelve recommend_review; el resto del flujo
  # de aprobación/rollback de 1.5.0 sigue vigente.
end
```

Una regresión es una caída de la tasa de éxito entre repeticiones de la misma
tarea; se detecta incluso si ambas variantes superan el umbral de aprobación.
`max_regressions: nil` permite esas caídas, pero siguen bloqueando los checks
obligatorios fallidos, las tareas críticas bajo el umbral y las cadenas sin
cobertura. Calidad es una medida separada: no se convierte automáticamente en
éxito. Un resultado mal formado o un check obligatorio ausente invalida el probe.

Los reportes muestran cambios éxito→fallo/fallo→éxito, tasas de éxito,
repeticiones y deltas por tarea. Se guardan explícitamente en Memory como
snapshots durables imagined, sin embeddings, aislados por tenant/cuenta y
verificados por digest. La consola `/agentkit/exploration` muestra también
reportes bloqueados de entrenamiento y holdout. Registrar un reporte no crea
un review ni cambia el binding. Sin `architecture_evaluation:`, los estudios
1.5.0 conservan su identidad y comportamiento.

### Diagnóstico de delegación

```ruby
diagnostics = Agentkit::Harness::DelegationDiagnostics.analyze(
  context: Agentkit.context, minimum_requests: 5, coupling_threshold: 0.8,
  agents: [
    { name: "orders", role: "domain", context_group: "support" },
    { name: "shipping", role: "domain", context_group: "support" }
  ],
  traces: [{
    id: "request-1", tenant_key: Agentkit.context.tenant_key || "__global__",
    account_id: Agentkit.context.to_h[:account_id],
    calls: [
      { agent: "orders", start_ms: 0, duration_ms: 20, input_tokens: 300, cost_usd: 0.01 },
      { agent: "shipping", start_ms: 20, duration_ms: 15, input_tokens: 200, cost_usd: 0.01 }
    ]
  }]
)
diagnostics.to_h["agents"] # insuficiente evidencia con sólo un request
diagnostics.required_chains
# Puedes pasar delegation_diagnostics: diagnostics al construir GovernedStudy
# para vincular el informe a su identidad, dossier y dashboard.
```

Importa spans medidos de invocaciones de agentes pares; los tiempos se expresan
en milisegundos desde el inicio de cada request. No incluyas el span envolvente
del coordinador como si fuera un par, ni interpretes llamadas al modelo como
invocaciones distintas del mismo agente. El host exporta estos datos desde sus
trazas; esta versión no instrumenta automáticamente el ciclo del proveedor.

El diagnóstico propone `fold_candidate`, `merge_candidate`, `keep_as_tool`,
`inspect` o `insufficient_evidence`. Para sugerir merge exige frecuencia,
adyacencia temporal, contexto compartido declarado y ausencia de solapamiento.
Los roles verifier y las banderas `permission_boundary` o
`independent_context` preservan la separación. Sin datos suficientes no emite
una recomendación de migración. Las métricas ausentes se marcan incompletas:
un subtotal reportado no equivale al costo total.

Sólo requests completamente secuenciales generan cadenas observadas, en orden;
las ejecuciones concurrentes se cuentan como no lineales. Puedes usar
`diagnostics.required_chains` como entrada explícita de
`ArchitectureEvaluation.new(required_chains: ...)`, completándola con las rutas
que el host conozca. La cobertura comprueba casos de evaluación declarados;
el grader comprueba que cada caso cumpla realmente su procedimiento.
Los diagnósticos son hipótesis para ensayar, no decisiones automáticas.

## Governed Self-Improvement en 1.5.0

`Harness::GovernedStudy` evalúa manifests con probes reales, repetidos y
emparejados. Selecciona por calidad entre candidatos Pareto de entrenamiento
(calidad ↑, costo ↓, latencia ↓) y contrasta sólo al seleccionado contra la base
en tareas holdout disjuntas. El bootstrap usa medias por tarea independiente,
no trata las repeticiones como muestras nuevas.

```ruby
Agentkit.configure do |config|
  config.exploration.enabled = true
  # Debe cubrir repetitions * (1 + número de candidatos).
  config.exploration.max_rounds = 12
end

study = Agentkit::Harness::GovernedStudy.new(
  id: "support-cycle-2026-10",
  base: manifest,
  revisions: candidate_revisions,
  training_tasks: training_tasks, # ExperimentTask; mínimo 5 por defecto
  holdout_tasks: holdout_tasks,   # mínimo 5; ids e input_digest disjuntos
  repetitions: 3,
  executor: run_measured_probe,
  executor_digest: Agentkit::Harness.digest("runner-and-judge-v3"),
  context: Agentkit.context
)
# El executor recibe el request habitual de un probe y devuelve:
# { output_digest: "sha256:...", metrics: { quality: 0.9, cost: 0.02, latency: 120 } }
# Define unidades consistentes de costo/latencia en todas las tareas.

training = study.run_training
selection = study.select(training_worlds: training)
unless selection.selected == "baseline"
  holdout = study.run_holdout(selection: selection)
  recommendation = study.recommend(selection: selection, holdout_worlds: holdout)
  if recommendation.status == "recommend_review"
    review = study.submit!(target: "harness.support",
                          selection: selection, holdout_worlds: holdout)
    # Tras autenticar y autorizar al revisor, o desde el dashboard:
    Agentkit::Exploration::Governance.approve!(
      review, actor: "human:42", reason: "holdout revisado",
      scope: Agentkit::Scope.resolve(context: Agentkit.context)
    )
    approved_manifest = study.active_manifest(target: "harness.support")
    # Rollback explícito:
    Agentkit::Exploration::Governance.rollback!(
      review, actor: "human:42", reason: "regresión operativa",
      scope: Agentkit::Scope.resolve(context: Agentkit.context)
    )
  end
end
```

La promoción sólo cambia un binding declarativo; el host decide cuándo resolverlo
y ejecutarlo. Si otro review cambió el binding desde la base evaluada, la
aprobación falla. El dashboard existente `/agentkit/exploration` muestra
intervalo de confianza, tamaño de holdout, Pareto y costo/latencia, junto con
aprobación, rechazo y rollback bajo el guard de consola.

Para distribuir, configura `exploration.store = :active_record` y
`exploration.execution = :distributed`, usa una cola Active Job durable y
registra **la misma definición del estudio y executor** con `study.register!`
en cada worker. Invoca `run_training(distributed: true)`, conserva los world IDs
y espera su finalización antes de `select`; luego usa
`run_holdout(selection: selection, distributed: true)` y espera de nuevo.
Cada job ejecuta una tarea con sus variantes/repeticiones: el paralelismo es
entre tareas. Reutiliza leases, conciliación de intentos ambiguos y cuotas
diarias de worlds/attempts. Una entrega duplicada del mismo world no lo repite;
invocar otra vez `run_training` o `run_holdout` crea un lote nuevo.

Los candidatos y la asignación de datasets quedan fijados en el digest del
estudio. Puedes pasar `goal:` para aplicar sus recursos protegidos y límites de
alcance durante la validación. El host garantiza independencia real de tareas, aislamiento del runner,
versionado del juez y que el holdout no se reutilice para ajustar candidatos
entre ciclos. Los checks de disjunción no detectan entradas semánticamente
equivalentes. No hay activación ni ajuste de código automáticos.

## Experience Library en 1.4.1

Convierte resultados de experimentos en lecciones candidatas con procedencia
verificable, separadas por tenant, cuenta y dominio. No modifica el harness
ni activa lecciones automáticamente.

```ruby
library = Agentkit::Harness::ExperienceLibrary.new(
  domain: "support", context: Agentkit.context
)
entry = library.capture!(
  result: result, revision_id: result.revisions.first.id,
  cue: "support citations", lesson: "Verificar citas antes de responder.",
  applicability: "Respuestas de soporte con fuentes",
  topics: %w[support citations], ttl: 30.days
)
# nil significa NO_ENTRY: la evidencia no supera la compuerta.
if entry
  library.transition!(entry.id, to: :active, actor: "reviewer:42",
                      reason: "Evidencia revisada")
end
context_slice = library.retrieve(query: "support citations")
library.maintain!                      # dry-run por defecto
library.maintain!(dry_run: false)       # vencidas -> stale; conserva historia
```

Se exige un único cambio validado, al menos dos probes exitosos por variante,
condiciones emparejadas y atribución `helped` o `hurt` con evidencia de ambas.
Los resultados confundidos, sin efecto o fallidos no generan entrada.
Las lecciones negativas también sirven aunque el experimento conserve la base.
La aplicación anfitriona autentica y autoriza al revisor; `actor` es trazabilidad,
no un mecanismo de permisos.

Sólo se recuperan entradas activas y vigentes, mediante los límites de ContextMap,
etiquetadas como hipótesis no confiables que deben revalidarse. Memory conserva
snapshots durables `imagined`, sin embeddings ni outputs brutos de probes.
Las revisiones declarativas y los textos proporcionados sí se almacenan:
no incluyas secretos. No requiere migración. El host debe serializar escrituras
por experiencia; los conflictos concurrentes se detectan y bloquean la lectura,
pero no existe compare-and-swap distribuido.

## Harness Experiments en 1.4

1.4 añade un ciclo gobernado `Propose -> Probe -> Compose` para mejorar el
harness sin reentrenar el modelo. Los candidatos son patches declarativos
sobre un manifest inmutable; no contienen callables ni código ejecutable. Antes
de un probe, el runtime rechaza ampliaciones de efecto, riesgo o permisos,
dependencias ausentes, skills sin trigger, recursos protegidos y crecimiento
excesivo de contexto.

```ruby
component = Agentkit::Harness::Component.new(
  name: :planner,
  type: :system_prompt,
  configuration: { text: "Plan, execute, verify." }
)

manifest = Agentkit::Harness::Manifest.new(
  id: "support-harness",
  version: "1",
  components: [component],
  output_contract: {
    type: "object",
    properties: { answer: { type: "string" } },
    required: ["answer"],
    additionalProperties: false
  }
)

task = Agentkit::Harness::ExperimentTask.new(
  id: "ticket-42",
  input_reference: "ticket:42",
  input_digest: Agentkit::Harness.digest(ticket_body),
  model: { name: "frozen-model", temperature: 0, seed: 42 },
  output_contract: manifest.output_contract
)

result = Agentkit::Harness::Experiment.new(
  base: manifest,
  task: task,
  repetitions: 2,
  proposer: propose_candidates, # devuelve Revision invariant/domain
  executor: run_in_isolated_sandbox,
  contrastor: compare_matched_probes,
  composer: choose_or_keep_base
).run

result.composition.action       # "keep_base", "adopt" o "compose"
result.selected_manifest.digest # el candidato nunca se activa automáticamente
```

Los callbacks reciben snapshots profundamente congelados. Cada probe conserva
sólo referencias, digests, observaciones y métricas; el output bruto no entra
al resultado ni al Audit. El entorno declarado debe ser sandboxed, sin red y
con efectos aislados. `KEEP_BASE` es una decisión normal y siempre requiere
evidencia producida por validaciones, probes o contrastes.

## Harness engineering verificable en 1.3

1.3 convierte las instrucciones operativas en contratos ejecutables: alcance,
restricciones, recursos protegidos y aprobaciones son compuertas de
finalización. Un `ContextMap` recupera sólo fuentes relevantes y comprueba su
frescura/digest; un `Verifier` independiente sólo admite herramientas de
lectura; el recibo final separa lo verificado, pendiente y riesgoso.

Los trabajos largos terminan por evidencia, no porque el modelo escriba
"terminado". Un goal declara criterios, outputs y un presupuesto de pasos; el
checkpoint conserva únicamente referencias y digests, queda aislado por tenant
y reemplaza al anterior de forma no destructiva.

```ruby
goal = Agentkit::Harness.define(
  id: "release-42",
  objective: "publicar una release verificable",
  criteria: [
    { id: "tests", description: "suite completa en verde" },
    { id: "review", description: "revisión independiente sin bloqueos" }
  ],
  constraints: [
    { id: "no-prod-write", description: "producción permanece intacta", kind: :must_not }
  ],
  scope: { include: ["lib/**", "spec/**"], exclude: ["config/credentials.yml.enc"] },
  protected_resources: ["production/database"],
  required_approvals: ["release:publish"],
  required_outputs: %w[changelog package],
  max_steps: 12
)

progress = Agentkit::Harness.start(goal)
progress.record_output("package", reference: "artifact:agentkit-1.3.0.gem", value: gem_bytes)
progress.record_evidence(
  criterion: "tests", verdict: :verified,
  source: "ci:build-918", summary: "1,203 examples, 0 failures",
  value: junit_xml
)
progress.next_action = "obtener revisión independiente"
Agentkit::Harness.checkpoint!(progress, context: Agentkit.context)

# Otro worker o una sesión posterior:
progress = Agentkit::Harness.resume("release-42", context: Agentkit.context)
progress.context_fragment # bloque acotado para build_context(extra: ...)
progress.record_approval(
  "release:publish", actor: "principal:42", evidence_ref: "approval:991"
)
progress.complete!        # falla cerrado mientras falte evidencia/output/aprobación
```

Las herramientas de Skills y Capabilities comparten `ToolContract`: schema de
entrada/salida, precondiciones, efecto, riesgo, timeout, retry acotado y
evidencia de éxito. Un efecto `internal` o `external` nunca se ejecuta
directamente desde ese contrato; sigue la vía `Capability -> Actions ->
Policy/HITL`.

```ruby
Agentkit::Skill.define(:release_evidence) do |skill|
  skill.tool(
    :ci_result,
    input_schema: {
      type: "object", properties: { build_id: { type: "integer" } },
      required: ["build_id"], additionalProperties: false
    },
    effect: :read_only,
    success_evidence: ->(result) { { source: result.fetch(:url) } }
  ) { |build_id:| CI.result(build_id) }
end
```

```ruby
context_map = Agentkit::Harness::ContextMap.new do
  source :release_policy, reference: "docs/release.md", topics: %w[release deploy],
                          observed_at: policy_mtime, fresh_for: 1.day,
                          digest: expected_policy_digest, required: true
end

compiled = context_map.compile(query: goal.objective) do |source|
  { content: File.read(source.reference), observed_at: File.mtime(source.reference) }
end

verifier = Agentkit::Harness::Verifier.new(
  name: "release-auditor", reviewer: EvidenceReviewer,
  rejection_criteria: ["rechazar afirmaciones sin evidencia"]
)
review = verifier.verify(progress)
review.apply_to(progress) # aplicación explícita; verify no muta progress

receipt = Agentkit::Harness::Receipt.build(progress, risks: ["rollout latency"])
Agentkit::Harness::Metrics.summary(goal_id: goal.id, context: Agentkit.context)
```

`RecoveryPolicy` aporta una taxonomía compartida (`timeout`, `rate_limited`,
`missing_context`, `permission_denied`, `ambiguous_effect`, etc.) y detiene
errores repetidos sin cambio. Los checkpoints 1.2 se leen y se actualizan al
schema 2 al volver a persistir; no hay migración de base de datos.

## Goal contracts y privilegio mínimo en 1.2

Los agentes también pueden limitar las herramientas que llegan al proveedor.
La política se aplica tanto a tools provenientes de skills como a `tools:`
explícitas; deny siempre gana.

```ruby
class EvidenceReviewer < Agentkit::Agent
  uses_skills :repository, :web_sources
  allow_tools :read_file, :grep, :fetch_url
  deny_tools  :write_file, :shell, :publish
end
```

Este límite gobierna herramientas entregadas al LLM a través de `Agent#chat` y
`Agent#complete`. Los efectos de dominio continúan protegidos en la frontera
`Capability -> Actions -> Policy/HITL`; procesos arbitrarios del sistema
operativo requieren además el sandbox del host.

## Memory Lifecycle en 1.1

1.1 hace efectiva la expiración en todos los caminos de recuperación. Una
memoria vencida deja de alimentar al agente inmediatamente, aunque permanece
disponible para inspección y auditoría hasta que mantenimiento la archive.
Los pins son una excepción explícita y auditable.

```ruby
config.memory.retention.default_policy = :keep # compatible con 1.0
config.memory.retention.policies = {
  keep: nil,
  ephemeral: 7.days.to_i,
  standard: 90.days.to_i,
  durable: nil
}
config.memory.retention.by_type = {
  observation: :standard,
  scenario: :ephemeral,
  insight: :durable
}

memory = Agentkit::Memory.store("resultado temporal", retention: :ephemeral)
Agentkit::Memory.pin!(memory, reason: "investigación activa")
Agentkit::Memory.unpin!(memory, reason: "investigación cerrada")
```

El mantenimiento es no destructivo y `dry-run` por defecto: cambia memorias
vencidas no fijadas a `archived`, conserva contenido/procedencia y deja el GC
de vectores bajo la política ya existente.

```bash
TENANT=acct:42 rails agentkit:memory_maintenance
TENANT=acct:42 DRY_RUN=0 rails agentkit:memory_maintenance
```

## Gobernanza de promociones en 1.0

1.0 cierra el ciclo de Adaptive Exploration sin convertir una recomendación
estadística en auto-despliegue. Sólo una recomendación que ya superó selección
Pareto, holdout intacto y significancia puede producir un expediente durable.
La evidencia se resume sin replays crudos y queda sellada con un digest.

```ruby
recommendation = Agentkit::Exploration.recommend(
  incumbent: CurrentPolicy.new,
  candidates: candidate_policies,
  worlds: replay_worlds
)

review = Agentkit::Exploration.submit_recommendation!(
  target: "support.search",
  recommendation: recommendation
)

# Acción humana explícita; requiere Audit disponible.
Agentkit::Exploration.approve_recommendation!(
  review,
  actor: "human:operator-42",
  reason: "benchmark and risk review complete"
)

binding = Agentkit::Exploration.policy_binding(target: "support.search")
# => candidate name/version/digest, review id and monotonic generation
```

El binding es declarativo: AgentKit no registra, evalúa ni ejecuta código al
aprobar. El host decide cómo resolver ese digest contra código que ya fue
desplegado y registrado. Rechazar y hacer rollback requieren motivo; el
rollback restaura el binding anterior y aumenta su generación. Todos los
cambios usan scope tenant/account, optimistic locking y auditoría obligatoria.

El dashboard `/agentkit/exploration`, protegido por el guard de consola,
muestra la cola de revisión y permite aprobar, rechazar y revertir. Para probes
de despliegue y retención de los ledgers de cuotas:

```ruby
Agentkit::Exploration.readiness(scope: scope)
Agentkit::Exploration.maintain!(scope: scope, dry_run: true)
```

```bash
# dry-run por defecto; sólo DRY_RUN=0 elimina cuotas anteriores a la retención
TENANT=acct:42 rails agentkit:exploration_maintenance
TENANT=acct:42 DRY_RUN=0 rails agentkit:exploration_maintenance
```

`config.exploration.quota_retention_days` vale 90 por defecto. El mantenimiento
nunca elimina worlds, intentos, expedientes, bindings ni entradas de auditoría.

## Ejecución distribuida, cuotas y dashboard en 0.9

0.9 permite entregar cada world de exploración a Active Job. El registro se
persiste en estado `queued` antes de enviar el job; entregas duplicadas compiten
por el lease durable del world y un world terminal se convierte en un no-op.
Los workers reconstruyen únicamente componentes registrados por nombre y
versión, nunca serializan closures ni código generado.

```ruby
config.exploration.enabled = true
config.exploration.store = :active_record
config.exploration.execution = :distributed
config.exploration.queue = :agentkit_exploration
config.exploration.daily_world_limit = 20
config.exploration.daily_attempt_limit = 200

Rails.application.config.to_prepare do
  Agentkit::Exploration.generators.register(
    :support_discovery, version: "2",
    generator: SupportDiscovery.method(:propose)
  )
  Agentkit::Exploration.evaluators.register(
    :support_quality, version: "4",
    evaluator: SupportEval.method(:score)
  )
end

world = Agentkit::Exploration.enqueue(
  objective: "mejorar resolución de tickets",
  generator: :support_discovery, generator_version: "2",
  evaluator: :support_quality, evaluator_version: "4"
)
```

Los límites son reservas UTC por tenant y día. Cada world y cada ronda usan
una reservation key durable: una redelivery no vuelve a consumir cuota. Si se
agota la cuota de intentos entre rondas, el world termina de forma válida con
`quota_exhausted`; el límite de worlds rechaza la admisión antes de persistir.
`quota_resolver` permite límites por tenant sin compartir contadores.

El dashboard de operaciones está en `/agentkit/exploration`. Expone estados,
intentos, cuotas y procedencia por digest, pero no objetivos, candidatos ni
diagnósticos. Desde 1.0 también contiene la revisión humana de promociones.
Usa exactamente `console.enabled`, `console.guard` y
`console.principal_resolver`, y conserva las cabeceras `no-store` de la consola.
Para reentregar manualmente un world no terminal puede usarse
`Agentkit::Exploration.redispatch(world: id, scope: ...)`.

## Evaluación estadística, Pareto y holdout en 0.8

0.8 separa selección y validación. Las políticas candidatas se evalúan sobre
training, se filtran por cobertura histórica y frontera de Pareto, y sólo el
único candidato seleccionado se compara con el incumbente sobre el holdout.
El resultado continúa siendo una recomendación N3 revisable; nunca una
promoción automática.

```ruby
config.exploration.holdout_fraction = 0.2
config.exploration.holdout_seed = ENV.fetch("AGENTKIT_EXPLORATION_HOLDOUT_SEED")
config.exploration.min_training_worlds = 5
config.exploration.min_holdout_worlds = 5
config.exploration.bootstrap_samples = 2_000
config.exploration.confidence_level = 0.95
config.exploration.min_score_improvement = 0.0

split = Agentkit::Exploration.split_holdout(worlds: replay_worlds)

recommendation = Agentkit::Exploration.recommend(
  incumbent: CurrentPolicy.new,
  candidates: [DepthPolicy.new, RecoveryPolicy.new],
  worlds: replay_worlds
)

recommendation.pareto_frontier
recommendation.comparison&.to_h
recommendation.holdout
```

La asignación automática usa un bucket hash estable: agregar nuevos worlds no
reasigna los anteriores. Para un benchmark congelado puede pasarse
`holdout_worlds:` explícitamente; AgentKit rechaza cualquier world que aparezca
en ambos conjuntos.

`Exploration.compare` calcula diferencias pareadas del replay score sobre los
mismos worlds y un intervalo bootstrap percentil reproducible. Esto cuantifica
incertidumbre, pero no convierte histories correlacionados en muestras
independientes ni corrige evaluator drift. Los pools comparados deben conservar
el mismo evaluator digest.

La frontera de Pareto maximiza calidad y minimiza probes/rondas. Cobertura se
mantiene como gate de evidencia, no como objetivo que pueda compensar una mala
política. Si el holdout domina al candidato, su intervalo cruza el efecto
mínimo, o faltan muestras, `recommend` retiene el incumbente.

## Adaptive Exploration en 0.7.1

0.7 hace explícita la política que decide dónde continuar un descubrimiento,
qué intentos agrupar y cuándo parar. Cada rollout online produce un árbol
tenant-scoped; después, políticas alternativas recorren sólo el prefijo
revelado de ese árbol, sin invocar de nuevo al generador ni al evaluador.

La función objetivo de replay combina mejor calidad observada, costo de probes
y paralelismo útil. Los límites son techos del servidor: un caller puede
reducirlos, nunca ampliarlos. La feature es opt-in.

```ruby
config.exploration.enabled = true
config.exploration.max_rounds = 8
config.exploration.max_parallelism = 4
config.exploration.max_nodes = 64
config.exploration.min_replay_coverage = 0.8

world = Agentkit::Exploration.run(
  objective: "mejorar resolución de tickets",
  generator: ->(parent:, view:) { SupportDiscovery.propose(parent:, view:) },
  evaluator: ->(candidate) { SupportEval.score(candidate) },
  evaluator_id: "support-eval-v3"
)

replay = Agentkit::Exploration.replay(world:, policy: :portfolio)
sweep  = Agentkit::Exploration.sweep(worlds: [world], betas: [0.2, 0.4, 0.6, 0.8])
```

Para operación durable, 0.7.1 crea un checkpoint después de cada ronda y un
registro idempotente por intento. Un proceso interrumpido puede reanudar el
world sin repetir intentos ya terminales:

```ruby
world = Agentkit::Exploration.resume(
  world: world_id,
  policy: :portfolio,
  generator: SupportDiscovery.method(:propose),
  evaluator: SupportEval.method(:score),
  evaluator_id: "support-eval-v3"
)
```

Si un worker había reclamado un intento cuando se perdió el proceso, el intento
pasa a `execution_unknown` sólo después de `attempt_stale_after`; nunca se
repite a ciegas. Un operador debe confirmar su resultado o autorizar el retry:

```ruby
Agentkit::Exploration.reconcile_attempt!(attempt_id, status: :pending)
# o status: :completed, outcome: { score: 0.82, artifact_digest: "sha256:..." }
```

Los evaluadores registrados fijan versión, código, schemas y normalización en
un manifest inmutable. Cambiar el contrato sin cambiar la versión falla cerrado:

```ruby
Agentkit::Exploration.evaluators.register(
  :support_quality,
  version: "3",
  evaluator: SupportEval.method(:score),
  output_schema: {
    type: "object",
    properties: { score: { type: "number" } },
    required: ["score"],
    additionalProperties: false
  },
  normalization: :identity
)
```

`beta` permanece fijo dentro de cada episodio. `sweep` compara puntos mediante
replays frescos y `plan_beta` sólo recomienda el valor del siguiente ciclo. De
igual modo, `recommend` siempre incluye la política incumbente y devuelve una
recomendación N3 revisable; nunca registra/evalúa source code generado ni
promueve una política automáticamente.

Los árboles persisten únicamente digests del objetivo y artefactos, junto con
scores y diagnósticos redactados/acotados. La migración
`018_create_agentkit_exploration_worlds` agrega el replay pool; las migraciones
019 y 020 agregan checkpoints, intentos idempotentes y leases de reanudación.
Cada replay reporta cobertura de decisiones y `recommend` retiene el incumbente
cuando la cobertura media queda bajo `min_replay_coverage`.

## Recuperación sobre grafos en 0.6

0.6 añade snapshots normalizados y versionados para Wiki, CodeGraph y chunks
RAG. La activación sobre grafos es opt-in: el comportamiento default continúa
siendo BM25/vector con RRF.

```ruby
snapshot = Agentkit::TeamMemory::Wiki.build_snapshot("EngineeringWiki")

results = Agentkit::RAG.retrieve(
  "cómo se valida un reembolso",
  corpus_name: "engineering",
  strategy: :hybrid_graph,
  graph: "EngineeringWiki",
  explain: true
)
```

El pipeline filtra tenant, principal, ACL y lifecycle antes de construir la
adyacencia. Después ejecuta Personalized PageRank acotado y fusiona los ranks
vectorial, BM25 y graph mediante RRF. Los caminos explicativos usan aliases
opacos; ante snapshot ausente/inválido o límites agotados vuelve al retrieval
anterior y emite `graph.activation.degraded`.

CodeGraph usa el AST de Ripper, IDs calificados y provenance/confidence. Limita
raíces, tamaño y symlinks mediante `config.team_memory.graph_allowed_roots` y
los límites `graph_max_*`.

Los flows aceptan contratos topológicos y exponen un plan determinista:

```ruby
parallel :review, over: reviewers, branch_effect: :read_only,
                  independence_key: ->(item) { item.id }, max_concurrency: 4
reduce :synthesize, algebra: :associative, ordering: :stable

MyFlow.explain_plan
```

Ejecuta la evaluación etiquetada sin publicar cifras inventadas:

```bash
DATASET=config/graph_retrieval_eval.json bundle exec rake agentkit:graph_eval
```

## Control plane de acciones en 0.5

0.5 separa intención, autorización, ejecución y resultado observado. Una
capacidad que cambia estado ya no se ejecuta directamente desde A2A o MCP:
ambos adaptadores pasan por `Agentkit::Policy` y `Agentkit::Actions`.

```ruby
Agentkit::Capability.register :charge_invoice do |cap|
  cap.input_schema(
    type: "object",
    properties: { invoice_id: { type: "integer" }, cents: { type: "integer" } },
    required: %w[invoice_id cents],
    additionalProperties: false
  )
  cap.output_schema(type: "object", properties: { charge_id: { type: "string" } },
                    required: ["charge_id"], additionalProperties: false)
  cap.effect :external
  cap.risk :irreversible
  cap.required_permission "billing.charge"
  cap.idempotency :required
  cap.reconciliation :required
  cap.executor { |args, idempotency_key:| Payments.charge(**args, idempotency_key:) }
  cap.reconciler { |_args, idempotency_key:| Payments.lookup(idempotency_key:) }
  cap.expose :a2a, mode: :propose
  cap.expose :mcp, mode: :propose
end
```

El lifecycle durable es
`draft → open → approved → executing → executed|execution_failed|execution_unknown`. Una decisión
es un registro distinto de cada intento, y un `unknown` externo exige
reconciliación antes de reintentar. `Agentkit::Receipt.action(id)` devuelve
evidencia portable sin incluir argumentos crudos.

Audit v2 encadena cada evento por tenant con SHA-256 y HMAC. Configura una clave
estable antes de arrancar un store ActiveRecord:

```ruby
config.audit.active_key_id = "2026-09"
config.audit.signing_keys = { "2026-09" => Rails.application.credentials.audit_key }
```

Verifica y vigila el control plane con:

```bash
rails agentkit:audit_verify TENANT=acct:42
rails agentkit:watchtower
rails agentkit:dispatch_actions
```

MCP es un paquete opcional que usa el SDK oficial y no se carga con el gem
principal:

```ruby
gem "agentkit-mcp", "~> 1.0.0"
```

Definir una capacidad no la publica. Cada transporte requiere un `expose`
explícito; MCP no ofrece una herramienta de aprobación.

```ruby
Agentkit::MCP.configure do |mcp|
  mcp.enabled = true
  mcp.authenticator = ->(env) { env["HTTP_AUTHORIZATION"]&.delete_prefix("Bearer ") }
  mcp.principal_resolver = ->(token) { ApiPrincipal.from_token(token) }
  mcp.expose :charge_invoice, mode: :propose
end

mount Agentkit::MCP.rack_app, at: "/mcp"
```

La versión 0.4 añade interoperabilidad A2A 1.0 sobre HTTP+JSON, identidad
multi-tenant, tareas persistentes y Agent Cards firmables, manteniendo el
transporte JSON-RPC anterior durante la migración.

El instalador registra el engine durante `config/application.rb`; hacerlo por
primera vez desde un initializer es demasiado tarde para que Rails incorpore
sus modelos y tareas. El generador puede ejecutarse de nuevo de forma segura si
una instalación anterior no encuentra las migraciones.

### Seguridad operacional en 0.4.1

Las decisiones HITL son atómicas y sus efectos se ejecutan en
`Agentkit::ExecuteSuggestionJob`. Las claves de idempotencia son durables por
tenant y namespace; reutilizar una clave con argumentos distintos produce
`Agentkit::IdempotencyConflict`.

La captura de prompts y la consola web están desactivadas por defecto:

```ruby
config.audit.prompt_preview_chars = 0
config.audit.failure_mode = :best_effort # usa :required para fallar cerrado

config.console.enabled = true
config.console.principal_resolver = -> { current_user }
config.console.guard = ->(principal) { principal.admin? }
# Optional: only this permission sees unredacted suggestion payloads.
config.console.payload_guard = ->(principal) { principal.security_admin? }
```

Conserva las filas de `agentkit_suggestions` durante todo el horizonte en el
que prometes reintentos idempotentes. Borrarlas elimina esa garantía.

---

## Novedades en la versión 0.4.0

- Agent Card A2A 1.0 en `/.well-known/agent-card.json`.
- Binding `HTTP+JSON`, negociación mediante `A2A-Version: 1.0` y media type
  `application/a2a+json`.
- Mensajes, tareas, artefactos y estados `INPUT_REQUIRED`/`AUTH_REQUIRED`.
- Identidad y almacenamiento durable de tareas aislados por tenant.
- Autenticación Bearer, firma RS256/JWS y verificación configurable.
- Cliente A2A 1.0 saliente con HTTPS obligatorio para peers remotos.
- Compatibilidad opt-out con JSON-RPC 0.2 y `/.well-known/agent.json`.

Para actualizar desde 0.3, instala las migraciones del engine y ejecuta
`rails db:migrate`; la migración `014_create_agentkit_a2a_tasks` agrega la
persistencia A2A.

## Novedades en la versión 0.3.0

La versión **0.3.0** incorpora una arquitectura completa de **RAG Nativo**, **Orquestación Distribuida para Documentos Masivos**, el **Team Memory Hub** (basado en TencentDB Agent Memory) y **Mejoras Avanzadas de Memoria**.

### 1. 📚 RAG Nativo (`Agentkit::RAG`) y Orquestación Distribuida

Integración completa de Retrieval-Augmented Generation directamente en el gem sin dependencias externas complejas.

#### Componentes RAG:
- **Indexación Híbrida**: Búsqueda vectorial densa + Okapi BM25 (`BM25Index`) con fusión **Reciprocal Rank Fusion (RRF)**.
- **Estrategias de Chunking**: `sliding_window`, `semantic`, `sentence` y **`ChapterChunker`** por expresiones regulares de encabezado o presupuesto de tamaño (`max_slice_mb`).
- **Almacenamiento por Capas (`KnowledgeStore`)**: Soporte síncrono/asíncrono con backend en memoria (`:memory` singleton) y PostgreSQL con `pgvector` + `tsvector` (`008_create_agentkit_knowledge.rb`).

#### Integración en Agentes (`RAG::AgentConcern`):
```ruby
class SecurityComplianceAgent < ApplicationAgent
  use_knowledge :enterprise_rules, filter: { department: "security" }

  def call(input)
    chunks = rag_retrieve(input[:query])
    context_text = rag_context(input[:query])
    # ...
  end
end
```

#### Orquestación Distribuida Map/Reduce (`CoordinatorFlow`):
Permite partir archivos masivos (e.g. PDFs de 90MB+) por capítulo y lanzar sub-agentes en paralelo con control de concurrencia:
```ruby
flow_run = Agentkit::RAG::CoordinatorFlow.call(
  pdf_text: pdf_content,
  corpus_name: "large_book",
  strategy: :heading_regex,
  max_slice_mb: 10,
  max_concurrency: 4
)

flow_run.value[:global_index] # Lista reducida de referencias bibliográficas
```

---

### 2. 🏛️ Team Memory Hub (`Agentkit::TeamMemory`)

Un hub de memoria a nivel de equipo basado en la arquitectura **TencentDB Agent Memory**, gobernando 4 tipos de assets reutilizables entre agentes y frameworks:

1. **Chat Memory**: Escenas y conversaciones estructuradas.
2. **Skill**: Habilidades ejecutables y fragmentos de prompt.
3. **Wiki Engine**: Documentación con enlaces tipo `[[Wikilink]]` y búsqueda de páginas.
4. **CodeGraph Engine**: Análisis estático de Ruby con `Ripper` para mapear clases, módulos, métodos, llamadas callers/callees y análisis de impacto en cascada.

#### Control de Acceso (ACL):
Reglas de gobernanza con visibilidad `private` (dueño), `team` (equipo), `restricted` (agentes vinculados) y `public/agent`.

#### Integración en Agentes (`TeamMemory::AgentConcern`):
```ruby
class IncidentAgent < ApplicationAgent
  belongs_to_team "SecurityTeam"

  def call(input)
    assets = load_team_assets
    share_skill("DDoSResponse", prompt_fragment: "Activar reglas de firewall en Cloudflare.")
  end
end
```

#### Dashboard Web:
Accedé a la consola de gobernanza de memoria en `/agentkit/team_memory`.

---

### 3. 🌟 Mejoras de Memoria Avanzada

- **4 Capas de Memoria (`Memory::Layers`)**: Progresión continua L0 (logs crudos) → L1 (átomos) → L2 (escenarios/escenas) → L3 (personas/skills).
- **ColdStart Importer (`Memory::ColdStart`)**: Ingesta masiva de transcripciones históricas JSON/JSONL preservando timestamps originales.
- **Custom Prompts (`Memory::CustomPrompts`)**: Plantillas personalizables por inquilino/equipo con interpolación de contexto (`{tenant}`, `{input}`).
- **Recall por Ventanas de Tiempo**: `Memory.recall(query, since: 1.day.ago, until: Time.now)`.
- **Comandos Interactivos `mem:`**: Intercepción en `Agentkit::Chat.say`:
  - `mem:status` → Estado de registros y assets.
  - `mem:sync` → Sincronización y flush de embeddings.
  - `mem:skill` → Extracción de skill de la sesión.
  - `mem:help` → Ayuda interactiva.
- **Skill Export & Import (`SkillExport`)**: Exporta e importa habilidades como paquetes estructurados `SKILL.md` + `tools.json`.

---

### 🧪 Ejemplo Real de Verificación

Ejecutá el script completo en `examples/v03_demo.rb` (utiliza tu `GEMINI_API_KEY` cargada desde `.env`):
```bash
ruby examples/v03_demo.rb
```

---

## Qué cambia respecto a 0.1

v0.1 se usó en seis aplicaciones reales. Cinco de ellas vendorizaron la gema y le
aplicaron el mismo parche, tres reimplementaron A2A por su cuenta, cuatro
escribieron su propio `parse_json`, y la Fábrica de auto-mejora terminó con **cero
usos en seis proyectos**. v2/v3 están construidas a partir de ese diagnóstico.

| Problema en 0.1 | v2 / v3 |
|---|---|
| `RubyLLM.chat(model:, messages:, system:)` no existe — 5 forks idénticos | Adaptador verificado contra la gema real, soporte OpenAI-compatible / Gemini, más `:fake` oficial |
| Sin RAG nativo ni ingesta distribuida | `Agentkit::RAG` nativo con BM25+Dense+RRF y `CoordinatorFlow` paralelo para PDFs de 90MB+ |
| Sin memoria compartida a nivel de equipo | `TeamMemory` Hub (ChatMemory, Skill, Wiki, CodeGraph, ACL) basado en TencentDB |
| `perform_in` es API de Sidekiq, no de ActiveJob | Scheduling por puerto; `set(wait:).perform_later` en el engine |
| `trigger_agent` ejecutaba N² veces (3 bots → 9 llamadas LLM) | Un solo callback por evento; spec de regresión |
| Cada `memorize!` = una llamada de embedding | 7 políticas, default `:on_promotion`,Layers L0-L3 y `ColdStart` |
| Aprobar una sugerencia no ejecutaba nada | `HITL.on(type) { }` y `human_gate` que reanuda el flow |
| Sin forma de expresar paralelo/fan-in | Flow engine con barrera atómica y concurrencia configurable |

---

## Los cinco pilares

### 1. Flow engine — secuencial, paralelo y fan-in real

```ruby
class OverdueInvoiceCouncilFlow < Agentkit::Flow
  input :factura
  idempotency ->(i) { "council:invoice:#{i[:factura].id}" }

  step :observe, agent: PaymentMonitorAgent

  parallel :council, over: [FinanceBotAgent, AccountingBotAgent, CeoBotAgent],
                     with: ->(ctx) { ctx[:observe].memory }
  join     :council, on: :all_settled, timeout: 180, on_timeout: :continue_with_partial

  step :synthesize, agent: CouncilSynthesizerAgent,
       input: ->(ctx) { ctx[:council].values }

  human_gate :approve, timeout: 48 * 3600, on_timeout: :auto_reject
  step :apply, if: ->(ctx) { ctx[:approve].approved? }, agent: ApplyDecisionAgent

  compensate :apply, with: ->(ctx) { Rollback.call(ctx) }
end

OverdueInvoiceCouncilFlow.call(factura: invoice)          # síncrono
OverdueInvoiceCouncilFlow.perform_later(factura: invoice) # asíncrono
```

Primitivas: `step` · `parallel` · `join` · `map`/`reduce` · `loop_until` · `race` ·
`human_gate` · `sub_flow` · `on_error` · `compensate`.

**El join no es un `sleep`.** El fan-out crea la barrera con `pending_count = N`;
cada rama la decrementa atómicamente al cerrarse y la que llega a 0 dispara la
continuación. Una reentrega de job encuentra el paso ya `completed` y no
decrementa dos veces.

Estado en `agentkit_runs` / `agentkit_run_steps`, con índice único
`(run_id, step_key)`: eso es lo que hace que un run sea reanudable e idempotente.

**En modo async** cada rama es su propio job y lleva en su fila todo lo que
necesita, así que corre en cualquier worker. El run **se suspende** en un join o
en un gate humano en vez de bloquear un worker, y la rama que baja la barrera a
cero encola la continuación.

```ruby
Agentkit.config.flow.dispatcher = :active_job   # :inline | :test

run = MiFlow.perform_later(factura: invoice)    # devuelve el run aparcado
run.status                                      # => "pending" → "waiting_join" → "completed"
```

Los payloads entre jobs pasan por `Flow::Coder`: los registros viajan como
referencia y se recargan del otro lado (nunca una copia vieja), y lo que excede
`max_inline_payload` se guarda como artefacto. El timeout de un join es **un job
programado por join**, no un poller, con tres políticas:
`:continue_with_partial` cancela a los rezagados y sigue, `:compensate` deshace
la saga, `:fail` corta.

### 2. Memoria: guardar y vectorizar son decisiones distintas

```ruby
config.memory.level            = :hybrid       # :off :log :keyword :hybrid :semantic :full
config.memory.embedding.policy = :on_promotion # solo lo que se promueve recibe vector
```

```ruby
memorize!(txt, embed: false)        # nunca
memorize!(txt, embed: :now)         # ahora, pase lo que pase la política
recall!(q, mode: :keyword)          # 0 llamadas a la API
Agentkit::Memory.estimate_embedding_cost(policy: :on_promotion)
# => { memories: 21, would_embed: 3, usd: 0.0001, vs_immediate: { would_embed: 21, ... } }
```

Cuatro niveles de configuración: **global → tenant → agente → llamada** (gana la
llamada). Más dedupe por `content_hash`, caché de query, presupuesto por tenant
que **degrada a keyword en vez de lanzar excepción**, y GC de vectores al archivar.

```ruby
class SkinDiagnosticAgent < ApplicationAgent
  memory_policy level: :log, embedding: :never   # sin sobreescribir memorize!
end
```

### 3. Cognición on-demand

Dreaming, Summarizer e Imagination son el mismo motor con distinta estrategia.
Cron es *un* disparador entre cuatro (cron / HTTP / CLI / paso de flow).

```ruby
Agentkit::Cognition.run(:dreaming,   dry_run: true)          # plan sin escribir nada
Agentkit::Cognition.run(:summarizer, source: memories, strategy: :map_reduce)
Agentkit::Cognition.run(:imagination, focus: "retención enterprise",
                                      divergence: { strategy: :cross_agent, threshold: 0.65 },
                                      gates: { innovation: 0.6 })
```

- **Dreaming** consolida de forma **no destructiva** (`superseded_by`, con rollback) y
  puede agrupar sin embeddings (`strategy: :lexical`) o con una sola llamada en
  lote (`:batch_embed`).
- **Summarizer** acepta cualquier fuente, cinco estrategias, presupuesto de tokens
  y caché por hash de contenido.
- **Imagination** corre las tres fases (divergencia → incubación → verificación)
  **localmente**, sin depender de un servicio externo, y guarda los escenarios con
  `ontological_type: "imagined"` — el cortafuegos ontológico vive en el kernel:
  `recall!` nunca los devuelve salvo `include: :imagined`.

### 4. HITL con ledger de decisiones

```ruby
Agentkit::HITL.on("council_recommendation") { |s| ApplyDecision.call(s.payload) }

Agentkit::HITL.reject(id, actor: "human:1", code: :wrong_target)  # taxonomía cerrada
Agentkit::HITL.ledger.summary(agent: "SalesAgent")
# => { acceptance_rate:, clean_acceptance_rate:, ignore_rate:,
#      rejection_profile:, time_to_decision:, cost_per_accepted: }
```

`mode` separa juicios humanos de vencimientos automáticos: **una aprobación por
timeout nunca cuenta como validación**. Cada rechazo o edición se convierte en un
caso del golden set con la corrección humana como salida esperada.

### 5. Fábrica de mejora continua

```
OBSERVE → DIAGNOSE → HYPOTHESIZE → EXPERIMENT → EVALUATE → ADOPT/ROLLBACK
```

Los hallazgos los produce **código determinista con evidencia**, no un LLM
opinando: `acceptance_drop`, `rejection_cluster`, `ignored_proposals`,
`retrieval_useless`, `cost_spike`, `schema_thrash`, `model_overkill`,
`join_starvation`, `capability_gap`.

Escalera de intervención por riesgo:

| Nivel | Cambia | Reversible | Automático |
|---|---|---|---|
| N1 | parámetros (modelo, k, umbrales, política de embedding) | sí | sí |
| N2 | prompts versionados con canary | sí | sí |
| N3 | políticas HITL y gates | sí | no |
| N4 | composición (context providers, pasos) | sí | no |
| N5 | código | — | **solo emite un patch revisable, nunca escribe en disco** |

Hallazgos, experimentos, golden cases y corridas de diagnóstico persisten en
PostgreSQL. Los hallazgos activos se deduplican por fingerprint y conservan
recurrencia, primera/última observación y resolución auditable.

N1–N4 requieren un adaptador registrado con `apply/adopt/rollback`; no existe
un escritor genérico de configuración. N2 compara brazos concurrentes ligados a
`experiment_id`; los cambios globales N1/N3/N4 comparan una ventana base
capturada antes de aplicar contra la cohorte temporal posterior. El motor impide
experimentos simultáneos con cohortes solapadas.

Nada se promueve sin `min_samples`, efecto mínimo, significancia estadística,
duración mínima, no-regresión del golden set y datos de costo. Si falta un
runner, una cohorte o costo, falla cerrado como inconcluso. Los guardrails de
aceptación y costo viven en `Agentkit::FactoryGuardrailsJob` para correr con más
frecuencia que el diagnóstico semanal.

```bash
rails agentkit:factory_report          # informe del ciclo en Markdown
```

### Bonus: chat propositivo e interactivo

```ruby
turn = Agentkit::Chat.open(candidates: Company.recent)
# => "Según tu setup, te propongo estas 2 acciones:"
#    · "Traer los 12 contactos de dirección de Acme"
#      why: ["sector saas está en tu ICP", "3 visitas a tu landing esta semana"]

# Comandos de memoria interactivos:
Agentkit::Chat.say("mem:status") # => "Estado de Memoria: 4 registros, 2 assets de equipo."
```

Sin `why` trazable, la propuesta no se muestra. Aceptar ejecuta un Flow con HITL;
el chat nunca actúa por su cuenta. Una orden imperativa se convierte igualmente en
propuesta confirmable, así el 100 % de las acciones pasa por el mismo carril de
telemetría. Y una intención sin capacidad detrás genera un `capability_gap`, que
es un hallazgo para la fábrica.

---

## A2A 1.0: identidad multi-tenant y tareas estándar

```ruby
config.a2a.enabled    = true
config.a2a.secret_key = ENV["AGENTKIT_A2A_KEY"]
config.a2a.expose     = %i[import_contacts]   # nil = todas las elegibles
config.a2a.tenant_resolver = ->(request) {
  Account.find_by(subdomain: request.subdomains.first)
}
config.a2a.key_resolver = ->(token) { Account.find_by(a2a_token: token) }
```

`GET /.well-known/agent-card.json` devuelve una Agent Card A2A 1.0 generada para
el tenant actual. Solo anuncia capacidades cuyas **precondiciones se cumplen**.
La interfaz preferida es `HTTP+JSON` y declara `protocolVersion: "1.0"`.

Un mensaje remoto entra por el mismo carril que una propuesta local —
Capability → Flow → HITL → auditoría. Lo irreversible **no se ejecuta**: se
representa como `TASK_STATE_AUTH_REQUIRED`. Los argumentos faltantes producen
`TASK_STATE_INPUT_REQUIRED` y pueden completarse en otro mensaje.

```bash
curl -X POST https://acme.test/agentkit/a2a/message:send \
  -H "Authorization: Bearer $KEY" -H "A2A-Version: 1.0" \
  -H "Content-Type: application/a2a+json" -d '{
  "message":{"role":"ROLE_USER","messageId":"msg-1",
    "metadata":{"skillId":"issue_refund"},
    "parts":[{"data":{"order_id":42}}]}}'
```

Y hacia afuera, para federar:

```ruby
peer = Agentkit::A2A::V1::Client.new(base_url: "https://peer.test", token: ENV["PEER_KEY"])
peer.send_message({
  role: "ROLE_USER", messageId: SecureRandom.uuid,
  metadata: { skillId: "reserve_slot" },
  parts: [{ data: { date: "2026-08-01" } }]
})
```

El cliente JSON-RPC anterior y `/.well-known/agent.json` siguen disponibles
durante la migración. Se desactivan con `config.a2a.legacy = false`.

### Firmar y verificar Agent Cards

```ruby
config.a2a.signing_key = ENV["AGENTKIT_A2A_SIGNING_KEY_PEM"]
config.a2a.signing_key_id = "provider-2026-01"
config.a2a.signing_jwks_url = "https://acme.test/.well-known/jwks.json"

# Cliente saliente: :disabled | :if_present | :required
config.a2a.verification = :required
config.a2a.trusted_keys = {
  "peer-2026-01" => ENV["PEER_A2A_PUBLIC_KEY_PEM"]
}
```

La firma es opcional. AgentKit no descarga ni confía automáticamente en claves
indicadas por `jku`; el operador debe incorporarlas explícitamente a
`trusted_keys`.

## Consola

Montá el engine y tenés tres pantallas principales:

- **`/agentkit`** — bandeja HITL en vivo (Turbo Streams). Aprobar ejecuta el
  handler y reanuda el flow suspendido; rechazar exige un código de la taxonomía
  cerrada.
- **`/agentkit/team_memory`** — panel de gobernanza de Team Memory Hub (ChatMemory, Skill, Wiki, CodeGraph).
- **`/agentkit/runs`** — timeline por paso, con la barrera del fan-out y sus
  ramas visibles: un join atascado se diagnostica en vez de ser un misterio.
- **`/agentkit/factory`** — hallazgos con evidencia, calidad por agente, economía y botones de cognición.

---

## Telemetría desde el día 0

El usuario del framework **no instrumenta nada** para obtener el 90 % de la señal:
`llm.call`, `memory.write`, `memory.recall`, `memory.recall.used`,
`embedding.generate`, `hitl.propose`, `hitl.decide`, `flow.step.*`,
`flow.join.resolve`, `trigger.fire`, `proposal.*` ya están sondeados.

```ruby
Agentkit::Telemetry.stats("llm.call", measure: :duration_ms, by: :model)

Agentkit.probe(:lead_qualified, dims: { source: "outreach" })
Agentkit.outcome(:deal_closed, for: proposal, value: -> { deal.amount })
```

---

## Arquitectura

```
lib/agentkit/          núcleo en Ruby plano, sin dependencia de Rails
  ├─ context, result, settings, configuration
  ├─ llm/ (adapters, schema, pricing)   telemetry/ (stats, backends)
  ├─ memory/ (policy, embedder, stores, layers, cold_start, custom_prompts)
  ├─ rag/ (bm25, chunker, chapter_chunker, indexer, retriever, pipeline, coordinator_flow)
  ├─ team_memory/ (acl, team, asset, wiki, code_graph, skill_extractor, layered_pipeline)
  ├─ exploration (online rollout, prefix-only replay, policy evaluation)
  ├─ flow/ (definition, executor, run)
  ├─ hitl/ (ledger)   cognition/ (processors)   factory
  └─ capability, setup, proposals, agent, skill, skill_export, prompt
app/                   engine Rails: modelos AR, controllers, views, concerns
db/migrate/            migraciones aditivas, incluida 018 para replay worlds
```

---

## Testing

```ruby
Agentkit::Flow.test_mode!   # executor síncrono, LLM fake, stores en memoria
Agentkit.config.memory.store = :memory
Agentkit.config.rag.store    = :memory
```

```bash
bundle install
bundle exec rake verify     # validación sintáctica + suite completa
```

---

## Licencia

MIT
