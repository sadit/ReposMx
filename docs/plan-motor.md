# Plan: ReposMx sobre SimilaritySearchEngine

Fecha: 2026-10-24. Estado: propuesta, sin implementar.

## Objetivo

ReposMx deja de mantener su propia capa de almacenamiento e índice de texto, y usa
`SimilaritySearchEngine.jl` (el Engine) como dependencia. El código de ReposMx se queda en este
repositorio. Lo que cambia es su diseño: los documentos y los cuatro índices BM25 pasan a
proyectos del Engine. Los autores, la coautoría, las citas y los tópicos se quedan en el RocksDB
de ReposMx.

Al Engine solo se agrega lo que es genérico: filtro y paginación en `ftsearch`.

## Estado actual

| Pieza | Hoy | Después |
|---|---|---|
| SimilaritySearch | 1.4.0, checkout `~/.julia/dev/SimilaritySearch` | 1.6.8, checkout `~/Research/SimilaritySearch.jl` |
| TextSearch | 1.1.2 del registro, compat `~1.1.1` | 1.3.0 |
| Documentos | CF `default`, clave `doc:<repo>:<doc_id>`, JSON | proyecto `docs_content` del Engine, en `meta` |
| Índices BM25 | 4 índices escritos a mano: `LazyBM25.jl`, `VocabIO.jl`, `IndexShellIO.jl`, CFs `postings`, `docvecs`, `dockeys`, `authorkeys`, y 8 zips en `data/index` | 4 proyectos `FullTextEngine` con `BM25InvertedFile` |
| Autores, citas, tópicos, estadísticas | CFs `authors`, `consolidated_authors`, `references`, `topics`, `stats` | sin cambio de formato, en un RocksDB propio de ReposMx |
| Agrupación de autores | `AuthorConsolidation` y `AuthorGrouping`, TOMLs en `data/index/authors_consolidated` | sin cambio |
| Búsqueda por párrafos en un documento | BM25 en memoria con TextSearch | sin cambio |

El índice ocupa 240 MB (`data/index` más las CFs de índice). El corpus cosechado ocupa 506 GB y
no se vuelve a cosechar: todo lo derivado se reconstruye desde `corpus.jsonl`.

## Fase 0: bibliotecas base

Esta fase es independiente de las demás y va primero, en su propio commit.

1. `Project.toml`: `SimilaritySearch = "1.6.8"`, `TextSearch = "1.3"`. TextSearch 1.3.0 exige
   SimilaritySearch 1.5.1 o mayor.
2. `Manifest.toml` (versionado en este repositorio): apuntar SimilaritySearch a
   `~/Research/SimilaritySearch.jl`. `~/.julia/dev/SimilaritySearch` es un segundo clon detenido
   en 1.4.0. Correr `Pkg.resolve()` y `Pkg.update(["SimilaritySearch", "TextSearch"])`.
3. Perfiles. TextSearch 1.3 lee solo los formatos 1.1 y 1.2, y `merge_profiles` rechaza perfiles
   de idiomas distintos. Por eso ya no hay perfil bilingüe. La base es el perfil publicado `es`,
   reajustado al corpus completo con `refit_profile` (`TextModel.refit_corpus_profile`). Del
   corpus, cerca del 80% de los documentos declara español y cerca del 7% inglés (2026-10-24).
   Se borraron `data/repos/profiles` (el perfil bilingüe en caché) y `data/index/profile`.
