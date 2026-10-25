# Verified Knowledge Core — Agentkit 1.7.0

Para persistencia, adaptadores Rails y gates implementados en 1.8, consultar la
[guía Rails Evidence & Decision Gates](RAILS_EVIDENCE_AND_DECISION_GATES.md).
Esta página conserva el contrato del núcleo 1.7.

Esta guía define el contrato de implementación para una aplicación Rails.
El núcleo es Ruby puro, opt-in y no necesita migraciones ni servicios externos.
También puede cargarse con `require "agentkit/knowledge"`.

## Garantía y frontera de confianza

Una consulta `entailed` tiene una derivación a partir de observaciones activas y
reglas suministradas por la aplicación. La aplicación es responsable de que las
observaciones sean correctas, de autenticar al aprobador y de seleccionar reglas
autorizadas. Los campos `source` y `approved_by` son procedencia declarada: el
núcleo no contacta esas fuentes ni autentica esas identidades.

El núcleo verifica tipos, aridad, alcance, tiempo, seguridad de variables y pasos
deductivos. No comprueba causalidad, veracidad del mundo, cumplimiento legal ni
autorización para modificar pedidos. Un digest identifica contenido; no es firma
digital ni prueba de autenticidad. Datos extraídos por LLM requieren validación
de la app antes de convertirse en observaciones.

## Responsabilidades obligatorias

| Capa | Agentkit 1.7.0 proporciona | La aplicación Rails implementa |
|---|---|---|
| Dominio | Contrato `Ontology`, dominios nominales y tipos primitivos | Entidades, significado de cada relación, unidades y reglas de negocio |
| Fuente de verdad | `Assertion` con procedencia y validez temporal | Modelos ActiveRecord, consultas autorizadas, exactitud y completitud de los datos |
| Alcance | Rechazo de hechos cuyo `scope` difiere del snapshot | Construcción del scope desde identidad autenticada, autorización por principal y filtrado por tenant/cuenta |
| Reglas | `Rule`, control de variables y versiones incluidas en digest | Revisión, aprobación real, catálogo autorizado y selección de versión vigente |
| Inferencia | Cierre positivo, límites, consulta y derivación verificable | Elección de preguntas que corresponden al proceso y manejo de incertidumbre |
| Persistencia | Exportación JSON e importación validada | Almacenamiento, acceso, cifrado si aplica, retención y recuperación de snapshots y decisiones |
| Operación | Ninguna acción de negocio automática | Transacciones, locks, idempotencia, permisos, pagos y reembolsos |
| Aprendizaje | Hipótesis identificadas y rechazadas como premisas | Recolección de resultados y revisión; el ciclo de aprendizaje es posterior a 1.7 |
| Agentes | API Ruby invocable por una herramienta propia | ToolContract, schema de salida y verificador configurados explícitamente |

Ni Rails ni Agentkit deben aceptar reglas, `scope`, `approved_by` o hechos
autorizados directamente de una respuesta LLM o de parámetros del navegador.
No existe un bypass por tener `status == "entailed"`.

## Organización sugerida en Rails

```text
app/knowledge/returns_contract.rb          # Ontología y reglas revisadas
app/services/returns/evidence_builder.rb  # Lee datos autorizados y crea snapshot
app/services/returns/eligibility.rb       # Consulta el núcleo y presenta evidencia
app/services/returns/execute_refund.rb    # Transacción y autorización de la acción
app/models/knowledge_snapshot.rb          # Opcional: almacenamiento propio
app/models/business_decision.rb           # Opcional: vincula decisión y evidencia
```

Estos nombres son una recomendación, no clases generadas ni modelos incluidos
en la gem. No se añade una tabla global de hechos ni se escanea la base de datos.

## API ejecutable

Consultar [el ejemplo completo](../examples/knowledge_returns.rb):

```sh
ruby -Ilib examples/knowledge_returns.rb
```

El ejemplo declara `Paid(Order)`, `WithinWindow(Order)` y la regla:

```text
EligibleForReview(order) <- Paid(order), WithinWindow(order)
```

`WithinWindow` es un hecho calculado por la aplicación usando su política y
fechas; el núcleo 1.7 no incorpora comparaciones temporales dentro de reglas.
`EligibleForReview` habilita una revisión bajo esta política de ejemplo. No
significa que se haya autorizado o ejecutado un reembolso.

Los contratos son:

- `Ontology.new(name:, version:, entities: [], relations:)`.
  Las relaciones son hashes con nombres string y listas ordenadas de dominios.
  Primitivos: `string`, `integer`, `boolean`. Entidades nominales como `Order`
  usan identificadores string no vacíos. No se comprueba existencia de una fila
  ActiveRecord ni integridad referencial entre entidades.
