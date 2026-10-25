# Rails Evidence & Decision Gates — 1.8.0

Este módulo conecta el [núcleo 1.7](VERIFIED_KNOWLEDGE_CORE.md) con datos Rails,
decisiones persistentes y ejecución transaccional. Es opt-in. La app conserva
la definición del negocio, las autorizaciones y la integración con proveedores.

## Instalación y cambios de base de datos

```sh
rails agentkit:install:migrations
rails db:migrate
```

La migración 024 crea `agentkit_knowledge_entries` y agrega
`knowledge_gate_digest` a `agentkit_action_proposals`. Aplicar antes de desplegar
workers 1.8. Las entradas almacenan snapshots, decisiones, comprobantes de
ejecución, eventos y confirmaciones de procesamiento. La clave única combina
scope, tipo y clave idempotente; los payloads llevan digest y versión contractual.
No confundir esta tabla con los documentos/chunks de RAG.

## Contrato de capas

| Capa | Incluida en Agentkit | Obligación de la app Rails |
|---|---|---|
| Ontología y reglas | Contratos e inferencia de 1.7 | Definir significado, constantes, unidades y aprobación real |
| Identidad | Scope por tenant + cuenta, principal obligatorio | Autenticar usuario/servicio y reconstruir identidad vigente en workers |
| Lectura | `ActiveRecordSource` con transacción y lock de una fila raíz | Proveer relación filtrada, permiso de lectura y extracción de observaciones |
| Datos adicionales | Se conserva el lock raíz durante evaluación y ejecución | Bloquear otras filas relevantes en orden estable y versionar sus fuentes |
| Decisión | `DecisionGate` comprueba consultas, derivaciones y completitud | Definir consultas requeridas y permiso para decidir/ejecutar |
| Persistencia | `Journal`, índice único, digests, rollback y replay | Autorizar acceso al diario, retención, respaldo y protección de datos |
| Agentes | `AnswerVerifier` y `gate.precondition` | Configurar schema de respuesta, herramientas y argumentos de confianza |
| Acciones internas | `Capability#knowledge_gate` dentro de la transacción | Implementar el efecto síncrono en la misma base de datos |
| Acciones externas | Se rechazan dentro del gate transaccional | Registrar intención/outbox local y usar un dispatcher idempotente con reconciliación |
| Eventos | Inbox durable y consumo transaccional idempotente | Registrar el evento en la transacción de negocio y programar/reintentar workers |

El scope se deriva con `Knowledge::Boundary.scope(context)`. No aceptar `scope`
ni principal del payload LLM. Una coincidencia de tenant no reemplaza la
autorización por usuario: las tres políticas de lectura, decisión y diario son
callbacks obligatorios. Una aprobación humana de una acción tampoco reemplaza
la revalidación de los datos en el momento de ejecutarla.

## Construcción del adaptador

El [ejemplo Rails](../examples/rails_evidence.rb) es una fábrica configurable que
puede cargarse dentro de una app. Usa un modelo con `account_id`, `status` y
`updated_at`, y exige callbacks de autorización. Su regla sólo habilita revisión
cuando `status` tiene el valor configurado; adaptar a la política real.

Configuración equivalente para una app de devoluciones:

```ruby
K = Agentkit::Knowledge

journal = K::Journal.new(authorize: ->(kind, ctx) {
  # Este servicio es de la app; controla lectura y escritura de este tipo de dato.
  KnowledgePolicy.allowed?(ctx.principal, kind: kind, account: ctx.account)
})

source = K::ActiveRecordSource.new(
  name: "returns", version: "2", ontology: ReturnsContract::ONTOLOGY,
  rules: ReturnsContract::APPROVED_RULES, subject_key: "order_id",
  relation: ->(ctx) { Order.where(account_id: ctx.account.id) },
  authorize: ->(order, ctx) { OrderPolicy.new(ctx.principal, order).read? },
  extract: ->(order, ctx, at) {
    # Rails implementa este servicio. Devuelve Array<Knowledge::Assertion>.
    # Usar scope: K::Boundary.scope(ctx), fechas ISO8601 y versiones de fuentes.
    Returns::EvidenceFacts.call(order: order, context: ctx, at: at)
  }
)

gate = K::DecisionGate.new(
  name: "return_review", version: "3", source: source, journal: journal,
  queries: ->(args, _ctx) {
    [{ "relation" => "EligibleForReview", "values" => ["order:#{args.fetch('order_id')}"] }]
  },
  authorize: ->(args, ctx) {
    ReturnsPolicy.may_request_review?(ctx.principal, account: ctx.account, order_id: args.fetch("order_id"))
  },
  execution_context: ->(proposal) {
    # Servicio de la app: resuelve cuenta y usuario desde identificadores persistidos,
    # autentica vigencia y carga permisos actuales. No usar el usuario del thread web.
    BusinessExecutionContext.for_requester(proposal.requester_principal_id, tenant: proposal.tenant_key)
  },
  require_complete: true,
  limits: { max_steps: 100_000, max_facts: 20_000, max_iterations: 100 }
)
```

