# AgentKit Rails v2

**Kernel de agentes para aplicaciones Rails** — orquestación real, memoria on-demand,
HITL con ledger de decisiones y una fábrica de mejora continua desde el día 0.

```ruby
gem "agentkit-rails", "~> 0.2"
```

```bash
rails g agentkit:install --with-chat
rails db:migrate
rails agentkit:doctor
```

---

## Qué cambia respecto a 0.1

v0.1 se usó en seis aplicaciones reales. Cinco de ellas vendorizaron la gema y le
aplicaron el mismo parche, tres reimplementaron A2A por su cuenta, cuatro
escribieron su propio `parse_json`, y la Fábrica de auto-mejora terminó con **cero
usos en seis proyectos**. v2 está construida a partir de ese diagnóstico.

| Problema en 0.1 | v2 |
|---|---|
| `RubyLLM.chat(model:, messages:, system:)` no existe — 5 forks idénticos | Adaptador verificado contra la gema real, más `:fake` oficial |
| `perform_in` es API de Sidekiq, no de ActiveJob | Scheduling por puerto; `set(wait:).perform_later` en el engine |
| `trigger_agent` ejecutaba N² veces (3 bots → 9 llamadas LLM) | Un solo callback por evento; spec de regresión |
| `on: :destroy, async: true` nunca funcionó | Snapshot serializado en vez de id |
| Cada `memorize!` = una llamada de embedding | 7 políticas, default `:on_promotion` |
| Aprobar una sugerencia no ejecutaba nada | `HITL.on(type) { }` y `human_gate` que reanuda el flow |
| Sin forma de expresar paralelo/fan-in | Flow engine con barrera atómica |
| Fábrica que medía conteos y escribía Ruby en disco | Detectores deterministas + escalera N1–N5, N5 solo emite PR |
| A2A del kernel con 0 usos (3 proyectos escribieron el suyo) | Card generada desde el registro de Capabilities |
| Specs con un `module RubyLLM` inventado | Puerto `:fake` real; 203 specs (166 unitarios + 37 de integración contra Postgres) |

Detalle completo: `PLAN_V2.md`, `FLOW_ENGINE.md`, `MEMORY_POLICY.md`,
`FACTORY_AND_CHAT.md` en `agentkit-rails2/`.

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
| N5 | código | — | **solo emite un PR, nunca escribe en disco** |

Nada se promueve sin `min_samples`, efecto mínimo, significancia estadística y
no-regresión del golden set.

```bash
rails agentkit:factory_report          # informe del ciclo en Markdown
```

### Bonus: chat propositivo

```ruby
turn = Agentkit::Chat.open(candidates: Company.recent)
# => "Según tu setup, te propongo estas 2 acciones:"
#    · "Traer los 12 contactos de dirección de Acme"
#      why: ["sector saas está en tu ICP", "3 visitas a tu landing esta semana"]
```

Sin `why` trazable, la propuesta no se muestra. Aceptar ejecuta un Flow con HITL;
el chat nunca actúa por su cuenta. Una orden imperativa se convierte igualmente en
propuesta confirmable, así el 100 % de las acciones pasa por el mismo carril de
telemetría. Y una intención sin capacidad detrás genera un `capability_gap`, que
es un hallazgo para la fábrica.

---

## A2A: la card se genera, no se escribe a mano

```ruby
config.a2a.enabled    = true
config.a2a.secret_key = ENV["AGENTKIT_A2A_KEY"]
config.a2a.expose     = %i[import_contacts]   # nil = todas las elegibles
```

`GET /.well-known/agent.json` devuelve las capacidades cuyas **precondiciones se
cumplen ahora mismo**, con su riesgo y si van a requerir un humano:

```json
{ "id": "issue_refund", "risk": "irreversible", "requiresHumanApproval": true }
```

Una invocación remota entra por el mismo carril que una propuesta local —
Capability → Flow → HITL → auditoría. Lo irreversible **no se ejecuta**: se
aparca como sugerencia y el par recibe un `taskId` para consultar.

