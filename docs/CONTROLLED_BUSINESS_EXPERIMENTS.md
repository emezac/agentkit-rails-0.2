# Controlled Business Experiments — 1.10.0

`Agentkit::Knowledge::BusinessExperiment` implementa experimentos A/B de horizonte
fijo con asignación 50:50, protocolo inmutable, aprobación humana independiente,
cupo, ejecución protegida y análisis por **intención de tratar (ITT)**.
Complementa `BusinessLearning` (1.9), sin convertir retrospectivas en experimentos.

No demuestra causalidad universal. El resultado puede respaldar una interpretación
causal **local y condicionada** al diseño, a la independencia de las unidades y a
la implementación fiel de Rails. Nunca genera una regla Knowledge automáticamente.

## Instalación

```sh
rails agentkit:install:migrations
rails db:migrate
```

Requiere migración **025** además de 024. La nueva tabla
`agentkit_business_experiments` guarda el protocolo, el estado operativo, la
semilla privada y el registro completo de unidades. Journal conserva eventos
inmutables bajo kind `experiment`. Autorizar este kind explícitamente. Ambos
modelos y el efecto de negocio deben compartir connection pool y transacción.
No ejecutar workers 1.9 sobre procesos que dependan de las restricciones de 1.10.

## Responsabilidades exactas

| Agentkit | Aplicación Rails |
| --- | --- |
| Protocolo versionado e inmutable y aprobación independiente | Hipótesis, cambios concretos, significado de métricas y revisión de riesgos |
| Asignación HMAC 50:50, persistida antes de intervenir | Identificador estable y opaco, elegibilidad pretratamiento y consentimiento cuando corresponda |
| Cuota global por experimento/tenant y cierre temporal | Presupuesto monetario, límites por operación y exclusión entre experimentos concurrentes |
| Bloqueo experimento → DecisionGate → exposición | Servicios transaccionales locales y vínculo correcto unidad/argumentos |
| Resultados finales acotados, procedencia, recepción y reintentos | Medición para **todos** los asignados, incluso fallos y no expuestos |
| ITT, intervalos conservadores, alertas de desequilibrio y métricas de seguridad | Potencia/tamaño de muestra, independencia, interferencia, cambios externos y validez causal |
| Stop permanente y revocación de resultado auditables | Monitoreo de seguridad, compensaciones, restauración y despliegue revisado |

Una unidad debe ser independiente: si varias órdenes del mismo cliente se influyen,
usar cliente como unidad y **un resultado agregado por cliente**, no tratar cada
orden como una observación independiente. No incluye inferencia por clusters,
switchbacks, bandits, asignación adaptativa, más de dos brazos ni diseños secuenciales.

## Construcción del protocolo

```ruby
experiment = Agentkit::Knowledge::BusinessExperiment.new(
  name: "checkout_simplification", version: "1",
  hypothesis: "el flujo simplificado mejora conversión sin daño excesivo en soporte",
  unit: "customer",
  metrics: {
    conversion: { min: 0, max: 1, direction: "maximize" },
    support_cost_cents: { min: 0, max: 10_000, direction: "minimize", max_harm: 100 }
  },
  primary_metric: "conversion",
  starts_at: starts_at.iso8601(6),
  enrollment_ends_at: enrollment_ends_at.iso8601(6),
  analysis_at: analysis_at.iso8601(6),
  window_seconds: 7 * 86_400, max_units: 2_000, min_per_arm: 500,
  gates: { control: control_gate.digest, treatment: treatment_gate.digest },
  variants: { control: { flow: "original" }, treatment: { flow: "simplified" } },
  evidence_versions: { eligibility: "1", measurement: "2", hypothesis_proposal: proposal_digest },
  journal: journal,
  authorize: ->(action, ctx) { ExperimentPolicy.allowed?(ctx, action) },
  eligible: ->(unit_id, ctx) { EligibleCustomers.new(ctx).include?(unit_id) },
  bind_unit: ->(unit_id, args, ctx) { CustomerOrderBinding.valid?(unit_id, args, ctx) }
)
```

