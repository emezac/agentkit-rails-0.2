# 1.8.0 — Rails Evidence & Decision Gates

## Alcance

Conectar el núcleo 1.7 con fuentes Rails autorizadas, decisiones persistentes,
verificación de respuestas y ejecución de efectos locales bajo evidencia actual.
Contrato de la app: [guía Rails](docs/RAILS_EVIDENCE_AND_DECISION_GATES.md).

## Componentes

- `Boundary`: identidad explícita, scope derivado de tenant/cuenta y datos canónicos.
- `ActiveRecordSource`: relación autorizada, fila raíz bloqueada, extracción de
  observaciones y snapshot dentro de la transacción; exige pool compartido con diario.
- `Journal`: entradas únicas por scope/tipo/clave, payload con digest, reintentos
  transaccionales y API de inbox durable. Migración 024.
- `DecisionGate`: autorización de la app antes y después del lock, consultas
  determinadas por el host y pruebas independientes. Completitud por defecto.
- `AnswerVerifier`: contrato cerrado de afirmaciones esperadas en AgentLoop.
- `Capability#knowledge_gate`: executor interno síncrono, schema cerrado y clave
  idempotente requerida; salida validada antes del commit con el comprobante.
- `Actions`: propuesta vinculada al gate, detección de cambios/remoción, resolución
  del solicitante vigente y revalidación de permiso al ejecutar.

## Atomicidad y recuperación

La fila raíz mantiene el lock mientras se consulta el núcleo y se ejecuta el
efecto. El resultado y su comprobante se guardan en la misma transacción. Dos
claves distintas compiten por el estado actual; la misma clave reproduce el
resultado sin repetir el efecto. Claves con solicitudes distintas fallan.
Un rechazo tiene comprobante bloqueado. Una excepción revierte el bloque local.

La marca final de Actions usa su rail existente; un fallo posterior al commit
local requiere reintento con la misma clave, que recupera el resultado durable.
Los eventos se registran en la transacción de negocio y se consumen con marcador
de entrega en la misma base. El host programa y recupera los jobs pendientes.

## Evidencia de aceptación

Pruebas PostgreSQL: replay y reconstrucción de snapshots, autorización por capas,
aislamiento de tenant/cuenta, detección de corrupción, deduplicación y concurrencia,
rollback y recuperación de eventos, decisiones incompletas, cambios de estado
posteriores a aprobación, gate drift, permisos revocados y output inválido.
La integración con AgentLoop usa el adaptador Fake y el verificador real.
El ejemplo Rails se ejecuta contra el modelo Widget de la app de prueba.

## Límites explícitos

El host aporta la verdad de las fuentes y la autorización real. El adaptador
bloquea una fila raíz; otras fuentes y locks son responsabilidad de la app.
No hay transacción distribuida, llamadas externas dentro del gate, scheduler
automático, retención automática ni evaluación causal. Los callbacks se versionan
por contrato declarado, no por hash del código ejecutable. Las abstracciones
matemáticas y el aprendizaje de negocio siguen fuera de este release.