4. Agrupación de autores (hecho el 2026-10-24, fuera del plan original).
   - `index` usaba `AuthorConsolidation.compute_name_clusters`. En el corpus completo, su primera
     fase junta 254,632 de 446,650 nombres en un solo componente, y su segunda fase no terminó en
     2.5 horas sobre ese componente.
   - Ahora `index` usa el módulo nuevo `AuthorGrouping`: `NameVocabulary`,
     `PrecisionClustering.compute_precision_clusters` e `Imputation.impute_candidates`. Estas
     piezas existían desde 2026-09-09, pero solo las usaban las pruebas.
   - `Corpus.parse_author_names` ahora quita fechas, ids pegados con `:`, `:-`, `%` o `*`, números
     sueltos, títulos académicos (`M. en C.`, `MVZ.`, …), roles en su propio segmento (`sinodal`,
     `sustentante`, …) y `[y otros]`. Los nombres distintos bajaron de 446,650 a 441,628, y los
     que tienen dígitos de 5,610 a 588.
   - `Storage.list_repo_names` ya no cuenta `data/repos/rocksdb` como repositorio.
   - Con la agrupación nueva, el grupo más grande tiene 45 nombres (2026-10-24). Los 441,628
     perfiles crudos quedaron en 232,360 perfiles consolidados. La reconstrucción tardó 2 h 52 min
     y usó 47.9 GB de memoria: 2.2 h en los clusters de precisión y 9.5 min en la imputación.
   - Segunda limpieza de nombres (2026-10-25). `parse_author_names` descarta las URL (antes
     formaban 561 perfiles consolidados), los nombres con palabras de institución (unos 2,800) y
     los segmentos de más de 10 palabras. Divide las listas de personas separadas por comas (unos
     30 segmentos). Repara guiones Unicode, caracteres invisibles, acentos sueltos (`Hern´andez`) y
     paréntesis. `build_authors_index_data` repara las letras perdidas (`Garc?a`, 3,818 nombres)
     con las palabras del resto del corpus.
   - Ids estables (2026-10-25). Los ids crudos dependen del orden de todos los nombres, así que
     cambian entre reconstrucciones. Un grupo con líder nuevo podía recibir el id de otro grupo
     anterior (`martinez_5457`). `build_and_persist` ahora le asigna otro id y escribe los TOML en
     un directorio temporal. Una falla ya no borra los perfiles anteriores.
   - Reglas de imputación (2026-10-26). La imputación no une un apellido solo. Tampoco une dos
     nombres que difieren en el primer apellido, ni nombres que solo coinciden en el segundo nombre
     de pila sin un coautor en común. Un componente que no es clique se corta por esas aristas.
     Sobre los mismos clusters de precisión, las propuestas pasaron de 2,755 a 3,347. Las que
     tienen un apellido solo bajaron de 329 a 0, y las que mezclan iniciales distintas de 386 a 201.
   - Reconstrucción con `consolidate-authors` (2026-10-26): 436,828 perfiles crudos quedaron en
     228,272 consolidados. El grupo más grande tiene 39 nombres. Tardó 2 h 34 min y usó 30.0 GiB
     de memoria: 2.2 h en los clusters de precisión y 9.3 min en la imputación. Quedan 663 grupos
     con un nombre de una sola palabra. Vienen de los clusters de precisión, no de la imputación.
5. Reconstruir con `reposmx build-corpus` y después `reposmx index`.
6. Medir lo que cambia sin ser un error de compilación. En TextSearch 1.2, `refit_profile` decide
   qué tokens conserva con `min_ndocs` (por omisión 1), y `kappa` solo controla los pesos. El
   vocabulario reajustado crece. Registrar el tamaño del vocabulario de cada índice y el tamaño
   en disco, antes y después.
7. Corregir el docstring de `VocabIO.jl:28-30`, que dice que TextSearch está fijo en `=1.1.1`.
   Hecho. Además, `VocabIO` no guardaba los lemas ni las stopwords del `TextConfig`. El índice
   del 2026-10-24 se construyó con lemas y se cargaba sin ellos, así que la consulta "ministros"
   no encontraba el lema "ministro". Ahora el zip guarda `lemmas.json` y `stopwords.json`.

El código de `LazyBM25` compila sin cambios. La firma de los símbolos que usa no cambió entre las
dos versiones, y el orden de campos de `BM25InvertedFile` ya
era el mismo en TextSearch 1.1.