`ExperimentPolicy`, `EligibleCustomers` y `CustomerOrderBinding` son componentes
que debe implementar la aplicación. El host construye los gates con **la misma
instancia de Journal**. `bind_unit` debe comprobar, bajo el contexto autorizado,
que los argumentos pertenecen a la unidad asignada y que la intervención no se
repite sobre otro recurso/unidad. No confiar en IDs propuestos por el LLM.

Acciones de autorización: `register`, `approve`, `assign`, `execute`, `outcome`,
`stop`, `analyze`, `read`, `review_result`, `revoke_result`. Retorno exacto `true`.
Para aprobar/revisar, Rails debe exigir una identidad humana real con permiso;
Agentkit sólo verifica que su ID difiere del autor que registró el experimento.

Límites: 40–10.000 unidades, mínimo 20 por brazo, 1–16 métricas, enteros acotados
entre −10^12 y 10^12. `primary_metric` es un string. Fechas ISO8601 con zona.
`analysis_at >= enrollment_ends_at + window_seconds`. Los límites de métricas
deben elegirse **antes** del experimento; no se ajustan a los datos observados.
Fuera de rango se rechaza, no se recorta automáticamente. Si necesita winsorizar,
definir y versionar esa transformación previamente en la medición Rails.

`max_harm` declara una tolerancia máxima en unidades de la métrica; para una
métrica a minimizar, un incremento es daño. No basta que el promedio observado
esté dentro de la tolerancia: el límite de confianza también debe establecerlo.
La cuota no equivale a un cálculo de potencia ni a un presupuesto monetario.

## Registro, aprobación y asignación

```ruby
experiment.register(context: author_ctx)
experiment.approve(reason: "protocolo y límites revisados", context: human_ctx)
# Dentro de la ventana:
assignment = experiment.assign(unit_id: customer_experiment_id, context: request_ctx)
```

Registro y aprobación deben ocurrir antes de `starts_at`. La pareja nombre/versión
queda vinculada al digest de **todo** el protocolo; modificarlo exige una nueva
versión. Variantes, gates y dependencias quedan incluidas en ese digest.

La semilla se genera en el servidor con `SecureRandom`, nunca viene del LLM.
HMAC-SHA256 produce un bit 50:50 por ID y scope. La asignación se persiste bajo
lock y un ID siempre conserva el brazo. La cuota y los duplicados se serializan
entre workers. La semilla no sale por la API; se conserva un compromiso SHA256
en el registro y se verifica al acceder. Administradores de base de datos siguen
siendo parte de la frontera de confianza. No existe un endpoint público para
previsualizar brazos sin inscribir unidades. Tampoco se permite borrar unidades
del registro del experimento a través de esta API.

Los IDs se almacenan como hashes; eso no anonimiza IDs enumerables. Usar IDs
opacos y aplicar cifrado/retención en Rails. Las asignaciones son por tenant y
account, no entre tenants; analizar una población inter-tenant requiere otro diseño.

## Ejecutar y registrar la exposición

```ruby
arm = assignment.fetch("arm")
gate = { "control" => control_gate, "treatment" => treatment_gate }.fetch(arm)
receipt = experiment.execute(unit_id: customer_experiment_id,
  gate: gate, arguments: { id: order.id }, context: request_ctx) do |assigned_arm, variant|
  CheckoutService.new(order).apply_flow!(variant.fetch("flow"))
  { flow: variant.fetch("flow") }
end
```

Se revalida autorización, elegibilidad, binding, estado, ventana y digest del gate.
La clave idempotente la construye Agentkit a partir del experimento y la unidad:
una única intervención por unidad en esta versión. Conserva el execution receipt
de 1.8 y su digest. Los reintentos con el mismo contexto/argumentos recuperan el
resultado sin repetir el efecto mientras la ejecución siga permitida. Tras stop
o cierre, usar `fetch` para consultar, no `execute`. Cambiar argumentos o principal
en una repetición no autoriza otra ejecución.

