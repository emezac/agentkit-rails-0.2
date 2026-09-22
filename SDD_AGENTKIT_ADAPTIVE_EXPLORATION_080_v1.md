# SDD AgentKit 0.8.0 — Statistical Evaluation, Pareto and Holdout

## 1. Objetivo

Evitar que una mejora aparente en el replay score se convierta por sí sola en
una recomendación de cambio. 0.8.0 separa búsqueda y confirmación, representa
trade-offs multiobjetivo y cuantifica incertidumbre sobre comparaciones
pareadas. La salida conserva nivel N3 y requiere revisión humana.

## 2. Contrato de evidencia

```text
worlds completos con evaluator digest fijo
  └─ asignación estable
       ├─ training: cobertura → Pareto → selección de un candidato
       └─ holdout: incumbente vs candidato seleccionado
                      ├─ cobertura suficiente
                      ├─ candidato no dominado
                      └─ CI bootstrap > efecto mínimo
                               └─ recommend_review (N3, nunca apply)
```

El holdout no elige entre candidatos. Esto evita aplicar múltiples pruebas al
mismo conjunto de confirmación. Quien genere candidatos fuera de AgentKit debe
mantener igualmente el holdout fuera de ese proceso.

## 3. Asignación holdout

La asignación automática calcula un bucket de cada `World#digest` con un seed
estable. La pertenencia de worlds existentes no cambia cuando llegan nuevos.
El reporte expone:

- estrategia (`stable_hash_v1` o `explicit`);
- conteos de training y holdout;
- digest de cada partición;
- digest de asignación que incluye sólo el digest del seed.

Un holdout explícito debe ser disjunto. Todos los worlds de ambas particiones
deben estar completos y compartir evaluator digest. Cambiar el seed invalida la
comparabilidad histórica del split.

## 4. Frontera de Pareto

Una evaluación domina a otra cuando no es peor, dentro de `pareto_epsilon`, en
todas estas dimensiones y es estrictamente mejor en al menos una:

- `mean_quality`, maximizar;
- `mean_attempts`, minimizar;
- `mean_rounds`, minimizar.

`mean_coverage` no entra como objetivo compensable: permanece como gate. Entre
los puntos no dominados y cubiertos, el replay score escoge un único candidato
para holdout.

## 5. Comparación estadística

`Exploration.compare` alinea incumbente y candidato por `world_id` y calcula la
diferencia de replay score por world. Sobre esas diferencias ejecuta bootstrap
percentil pareado con PRNG y seed digest deterministas.

El reporte contiene tamaño muestral, diferencia media/mediana, error estándar,
intervalo, nivel de confianza, proporción de resamples sobre el efecto mínimo,
método y seed digest. `significant` sólo puede ser verdadero cuando:

- se alcanza `min_holdout_worlds`; y
- el límite inferior del intervalo es mayor que
  `min_score_improvement`.

No se presenta la proporción bootstrap como probabilidad bayesiana ni se
inventa un p-value. El método asume que los worlds son unidades de muestreo
razonables; duplicados, histories correlacionados y evaluator drift siguen
siendo responsabilidades del diseño experimental.

## 6. Decisión de recomendación

`recommend_review` requiere simultáneamente:

- mínimos de training y holdout;
- cobertura de incumbente y candidato en ambas particiones;
- mejora del replay score en training;
- pertenencia del candidato a la frontera de holdout;
- intervalo estadístico por encima del efecto mínimo.

Cualquier fallo devuelve `retain` con un reason estable:
`insufficient_*`, `no_pareto_training_improvement`,
`holdout_pareto_regression` o `statistically_inconclusive`.

## 7. Límites de autoridad

- no hay evaluación de source generado;
- no hay promoción o deployment automático;
- no se cambian evaluator, bounds ni interfaces durante replay;
- el holdout no se usa para elegir candidatos;
- resultados insuficientes no revelan evaluaciones de holdout como diagnóstico;
- los límites de muestras/bootstrap/configuración son server-side.

## 8. Definition of done

- split estable y split explícito disjunto cubiertos por tests;
- Pareto conserva trade-offs y elimina puntos dominados;
- bootstrap pareado es reproducible y falla cerrado con muestras insuficientes;
- una mejora de training que no se confirma en holdout retiene al incumbente;
- `agentkit:doctor` informa readiness por evaluator pool;
- documentación, versión, suite y artefactos de release actualizados.
