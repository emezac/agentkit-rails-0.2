# Business Learning Loop — 1.9.0

`Agentkit::Knowledge::BusinessLearning` conecta ejecuciones verificadas de 1.8
con resultados de negocio tardíos y propuestas revisables. Es aprendizaje
**retrospectivo**, no una prueba causal ni un entrenador de modelos.

Para contrastar una hipótesis mediante asignación controlada, consultar
[Controlled Business Experiments (1.10)](CONTROLLED_BUSINESS_EXPERIMENTS.md).

## Frontera entre framework y aplicación Rails

| Agentkit | Aplicación Rails |
| --- | --- |
| Contrato inmutable, digest y aislamiento tenant/account | Objetivo, métricas, unidades, restricciones y ventanas pertinentes al negocio |
| Referencia comprobada a un execution receipt y snapshot | Transacciones, extracción de fuentes, reglas y autorización mediante DecisionGate |
| Outcome final idempotente, procedencia y fecha de recepción | Agregar eventos parciales, conciliar pagos/devoluciones y decidir cuándo el resultado es final |
| Separación temporal y conteos complete/pending/missing | Seleccionar una cohorte reproducible y completa, controlar sesgo de selección y retención |
| Propuesta declarativa, aprobación independiente, expiración y revocación | Generar hipótesis (analista/LLM), validar su semántica y autorizar humanos reales |
| Registro de versión aplicada en observaciones | Aplicar cambios mediante servicios Rails, registrar usos y restaurar la configuración anterior |

Las restricciones del contrato son metadatos versionados: **no se ejecutan como
validaciones**. Rails debe implementarlas en sus servicios y DecisionGate. No
permitir que el LLM suministre `context`, autorizadores, versiones o reloj.
La identidad diferente del revisor no prueba que sea humano: el callback Rails
debe exigir una sesión humana autorizada, no una identidad inventada por un agente.

## Configuración

```ruby
journal = Agentkit::Knowledge::Journal.new(
  authorize: ->(kind, ctx) { EvidencePolicy.allowed?(ctx, kind) }
)
learning = Agentkit::Knowledge::BusinessLearning.new(
  name: "order_returns", version: "1",
  objective: "reducir costo de devoluciones sin degradar servicio",
  metrics: { cost_cents: "minimize", satisfied_count: "maximize" },
  constraints: { max_refund_cents: 50_000, human_approval: true },
  window_seconds: 30 * 86_400,
  evidence_versions: { gate: returns_gate.digest, ledger_schema: "2", cohort_query: "3" },
  journal: journal,
  authorize: ->(action, ctx) { LearningPolicy.allowed?(ctx, action) }
)
```

`EvidencePolicy` y `LearningPolicy` son clases **de la app**, no APIs incluidas.
Autorizar el nuevo kind `learning` explícitamente en Journal. Acciones del
callback: `observe`, `outcome`, `evaluate`, `propose`, `review`, `rollback`, `use`, `read`.
Se requiere retorno `true`, tanto en Learning como en Journal. No exponer Journal
directamente al LLM ni a clientes: es una frontera interna de confianza.

Todos los valores de métricas son enteros; usar centavos, milisegundos o puntos
básicos. Los objetos JSON no admiten floats. El orden de las métricas no importa.
`minimize`/`maximize` documenta la dirección; no implica que una comparación sea
significativa ni selecciona automáticamente un ganador.

## Ciclo de vida y API

1. Ejecutar el proceso con `DecisionGate#execute` (o capability protegida).
2. Registrar la ejecución confirmada:

```ruby
learning.observe(id: "order:42", execution_key: "refund:request-42", context: ctx)
```

`execution_key` es `"#{operation}:#{idempotency_key}"` de DecisionGate, no el
ID de ActionProposal. Se rechazan receipts ausentes/no ejecutados y snapshots
ausentes. La fecha de decisión proviene del snapshot, no del LLM. La observación
conserva gate/snapshot/receipt digests. Registrar inmediatamente después del
commit mediante un job recuperable/outbox; no antes de confirmar la ejecución.

3. Al cerrar la ventana, consolidar **todos** los indicadores y entregar:

```ruby
learning.outcome(id: "order:42", values: { cost_cents: 900, satisfied_count: 1 },
  source: "business_outcomes/42", source_version: "revision-1",
  observed_at: finalized_at.iso8601(6), context: ctx)
```

`observed_at` debe ser posterior o igual al fin de ventana y no futuro.
`journaled_at` lo fija el servidor al persistir, también para reintentos concurrentes.
No se acepta un resultado parcial. La misma petición se puede repetir; cambiar
sus datos con el mismo ID produce `IntegrityError`. Para corregir evidencia,
versionar el contrato, revocar propuestas afectadas y reconstruir explícitamente
observaciones/resultados/reportes; nunca sobrescribir el historial.

4. Generar un informe inmutable:

```ruby
report = learning.evaluate(id: "cohort-2026-09-v1",
  observation_ids: cohort_ids, split_at: training_cutoff.iso8601(6),
  as_of: evaluation_cutoff.iso8601(6), context: ctx)
```

