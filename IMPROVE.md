# Plan de mejora de AgentKit Rails 0.3.1

## Propósito

AgentKit Rails 0.3.1 ya ofrece flows reanudables, HITL, memoria, cognición,
Factory, A2A, RAG nativo y Team Memory. La siguiente mejora debe concentrarse
en gobernar esas capacidades de forma uniforme: autoridad explícita,
aislamiento tenant completo, evidencia verificable, presupuestos durables y
tratamiento seguro del conocimiento no confiable.

El objetivo no es convertir AgentKit en una plataforma de CI/CD. AgentKit debe
seguir siendo un kernel embebible para agentes que actúan dentro del dominio de
una aplicación Rails.

## Principios no negociables

1. Un parámetro proporcionado por el caller nunca puede reducir la autorización
   exigida por el servidor.
2. Con `multi_tenant` activo, toda lectura y mutación requiere scope tenant y
   falla cerrada si este falta.
3. Los agentes pueden proponer, pero no aprobar sus propias propuestas ni elevar
   sus permisos.
4. Una aprobación autoriza una acción; no demuestra que fue ejecutada.
5. Texto de usuarios, documentos, memorias, skills y peers es dato no confiable,
   nunca autoridad.
6. La evidencia determinista tiene precedencia sobre el auto-reporte del agente.
7. Toda operación irreversible debe ser idempotente, auditable y atribuible.
8. Una degradación debe ser explícita; nunca debe inventar datos para aparentar
   funcionamiento normal.
9. Los límites de gasto se aplican antes de consumir y funcionan con varios
   procesos.
10. Las mejoras automáticas solo se activan si son reversibles, medibles y están
    dentro del nivel de autonomía configurado.

## Estado de partida

La 0.3.1 ya contiene avances que deben preservarse:

- Factory durable con fingerprints, recurrencia y resolución auditable;
- ejecuciones de Factory persistentes y guardrails programables;
- experimentos con cohortes, duración, significancia, costo y golden set;
- patches N5 revisables sin escritura directa al repositorio;
- RAG híbrido vectorial + BM25 + RRF;
- Team Memory con tenants, teams, assets, Wiki y CodeGraph;
- migración `010_add_agentkit_tenancy.rb` para instalaciones existentes;
- rechazo de RAG/Team Memory sin tenant cuando `multi_tenant` está activo;
- pruebas iniciales de aislamiento para RAG y Team Memory.

La mejora debe extender esas garantías al kernel histórico y cerrar las
superficies nuevas introducidas por RAG, A2A y skills portables.

## Fuera de alcance

- administrar repositorios GitHub o sustituir CI/CD;
- construir previews o sandboxes generales;
- crear una plataforma SaaS multi-repositorio;
- añadir tipos de memoria, chunkers o procesadores cognitivos antes de completar
  P0 y P1.

---

# Release 0.3.2: seguridad y consistencia

0.3.2 debe ser un release concentrado, sin nuevas features de producto.

## P0.1 — Eliminar el bypass A2A de HITL

### Problema

`A2A::Server.capabilities_invoke` permite que el caller envíe `force_sync` para
evitar una sugerencia protegida:

```ruby
if A2A.requires_approval?(cap) && !params["force_sync"]
```

### Trabajo

- Eliminar `force_sync` como bypass de autorización.
- Si se conserva, usarlo solo para decidir si la conexión espera la resolución
  o devuelve inmediatamente un `taskId`.
- Resolver la política HITL en el servidor tras autenticar al principal.
- Recalcular policy y precondiciones inmediatamente antes de ejecutar.
- Ligar la aprobación al digest del payload exacto.
- Impedir que un principal proponga y apruebe cuando se requiera separación de
  deberes.

### Criterios de aceptación

- Una capability irreversible nunca se ejecuta sin decisión válida.
- `force_sync: true` no reduce `requiresHumanApproval`.
- Alterar el payload después de aprobar invalida la autorización.
- Reintentar no duplica sugerencia ni efecto.
- Hay specs para strict, advisory, reversible, irreversible, `hitl: :propose`,
  expiración e idempotencia.

