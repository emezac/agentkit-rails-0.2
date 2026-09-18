# AgentKit Rails v0.7.0

**Kernel de agentes para aplicaciones Rails** — orquestación real, RAG nativo, Team Memory Hub (TencentDB Agent Memory), memoria on-demand, HITL con ledger de decisiones y una fábrica de mejora continua desde el día 0.

```ruby
gem "agentkit-rails", "~> 0.7.0"
```

```bash
rails g agentkit:install --with-chat
rails g agentkit:rag
rails g agentkit:team_memory
rails db:migrate
rails agentkit:doctor
```

## Adaptive Exploration en 0.7

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

world = Agentkit::Exploration.run(
  objective: "mejorar resolución de tickets",
  generator: ->(parent:, view:) { SupportDiscovery.propose(parent:, view:) },
  evaluator: ->(candidate) { SupportEval.score(candidate) },
  evaluator_id: "support-eval-v3"
)

replay = Agentkit::Exploration.replay(world:, policy: :portfolio)
sweep  = Agentkit::Exploration.sweep(worlds: [world], betas: [0.2, 0.4, 0.6, 0.8])
```

`beta` permanece fijo dentro de cada episodio. `sweep` compara puntos mediante
replays frescos y `plan_beta` sólo recomienda el valor del siguiente ciclo. De
igual modo, `recommend` siempre incluye la política incumbente y devuelve una
recomendación N3 revisable; nunca registra/evalúa source code generado ni
promueve una política automáticamente.

Los árboles persisten únicamente digests del objetivo y artefactos, junto con
scores y diagnósticos redactados/acotados. La migración
`018_create_agentkit_exploration_worlds` agrega el replay pool durable.

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
gem "agentkit-mcp", "~> 0.7.0"
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