- `Assertion.new(id:, scope:, relation:, values:, source:, source_version:,
  observed_at:, valid_from:, valid_until: nil, kind: "observation")`.
  `kind: "hypothesis"` permite representar una propuesta separadamente;
  `Snapshot` rechaza incluirla entre los hechos. La promoción exige una nueva
  observación respaldada por una fuente o una regla revisada, según su significado.
- `Atom.new(relation:, terms:)`: constantes string/integer/boolean y variables
  explícitas `Knowledge.var("order")`. Los símbolos Ruby no son términos.
- `Rule.new(id:, version:, head:, body:, approved_by:, approved_at:)`.
  El cuerpo es una conjunción positiva no vacía. Todas las variables de la cabeza
  deben aparecer en el cuerpo. Una variable no puede cruzar dominios nominales.
- `Snapshot.new(ontology:, scope:, at:, facts:, rules:)`: captura inmutable.
  IDs únicos por colección. Reglas y hechos se ordenan por ID para reproducibilidad.
- `Engine.new(max_iterations: 100, max_steps: 100_000, max_facts: 20_000).run(snapshot)`.
  El motor puede reutilizarse: cada evaluación tiene estado independiente.
- `result.query("EligibleForReview", "order:42")`: consulta exacta, sin comodines.
- `ProofChecker.new.verify(snapshot:, relation:, values:, proof:)`: booleano.

Los timestamps son ISO8601 con zona explícita y se normalizan a UTC/microsegundos.
La validez es `[valid_from, valid_until)`; también se exige `observed_at <= at`.
Los hechos inactivos permanecen en el snapshot para auditoría, pero no participan
en la deducción. Las reglas deben estar aprobadas a más tardar en `at`.
Para evaluar una historia real, Rails debe conservar sus versiones históricas:
no basta con asignar una fecha antigua a filas actuales.

## Semántica de respuestas

| Resultado | Interpretación | Uso en Rails |
|---|---|---|
| `entailed` | Existe una derivación con estos hechos y reglas | Mostrar la conclusión con su alcance; aplicar permisos adicionales antes de actuar |
| `not_entailed` | El cierre terminó sin derivar la tupla | Informar «no se pudo establecer con esta evidencia» |
| `incomplete` | No se encontró y la evaluación alcanzó un límite | Abstenerse, obtener más recursos o escalar a revisión |

Una evaluación incompleta puede contener conclusiones positivas comprobables.
Por ello `status == "entailed"` puede coexistir con `closure_complete == false`.
Un proceso que requiera todas las alternativas debe exigir además cierre completo.
No hay negación por ausencia ni un estado `false` inferido automáticamente.
Una relación con un argumento booleano `false` es una tupla positiva explícita.

No hay funciones generadoras, negación, agregaciones, probabilidades, aprendizaje
de pesos, causas, RDF/OWL, Lean o backend GPU. Hay recursión positiva sobre el
dominio finito aportado por hechos y constantes de las reglas. La declaración de
una relación y sus tipos constituye el contrato; validaciones cruzadas de negocio
que requieran cálculos, unicidad o ausencia corresponden a Rails en esta versión.

## Adaptador de evidencia Rails

El siguiente es un patrón para la app, no una API ActiveRecord de Agentkit:

```ruby
class Returns::EvidenceBuilder
  def initialize(account:, principal:, policy:)
    @account, @principal, @policy = account, principal, policy
  end

  def call(order_id:, at: Time.current)
    order = @account.orders.find(order_id) # nunca Order.find sin scope
    @policy.authorize_read!(@principal, order)
    scope = "account:#{@account.id}"
    timestamp = at.utc.iso8601(6)
    predicates = []
    predicates << "Paid" if order.paid?
    predicates << "WithinWindow" if @policy.within_return_window?(order, at: at)
    facts = predicates.map do |relation|
      Agentkit::Knowledge::Assertion.new(
        id: "order:#{order.id}:#{relation}", scope: scope,
        relation: relation, values: ["order:#{order.id}"],
        source: "orders/#{order.id}",
        source_version: "lock:#{order.lock_version}/policy:#{@policy.version}",
        observed_at: timestamp, valid_from: timestamp
      )
    end
    Agentkit::Knowledge::Snapshot.new(
      ontology: ReturnsContract::ONTOLOGY, scope: scope, at: timestamp,
      facts: facts, rules: ReturnsContract::APPROVED_RULES
    )
  end
end
```

La app define `ReturnsContract`, `policy` y sus métodos. Este ejemplo presupone
optimistic locking (`lock_version`) en su modelo. Si usa varias filas para formar
un snapshot, debe leerlas consistentemente y registrar todas las versiones
relevantes. Una fuente calculada debe identificar tanto los datos como la versión
del cálculo. Si falta un dato, no inventar una observación positiva o negativa.