Si falla el efecto, la validación o el registro de exposición, se revierte la
transacción completa; **la asignación previa permanece**, para conservar ITT.
Una asignación fallida/no expuesta también necesita medición final.

El lock se mantiene durante el efecto: experiment → fila de negocio → journal.
Todos los caminos de la app deben respetar ese orden para evitar deadlocks.
No hacer HTTP, emails ni pagos remotos dentro del bloque: guardar una intención
en el outbox de la misma base. El control de idempotencia y cancelación en el
consumidor externo es responsabilidad Rails. Registrar una intención de envío no
prueba que el cliente recibió el tratamiento; verificar esa fidelidad por separado.
El lock global del experimento prioriza seguridad y cuota exacta sobre throughput.

## Medir todos los asignados

```ruby
experiment.outcome(unit_id: customer_experiment_id,
  values: { conversion: 1, support_cost_cents: 500 },
  source: "customer_outcomes/#{outcome.id}", source_version: outcome.revision.to_s,
  observed_at: outcome.finalized_at.iso8601(6), context: worker_ctx)
```

La ventana empieza en **asignación**, no en exposición (estimando ITT).
`observed_at` debe ser >= asignación + ventana y <= reloj del servidor.
Se exige el conjunto completo de métricas con enteros dentro de los límites.
`recorded_at` es la fecha del servidor al persistir, no se puede aportar como input.
Repetir exactamente es idempotente; corregir bajo la misma identidad produce
`IntegrityError`. Un defecto de medición exige detener/revocar y crear una nueva
versión, conservando el historial, no editar resultados retrospectivamente.

Resultados recibidos después de `analysis_at` no entran al análisis aunque su
observación se declare anterior. Una vez sellado el informe, ya no se admiten
outcomes nuevos. Jobs Rails deben entregar resultados con margen antes del corte.

## Análisis final y lectura estadística

```ruby
report = experiment.analyze(context: analyst_ctx)
```

Sólo a partir de `analysis_at`. No acepta una lista seleccionada de unidades:
utiliza el registro completo. Se persiste **un único informe** y llamadas futuras
devuelven el mismo. No hay análisis repetidos con cortes elegidos después de ver
resultados. El acceso de lectura a outcomes no impide que un humano espíe datos:
la política y disciplina del host deben evitar decisiones basadas en peeking.

Por brazo informa assigned/complete/missing/exposed y conserva cada asignación,
outcome disponible y comprobante de exposición. Missing nunca es cero ni éxito.
Si falta cualquier resultado, se omiten estimaciones de efecto y el informe es
inconcluso, sin análisis selectivo de sólo quienes completaron.

Con outcomes completos, estima diferencia de medias tratamiento − control.
Es el efecto de **asignar** la variante, no el efecto entre quienes efectivamente
la recibieron. No interpretar ITT como un efecto per-protocol cuando hay no exposición.
Para cada métrica de rango R, m métricas y n unidades en un brazo:

```text
radio_brazo = R × sqrt(log(4 × m / 0.05) / (2 × n))
radio_diferencia = radio_control + radio_tratamiento
```

