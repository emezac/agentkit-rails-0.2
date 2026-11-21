# Evaluación de generalización composicional

`Harness::CompositionalGeneralizationEvaluation` comprueba si un cambio de
harness conserva la misma estrategia de descomposición cuando la tarea crece o
cambia de dominio. Es una evaluación opt-in sobre `GovernedStudy`: no entrena
modelos, no ejecuta una recursión nueva y no promueve candidatos por sí sola.

El host sigue siendo responsable de construir datasets independientes, ejecutar
el caso, calificar el resultado completo y los subtareas, y suministrar métricas
comparables. AgentKit valida el contrato, agrega evidencia redacted y aplica las
compuertas de entrenamiento, holdout y revisión.

## Implementación en tres fases

### Fase 1: telemetría por llamada

Cada `AgentLoop::Outcome` incluye `execution_metrics` con rol y profundidad del
loop, turnos del modelo, llamadas anidadas, tools/subagentes, tamaño de contexto,
compactaciones, duración y agotamiento de límites. Además:

- `llm.turn` distingue `loop_role: root|delegate` y publica tokens, duración,
  bytes de contexto y conteos de mensajes/esquemas;
- `agent_loop.completed` resume el loop y su subárbol;
- `agent_tool.completed` resume cada delegación.

`direct_*` representa exclusivamente las llamadas del loop observado;
`subtree_*` incluye sus descendientes. `nested_model_calls` es la diferencia
medida entre ambos. Por compatibilidad, `usage` y las medidas históricas
`input_tokens`/`output_tokens`/`cost_usd` de `agent_loop.completed` siguen
representando el subárbol completo.

Los eventos contienen identificadores y números allowlisted. No contienen
prompts, argumentos, respuestas, resultados de tools ni mensajes de excepción.
`context_*_bytes` mide el JSON serializado enviado al adaptador, no tokens de un
tokenizer.

`outcome.usage` del coordinador incluye el consumo de su subárbol. Para separar
raíz y subagentes en una evaluación, agrega los eventos `llm.turn` por
`loop_role`; no sumes de nuevo el uso total del coordinador y el de sus hijos.

### Fase 2: transferencia source → target

Cada tarea declara metadata cerrada bajo `compositional_generalization`:

| Campo | Contrato |
| --- | --- |
| `family` | Familia de tarea usada para detectar regresiones end-to-end. |
| `pair_id` | Identificador compartido por un source y un target. |
| `axis` | `length` o `domain`. |
| `stage` | `source` en training; `target` en holdout. |
| `domain` | Dominio acotado de la tarea. |
| `strategy` | Estructura composicional que debe permanecer igual. |
| `scale` | Escala numérica positiva. |
| `critical` | Marca casos críticos para el reporte y la compuerta. |
| `local_subtasks` | Exige conteos locales calificados cuando es `true`. |

Un par `length` usa el mismo dominio y un target con escala mayor. Un par
`domain` usa dominios distintos a la misma escala. En ambos casos deben
coincidir `pair_id`, `family`, `axis`, `strategy`, `critical` y
`local_subtasks`. Los pares faltantes, duplicados o incompatibles fallan cerrado.

```ruby
source = Agentkit::Harness::ExperimentTask.new(
  id: "ranking-short",
  input_reference: "dataset:ranking/train/short",
  input_digest: Agentkit::Harness.digest(short_set),
  model: "fixed-model",
  output_contract: manifest.output_contract,
  metadata: { compositional_generalization: {
    family: "ranking", pair_id: "ranking-length", axis: "length",
    stage: "source", domain: "news", strategy: "map_reduce",
    scale: 1, critical: true, local_subtasks: true
  } }
)

target = Agentkit::Harness::ExperimentTask.new(
  id: "ranking-long",
  input_reference: "dataset:ranking/holdout/long",
  input_digest: Agentkit::Harness.digest(long_holdout),
  model: "fixed-model",
  output_contract: manifest.output_contract,
  metadata: { compositional_generalization: {
    family: "ranking", pair_id: "ranking-length", axis: "length",
    stage: "target", domain: "news", strategy: "map_reduce",
    scale: 8, critical: true, local_subtasks: true
  } }
)
```

