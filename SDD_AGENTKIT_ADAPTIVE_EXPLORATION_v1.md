# SDD AgentKit 0.7.0 — Adaptive Exploration

## 1. Objetivo

Introducir en AgentKit la capa de meta-exploración de *Dream-RSI* sin convertir
el kernel en un sistema que reescribe o ejecuta código generado. La unidad de
mejora es la política que asigna trabajo de descubrimiento: abre ramas, refina
hojas, agrupa intentos independientes y decide cuándo parar.

## 2. Traducción del paper al producto

| Dream-RSI | AgentKit 0.7.0 |
|---|---|
| árbol de discovery | `Exploration::World` con un padre primario por nodo |
| `CONTINUE(v)` | seleccionar el id del root o de una hoja legal |
| rollout online | `Exploration.run` con generator y evaluator fijos |
| history como simulator | store durable de worlds tenant-scoped |
| replay off-policy | `Exploration.replay`, sin llamadas externas |
| calidad − costo + paralelismo | `ReplayResult#score` con coeficientes acotados |
| beta sweep | `Exploration.sweep`, beta fijo por replay |
| selección de política | `Exploration.recommend`, incumbente incluido |
| redeploy automático del paper | recomendación N3 con revisión, nunca auto-promoción |

## 3. Contratos

### 3.1 Online

El caller entrega un `generator`, un `evaluator` y un `evaluator_id` versionado.
El generador recibe sólo el padre seleccionado y una vista inmutable del árbol
visible. El evaluador devuelve un score finito y diagnósticos opcionales. Cada
batch se ejecuta concurrentemente; el orden de inserción permanece
determinista.

La única acción legal es continuar desde el root o desde una hoja. Root abre
una rama y una hoja profundiza o repara su rama. Seleccionar vacío termina el
rollout.

### 3.2 Replay prefix-only

Cada replay comienza únicamente con el root. La política recibe nodos ya
revelados y acciones legales; no recibe el `World` completo. Continuar revela
el siguiente hijo ya grabado. El replay nunca invoca generator/evaluator y
cada política empieza desde un prefijo nuevo.

### 3.3 Función objetivo

Para calidad `Q`, probes revelados `N`, rondas `K`, penalización `c` y bonus
`p`:

```text
V = Q - cN + p(N / max(1, K))
```

Los coeficientes son no negativos y finitos. Evaluar una política promedia `V`
en el mismo history digest usado por las demás.

## 4. Adaptación

La política `Portfolio` construye en cada ronda un batch determinista con:

- explotación de refinamientos prometedores;
- exploración de root o frentes novedosos;
- como máximo una recuperación con fallo reparable.

`beta` cambia la prioridad relativa, pero queda congelado durante un episodio.
El sweep offline evalúa valores alternativos desde cero. `plan_beta` sólo
recomienda pasos pequeños entre ciclos usando simultáneamente tendencia live y
trade-off de replay.

## 5. Límites de autoridad y seguridad

- feature desactivada por default;
- techos server-side para rondas, workers, nodos, replays, políticas y bytes;
- acciones ilegales, duplicadas o demasiado anchas fallan cerrado;
- árboles rechazan ids/secuencias duplicados, huérfanos, relaciones no forward
  y contadores fuera de sus bounds;
- objective y artifact se persisten como SHA-256, no como payload crudo;
- diagnósticos pasan por redacción recursiva y truncamiento con digest;
- tenant/account se aplican antes de devolver history;
- no `eval`, compilación o carga de source generado;
- el incumbente siempre participa y el resultado sólo puede ser recomendación
  N3 revisable;
- un worker fallido queda registrado como probe sin score; no se fabrica una
  evaluación favorable ni se pierde su costo.

## 6. Persistencia y telemetría

La migración 018 crea `agentkit_exploration_worlds`, con provenance de política
y evaluador, bounds, árbol JSONB, score agregado, stop reason e índices por
scope/política. Los eventos públicos son:

- `exploration.online.completed`;
- `exploration.replay.completed`;
- `exploration.attempt.failed`.

Las dimensiones son de cardinalidad baja y nunca incluyen el objetivo.

## 7. Fuera de alcance

- generar o editar código de políticas con un LLM;
- modificar el agente base, evaluator o interfaces durante replay;
- inferir resultados de nodos no observados;
- ejecutar efectos de negocio como parte del evaluator;
- declarar que replay garantiza mejora online.

## 8. Definition of done

- replay idéntico no hace llamadas externas y es determinista;
- una política no puede observar outcomes futuros;
- los límites del caller nunca superan la configuración;
- la recomendación incluye el incumbente y nunca auto-promueve;
- store memory y ActiveRecord aíslan tenant;
- migración, initializer, changelog y upgrade guide están actualizados;
- suite completa y verificación de release verdes.