La cohorte tiene de 1 a 10.000 IDs únicos y no permite contar dos veces una misma
ejecución aunque se registrara con distintos IDs. Decisiones anteriores a `split_at`
son training; las demás son holdout temporal. No se admiten decisiones después
de `as_of` ni cortes futuros. Para training, **ambas** fechas del outcome
(`observed_at`, `journaled_at`) deben ser <= `split_at`; para holdout, <= `as_of`.
Ventana no cerrada: `pending`. Ventana cerrada sin resultado conocido al corte:
`missing`. Ninguna cuenta como cero, éxito ni fracaso. Cada indicador devuelve
`sum` y `count`; con count=0 no hay media definida. El informe conserva todas
las observaciones y sólo los outcomes disponibles al corte, y marca `causal: false`.
Los IDs de informes no se reutilizan para datos actualizados: crear otro informe.

La selección de IDs es responsabilidad de Rails. Este informe no garantiza una
cohorte completa ni ausencia de sesgo, y no estima intervalos, p-values ni efectos
causales. Un holdout inspeccionado repetidamente deja de ser independiente para
selección: reservar nuevos períodos para nuevas hipótesis.

5. El analista o un LLM propone una hipótesis a partir del informe:

```ruby
learning.propose(id: "discount-v2", report_id: "cohort-2026-09-v1",
  hypothesis: "un descuento menor podría reducir costo sin degradar satisfacción",
  change: { discount_basis_points: 100 }, expires_at: expiry.iso8601(6), context: ctx)
learning.review(id: "discount-v2", approve: true, reason: "piloto acotado autorizado",
  context: human_reviewer_context)
```

Se exige al menos una observación completa en cada partición; es un requisito
de trazabilidad mínimo, **no suficiencia estadística**. Rails debe imponer tamaño
de muestra, riesgos, métricas secundarias y reglas de aprobación adicionales.
`change` es un objeto declarativo, nunca código evaluado por Agentkit. `review`
persiste actor, razón, fecha y digest de propuesta; autor y revisor deben diferir.
Una revisión no puede cambiarse silenciosamente. Rechazo: `approve: false`.

6. Consultar en el servicio de negocio antes de considerar una versión:

```ruby
proposal = learning.active(id: "discount-v2", context: ctx)
# Rails valida proposal["change"] y aplica el servicio autorizado con DecisionGate.
# Después del commit, documenta qué versión realmente utilizó:
learning.observe(id: "order:99", execution_key: "refund:request-99", context: ctx,
  applied_proposal_id: "discount-v2")
```

`active` devuelve nil para no aprobada/revocada; versión desconocida o caducada
produce `InvalidContract`. No es un permiso de ejecución ni un lock distribuido:
Rails debe serializar despliegue/revocación y validar de nuevo en la transacción
de negocio. `applied_proposal_id` es una declaración de Rails, no inferida por el
framework; comprueba que la propuesta sigue activa al registrar. Para evitar
perder la atribución por una revocación concurrente, serializar ese registro con
la aplicación de versión usando el mismo lock de configuración del proceso.

7. Revocar:

```ruby
learning.rollback(id: "discount-v2", reason: "señal adversa", context: human_reviewer_context)
```

La revocación es permanente para ese ID y lo hace inutilizable mediante `active`.
**No revierte transacciones, reembolsa dinero ni restaura configuración por sí
sola**. Rails ejecuta la compensación/restauración aprobada. Registrar una nueva
propuesta para volver a probar. No hay selección automática de versión global.

## Dependencias, almacenamiento y seguridad

El digest del proceso incluye versión, objetivo, métricas, restricciones, ventana
y `evidence_versions`. Cambiar cualquiera crea otro espacio de aprendizaje:
las propuestas anteriores no pueden resolverse en el nuevo contrato. Rails debe
proporcionar las versiones actuales de fuentes, reglas y consulta de cohorte y
reconstruir el objeto cuando cambien; Agentkit no detecta cambios ocultos de código
ni de semántica en callbacks. La dependencia especial `evidence_versions[:gate]`,
si está presente, se coteja con el digest del receipt al observar la ejecución.
Revocar explícitamente los contratos anteriores si
aún existen workers con configuración vieja. La caducidad se verifica al aprobar
y usar, sin requerir un scheduler; reevaluar mediante un job Rails con nueva
cohorte/reporte/propuesta, no renovando una aprobación anterior.

Persistencia: tabla `agentkit_knowledge_entries`, kind `learning`, de migración
024. No hay migración nueva. Índice único y locks de Journal garantizan reintentos
idempotentes. Reportes/payloads mantienen límite de Journal (16 MiB); dividir
cohortes si exceden el tamaño. Esta API no integra propuestas retrospectivas en
`Exploration::Governance` ni `ExperienceLibrary`: sus requisitos experimentales
siguen intactos. Tampoco incluye un dashboard nuevo. Rails puede consultar el
journal mediante `learning.fetch(type: "report", id: report_id, context: ctx)`
para construir su interfaz (tipos: observation/outcome/report/proposal/review/rollback).
Cada registro conserva también el contrato completo para reconstruir su significado.

Los hashes detectan alteraciones accidentales; no son firmas frente a un atacante
con control total de base de datos. Aplicar políticas de retención, cifrado y
minimización de datos en Rails. Nunca guardar PII innecesaria en `change`/hypothesis.
Las premisas de Knowledge siguen siendo observaciones/reglas autorizadas; ninguna
hipótesis aprobada se convierte automáticamente en hecho o ley causal.