Cada repetición del executor devuelve el contrato habitual y un outcome
composicional cerrado:

```ruby
{
  output_digest: output_digest,
  metrics: { quality: 0.9, cost: 0.02, latency: 120 },
  compositional_evaluation: {
    success: true,
    subtasks: { correct: 7, total: 8 },
    root: {
      turns: 3, input_tokens: 1_200, output_tokens: 180,
      context_peak_bytes: 9_100
    },
    subagents: {
      calls: 2, turns: 4, input_tokens: 850, output_tokens: 140,
      context_peak_bytes: 5_200
    },
    subcalls: 2,
    limit_exhausted: false,
    delegation_enabled: true
  }
}
```

Los conteos describen ejecución, no contenido. No incluyas respuestas, etiquetas,
trazas, razonamiento o texto de errores. Si `delegation_enabled` es `false`,
`subcalls` y toda la actividad de `subagents` deben ser cero. Si
`local_subtasks` es `true`, `subtasks.total` debe ser mayor que cero.

### Fase 3: compuertas gobernadas

```ruby
evaluation = Agentkit::Harness::CompositionalGeneralizationEvaluation.new(
  minimum_source_success_rate: 0.5,
  minimum_target_success_rate: 0.5,
  minimum_local_accuracy: 0.85,
  max_transfer_drop: 0.15,
  minimum_target_lift: 0.0,
  max_family_regressions: 0,
  maximum_limit_exhaustion_rate: 0.0,
  require_no_delegation_baseline: true
)

study = Agentkit::Harness::GovernedStudy.new(
  id: "compositional-ranking-v1",
  base: manifest,
  revisions: candidate_revisions,
  training_tasks: [source],
  holdout_tasks: [target],
  repetitions: 4,
  executor: run_measured_probe,
  executor_digest: Agentkit::Harness.digest("runner-grader-v1"),
  compositional_evaluation: evaluation,
  context: Agentkit.context
)
```

La selección usa sólo source/training y descarta candidatos con bajo éxito
local, precisión insuficiente, agotamiento de límites o regresiones familiares.
Después, el holdout empareja cada target con su source congelado y comprueba la
caída de transferencia y el lift frente a la base. `Exploration::Governance`
revalida `allowed == true`; la revisión humana y el rollback existentes siguen
siendo obligatorios.

## Las siete medidas

1. Transferencia de entradas cortas a largas (`axis: length`).
2. Transferencia entre dominios con la misma estrategia (`axis: domain`).
3. Exactitud agregada de subtareas delegadas, calculada como
   `sum(correct) / sum(total)`.
4. Tokens y pico de contexto separados entre raíz y subagentes.
5. Turnos, subcalls, costo, latencia y tasa de agotamiento de límites.
6. Éxito end-to-end y regresiones agregadas por familia de tarea.
7. Comparación contra una base observada sin delegación.

Los defaults son: éxito source/target `0.5`, exactitud local `0.8`, caída máxima
`0.2`, lift mínimo `0`, cero familias regresadas, cero agotamientos y baseline
sin delegación obligatoria. Cambiar un umbral cambia el digest del estudio.

## Baseline y privacidad

La base sin delegación no se infiere por nombre. Cada repetición debe declarar
`delegation_enabled: false`, `subcalls: 0` y contadores de subagentes en cero.
AgentKit comprueba esa evidencia tanto en training como en holdout.

Los outcomes composicionales se guardan en
`Evaluation#compositional_outcomes`, separados de los outcomes de
`ArchitectureEvaluation`. Sin `compositional_evaluation:` no se añaden campos a
los probes, evaluaciones, dossier o identidad legacy.

En ejecución distribuida, todos los workers deben registrar la misma definición
del estudio, evaluator, metadata y executor. El host conserva la responsabilidad
de aislamiento, autorización, datasets realmente independientes, grader
versionado y retención de telemetría.
