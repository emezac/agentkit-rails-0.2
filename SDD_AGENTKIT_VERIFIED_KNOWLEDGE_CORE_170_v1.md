# 1.7.0 — Verified Knowledge Core

## Objetivo

Derivar conclusiones reproducibles a partir de observaciones identificables y
reglas explícitas, manteniendo la autoridad de negocio en la aplicación Rails.
Contrato público y distribución de capas: [guía Rails](docs/VERIFIED_KNOWLEDGE_CORE.md).

## Diseño implementado

Namespace opcional `Agentkit::Knowledge`, Ruby puro. `Ontology` define relaciones
con aridad y dominios nominales/primitivos. `Assertion` distingue observaciones
de hipótesis. `Rule` contiene átomos, variables explícitas, versión y procedencia
de aprobación. `Snapshot` valida ámbito, tiempos, tipos y variables, captura
entradas inmutables y las identifica con SHA-256 de JSON canónico.

Semántica: Datalog positivo, finito, sin negación, funciones ni agregaciones.
Evaluación por punto fijo con unión de tuplas. Las reglas consultan las relaciones
actuales, conservan los índices del cuerpo y proyectan sólo después de unificar.
Un test de referencia usa recorridos de grafos independientes para contrastar
el cierre recursivo en grafos generados, incluidos ciclos.

Cada tupla conserva el primer testigo determinista: observación fuente o regla,
sustitución y claves de premisas ya existentes. Esto produce un DAG sin ciclos.
`ProofChecker` verifica un DAG exportado contra entradas confiables sin ejecutar
texto de reglas generado por el consumidor. Comprueba conclusiones positivas;
la completitud requiere ejecutar el motor.

Los límites de pasos, iteraciones y tuplas producen un resultado incompleto.
Los errores de contrato se rechazan antes de ejecutar. Consultas ausentes son
`not_entailed` sólo tras cierre completo; de otro modo son `incomplete`.

## Integración

La app Rails implementa contratos de dominio, evidencia, aprobación real,
persistencia y servicios transaccionales. El módulo no accede a modelos Rails,
no ejecuta LLMs, no registra contenido automáticamente y no instala gates.
AgentLoop/Harness pueden usarlo desde sus callbacks explícitos existentes.
El ejemplo de devoluciones deriva elegibilidad para revisión, no autorización
de pago. No se agregan migraciones ni dependencias de runtime.

## Criterios de aceptación

- Joins, unión multirregla y recursión correctos frente a referencia independiente.
- Constantes, variables repetidas, orden de proyección y booleanos preservados.
- Scope, tipos, aridad, versiones, aprobación temporal e hipótesis validados.
- Resultados y snapshots inmutables; replay JSON conserva digest y derivación.
- Evidencia alterada, dependencias cíclicas y versiones distintas rechazadas.
- Límites visibles y ausencia no confundida con falsedad.
- Guía Rails y ejemplo incluidos en artefacto instalable; suite existente verde.

## Fuera de alcance

No se certifica la verdad empírica de las fuentes ni la causalidad. No hay firmas
de aprobación, aprendizaje, invalidación incremental, integración persistente
automática, negación estratificada, Tensor/GPU, conexiones de Galois ni Lean.
Estos requieren contratos y validaciones específicos en entregas posteriores.