## Persistencia, revocación y replay

```ruby
json = JSON.generate(snapshot.to_h)
restored = Agentkit::Knowledge::Snapshot.from_json(json)
raise "digest mismatch" unless restored.digest == snapshot.digest
replayed = Agentkit::Knowledge::Engine.new.run(restored)
```

La importación revalida estructura y semántica, pero no autentica al exportador.
La app debe comprobar que el scope del snapshot recuperado corresponde al contexto
autorizado antes de usarlo. No exponer este importador como vía para que el usuario
aporte sus propias reglas aprobadas. Un formato futuro requiere una versión nueva.

Para auditoría, conservar snapshot, digest, límites de evaluación, resultado,
versión de Agentkit y referencia de la decisión. La prueba usa un DAG de hechos y
reglas, con una sola derivación determinista por tupla. El checker valida una
conclusión positiva contra el snapshot confiable; no certifica completitud del
cierre ni actualidad de la evidencia. No importar un booleano `complete` como
prueba: volver a evaluar si se necesita completitud.

Al revocar una fuente, sustituir una regla o corregir un hecho, construir un nuevo
snapshot y volver a evaluar. El resultado histórico permanece inmutable. La app
debe invalidar sus caches por digest y asociar nuevas decisiones al nuevo resultado.
1.7 no hace invalidación incremental ni persiste un índice de dependencias.

Los snapshots contienen identificadores y datos de negocio. Aplicar el mismo
control de acceso y retención que a las fuentes. El núcleo no los envía al LLM,
no genera embeddings y no los escribe automáticamente en Audit o Memory.

## Integración con herramientas y AgentLoop

Una herramienta de lectura puede construir el snapshot y devolver una consulta
estructurada. La app selecciona la relación y los argumentos permitidos; una
relación con nombre inventado produce `InvalidContract`. Mantener las pruebas
completas en almacenamiento autorizado y enviar al modelo sólo lo necesario.

El callback `verifier:` existente recibe `(request, context)`. La app puede parsear
su salida estructurada y consultar el núcleo para cada afirmación que quiera
aceptar. Debe comprobar el scope del snapshot, autorizar la pregunta y vincular la
respuesta a la entidad exacta. El texto libre adicional no queda verificado por
aprobar una tupla. Un schema JSON válido tampoco demuestra la afirmación.

No se instala automáticamente un verificador, un gate de herramientas o una
conexión con Experience Library. El contrato 1.7 permite esas integraciones
explícitas; los adaptadores generales y gates de acciones corresponden a 1.8.

Antes de un reembolso real, Rails debe volver a autorizar al principal, verificar
el estado actual y el importe restante dentro de la transacción, usar locking e
idempotencia, y coordinar el proveedor de pagos. Una deducción anterior no resuelve
condiciones de carrera ni deshace una operación externa.

## Límites operativos y aceptación de la app

Snapshots: 10 000 observaciones, 256 reglas, 16 átomos por cuerpo y 4 MiB de JSON.
Importación JSON: profundidad máxima 32. `max_steps` cuenta intentos de emparejar
tuplas y visitas a reglas; `max_facts` incluye observaciones y deducciones únicas.
`max_iterations` incluye la pasada que confirma estabilidad. Los límites del
motor pueden ajustarse explícitamente y no son un timeout de reloj.
El checker acepta hasta 20 000 nodos y 16 MiB de prueba. Si se eleva el límite del
motor por encima de esa capacidad, una prueba grande puede ser rechazada.

Los joins usan un evaluador de referencia sin índices por variable: para grandes
volúmenes, reducir hechos al caso autorizado y medir antes de ampliar límites.

Antes de conectar una acción real, la app debe tener pruebas para:

1. Aislamiento de tenant y permiso del principal para leer los datos.
2. Hechos faltantes, caducados y provenientes de versiones anteriores.
3. Regla revisada correcta y rechazo de propuestas LLM como premisas.
4. Manejo de `not_entailed` e `incomplete` sin convertirlos en falsedad.
5. Carrera entre evaluación y ejecución, idempotencia y estado del pago.
6. Persistencia y reconstrucción de la evidencia de una decisión.

## Evolución prevista

1.8 incorporará adaptadores de evidencia y gates; 1.9, resultados de negocio y
propuestas evaluadas; 1.10, experimentos controlados. Las abstracciones verificadas
mediante conexiones de Galois y los backends Tensor/Lean se evaluarán después sobre
garantías concretas. Esas capacidades no están implementadas en 1.7.0.