## P0.2 — Aislamiento tenant completo

### Problema

RAG y Team Memory están scopeados, pero Suggestions, Runs, A2A tasks, Audit,
Artifacts y varias búsquedas históricas todavía admiten lookups globales.

### Diseño

Introducir un scope único:

```ruby
Agentkit::Scope.new(
  tenant_key: context.tenant_key,
  account_id: context.account&.id,
  principal: context.principal
)
```

Todos los stores aceptan `scope:`:

```ruby
HITL.fetch!(id, scope:)
Flow.find_run(id, scope:)
Audit.entries(run_id:, scope:)
Memory.find(id, scope:)
ArtifactStore.fetch(id, scope:)
```

### Reglas

- Con `multi_tenant: true`, faltar tenant produce `ConfigurationError`.
- Un recurso de otro tenant devuelve `NotFound` para no filtrar su existencia.
- Controllers no consultan modelos AgentKit directamente por ID.
- Steps y Artifacts heredan tenant del Run y validan coherencia.
- Jobs serializan/restauran scope; no dependen de thread-local accidental.
- Counts, reportes y dashboards se scopean antes de agrupar.
- Idempotency keys usan namespace tenant.

### Migraciones

- Añadir `tenant_key`/`account_id` donde falten.
- Reemplazar índices globales por índices compuestos tenant-aware.
- Usar `(tenant_key, idempotency_key)` para idempotencia.
- Definir el backfill de registros históricos a `__global__`.
- Hacer irreversible cualquier rollback que mezcle fronteras de seguridad.

### Criterios de aceptación

- Matriz A/B para cada store, controller y endpoint A2A.
- Tenant A no lee, decide, reintenta ni infiere recursos de tenant B.
- Tests con IDs/UUID conocidos y colisiones de idempotency key entre tenants.

## P0.3 — Retirar el vector aleatorio del fallback RAG

### Trabajo

- Si no hay query vector, ejecutar BM25 exclusivamente.
- Emitir `rag.retrieval.degraded` con causa y estrategia efectiva.
- No presentar scores vectoriales si no hubo búsqueda vectorial.
- Registrar la estrategia efectiva en trace y receipt.

### Criterios de aceptación

- Búsquedas degradadas idénticas producen resultados deterministas.
- Ningún vector sintético llega al store.
- El caller puede saber que se utilizó keyword-only.

## P0.4 — Contexto RAG como dato no confiable

### Trabajo

- Delimitar cada chunk por ID, digest y trust level.
- Indicar al modelo que no siga instrucciones de documentos recuperados.
- Separar instrucciones, pregunta y evidencia.
- Prohibir que contenido RAG aumente permisos, elija tools privilegiadas u
  omita HITL.
- Limitar tamaño de contexto y truncar de forma determinista.
- Conservar procedencia de cada chunk enviado al modelo.

Ejemplo:

```xml
<retrieved-evidence trust="untrusted">
  <document chunk-id="handbook:42" source-digest="sha256:...">
    ...
  </document>
</retrieved-evidence>
```

### Pruebas adversariales

- “ignore previous instructions” dentro de documento y metadata;
- contenido que solicita ejecutar tools o exfiltrar otros chunks;
- texto que imita delimitadores;
- instrucciones en títulos y nombres de fuente.

## P0.5 — Cuarentena de skills importadas

### Trabajo

- Validar bundles con schema versionado.
- Parsear frontmatter de forma segura.
- Validar nombre y longitud.
- Calcular digest y conservar origen, autor e importador.
- Detectar colisiones de nombre/versión.
- Limitar tamaños de `SKILL.md` y `tools.json`.
- Crear el asset como `quarantined`/`draft`.
- Generar propuesta HITL para activarlo.
- No registrar la skill ejecutable antes de activación.
- Validar `tools.json`; no ignorarlo silenciosamente.

### Estados

```text
quarantined -> reviewed -> active -> deprecated -> archived
            \-> rejected
```

### Criterios de aceptación

- Importar no hace la skill utilizable.
- Una colisión no reemplaza una versión activa.
- Activación conserva aprobador, digest y diff.
- Bundle inválido no crea registros parciales.

