# Verified Abstractions & Optional Backends — 1.11.0

Esta versión añade conexiones de Galois **entre órdenes finitos**, composición de
capas, transformadores comprobados, vistas con pruebas concretas, un backend
tensorial booleano y exportación opcional a Lean 4. No introduce grupos de Galois
de extensiones de cuerpos, entrenamiento de tensores ni una garantía causal.

El motor Ruby sigue siendo el predeterminado y la referencia. Todo es opt-in.
No hay migraciones nuevas; la persistencia opcional usa Journal de migración 024.

## Garantías y fronteras

| Componente | Comprueba | No comprueba |
| --- | --- | --- |
| FiniteOrder | Reflexividad, antisimetría y transitividad sobre todo el dominio declarado | Que el orden modela correctamente el negocio |
| GaloisConnection | `alpha(c) <= a` si y sólo si `c <= gamma(a)`, para todos los pares | Que una categoría abstracta sea un hecho nuevo o causal |
| AbstractTransformer | Monotonía y `alpha(f(c)) <= f_abstract(alpha(c))` para todo c | Que un servicio Ruby implemente la tabla declarada |
| AbstractionView | Cada testigo tiene una prueba válida contra su snapshot concreto | Universalidad de la categoría, ausencia de casos o permiso de actuar |
| Backends::Verified | Pruebas concretas y coincidencia con referencia para cierres completos | Seguridad del código del plugin, mejora de rendimiento o semántica externa |
| LeanExport | Genera una obligación cerrada vinculada al digest de la conexión | Ejecutar Lean o validar por sí solo una prueba externa |

