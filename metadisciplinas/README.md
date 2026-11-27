# Meta-disciplinas oficiales

La corrida del 2026-11-26 (19:39) de `experiments/rag_web/metadisciplinas.jl`, fijada como la oficial por el
usuario. Las claves `M001`… y los nombres son de esta corrida: no cambian aunque el experimento se vuelva a correr
(eso escribe en `data/index/dense/metadisciplinas-corrida/`). Detalle del método en `docs/plan-rag-web.md`,
decisión 15.

| Archivo | Qué es |
|---|---|
| `oficial.json` | los 113 grupos: `clave`, `nombre` y `nombre_en` y `descripcion` (de `qwen3.8-flash`), `palabras` (las más cercanas al centro), `documentos`; además `k` = 120, `margen` = 0.01 y `orden_centros` |
| `centros.f32` | los centros, `Float32` de 1,024 × 113, por columnas en el orden de `orden_centros` |
| `grafo.json` | el grafo del mapa: `nodos` y `enlaces` (3 vecinos por centro y 3 pares con más documentos compartidos por nodo) |
| `vocabulario.json` | las 18,400 palabras clave limpias de las que salieron los grupos |

La asignación de cada documento (`data/index/dense/metadisciplinas_documentos.jsonl`, fuera de git por su tamaño)
sale de los centros: el más cercano a la ficha del documento y, si está a menos de `margen` de similitud, también el
segundo. `experiments/rag_web/asigna_metadisciplinas.jl` la recalcula (documentos nuevos, otra codificación); luego
`Dense.build_dense_project` construye el seguidor `metadisciplina`. Copia en Drive: `gdrive:DATA/ReposMx/metadisciplinas`.