## P0.6 — ACL fail-closed

- Visibility desconocida siempre deniega.
- `team` exige `team_id` válido.
- `private` exige owner válido.
- `restricted` exige bindings válidos.
- Un asset sin team no se vuelve implícitamente accesible.
- Separar `read`, `use`, `update`, `bind`, `export` y `activate`.
- Comprobar tenant antes de ACL.

## P0.7 — Suite reproducible

- Documentar todas las dependencias de specs.
- Proporcionar un comando único de verificación.
- Probar instalación desde cero y upgrade `0.2.1 -> 0.3.0 -> 0.3.1 ->
  0.3.2`.
- CI sobre versiones soportadas de Ruby, Rails y PostgreSQL.
- Probar pgvector presente/ausente.
- Probar ActiveJob inline/test y un backend distribuido.
- Eliminar del README conteos manuales de specs o generarlos automáticamente.

### Definition of done de 0.3.2

- Suite verde y reproducible.
- Sin bypass HITL conocido.
- Matriz tenant verde en todas las superficies.
- RAG no usa vectores aleatorios y pasa corpus adversariales básicos.
- Skills importadas no se activan sin revisión.
- Upgrade desde una instalación 0.3 existente probado en CI.

---

# Release 0.4: Governed Agent Kernel

## P1.1 — Principals y autorización granular

### Principals

```text
human
agent
peer
system
job
```

Cada principal tiene ID estable, tenant y tipo. No se infiere autoridad de un
string como `human:1`.

### Catálogo inicial

```text
runs:read
runs:retry
suggestions:read
suggestions:decide
audit:read
factory:read
factory:diagnose
experiments:activate
cognition:run
memory:read
memory:write
team_memory:read
team_memory:write
skills:import
skills:activate
a2a:invoke
capability:execute:<nombre>
```

### Adapter del host

```ruby
config.authorization.check = lambda do |principal, permission, resource|
  ApplicationAgentkitPolicy.allowed?(principal, permission, resource)
end
```

Reglas: deny-by-default, permiso declarado por operación, revalidación al cargar
el recurso y adapters opcionales para Pundit/CanCanCan.

## P1.2 — HITL durable, tipado y transaccional

Una propuesta conserva:

```ruby
{
  action_type:,
  arguments:,
  arguments_digest:,
  requester_principal_id:,
  required_permission:,
  tenant_key:,
  target_type:,
  target_id:,
  risk:,
  policy_version:,
  expires_at:
}
```

Máquina de estados:

```text
draft -> open -> approved -> executing -> executed
             \-> rejected     \-> execution_failed
             \-> expired
             \-> cancelled
```

Reglas:

- bloquear al decidir;
- una sola decisión terminal;
- revalidar policy, scope, target y precondiciones;
- ejecutar mediante resolvers registrados;
- separar decisión, intento y confirmación del efecto;
- retry acotado e idempotente;
- conservar resultado, error y compensación.

## P1.3 — Catálogo de riesgo

| Riesgo | Ejemplos | Política predeterminada |
|---|---|---|
| read | consultas | automática, scopeada |
| reversible | borrador, etiqueta | automática con audit |
| sensitive | comunicación externa | policy explícita |
| irreversible | cobro, borrado, refund | aprobación separada |
| privileged | permisos, secretos | fuera del agente normal |

La policy efectiva considera capability, tenant, principal, canal, monto,
entorno y target.

## P1.4 — Presupuestos durables

Scopes: global, tenant, agent, flow, run, capability y corpus/indexing job.

Recursos:

- USD y tokens;
- requests y embeddings;
- bytes/chunks indexados;
- fan-out, wall time y retries.

Semántica:

- `soft`: alerta y registra;
- `hard`: reserva o rechaza antes de consumir;
- reservas atómicas con idempotency key;
- reconciliación con usage real;
- contadores PostgreSQL, no memoria local;
- estimación previa para CoordinatorFlow;
- circuit breakers compartidos entre workers.

## P1.5 — Lifecycle y procedencia del conocimiento

