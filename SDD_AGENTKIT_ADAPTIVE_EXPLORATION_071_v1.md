# SDD AgentKit 0.7.1 — Durable Adaptive Exploration

## 1. Objetivo

Cerrar la brecha entre el prototipo replay-first de 0.7.0 y una ejecución que
pueda recuperarse de caídas sin duplicar probes ni confundir ausencia de
respuesta con fallo. La mejora conserva el límite de autoridad: AgentKit adapta
la política de exploración, pero no auto-promueve políticas ni reintenta efectos
ambiguos.

## 2. Invariantes

- cada world se guarda como `running` antes del primer probe y después de cada
  ronda completa;
- cada slot `(tenant, world, round, position)` tiene un solo intento durable;
- cada intento tiene una idempotency key estable y transiciones cerradas;
- sólo un owner puede reanudar un world mientras su lease esté vigente;
- un intento `running` reciente continúa activo; al expirar se convierte en
  `execution_unknown`, no en `failed` ni `pending`;
- sólo `reconcile_attempt!` puede sacar un intento de `execution_unknown`;
- un world incompleto nunca entra al replay pool;
- una recomendación exige suficientes worlds y cobertura histórica suficiente.

## 3. Estados

```text
pending ──claim──> running ──result──> completed
                         └──error────> failed
                         └──stale────> execution_unknown

execution_unknown ──operator──> pending | completed | failed
```

`Interrupt` y una caída de proceso quedan fuera del rescue de errores normales:
el world permanece `running`, el lease expira y cualquier intento reclamado se
reconcilia antes de continuar.

## 4. Evaluador reproducible

El registry identifica un evaluador por `(name, version)` y fija un manifest
con digest de source, schema de entrada, schema de salida, normalización y
metadata sanitizada. Registrar el mismo nombre/versión con otro manifest falla.
El digest del manifest queda tanto en el world como en la columna dedicada.

Normalizaciones soportadas:

- `identity`: persiste el score finito del evaluador;
- `relative_to_baseline`: persiste `score - evaluator_baseline_score` y expone
  baseline `0.0` a política y replay.

## 5. Replay y evidencia

En cada decisión, replay separa acciones estructuralmente posibles de acciones
respaldadas por un hijo observado. Reporta:

- `decision_coverage`: oportunidades soportadas / oportunidades estructurales;
- `unsupported_actions`: acciones sin outcome histórico;
- `unsupported_decisions`: decisiones donde faltó al menos una alternativa.

`Evaluation` agrega cobertura media y mínima. `recommend` sólo considera una
mejora si incumbente y candidato alcanzan `min_replay_coverage`; de lo contrario
devuelve `retain / insufficient_replay_coverage`.

## 6. Persistencia

La migración 019 permite worlds en ejecución, agrega checkpoint/manifest y crea
`agentkit_exploration_attempts` con unicidad por slot e idempotency key. La 020
agrega owner, vencimiento e índice de leases. Todas las lecturas y mutaciones
aplican scope tenant/account antes de acceder al registro.

## 7. Observabilidad y privacidad

- telemetría de completitud, replay, fallo y ambigüedad usa dimensiones de baja
  cardinalidad;
- reconciliación genera audit record y no guarda el outcome crudo;
- artifacts se persisten como SHA-256;
- diagnósticos y metadata pasan por redacción y límite de bytes;
- `agentkit:doctor` verifica tablas/índices y advierte worlds o intentos que
  necesitan atención.

## 8. Definition of done

- unit tests cubren reanudación limpia, lease concurrente, intento fresco,
  expiración ambigua y reconciliación;
- integration tests cubren migrations, checkpoints, attempts y liberación del
  lease con PostgreSQL;
- evaluator manifests son inmutables y sus outputs se validan fail-closed;
- replay bloquea recomendaciones con cobertura insuficiente;
- `bundle exec rake verify` y artefactos de release pasan sin cambios no
  relacionados.