**Conjunto de referencia.** Al terminar esta fase, guardar en
`test/golden/` las respuestas del índice reconstruido a un conjunto fijo de consultas. El conjunto
tiene unas 200 consultas para `query_index` (con y sin filtros, páginas 1 y 2), `search_authors`,
`search_references`, `find_similar_authors_by_profile` y `find_similar_documents_by_references`.
Se guardan las claves `(repo, doc_id)` o `cid` y los puntajes. Este conjunto es la referencia de
las fases 2 y 3.

## Fase 1: filtro y paginación en `ftsearch` (repositorio del Engine)

Hoy `ftsearch(h, text, k; minrecall, policy, stats)` no acepta `filter` ni desplazamiento.
`search` sobre vectores sí acepta `filter` y `candidates`, en una sola pasada.

1. `ftsearch(h, text, k; filter=nothing, offset=0, candidates=..., policy, stats)`, con la misma
   semántica de `filter` que `search`: un predicado sobre el registro de metadatos.
2. Para BM25, la búsqueda ya calcula el puntaje de todos los documentos que aparecen en las
   listas de los términos de la consulta. Ampliar `k` cuesta poco en cómputo. Lo que cuesta es
   leer los metadatos de cada candidato en RocksDB, dos lecturas por elemento. Hay que decidir y
   medir entre dos diseños:
   - ampliar la ventana de candidatos (×4) hasta llenar `offset + k` o agotar las listas, como
     hace ReposMx hoy;
   - una pasada sobre todos los candidatos que puntúan, con la lectura de metadatos acotada por
     `candidates`.
3. El resultado indica si hay más resultados (`has_more`), porque ReposMx pagina con eso.
4. Un parámetro `offset` en el Engine no se puede implementar sin recalcular la consulta. Se
   acepta ese costo, que es el mismo que paga ReposMx hoy.
5. Por la regla del Engine, el cambio no termina hasta que compila el servidor, pasan las dos
   suites y se actualiza la página que lo describe. Decidir si la ruta `ftsearch` del servidor
   expone `filter` en el mismo commit.

**Consultas por tokens.** `top_informative_bow` (`Search.jl:345-352`) consulta con un `BOW` de
los 16 tokens más raros. `ftsearch` solo acepta una cadena. Antes de cambiar el Engine, probar
si unir esos tokens en una cadena y consultar con
`QueryPolicy(correction=:off, expansion=false)` produce el mismo `BOW`. Si no lo produce, agregar
al Engine una forma de consultar con tokens ya normalizados.

## Fase 2: documentos e índices en proyectos del Engine

El objetivo de esta fase es reproducir el comportamiento actual. Las respuestas deben coincidir
con el conjunto de referencia de la fase 0.

### Disposición en disco

```
data/index/engine/docs_content/      proyecto FullTextEngine, BM25InvertedFile
data/index/engine/docs_refs/
data/index/engine/authors_name/
data/index/engine/authors_profile/
data/index/rocksdb/                  RocksDB de ReposMx: authors, consolidated_authors,
                                     references, topics, stats
data/index/authors_consolidated/     sin cambio
```

Cada proyecto del Engine tiene su propio RocksDB. Hoy el RocksDB de ReposMx está en
`data/repos/rocksdb`, y `list_repo_names` (`Storage.jl:24-27`) lo lista como si fuera un
repositorio, igual que `data/repos/profiles`. El cambio de lugar corrige eso.

### Elementos de cada proyecto

| Proyecto | Texto | `doc_id` | `meta` |
|---|---|---|---|
| `docs_content` | `extract_index_text` (título ×3, autores ×2, palabras clave ×2, resumen, conclusiones) | `"<repo>:<doc_id>"` | `repo`, `type` (normalizado), `year` (int64), `keywords`, `title`, `creators`, `contributors`, `date`, `description`, `file`, `has_fulltext`, `reference_count` |
| `docs_refs` | textos de las referencias, unidos | `"<repo>:<doc_id>"` | ninguno: se cruza con `docs_content` por `doc_id` |
| `authors_name` | `"nombre . iniciales"` | `cid` | `repos` |
| `authors_profile` | nombre, palabras clave, tópicos, referencias citadas | `cid` | `repos` |