```text
draft -> indexed -> validated -> active -> deprecated -> archived
                  \-> rejected
```

Metadata obligatoria:

- source y digest;
- owner y tenant;
- clasificación y trust level;
- versión, vigencia y revisión;
- retención;
- agentes/propósitos permitidos;
- indexer, chunker, embedding model;
- aprobador.

Los agentes recuperan solo conocimiento `active` por defecto.

## P1.6 — RAG con citas verificables

```json
{
  "answer": "...",
  "claims": [
    {
      "text": "...",
      "citations": ["chunk:security-handbook:42"],
      "support": 0.91
    }
  ]
}
```

Registrar versión de corpus, digest de chunks, filtros, estrategia y rankings.
Si la evidencia no alcanza, indicarlo explícitamente.

---

# Release 0.5: evidencia y operación

## P2.1 — Receipts verificables

### `agentkit.run.v1`

- run, flow y versión;
- tenant y principal del trigger;
- agentes, modelos, prompts y skills versionados;
- decisiones humanas;
- usage/costo;
- checks, efectos, artifacts y outcomes;
- resultado terminal;
- digest y digest anterior.

### `agentkit.index.v1`

- corpus y source digest;
- chunker y número de chunks;
- embedding model/dimensions;
- errores, tenant y duración.

Los receipts son schemas versionados, se validan antes de persistir y no
incluyen prompts, secretos, documentos completos ni payloads crudos de tools.

## P2.2 — Auditoría tamper-evident

- `previous_hash` y `event_hash` por tenant;
- `rails agentkit:audit_verify`;
- redacción recursiva de Hash/Array y claves sensibles;
- cifrado opcional de payload sensible;
- exportación WORM/object storage;
- pruning registrado como evento;
- retención por tenant.

Modos:

```ruby
config.audit.failure_mode = :best_effort
config.audit.failure_mode = :required
```

Una operación irreversible puede exigir `:required`.

## P2.3 — Watchtower

Detectar:

- runs atascados y joins sin converger;
- gates vencidos y jobs sin consumidor;
- embeddings pendientes e índices parciales;
- dimensiones incompatibles;
- circuit breakers abiertos;
- fallos de audit o ausencia de tenant;
- presupuesto excedido;
- ausencia de actividad esperada.

Añadir un canary seguro que atraviese trigger, flow, LLM fake/económico, receipt
y verificación independiente.

Persistir issues operacionales deduplicados:

```text
kind, tenant, severity, state, first_seen_at, last_seen_at,
occurrence_count, evidence, resolution
```

## P2.4 — Outcomes de dominio

Distinguir:

```text
run completed
effect executed
effect confirmed
human accepted
domain outcome observed
```

API propuesta:

```ruby
Agentkit.outcome(
  :refund_settled,
  run: run,
  subject: refund,
  value: 42.50,
  evidence: { state: "settled" }
)
```

Factory evalúa mejoras contra outcomes, no solo aceptación inmediata.

---

# Cambios transversales

## Idempotencia

- namespace por tenant y operación;
- distinguir deduplicación, intent exactly-once y reconciliación externa;
- exigir idempotency key para A2A mutante;
- constraints de base como última barrera;
- conservar respuesta previa para reintentos equivalentes;
- rechazar misma clave con payload distinto.

## Seguridad A2A

- credenciales por peer almacenadas con hash;
- principal, tenant, permisos y capabilities permitidas;
- expiración, revocación y `last_used_at`;
- rate limit por peer/tenant/capability;
- timestamp, nonce/delivery ID y anti-replay;
- firma opcional del cuerpo exacto;
- límites de request/response;
- errores externos genéricos con request ID;
- `tasks.get` scopeado al principal autorizado.

## Cliente HTTP y SSRF

- HTTPS obligatorio en producción;
- rechazar credenciales en URL;
- bloquear rangos privados/reservados salvo allowlist;
- bloquear metadata endpoints;
- desactivar redirects o revalidarlos;
- timeouts de conexión, lectura y total;
- límite de respuesta y allowlist de hosts.

## Límites de entrada