```bash
curl -X POST https://acme.test/agentkit/a2a/rpc -H "X-A2A-Key: $KEY" -d '{
  "jsonrpc":"2.0","id":"1","method":"capabilities.invoke",
  "params":{"capability":"issue_refund","inputs":{"order_id":42}}}'
# => { "result": { "status": "pending_approval", "taskId": "suggestion:17" } }
```

Y hacia afuera, para federar como hizo `tres`:

```ruby
peer = Agentkit::A2A::Client.new(base_url: "https://peer.test", key: ENV["PEER_KEY"])
peer.call_capability(:reserve_slot, { date: "2026-08-01" }, poll: true)
```

## Consola

Montá el engine y tenés tres pantallas:

- **`/agentkit`** — bandeja HITL en vivo (Turbo Streams). Aprobar ejecuta el
  handler y reanuda el flow suspendido; rechazar exige un código de la taxonomía
  cerrada, que es lo que convierte un rechazo en señal de mejora.
- **`/agentkit/runs`** — timeline por paso, con la barrera del fan-out y sus
  ramas visibles: un join atascado se diagnostica en vez de ser un misterio.
- **`/agentkit/factory`** — hallazgos con evidencia, calidad por agente
  (aceptación *excluyendo* vencimientos automáticos), economía y botones de
  cognición on-demand.

La vista de una sugerencia hipotética enlaza con su traza XAI: qué memorias la
originaron y qué puntuó cada fase.

## Telemetría desde el día 0

El usuario del framework **no instrumenta nada** para obtener el 90 % de la señal:
`llm.call`, `memory.write`, `memory.recall`, `memory.recall.used`,
`embedding.generate`, `hitl.propose`, `hitl.decide`, `flow.step.*`,
`flow.join.resolve`, `trigger.fire`, `proposal.*` ya están sondeados.

```ruby
Agentkit::Telemetry.stats("llm.call", measure: :duration_ms, by: :model)
# => { "claude-opus-4-6" => Stats(n=42 mean=980.0 p50=910.0 p95=2310.0 max=4100.0) }

Agentkit.probe(:lead_qualified, dims: { source: "outreach" })   # sondas de dominio
Agentkit.outcome(:deal_closed, for: proposal, value: -> { deal.amount })
```

Escritura en lote y muestreo configurable — nunca un INSERT sincrónico por llamada.

---

## Arquitectura

```
lib/agentkit/          núcleo en Ruby plano, sin dependencia de Rails
  ├─ context, result, settings, configuration
  ├─ llm/ (adapters, schema, pricing)   telemetry/ (stats, backends)
  ├─ memory/ (policy, embedder, stores)  flow/ (definition, executor, run)
  ├─ hitl/ (ledger)   cognition/ (processors)   factory
  └─ capability, setup, proposals, agent, skill, prompt
app/                   engine Rails: modelos AR, jobs, concern de triggers
db/migrate/            5 migraciones
```

El núcleo no asume Rails, ni un modelo `User`, ni Sidekiq, ni un proveedor
concreto. Cada adaptador degrada a un no-op o a un `ConfigurationError` claro
cuando falta su dependencia.

---

## Testing

```ruby
Agentkit::Flow.test_mode!   # executor síncrono, LLM fake, stores en memoria

Agentkit::LLM::Adapters::Fake.respond_with({ concept: "x", score: 0.9 })
Agentkit::LLM::Adapters::Fake.fail_on(times: 2)
Agentkit::HITL.auto_approve!(type: "council_recommendation")
```

El adaptador `:fake` es parte de la superficie pública y produce **embeddings
deterministas** (mismo texto → mismo vector), así que las aserciones de recall son
reproducibles.

```bash
rspec spec/lib spec/flow spec/memory spec/factory   # 166 unit examples
rspec spec/integration                              # 37 against real Postgres
rspec                                               # 203 examples, 0 failures
```

**`spec/dummy` es una app Rails de verdad** con Postgres y pgvector. Existe
porque once defectos reales pasaron por delante de una suite unitaria en verde:
los stores en memoria aceptan `nil` en columnas `NOT NULL`, registran los pasos
en el `Run` gratis y nunca pierden estado al reiniciar. Probar el algoritmo no
es probar la integración.

---

## Licencia

MIT