- En el Engine, `doc_id` no es único: `fetch_items` devuelve todos los elementos que lo tienen.
  Con `"<repo>:<doc_id>"` y `cid` es único por construcción. Un elemento por documento o por
  autor.
- El año se extrae al construir, con la misma expresión regular que usa hoy la consulta
  (`\b(19|20)\d\d\b` sobre `date`). El filtro de años compara enteros.
- Los filtros de tipo y de palabra clave conservan su semántica actual (subcadena sin distinguir
  mayúsculas), escritos como predicados.
- Se declara el esquema de metadatos (`declare_meta_schema!`) para `repo`, `type` y `year`.

### Modelos de texto sin artefactos

Para reproducir el ranking actual, cada proyecto recibe un perfil sin lemas ni expansión,
construido en ReposMx con el constructor público
`TextSearch.TextProfile(VectorModel(IdfWeighting(), TfWeighting(), voc))` y pasado como
`BaseProfile`:

- `docs_content`: el vocabulario del perfil `es` reajustado, con `filter_tokens(ndocs >= 3)`.
- `docs_refs`: `Vocabulary(textconfig, textos)` con `ndocs >= 5`.
- `authors_name`: `Vocabulary(AUTHOR_NAME_CONFIG, textos)`, sin poda.
- `authors_profile`: el `TextConfig` del perfil reajustado, con `ndocs >= 3`.

`FitFromCorpus` no sirve aquí. Siempre ejecuta LSI, expansión y lemas (48.8 s por 3,000
documentos), y por omisión lee solo 1,000 documentos.

### Construcción

- Siempre es una reconstrucción completa, como hoy. Se construye en un directorio nuevo y se
  cambia de nombre al terminar. El índice anterior sigue disponible hasta el cambio.
- El RocksDB de autores, citas y tópicos también se construye desde cero. Esto corrige dos
  defectos actuales: los conteos de `coauth:` crecen en cada reconstrucción, porque se leen
  antes de escribirse y nada se borra, y las claves de documentos eliminados quedan en las
  estadísticas.
- Las estadísticas (`stat:global`, `stat:repo:<repo>`) se calculan durante la construcción,
  desde el corpus. El Engine no tiene una operación para recorrer todos los registros, y no hace
  falta.

### Código que se elimina

`LazyBM25.jl`, `VocabIO.jl`, `IndexShellIO.jl`, las CFs `default` (documentos), `postings`,
`docvecs`, `dockeys` y `authorkeys`, los 8 zips de `data/index`, y las pruebas de ida y vuelta
de `IndexShellIO` y `LazyBM25` (`test/runtests.jl:669-787`). Esas pruebas protegían el orden de
campos de `BM25InvertedFile`. Esa protección ahora es del Engine (`test/runtests.jl` del Engine).

### Código que se reescribe

- `Search.jl`: `SearchEngine` abre los cuatro proyectos con `open_project(read_only=true)` y el
  RocksDB de ReposMx en modo de solo lectura. `query_index`, `search_authors` y
  `search_references` usan `ftsearch` con `filter` y `offset`. El bucle de ampliación de
  candidatos desaparece de ReposMx.
- `QueryPolicy(expansion=false, correction=:off)` en todas las consultas de esta fase.
- `DB.get_document` lee de `docs_content` con `fetch_items`.
- Los resultados identifican el documento por `doc_id` (`"<repo>:<doc_id>"`). `doc_idx` (la
  posición interna del índice) desaparece de la API; el frontend la usa como id del DOM
  (`assets/js/search.js:189-198`).
- `total_hits` hoy es el tamaño de la página, no el total. Decidir si se mantiene así.
- `Project.toml`: dependencia `SimilaritySearchEngine`, y `julia = "1.12"`, que es lo que exige
  el Engine.

### Verificación

1. El conjunto de referencia de la fase 0 da las mismas claves y los mismos puntajes, con una
   tolerancia de punto flotante.