Todos los servicios `Returns*`, `OrderPolicy`, `KnowledgePolicy` y
`BusinessExecutionContext` son de la app, no clases de Agentkit. `ctx.account`
debe existir para este ejemplo; el scope también soporta apps sólo con tenant.
Si la fila expone `account_id`, el adaptador exige que el contexto lleve esa
cuenta y coincida. Si expone `tenant_key`, también lo compara. La relación
filtrada sigue siendo obligatoria, incluso cuando el modelo no tiene esos campos.

Los callbacks reciben argumentos string-keyed, salvo los ejecutores Capability,
que reciben una copia congelada con claves symbol. `queries` debe devolver entre
1 y 32 objetos únicos con exactamente `relation` y `values`. Cambiar código de
consulta, autorización o extracción exige incrementar la versión del gate o de
la fuente: los digests incluyen versiones declaradas, no el código de los Procs.

## Evaluación y registro

```ruby
verdict = gate.check(arguments: { order_id: 42 }, context: ctx)
verdict.fetch("accepted")
verdict.fetch("snapshot_digest")
snapshot = journal.load_snapshot(verdict.fetch("snapshot_digest"), context: ctx)
```

`check` abre una transacción, encuentra la fila dentro de la relación autorizada,
la bloquea, extrae los hechos y evalúa. Persiste snapshot y decisión en la misma
transacción. Por defecto requiere cierre completo además de derivaciones válidas
para todas las consultas. `require_complete: false` admite sólo conclusiones
positivas comprobadas aunque el cierre haya alcanzado un límite.

Una llamada nueva reconstruye evidencia actual. Si se proporciona `event_id:`,
repetir ese ID con los mismos argumentos, principal y contrato devuelve la
decisión histórica guardada; cambiar cualquiera produce `IntegrityError`.
Para reevaluar estado nuevo usar un nuevo ID. El ID aleatorio predeterminado
sirve para consultas actuales, no para deduplicación de red.

`accepted` es una decisión relativa a la evidencia. No es un permiso general ni
se convierte automáticamente en aprobación de un `ActionProposal`.

## Verificación de respuestas de AgentLoop

```ruby
verifier = K::AnswerVerifier.new(gate: gate, arguments: { order_id: 42 })
outcome = SupportAgent.new(context: ctx).run_loop(
  "Determina la elegibilidad del pedido 42. Devuelve sólo claims.",
  verifier: verifier
)
```

El formato aceptado es exactamente:

```json
{"claims":[{"relation":"EligibleForReview","values":["order:42"]}]}
```

Las afirmaciones deben coincidir con las consultas determinadas por la app; el
modelo no elige otra entidad ni una relación trivial. Se rechazan claves
adicionales y texto libre. El verificador reconstruye evidencia actual y entrega
al loop sólo aceptación, digests y razones acotadas. Es recomendable declarar
también un `schema:` cerrado que refleje este formato. El renderer de la app
puede producir una explicación a partir del resultado y la evidencia guardada.

Para una herramienta de lectura:

```ruby
tool = Agentkit::ToolContract.new(
  name: :return_details, params: { order_id: :integer },
  preconditions: gate.precondition,
  callable: ->(order_id:) { Returns::ReadDetails.call(order_id: order_id) }
)
```

El callable todavía debe aplicar permisos y scope a su propia lectura. La
precondición termina antes de esa lectura; no ofrece atomicidad con el callable.
Las herramientas mutantes siguen rechazadas por `ToolContract`.

## Gate de ejecución de Capability/Actions

```ruby
Agentkit::Capability.register(:reserve_return_review) do |cap|
  cap.input_schema type: "object", properties: { order_id: { type: "integer" } },
                   required: ["order_id"], additionalProperties: false
  cap.effect :internal
  cap.risk :irreversible
  cap.required_permission "returns.reserve"
  cap.idempotency :required
  cap.knowledge_gate gate
  cap.executor do |args, context:, idempotency_key:|
    # El lock raíz de source sigue activo. Servicio síncrono, misma conexión DB.
    reservation = Returns::ReserveReview.call(
      account: context.account, order_id: args.fetch(:order_id),
      principal: context.principal, idempotency_key: idempotency_key
    )
    { reservation_id: reservation.id.to_s }
  end
end
```

Invocar por `Actions.invoke` con principal autenticado y clave idempotente. El
ciclo de aprobación existente se conserva. La propuesta guarda el digest del
gate; al ejecutar se rechazan cambios, incorporación o eliminación del gate
respecto a esa propuesta. Una nueva versión requiere una nueva propuesta/clave.

El worker llama `execution_context`, exige el mismo tenant y solicitante original
y comprueba su permiso actual. Después vuelve a ejecutar autorización, lectura
bloqueada e inferencia. El executor no recibe el principal privilegiado
`system:action_executor`. Registrar el gate y sus callbacks en todos los workers.