Limitar body HTTP, bundles, documentos, slices, chunks, `top_k`, metadata,
queries, fan-out, artifacts y propuestas A2A.

## Privacidad

- Telemetry es muestreable/expirable.
- Audit nunca se confunde con Telemetry.
- Receipts son procedencia y métricas, no transcripciones.
- Prompts/documentos completos requieren opt-in explícito.
- Retención y exportación son tenant-aware.

---

# Estrategia de pruebas

## Unitarias

- policy resolution y state machines;
- digests de payload/receipt;
- redacción recursiva;
- ACL fail-closed;
- fallback RAG determinista;
- bundles de skills;
- reservas de presupuesto.

## Integración PostgreSQL

- decisiones HITL concurrentes;
- presupuesto con varios workers;
- idempotencia bajo redelivery;
- cadenas de audit;
- upgrades desde versiones anteriores;
- aislamiento en todos los stores;
- constraints y rollback transaccional.

## Adversariales

- prompt injection desde RAG, Wiki, memoria y skills;
- payload alterado tras aprobación;
- `force_sync` malicioso;
- task IDs de otro tenant;
- URLs hacia metadata/redes privadas;
- replay de requests;
- bundles enormes o malformados;
- visibility desconocida;
- fallo de audit durante efecto irreversible.

## End-to-end de referencia

La dummy app debe demostrar:

1. peer autenticado propone capability sensible;
2. se crea propuesta ligada al payload;
3. principal distinto la aprueba;
4. se revalida tenant/policy;
5. el efecto ocurre una sola vez;
6. se genera receipt;
7. audit verifica su cadena;
8. se vincula outcome posterior;
9. otro tenant no observa ninguna parte.

---

# Compatibilidad y migraciones

- No editar migraciones publicadas; añadir nuevas.
- Probar instalaciones limpias y parcialmente actualizadas.
- No revertir fronteras tenant si mezcla registros.
- Mantener contrato idéntico de scope en memoria y ActiveRecord.
- Deprecar APIs globales una versión antes de exigir `scope:`.
- Warnings accionables con ubicación de llamada.
- Ampliar `agentkit:doctor` para schema, tenant, permisos, budgets, queue,
  pgvector y audit.
- Documentar defaults seguros y upgrade.

---

# Métricas de éxito

## Seguridad

- cero caminos para omitir HITL desde input;
- cobertura tenant para 100 % de stores/endpoints;
- cero ACLs fail-open;
- cero skills importadas activas sin decisión.

## Fiabilidad

- cero efectos duplicados bajo redelivery;
- detección de runs/joins atascados;
- receipts válidos para todos los runs terminales;
- audit verificable tras concurrencia y pruning controlado.

## Economía

- costo por tenant, agente, flow, run y corpus;
- hard limits efectivos con varios workers;
- estimación previa de RAG masivo;
- ninguna degradación produce retrieval aleatorio.

## Calidad

- respuestas críticas con citas;
- Factory evaluada contra outcomes disponibles;
- recurrencia antes/después de mejoras;
- instalación y upgrade verdes en la matriz soportada.

---

# Orden recomendado

1. Restaurar suite reproducible y CI mínima.
2. Eliminar bypass `force_sync`.
3. Introducir `Scope` y cerrar lookups cross-tenant.
4. Eliminar fallback vectorial aleatorio.
5. Encapsular RAG como evidencia no confiable.
6. Cuarentena/versionado de skill imports.
7. ACL fail-closed.
8. Publicar 0.3.2.
9. Introducir principals, permisos y policy adapter.
10. Separar aprobación y ejecución HITL.
11. Implementar presupuestos durables.
12. Añadir lifecycle de conocimiento y citas RAG.
13. Publicar 0.4.
14. Añadir receipts y audit hash-chained.
15. Añadir Watchtower y outcomes.
16. Publicar 0.5.

## Regla de salida

No ampliar la superficie cognitiva hasta publicar 0.3.2 y probar P0. La
prioridad posterior a 0.3.1 no es hacer más cosas, sino demostrar que cada cosa
ocurre bajo el tenant, autoridad, presupuesto y evidencia correctos.