2. La memoria del proceso de búsqueda, medida antes y después. El Engine lee los vectores de
   documentos a memoria; ReposMx hoy los lee de RocksDB al consultarlos. Las listas de
   términos siguen en disco en ambos casos.
3. El tiempo de `reposmx index`, antes y después.
4. Las pruebas que hoy necesitan datos reales (`test/runtests.jl:789-904`) se adaptan. Se agrega
   una prueba que construye los cuatro proyectos desde un corpus pequeño de fixture, sin datos
   reales, porque hoy ninguna prueba ejecuta `build_search_index`.

## Fase 3: lemas, expansión y corrección en `docs_content`

1. `docs_content` recibe el perfil `es` reajustado completo como `BaseProfile`, con sus lemas
   y su red de expansión.
2. Se consulta con la política por omisión del Engine. Se evalúa `edit_correction=true` en
   `create_project`.
3. Se mide contra el conjunto de referencia: coincidencia de los primeros 10 resultados por
   consulta, y revisión manual de las consultas que más cambian.
4. Se decide con esas mediciones. `docs_refs`, `authors_name` y `authors_profile` se quedan sin
   artefactos, salvo que una medición indique otra cosa.

`ftexplain` del Engine reporta las sustituciones de cada consulta. Se puede exponer en la shell
y en la API de ReposMx.

## Defectos actuales que no dependen de la migración

Cada uno va en su propio commit, antes de la fase 2.

- `put_reference!` lee `ref["cited_authors"]` (`DB.jl:491`), pero el corpus escribe `"authors"`
  (`Corpus.jl:323`). Por eso nunca se escribe `cited_auth:`, y la red de autores no tiene aristas
  de citas.
- `populate-db` (`DB.ingest_repository_to_db!`) usa el nombre como clave de `auth_doc:` y
  `coauth:`, y `index` usa el id. Además escribe 1,000 documentos por lote aunque los conteos de
  coautoría se leen antes de escribirse. Propuesta: eliminar `populate-db`, porque `index` hace el
  mismo trabajo.
- En `/api/cli/execute`, `/cited` lee `r["text"]`, que `search_references` no devuelve, y
  `/explain` llama `explain_concept(q; lang="es")`, que no acepta `lang`.
- `docs/rocksdb_inverted_index.md` describe una CF `fulltext` que no existe. Este documento se
  reescribe en la fase 2, porque describe la capa que se elimina.

## Fuera de alcance

- La agrupación de autores (`AuthorConsolidation`, `NameVocabulary`, `PrecisionClustering`,
  `Imputation`) no cambia. No usa RocksDB y compila con las versiones nuevas.
- La búsqueda por párrafos dentro de un documento sigue con un BM25 en memoria de TextSearch.
  Un proyecto del Engine por documento no tiene sentido.
- La cosecha, la descarga y la extracción de texto.
- El servidor HTTP de ReposMx se queda. No se reemplaza por `SimilaritySearchServer`, que no
  tiene autores, citas ni tópicos.

## Decisiones pendientes

1. **Cómo depende ReposMx del Engine.** El Engine no está en el registro General. Opciones:
   registrarlo antes de la fase 2, o depender por ruta (`[sources]` en `Project.toml`). ReposMx
   versiona su `Manifest.toml`, que hoy ya contiene una ruta absoluta.
2. **Diseño del filtro en `ftsearch`**: ampliar la ventana de candidatos, o una pasada acotada
   por `candidates` (fase 1, punto 2).
3. **Si `total_hits` pasa a ser el total de coincidencias.** Para BM25 se conoce sin costo
   adicional, y sin filtro es el número de documentos que puntúan.

## Orden de los commits

1. ReposMx: fase 0 (bibliotecas, perfiles, conjunto de referencia).
2. ReposMx: los defectos independientes, un commit cada uno.
3. Engine: filtro y paginación en `ftsearch`, con el servidor y la documentación.
4. Engine, si hace falta: consulta por tokens.
5. ReposMx: fase 2, en un solo commit, con el conjunto de referencia pasando.
6. ReposMx: fase 3.
