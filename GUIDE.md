# Guía completa de agentkit-rails v0.4.0

> **Kernel de Agentes de IA para Aplicaciones Rails** — Orquestación distribuida, RAG nativo, Team Memory Hub (TencentDB Agent Memory), memoria semántica por capas (L0-L3), HITL con ledger de decisiones y Fábrica de mejora continua desde el día 0.

---

## Tabla de contenidos

1. [¿Qué es agentkit-rails v0.4?](#1-qué-es-agentkit-rails-v04)
2. [Principales novedades de la versión 0.4.0](#2-principales-novedades-de-la-versión-040)
3. [Instalación y Configuración](#3-instalación-y-configuración)
4. [Arquitectura y los Pilares del Kernel](#4-arquitectura-y-los-pilares-del-kernel)
5. [RAG Nativo y Orquestación Distribuida](#5-rag-nativo-y-orquestación-distribuida)
6. [Team Memory Hub (TencentDB Agent Memory)](#6-team-memory-hub-tencentdb-agent-memory)
7. [Memoria Semántica y Capas L0-L3](#7-memoria-semántica-y-capas-l0-l3)
8. [Flow Engine (Secuencial, Paralelo, Async & Sagas)](#8-flow-engine-secuencial-paralelo-async--sagas)
9. [Human-in-the-Loop (HITL) y Ledger](#9-human-in-the-loop-hitl-y-ledger)
10. [Cognición On-Demand e Imagination Firewall](#10-cognición-on-demand-e-imagination-firewall)
11. [Fábrica de Auto-Mejora Continua](#11-fábrica-de-auto-mejora-continua)
12. [Chat Propositivo e Interactivo (`mem:` commands)](#12-chat-propositivo-e-interactivo-mem-commands)
13. [Protocolo A2A (Agent-to-Agent)](#13-protocolo-a2a-agent-to-agent)
14. [Consola Web Dashboard](#14-consola-web-dashboard)
15. [Testing y Modo `:fake`](#15-testing-y-modo-fake)
16. [Ejemplo Completo de Demostración](#16-ejemplo-completo-de-demostración)
17. [Referencia de Configuración](#17-referencia-de-configuración)

---

## 1. ¿Qué es agentkit-rails v0.4?

`agentkit-rails` es un `Rails::Engine` de grado de producción que transforma cualquier aplicación Rails 8 en una plataforma avanzada de agentes autónomos y colaborativos. Proporciona:

- **Orquestación Distribuida (Flow Engine)**: Ejecución síncrona/asíncrona con barrera atómica SQL, resumiendo ejecuciones tras fallos o pausas por aprobación humana sin consumir threads de workers.
- **RAG Nativo (`Agentkit::RAG`)**: Motor híbrido BM25 + Vectores Densos con **Reciprocal Rank Fusion (RRF)** y orquestación distribuida Map/Reduce (`CoordinatorFlow`) para procesar documentos de gran volumen (e.g. PDFs de 90MB+).
- **Team Memory Hub (`Agentkit::TeamMemory`)**: Gobernanza de memoria a nivel de equipo basada en la arquitectura **TencentDB Agent Memory**, compartiendo ChatMemory, Skill, Wiki (enlaces `[[Wikilink]]`) y CodeGraph (análisis estático de Ruby con `Ripper`).
- **Memoria Semántica por Capas (L0-L3)**: Ingesta de conversaciones históricas (`ColdStart`), plantillas dinámicas por tenant (`CustomPrompts`), filtrado temporal (`since:`, `until:`) e intercepción de comandos interactivos (`mem:`).
- **HITL (Human-in-the-Loop) & Decision Ledger**: Taxonomía cerrada de rechazos, ejecución automática de handlers y métricas de desempeño.
- **Fábrica de Auto-Mejora**: Detección determinista con evidencia de cuellos de botella y experimentos con escalera N1–N5.
- **Protocolo A2A 1.0**: Agent Cards multi-tenant, HTTP+JSON, tareas
  persistentes, HITL, firmas JWS y cliente saliente verificable.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Tu Aplicación Rails                             │
│   (Modelos AR, Controllers, Jobs, UI de Negocio)                       │
├────────────────────────────────────────────────────────────────────────┤
│                     agentkit-rails Engine v0.4                         │
│  Flows · Native RAG · Team Memory Hub · Memory L0-L3 · HITL · A2A      │
├────────────────────────────────────────────────────────────────────────┤
│                 Infraestructura de Datos y Modelos                     │
│  PostgreSQL (pgvector + tsvector) · Redis · ActiveJob · OpenRouter/LLM │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Principales novedades de la versión 0.4.0

1. **A2A 1.0 sobre HTTP+JSON**: descubrimiento estándar, mensajes, tareas,
   artefactos, negociación de versión y respuestas `application/a2a+json`.
2. **Identidad multi-tenant**: una Agent Card por cuenta o subdominio y tareas
   aisladas por `tenant_key`.
3. **Interacción progresiva y HITL**: datos faltantes producen
   `TASK_STATE_INPUT_REQUIRED`; operaciones con aprobación producen
   `TASK_STATE_AUTH_REQUIRED`.
4. **Confianza configurable**: Bearer, Agent Cards RS256/JWS y verificación
   `:disabled`, `:if_present` o `:required`.
5. **Migración compatible**: JSON-RPC y `/.well-known/agent.json` permanecen
   disponibles hasta establecer `config.a2a.legacy = false`.

Las capacidades incorporadas en 0.3 —RAG nativo, CoordinatorFlow, Team Memory
Hub y memoria L0-L3— permanecen disponibles sin cambios incompatibles.

### Componentes incorporados originalmente en 0.3

1. **Épica 1 — RAG Nativo**:
   - Ingestador BM25 (`BM25Index`), Chunkers (sliding, semantic, sentence, `ChapterChunker`).
   - `KnowledgeStore` con soporte `:memory` (singleton) y PostgreSQL `pgvector` + `tsvector`.
   - DSL `use_knowledge` y helpers de agente (`rag_retrieve`, `rag_context`, `rag_generate`).
2. **Épica 1.5 — CoordinatorFlow**:
   - Flujo de orquestación Map/Reduce para partir documentos masivos (90MB+) por capítulos y coordinar sub-agentes en paralelo con control dinámico de concurrencia.
3. **Épica 2 — Team Memory Hub**:
   - Motor ACL de permisos (`private`, `team`, `restricted`, `agent`, `public`).
   - Wiki Engine (con análisis de wikilinks `[[Link]]`).
   - CodeGraph Engine (análisis estático AST con `Ripper` para símbolos Ruby, callers/callees y mapa de impacto).
   - `SkillExtractor` y empaquetado de habilidades `SkillExport` (`SKILL.md` + `tools.json`).
   - Pipeline en capas L0 → L1 → L2 → L3.
4. **Épica 3 — Memoria Avanzada**:
   - Ingestador histórico `Memory::ColdStart`.
   - Motor de plantillas `Memory::CustomPrompts`.
   - Búsqueda por ventanas de tiempo `Memory.recall(since:, until:)`.
   - Comandos interactivos `mem:status`, `mem:sync`, `mem:skill`, `mem:help` en Chat.
5. **Épica 4 — Generadores Rails**:
   - `rails g agentkit:rag`
   - `rails g agentkit:team_memory`

---

## 3. Instalación y Configuración

Add to your `Gemfile`:

```ruby
gem "agentkit-rails", "~> 0.4.0"
```

Ejecutá los generadores para instalar el engine, la configuración RAG y el Team Memory Hub:

```bash
# 1. Instalar el initializer, application_agent y la consola
rails g agentkit:install --with-chat

# 2. Scaffolding de RAG Nativo (Migración 008)
rails g agentkit:rag

# 3. Scaffolding de Team Memory Hub (Migración 009)
rails g agentkit:team_memory

# 4. Instalar las migraciones del engine y migrar PostgreSQL
rails agentkit:install:migrations
rails db:migrate

# 5. Diagnóstico de componentes
rails agentkit:doctor
```

---

## 4. Arquitectura y los Pilares del Kernel

### 4.1 Modos de Almacenamiento
AgentKit soporta dos tipos de backends transparentes:
- **`:active_record`**: Persistencia completa en PostgreSQL (aprovecha `pgvector`, `tsvector`, índices GIN y barrera SQL).
- **`:memory`**: In-memory store determinista ideal para entorno de desarrollo local, scripts aislados y testing.

### 4.2 ApplicationAgent
Todos los agentes de la aplicación heredan de `Agentkit::Agent` (o `ApplicationAgent`):

```ruby
class SecurityAgent < ApplicationAgent
  use_knowledge :enterprise_rules, filter: { department: "security" }
  belongs_to_team "CyberSecurityTeam"

  def call(input)
    # RAG Retrieval
    chunks = rag_retrieve(input[:query])
    context = rag_context(input[:query])

    # Acceso a Team Assets
    team_skills = load_team_assets(asset_type: "skill")

    # Guardar en memoria
    memorize!("Incidente auditado para #{input[:user_id]}", tags: ["security"])

    Result.ok({ context: context, chunks_count: chunks.size })
  end
end
```

---

## 5. RAG Nativo y Orquestación Distribuida

### 5.1 Indexación e Ingesta Híbrida
```ruby
# Ingestar documentos en un corpus
Agentkit::RAG.index(
  corpus_name: "legal_docs",
  source: [
    { "id" => "doc_1", "text" => "Contrato de arrendamiento de oficinas...", "category" => "real_estate" }
  ],
  chunk_documents: true
)

# Búsqueda híbrida (Dense Vector + BM25 con RRF)
results = Agentkit::RAG.retrieve(
  "contrato de arrendamiento",
  corpus_name: "legal_docs",
  top_k: 5,
  filter: { category: "real_estate" }
)
```

### 5.2 CoordinatorFlow (Map/Reduce para Documentos Masivos)
Cuando necesitás procesar un archivo PDF de 90MB+, `CoordinatorFlow` ejecuta un pipeline paralelo:

```ruby
flow_res = Agentkit::RAG::CoordinatorFlow.call(
  pdf_text: large_pdf_text,
  corpus_name: "heavy_manual",
  strategy: :heading_regex,
  max_slice_mb: 10,
  max_concurrency: 4
)

# flow_res.value contiene la reducción de referencias y análisis por capítulo
```

---

## 6. Team Memory Hub (TencentDB Agent Memory)

El **Team Memory Hub** coordina y gobierna 4 activos de memoria compartida entre agentes:

```
                  ┌─────────────────────────────────────┐
                  │          Team Memory Hub            │
                  └──────────────────┬──────────────────┘
                                     │
         ┌──────────────────┬────────┴─────────┬──────────────────┐
         ▼                  ▼                  ▼                  ▼
    ChatMemory            Skill           Wiki Engine         CodeGraph
  (Escenas L2/L3)   (Prompt/Acción)   ([[Wikilinks]])    (Parser Ripper)
```

### 6.1 ACL Engine (Reglas de Gobernanza)
- **`private`**: Acceso restringido únicamente al propietario (`owner_id`).
- **`team`**: Acceso para cualquier miembro perteneciente al `team_id`.
- **`restricted`**: Acceso limitado exclusivamente a los agentes explícitamente vinculados.
- **`public` / `agent`**: Acceso para agentes autorizados dentro del tenant actual.

```ruby
# Crear asset con visibilidad restringida
asset = Agentkit::TeamMemory.create_asset(
  asset_type: "skill",
  name: "DeployStaging",
  team_id: team.id,
  visibility: "restricted"
)

# Evaluar permisos
Agentkit::TeamMemory::ACL.accessible?(asset, agent_name: "DeployBot") # => true / false
```

### 6.2 Wiki Engine
Permite a los agentes mantener documentación estructurada y detectar hipervínculos automáticos:

```ruby
wiki = Agentkit::TeamMemory::Wiki.create_wiki(name: "EngineeringWiki", team_id: team.id)
page = Agentkit::TeamMemory::Wiki.add_page(
  wiki,
  title: "Arquitectura de Agentes",
  content: "Revisar el [[Protocolo DDoS]] y la sección de [[Seguridad API]]."
)

page.links # => ["Protocolo DDoS", "Seguridad API"]
```

### 6.3 CodeGraph Engine
Analiza estáticamente código Ruby usando `Ripper` para construir un mapa de símbolos, llamadas y análisis de impacto:

```ruby
graph = Agentkit::TeamMemory::CodeGraph.create_graph(name: "AppRepo", team_id: team.id)
Agentkit::TeamMemory::CodeGraph.index_files(graph, Dir["app/**/*.rb"])

symbols = Agentkit::TeamMemory::CodeGraph.all_symbols(graph)
impact  = Agentkit::TeamMemory::CodeGraph.impact_analysis(graph, symbol_name: "Authenticator")
```

---

## 7. Memoria Semántica y Capas L0-L3

### 7.1 Capas de Memoria
- **L0 (Raw Logs)**: Mensajes crudos de conversación y logs de sistema.
- **L1 (Atoms)**: Hechos o fragmentos de información extraídos de L0.
- **L2 (Scenes)**: Escenarios o conversaciones agrupadas por contexto.
- **L3 (Persona / Skills)**: Perfiles consolidados, preferencias y habilidades ejecutables.

### 7.2 ColdStart Importer
Importación en lote de transcripciones históricas preservando fechas originales:

```ruby
Agentkit::Memory::ColdStart.import(
  filepath: "data/history_chat.jsonl",
  source_agent: "LegacySupportAgent"
)
```

### 7.3 Búsqueda por Ventanas de Tiempo
```ruby
recent_memories = Agentkit::Memory.recall(
  "incidente de seguridad",
  since: 24.hours.ago,
  until: Time.now
)
```

---

## 8. Flow Engine (Secuencial, Paralelo, Async & Sagas)

El engine de flujos permite orquestar operaciones complejas con barreras atómicas SQL y reanudación automática:

```ruby
class IncidentResponseFlow < Agentkit::Flow
  input :incident_id

  step :fetch_details, agent: FetchIncidentAgent

  parallel :assess, over: [NetworkCheckAgent, LogAnalyzerAgent, ImpactEvalAgent],
                    with: ->(ctx) { ctx[:fetch_details] }

  join :assess, on: :all_settled, timeout: 300, on_timeout: :continue_with_partial

  step :synthesize, agent: IncidentReportAgent,
       input: ->(ctx) { ctx[:assess].values }

  human_gate :approve_mitigation, timeout: 24.hours, on_timeout: :auto_reject

  step :execute_mitigation, if: ->(ctx) { ctx[:approve_mitigation].approved? },
                            agent: ApplyMitigationAgent

  compensate :execute_mitigation, with: ->(ctx) { RollbackMitigation.call(ctx) }
end
```

---

## 9. Human-in-the-Loop (HITL) y Ledger

### 9.1 Registro de Handlers y Rechazos
```ruby
# Registrar un handler para cuando un humano apruebe una recomendación
Agentkit::HITL.on("mitigation_proposal") do |suggestion|
  ApplyMitigation.call(suggestion.payload)
end

# Rechazar una sugerencia exigiendo un código de la taxonomía cerrada
Agentkit::HITL.reject(suggestion_id, actor: "admin:1", code: :wrong_target)
```

### 9.2 Métricas de Ledger
```ruby
stats = Agentkit::HITL.ledger.summary(agent: "IncidentReportAgent")
# => { acceptance_rate: 0.92, clean_acceptance_rate: 0.88, ignore_rate: 0.02, ... }
```

---

## 10. Cognición On-Demand e Imagination Firewall

Motor unificado de procesamiento cognitivo:

- **Dreaming**: Consolida memorias no destructivamente agrupan por similitud léxica o de embedding.
- **Summarizer**: Sintetiza grandes volúmenes de texto mediante `map_reduce` o `extractive`.
- **Imagination**: Simula escenarios en 3 fases (*divergencia → incubación → verificación*).
  - **Ontological Firewall**: Los escenarios simulados se etiquetan como `ontological_type: "imagined"` y **nunca** son devueltos por `recall!` estándar, a menos que se especifique `include: :imagined`.

---

## 11. Fábrica de Auto-Mejora Continua

La Fábrica detecta problemas de rendimiento o costo mediante **detectores deterministas**:

- Detectores: `acceptance_drop`, `rejection_cluster`, `retrieval_useless`, `capability_gap`, `cost_spike`.
- Escalera N1–N5:
  - **N1**: Parámetros (modelo, $k$, umbrales).
  - **N2**: Prompts versionados con canarios deterministas.
  - **N3**: Políticas HITL.
  - **N4**: Composición de contexto.
  - **N5**: Modificaciones de código (**emite un patch en PR para revisión humana, nunca escribe directamente en disco**).

---

## 12. Chat Propositivo e Interactivo (`mem:` commands)

El módulo `Agentkit::Chat` permite una interacción propositiva trazable (`why`) e intercepta comandos de memoria:

```ruby
# Chat propositivo
turn = Agentkit::Chat.open(candidates: Company.recent)

# Comandos interactivos de memoria
Agentkit::Chat.say("mem:status") # => Devuelve el estado de memorias y assets de equipo
Agentkit::Chat.say("mem:sync")   # => Fuerza el flush de vectores y sincronización
Agentkit::Chat.say("mem:skill")  # => Extrae una habilidad de la sesión actual
Agentkit::Chat.say("mem:help")   # => Muestra el menú de ayuda
```

---

## 13. Protocolo A2A (Agent-to-Agent)

AgentKit expone las capacidades registradas como skills de una Agent Card A2A
1.0. Las mismas precondiciones, aislamiento tenant, HITL y auditoría aplican a
las invocaciones locales y remotas.

### 13.1 Configuración multi-tenant

```ruby
Agentkit.configure do |config|
  config.a2a.enabled = true
  config.a2a.expose = %i[quote_event check_availability reserve_date]

  # Identidad pública según dominio o subdominio.
  config.a2a.tenant_resolver = lambda do |request|
    Vendor.find_by(subdomain: request.subdomains.first)
  end

  # Credencial del peer → contexto privado de ejecución.
  config.a2a.key_resolver = ->(token) { Vendor.find_by(a2a_token: token) }
end
```

Cada tenant obtiene su propia tarjeta en:

```text
GET /.well-known/agent-card.json
Accept: application/a2a+json
```

La tarjeta anuncia `supportedInterfaces`, `protocolVersion: "1.0"`, esquemas
de seguridad y solamente los skills elegibles para ese contexto.

### 13.2 Enviar mensajes y consultar tareas

```bash
curl -X POST https://vendor.example/agentkit/a2a/message:send \
  -H "Authorization: Bearer $A2A_TOKEN" \
  -H "A2A-Version: 1.0" \
  -H "Content-Type: application/a2a+json" \
  -d '{
    "message": {
      "role": "ROLE_USER",
      "messageId": "msg-001",
      "metadata": { "skillId": "quote_event" },
      "parts": [{ "data": { "budget": 25000 } }]
    }
  }'
```

Endpoints disponibles:

- `POST /agentkit/a2a/message:send`
- `GET /agentkit/a2a/tasks/:id`
- `GET /agentkit/a2a/tasks`
- `POST /agentkit/a2a/tasks/:id:cancel`

Las tareas se almacenan en `agentkit_a2a_tasks` y están separadas por tenant.
Una capacidad irreversible conserva su aprobación humana y aparece como
`TASK_STATE_AUTH_REQUIRED`. Si faltan argumentos, la respuesta usa
`TASK_STATE_INPUT_REQUIRED`.

### 13.3 Cliente saliente

```ruby
peer = Agentkit::A2A::V1::Client.new(
  base_url: "https://peer-agent.acme.test",
  token: ENV["PEER_KEY"]
)

card = peer.card
response = peer.send_message({
  role: "ROLE_USER",
  messageId: SecureRandom.uuid,
  metadata: { skillId: "security_audit" },
  parts: [{ data: { target_host: "10.0.0.1" } }]
})
```

El cliente exige HTTPS para hosts remotos. `localhost` se permite para
desarrollo.

### 13.4 Agent Cards firmadas

```ruby
config.a2a.signing_key = ENV["AGENTKIT_A2A_SIGNING_KEY_PEM"]
config.a2a.signing_key_id = "provider-2026-01"
config.a2a.signing_jwks_url = "https://agents.example/.well-known/jwks.json"

config.a2a.verification = :required
config.a2a.trusted_keys = {
  "peer-2026-01" => ENV["PEER_A2A_PUBLIC_KEY_PEM"]
}
```

Las firmas RS256/JWS son opcionales. La política predeterminada es
`:if_present`: acepta tarjetas sin firma, pero verifica las que sí la incluyen.
AgentKit no confía automáticamente en una clave indicada mediante `jku`.

### 13.5 Compatibilidad con 0.3

El cliente `Agentkit::A2A::Client`, JSON-RPC y
`/.well-known/agent.json` siguen disponibles por defecto. Después de migrar
todos los peers:

```ruby
config.a2a.legacy = false
```

---

## 14. Consola Web Dashboard

Montá la interfaz web en tu `config/routes.rb`:

```ruby
mount Agentkit::Engine => "/agentkit"
```

Pantallas disponibles:
- **`/agentkit`**: Bandeja de sugerencias HITL en vivo (Turbo Streams).
- **`/agentkit/team_memory`**: Panel de gobernanza de Team Memory Hub (ChatMemory, Skill, Wiki, CodeGraph).
- **`/agentkit/runs`**: Timeline interactivo de ejecuciones de Flow y estado de la barrera.
- **`/agentkit/factory`**: Reportes de la fábrica de auto-mejora y métricas económicas.

---

## 15. Testing y Modo `:fake`

AgentKit incluye un adaptador `:fake` con **embeddings deterministas** y utilidades para tests reproducibles:

```ruby
RSpec.describe SecurityAgent do
  before do
    Agentkit::Flow.test_mode!
    Agentkit.config.memory.store = :memory
    Agentkit.config.rag.store    = :memory
  end

  it "procesa una auditoría correctamente" do
    Agentkit::LLM::Adapters::Fake.respond_with({ status: "ok" })
    agent = SecurityAgent.new
    result = agent.call(query: "tokens JWT")
    expect(result).to be_ok
  end
end
```

---

## 16. Ejemplo Completo de Demostración

Para ver todas las capacidades en acción, ejecutá el script oficial de demostración:

```bash
ruby examples/v03_demo.rb
```

---

## 17. Referencia de Configuración

Configuración centralizada en `config/initializers/agentkit.rb`:

```ruby
Agentkit.configure do |config|
  config.llm.adapter = :ruby_llm # :ruby_llm | :openai_compatible | :fake
  config.memory.store = :active_record # :active_record | :memory
  config.memory.level = :hybrid
  config.memory.embedding.policy = :on_promotion

  config.rag.store = :active_record
  config.rag.default_chunk_size = 1000

  config.team_memory.default_visibility = "team"

  config.a2a.enabled = true
  config.a2a.secret_key = ENV["AGENTKIT_A2A_KEY"]
  config.a2a.key_resolver = ->(token) { Account.find_by(a2a_token: token) }
  config.a2a.tenant_resolver = ->(request) {
    Account.find_by(subdomain: request.subdomains.first)
  }
  config.a2a.expose = %i[quote_event check_availability]
  config.a2a.verification = :if_present
end
```

---

## Licencia

Publicado bajo la licencia MIT.