Se usan cotas de Hoeffding y unión de eventos para cobertura simultánea nominal
de al menos 95% bajo las hipótesis de unidades independientes y medición acotada.
No se asume normalidad, no se estima varianza cero como certeza, ni se anuncia un
p-value. Son intervalos deliberadamente conservadores; pueden exceder el rango
posible del efecto. Las cifras se serializan como strings decimales porque el
journal de Knowledge no admite floats. El método se basa en la desigualdad para
sumas independientes acotadas de [Hoeffding](https://doi.org/10.1080/01621459.1963.10500830).

La corrección simultánea cubre métricas de este protocolo, no la búsqueda entre
muchos experimentos/versiones. No adaptar elegibilidad o admisión a resultados
vistos ni repetir versiones hasta obtener significancia. Esa multiplicidad exige
un plan estadístico adicional del host.

`benefit_lower`/`benefit_upper` orientan el efecto a la dirección deseada:
positivo significa mejora tanto para maximize como minimize. Para ser elegible
para revisión, el límite inferior primario debe ser >0 y todas las métricas con
`max_harm` deben tener límite inferior >= −max_harm. Esto no sustituye relevancia
práctica, potencia ni análisis de costos del negocio.

También calcula una alarma conservadora de desequilibrio 50:50:
`min(1, 2 × exp(-2 × (n_control - n_total/2)^2 / n_total)) < 0.001`.
Es una **cota de cola**, no un p-value binomial exacto ni un diagnóstico de causa.
Una alarma bloquea la recomendación; su ausencia no garantiza datos sanos.
Los desequilibrios pueden revelar problemas de calidad y asignación: ver
[investigación de Microsoft sobre SRM](https://www.microsoft.com/en-us/research/publication/diagnosing-sample-ratio-mismatch-in-online-controlled-experiments-a-taxonomy-and-rules-of-thumb-for-practitioners/).

El estado es `eligible_for_human_review` sólo si no hay razones de bloqueo:
aprobado, no detenido, mínimos por brazo, outcomes completos, sin alarma de
asignación, mejora primaria y guardrails satisfechos. Todo lo demás queda como
`inconclusive`, con razones explícitas. **Siempre** `causal_proof: false` y
`auto_promoted: false`. El informe muestra los supuestos no demostrados: independencia,
no interferencia, asignación fiel, outcomes completos y medición estable.

## Revisión, detención y revocación

```ruby
# Puede hacerse durante el experimento, incluso antes de cerrarlo:
experiment.stop(reason: "señal adversa", context: safety_ctx)

# Para un experimento finalizado, no detenido y elegible:
experiment.review_result(approve: true, reason: "supuestos y riesgos revisados", context: human_ctx)
# Para rechazar un resultado, incluso inconcluso: approve: false.
experiment.revoke_result(reason: "defecto de medición descubierto", context: safety_ctx)
```

Stop es permanente y se serializa con ejecuciones: una operación ya en curso
puede terminar antes de que stop adquiera el lock; después de su commit no comienza
otra. Aún se aceptan outcomes antes del sellado para auditar los daños. El informe
de un experimento detenido no permite aprobación positiva.

La revisión final guarda identidad, razón y digest del informe y exige un revisor
distinto del registrante. Es inmutable; una revocación posterior se registra aparte.
No aplica cambios, no crea reglas y no deshace efectos. La app debe comprobar
`final_review.approved` y ausencia de `revocation` al considerar un despliegue,
revalidar dependencias actuales y ejecutar su workflow humano de promoción/rollback.
No hay una transición automática a `Exploration::Governance` o `ExperienceLibrary`,
cuyos contratos experimentales de harness son distintos.

Lecturas autorizadas:

```ruby
experiment.fetch(type: "analysis", context: ctx)
experiment.fetch(type: "final_review", context: ctx)
experiment.fetch(type: "revocation", context: ctx)
experiment.fetch(type: "assignment", unit_id: customer_experiment_id, context: ctx)
```

Otros tipos: registration, approval, stop, exposure, outcome. No hay dashboard
nuevo ni scheduler: los construye Rails con su autorización y sus jobs. El límite
de Journal sigue siendo 16 MiB por payload; dimensionar protocolos/cohortes para
que el informe completo quepa. No fraccionar un experimento después de observar
resultados para elegir el subgrupo favorable.

## Conexión con 1.9

Usar un digest de propuesta 1.9 en `evidence_versions` para dejar trazabilidad de
la hipótesis que originó el experimento. Los receipts de `execute` son receipts
normales 1.8 y pueden alimentar `BusinessLearning#observe` mediante execution_key.
Mantener separados los informes retrospectivos y aleatorizados; no reinterpretar
una cohorte observacional como control ni traducir `eligible_for_human_review` a
una afirmación universal. Si cambian reglas, fuentes o mediciones, detener la
versión activa y registrar otro protocolo; cambiar callbacks sin actualizar sus
versiones no es detectable automáticamente por el framework.