Rails define dominios, significado del orden, clasificaciones, fuentes y reglas;
aprueba sus versiones, autoriza lecturas/escrituras y decide qué se despliega.
Las construcciones matemáticas no sustituyen esos controles. La adjunción es la
base habitual para relacionar semánticas concretas y abstractas; ver
[Cousot y Cousot](https://www.di.ens.fr/~cousot/COUSOTpapers/POPL14.shtml).

## 1. Definir órdenes explícitos

```ruby
k = Agentkit::Knowledge
concrete = k::FiniteOrder.new(name: "EvidenceSets", version: "1",
  elements: %w[none bounded any],
  leq: [%w[none none], %w[bounded bounded], %w[any any],
        %w[none bounded], %w[bounded any], %w[none any]])
abstract = k::FiniteOrder.new(name: "SummarySets", version: "1",
  elements: %w[bounded any],
  leq: [%w[bounded bounded], %w[any any], %w[bounded any]])
connection = k::GaloisConnection.new(name: "EvidenceSummary", version: "1",
  concrete: concrete, abstract: abstract,
  alpha: { none: "bounded", bounded: "bounded", any: "any" },
  gamma: { bounded: "bounded", any: "any" })
```

Cada dominio tiene 1–64 elementos únicos, strings no vacíos. `leq` debe incluir
**todos** los pares reflexivos y transitivos; el constructor rechaza errores,
no los corrige silenciosamente. No se interpreta orden alfabético, numérico o
lexicográfico. En el ejemplo, el orden representa inclusión de conjuntos de
posibilidades; `any` es menos preciso, no significa «riesgo alto» ni «verdad».

`alpha` y `gamma` son tablas totales. La comprobación es exhaustiva, no muestreo
ni una puntuación LLM. Un fallo lanza `Knowledge::InvalidContract`. La conexión
conserva las tablas y `checked_pairs`. Sus métodos son:

```ruby
connection.abstract_element("none") # "bounded"
connection.concretize("bounded")   # "bounded"
restored = k::GaloisConnection.from_json(JSON.generate(connection.to_h))
```

La importación limita el documento a 1 MiB, exige campos exactos y vuelve a
comprobar órdenes, mapas y adjunción. No confía en etiquetas de verificación.
El digest cambia al cambiar nombre, versión, dominios o mapas.

## 2. Componer una torre y comprobar transformadores

Si `first.abstract.digest == second.concrete.digest`:

```ruby
tower = first.compose(second, name: "EvidenceTower", version: "1")
# alpha = second.alpha ∘ first.alpha
# gamma = first.gamma ∘ second.gamma
```

El resultado se vuelve a verificar exhaustivamente. No se unen dominios que
casualmente tengan las mismas etiquetas pero distinta versión o definición.

```ruby
transformer = k::AbstractTransformer.new(connection: connection,
  concrete_map: { none: "bounded", bounded: "any", any: "any" },
  abstract_map: { bounded: "any", any: "any" })
```

Las tablas deben ser totales, endomorfismos de sus dominios y monótonas. Además
se verifica la desigualdad de corrección para **cada** elemento concreto. Esto
permite comprobar una abstracción conservadora de una transición declarada.
No ejecuta ni verifica el código Rails de esa transición. La app debe demostrar
mediante contratos/pruebas que su implementación coincide con la tabla y revisar
las nuevas versiones. Ni conexión ni transformador generan `Knowledge::Rule`.

## 3. Vistas con evidencia concreta

```ruby
result = k::Engine.new.run(snapshot)
view = k::AbstractionView.new(connection: connection, snapshot: snapshot,
  result: result,
  claims: { bounded: { relation: "Eligible", values: ["order:42"] } })
summary = view.query("any")
```

La relación y los valores deben existir en la ontología del snapshot. Cada
elemento concreto puede apuntar a una afirmación. Para un hecho derivado se
comprueba su DAG con `ProofChecker`; luego se vincula a `alpha(elemento)` y a
las abstracciones superiores según el orden. El resultado incluye los testigos
concretos y las pruebas originales, digests de snapshot/conexión/resultado y
`authorizes: false`.

Estados: `witnessed_abstraction` significa que hay **al menos un testigo**, no
que todos los miembros de una categoría cumplan una propiedad. Sin testigo:
`unproven`, nunca falso. Una afirmación ausente sigue siendo no probada incluso
si el resultado recibido declara completitud. Esta vista no puede sustituir las
afirmaciones concretas requeridas por DecisionGate. El vínculo entre categoría
y afirmación es semántica declarada por Rails, no aprendido automáticamente.

Máximos: 64 claims por dominio, 100.000 nodos de prueba visitados acumulados y
16 MiB de payload de vista. Reducir el snapshot/cohorte antes de ampliarlo.

### Persistencia y aislamiento

```ruby
journal.save_snapshot(snapshot, context: ctx)
journal.save_abstraction(connection, context: ctx)
journal.save_abstraction_view(view, context: ctx)
reloaded = journal.load_abstraction(connection.digest, context: ctx)
stored_view = journal.read(kind: "abstraction", key: "view:#{view.digest}", context: ctx)
```

Autorizar explícitamente el nuevo kind `abstraction` en el callback de Journal.
Conexión y snapshot deben estar guardados en el mismo tenant/account para guardar
la vista. La conexión se revalida al cargar; el journal comprueba integridad de
payload. Para reconstruir una vista, cargar su snapshot y conexión y volver a
crear `AbstractionView` con sus claims y el resultado del motor. Los hashes no
son firmas contra un administrador que controle toda la base.

## 4. Backend tensorial booleano opcional

```ruby
tensor = k::Backends::BooleanTensor.new(
  max_domain: 128, max_cells: 1_000_000,
  max_iterations: 100, max_steps: 100_000, max_facts: 20_000)
verified = k::Backends::Verified.new(backend: tensor,
  name: "boolean_paths", version: "1", fallback: "raise",
  max_proof_nodes: 100_000,
  max_iterations: 100, max_steps: 100_000, max_facts: 20_000)
result = verified.run(snapshot)
```

Es una implementación Ruby con matrices booleanas de rango 2: unión OR y
composición AND/OR. No instala dependencias, no usa GPU, temperatura ni floats.
Se preservan múltiples reglas para la misma relación mediante unión y se hace
join por la variable compartida **antes** de proyectar.

Gramática admitida, con variables distintas x/y/z:

```text
R(x,y) <- P(x,y)
R(x,z) <- P(x,y), Q(y,z)
```

Todas las relaciones deben ser binarias sobre un único dominio compartido,
incluidas las que no tienen reglas. No admite constantes en reglas, permutaciones,
predicados unarios, negación, aridades mayores ni joins generales. Esos casos
siguen soportados por Ruby cuando corresponden al lenguaje Datalog del núcleo.
Se rechazan dominios/celdas fuera de límites antes de asignar las matrices.
Los límites de evaluación producen resultados parciales: una prueba positiva
puede seguir siendo válida, pero la ausencia queda `incomplete`.

Este backend es independiente del prototipo legado `tensor_logic`: no importa
ni modifica esa biblioteca y no depende de sus resultados numéricos o convergencia.

### Qué verifica el wrapper

`Backends::Verified` exige un `Knowledge::Result` ligado al snapshot solicitado,
comprueba **cada** DAG y, si el adapter declara cierre completo, vuelve a ejecutar
el motor Ruby para comparar el conjunto exacto de tuplas. Si la referencia no
completa dentro de su presupuesto, no certifica completitud del candidato.

Los límites de referencia y de candidato son independientes. La salida de un
adapter externo tiene máximo 20.000 nodos y 16 MiB; el presupuesto acumulado de
verificación de pruebas es configurable entre 1 y 1.000.000. No hay aceleración
garantizada: comprobar completitud implica ejecutar también la referencia. Es
una frontera de corrección y compatibilidad, no un benchmark de rendimiento.

`fallback: "raise"` es el valor predeterminado: errores, falta de soporte o
pruebas inválidas generan `Backends::Failure`. Con `fallback: "ruby"`, se usa
la referencia y se registra `execution: "ruby_fallback"` y `failure_class`,
sin incluir posibles secretos del mensaje de error. Un fallback acotado puede
seguir incompleto; nunca fuerza una autorización.

### Integración con DecisionGate

```ruby
gate = k::DecisionGate.new(name: "returns", version: "2",
  source: source, journal: journal, queries: required_claims,
  authorize: authorized_decision, backend: verified)
```

El gate sólo admite `Backends::Verified`, no un adapter crudo. Al usarlo, poner
los límites en el wrapper/candidato, no simultáneamente en `DecisionGate#limits`.
Su descriptor —incluidos versiones, fallback y límites— forma parte del digest
del gate y el veredicto persiste la procedencia de ejecución. Cambiar esa política
invalida aprobaciones vinculadas al gate y exige nuevas versiones de protocolos
de negocio que fijaban su digest. No desactivar estos checks para conservar
propuestas anteriores. Gates sin backend mantienen su comportamiento y digest.

### Adapters propios, incluido un servicio Tensor/Lean externo

Un adapter host debe implementar `run(snapshot) -> Knowledge::Result`. Puede
exponer `descriptor` con datos JSON de su versión/configuración; además son
obligatorios name/version en `Verified`. Declarar cambios reales de implementación
en esa versión es responsabilidad Rails: el framework no calcula un hash del código.

Los outputs requieren DAGs con assertion/rule digests, bindings y premisas del
snapshot; un score, «verified: true» o certificado externo opaco no es suficiente.
Una prueba en otro formalismo requiere una traducción verificable al contrato
local; no se acepta por el nombre del proveedor. Los adapters ejecutan código
de confianza del host: el wrapper **no es un sandbox**. Rails controla timeouts,
memoria, red, secretos y autorización para enviar datos fuera. No cargar código,
shell commands o imports sugeridos por un LLM. No hay plugins externos activados
ni descargas automáticas.

## 5. Exportación opcional a Lean 4

```ruby
artifact = k::LeanExport.new(connection: connection)
artifact.data.fetch("source")        # fuente Lean cerrada
artifact.data.fetch("source_digest") # SHA256 de esa fuente exacta
```

Se limita a 16 elementos por dominio. La fuente usa `Fin`, tablas booleanas,
`by decide` y `#print axioms adjunction`, con único import fijo `Std`. Los nombres
y etiquetas de usuario se convierten a índices; no se interpolan como código.
No usa `sorry`, `native_decide`, axiomas añadidos ni tácticas externas.

La obligación exportada demuestra **sólo la adjunción de las tablas concretas**,
no la lógica de la app, los transformadores ni una interpretación jurídica o
causal. El orden ya fue validado exhaustivamente por Ruby. `connection_digest`
vincula el artefacto a la conexión y `source_digest` a su fuente. El estado sigue
siendo `exported_not_lean_checked`: exportar no equivale a ejecutar/verificar.

La app puede escribir esa fuente en un archivo controlado y ejecutar su toolchain
Lean fijado en un sandbox, sin usar proyectos/imports aportados por el modelo.
Debe conservar versión del toolchain, fuente exacta, digest, salida y axiomas;
no confiar sólo en un mensaje de éxito. La propia documentación de Lean distingue
la aceptación del kernel y las dependencias/axiomas del teorema:
[Validating a Lean Proof](https://lean-lang.org/doc/reference/latest/ValidatingProofs/).

El repositorio incluye una prueba opt-in que compila el artefacto con un binario
Lean instalado explícitamente:

```sh
AGENTKIT_LEAN_BIN=/ruta/absoluta/lean bundle exec rspec spec/lib/verified_abstractions_spec.rb
```

La suite sin esa variable no requiere Lean ni intenta instalarlo. La prueba usa
un directorio temporal y un límite de 30 segundos; la política de sandbox de
producción pertenece a Rails. No hay un resultado externo de Lean que autorice
acciones automáticamente.

## Integración recomendada para la app

1. Mantener los hechos y reglas concretos de 1.7–1.8 como autoridad del gate.
2. Versionar/revisar órdenes, alpha/gamma y la asociación de categorías a claims.
3. Usar vistas para explicación, búsqueda y propuestas de aprendizaje 1.9.
4. Contrastar intervenciones con los experimentos controlados de 1.10, sin
   confundir una prueba algebraica con evidencia causal.
5. Activar adapters sólo tras pruebas de equivalencia y límites con datos del dominio.
6. Cambiar versiones y reevaluar cuando cambien fuentes, reglas, mapas o backend.

No hay auto-clasificación de clientes, migración de reglas, promoción de hipótesis,
dashboard nuevo ni modificación automática del comportamiento de negocio.