La modificación de negocio, snapshot y comprobante de ejecución se confirman
juntos. Si el executor falla o su salida no satisface `output_schema`, todo ese
bloque se revierte. El intento del rail Actions se registra aparte como fallido;
el outbox y la política de reintento existentes siguen aplicando.

El gate soporta exclusivamente executors internos y síncronos, schema de entrada
cerrado e idempotencia requerida. No admite `flow`, `agent` ni `effect :external`.
Los contratos de entrada, salida y diario usan strings, integers, booleans, null,
arrays y hashes; para dinero usar unidades menores enteras o strings decimales,
no Float. El resultado retornado por una Capability gated se normaliza a datos
JSON con claves string, también cuando se reproduce un resultado anterior.

Un comprobante exitoso evita repetir el efecto con la misma operación y clave,
aunque el estado de negocio ya cambió por la ejecución. Aun así, cada replay
revalida permisos y acceso a la fila. Una clave ligada a argumentos, principal o
gate diferentes produce conflicto. Un rechazo también queda ligado a su clave;
para una nueva decisión con nueva evidencia se necesita otra clave/aprobación.

El marcador Actions de finalización puede fallar después del commit de negocio.
En ese caso, reintentar por el rail con la misma clave recupera el comprobante
sin repetir el efecto. No cambiar la versión del gate en medio de esa recuperación.

Para pagos y correos externos, el executor debe crear una intención/outbox local
en esta misma transacción. Un dispatcher separado ejecuta el proveedor con
idempotencia y reconciliación. La elegibilidad se fija al reservar esa intención;
si debe mantenerse hasta el envío, la app necesita un protocolo adicional de
reserva/cancelación. El módulo no ofrece una transacción distribuida con el proveedor.

## Inbox de eventos y recuperación

```ruby
Order.transaction do
  order.update!(status: "delivered")
  journal.record_event(
    id: "order:#{order.id}:delivered:v#{order.lock_version}",
    payload: { order_id: order.id, version: order.lock_version }, context: ctx
  )
end

# Dentro de un worker autenticado por la app:
journal.consume_event(id: event_id, context: ctx) do |payload|
  gate.check(arguments: { order_id: payload.fetch("order_id") }, context: ctx,
             event_id: event_id)
end

# Reconciliación: programar un job por ID pendiente; repetir es seguro.
journal.pending_event_ids(context: ctx, limit: 100)
```

El ID del evento debe identificar una versión del hecho de negocio. Registrar
el mismo ID/payload es idempotente; otro payload con ese ID se rechaza. Un fallo
del consumidor revierte sus efectos en la misma conexión y deja pendiente el
evento. Otro worker puede recuperarlo. No hay job recurrente ni scheduler
instalado automáticamente. El ejemplo presupone `lock_version` en la app.

El evento conserva su payload original; `gate.check` reconstruye estado actual.
Para preguntas históricas la app debe disponer de fuentes históricas y construir
la evidencia correspondiente. Registrar un evento no convierte su payload en
premisas confiables del motor.

`consume_event` es para trabajo local en la misma base, sin llamadas a proveedores.
Si se combina con otros servicios que toman locks, la app debe mantener un orden
global de bloqueo consistente y reintentar deadlocks abortados. Todas las escrituras
deben usar la conexión compartida; el gate comprueba que source y journal usen
el mismo pool, pero no puede inspeccionar SQL arbitrario del executor/consumidor.

## Operación y límites

Las transacciones usan savepoints cuando existe una transacción exterior. Un
rollback exterior revierte también comprobantes y eventos: la app no debe anunciar
éxito ni publicar un mensaje hasta el commit final. Evitar redes/LLMs dentro de
`extract`, autorizadores o executors mientras está activo el lock.

El diario tiene un límite de 16 MiB por payload; snapshots mantienen el límite
de 4 MiB de 1.7. La lista de pendientes acepta 1..1000 entradas. No hay expiración
ni borrado automático: definir retención que preserve comprobantes idempotentes
durante todo el período posible de reintento. No modificar filas manualmente.

Los digests detectan cambios accidentales; no son firmas frente a un administrador
con capacidad de reescribir datos y digests. No exponer los payloads completos por
un endpoint sin autorización. El diario incluye valores y pruebas de negocio;
no se envían automáticamente a telemetría ni al LLM.

Las reglas continúan siendo relativas a fuentes aprobadas: 1.8 no agrega
aprendizaje de reglas, causalidad, abstracciones Galois ni Lean.

## Pruebas que debe añadir cada app

- Permisos de lectura, escritura y diario, incluidos usuarios desactivados.
- Fuentes adicionales bloqueadas y versiones consistentes.
- Argumentos exactos, importe/unidades y entidad objetivo.
- Carrera entre dos operaciones distintas sobre el mismo recurso.
- Reintento después del commit de negocio y antes de marcar Actions finalizado.
- Reserva, envío, cancelación y reconciliación del proveedor externo si aplica.
- Jobs autenticados, recuperación de inbox y retención de claves idempotentes.
