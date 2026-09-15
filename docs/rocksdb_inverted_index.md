# Índice invertido BM25 sobre RocksDB

Notas de arquitectura sobre cómo `build_search_index` (`src/Indexing.jl`) construye y persiste
los 4 índices BM25 del buscador, y cómo `LazyBM25.jl` los hace consultables sin cargarlos
completos a RAM. No es un tutorial de RocksDB ni de `TextSearch.BM25InvertedFile` — es
específicamente CÓMO y POR QUÉ se conectaron ambas piezas en este proyecto.

## El problema que resuelve

Un `BM25InvertedFile` de `TextSearch.jl` normalmente vive completo en memoria: listas de
postings (qué documentos contienen cada token) y vectores de término por documento. A escala
completa (93 repos, cientos de miles de documentos/perfiles de autor) eso es una cantidad de
RAM que no vale la pena mantener residente todo el tiempo, sobre todo cuando el proceso que
SIRVE búsquedas (TUI/CLI) no necesariamente hace muchas búsquedas por segundo. La solución
adoptada: construir el índice en memoria UNA VEZ (como siempre se ha hecho, código de indexado
sin tocar), después volcar sus dos estructuras pesadas (postings, vectores por documento) a
RocksDB, y en tiempo de consulta reconstruir un `BM25InvertedFile` cuyos campos `adj`/`db` leen
de RocksDB bajo demanda en vez de vivir en un `Vector` en RAM.

## Los 4 índices segregados

`build_search_index` construye 4 `BM25InvertedFile` HOMOGÉNEOS e independientes, cada uno con
su propio vocabulario — nunca se mezclan en un solo índice, para no diluir el vocabulario de uno
con el ruido léxico del otro:

| índice | `idx_id` | contenido | poda de vocabulario |
|---|---|---|---|
| `docs_content` | `DOCS_CONTENT=1` | título/keywords/resumen/conclusiones (ver `extract_index_text`) | `min_ndocs=3` (279,021→108,709 tokens, 61%, 0 docs sin contenido) |
| `docs_refs` | `DOCS_REFS=2` | texto de referencias citadas | `min_ndocs=5` (849,793→148,225, ~83% — cola larga: nombres propios, revistas, DOIs, ruido OCR) |
| `authors_name` | `AUTHORS_NAME=3` | nombre de autor + su forma de iniciales | **sin poda** — es un string normalizado, no texto libre; no hay cola larga que recortar |
| `authors_profile` | `AUTHORS_PROFILE=4` | perfil bilingüe del autor (keywords/tópicos) | `min_ndocs=3` (400,698→165,733, 59%) |

Los umbrales de poda vienen de mediciones reales sobre el subconjunto de 10 repos (documentado
en las constantes `DOCS_REFS_MIN_NDOCS`/`DOCS_CONTENT_MIN_NDOCS`/`AUTHORS_PROFILE_MIN_NDOCS` en
`Indexing.jl`), validados construyendo el `BM25InvertedFile` real y contando cuántos documentos
quedan con `doclens==0` (contenido buscable cero) — no una regla general, una decisión medida
por índice.

`docs_content`/`docs_refs` comparten la MISMA numeración de documento (`doc_keys`, construida en
una sola pasada de recolección); `authors_name`/`authors_profile` comparten la numeración de
autor. Por eso `doc_keys`/`author_keys` se exportan a RocksDB UNA vez cada uno
(`export_dockeys_to_rocksdb!`/`export_authorkeys_to_rocksdb!`), no una vez por índice que los usa.

## Capas de persistencia: 3 piezas separadas, cada una por su costo real

Cada índice se parte en tres piezas con vidas y costos de carga MUY distintos — la separación es
deliberada, no incidental:

1. **Vocabulario** (`VocabIO.save_vocabulary_zip`/`load_vocabulary_zip`) — un `.zip` propio.
2. **"Shell"** (`IndexShellIO.save_index_shell_zip`/`load_index_shell_zip`) — otro `.zip`, con el
   resto de campos pequeños de un `BM25InvertedFile` (parámetros BM25, `doclens::Vector{Int32}`,
   `len`, el `query::QueryPipeline`) serializados como `shell.json` vía `JSON3`, NO vía `JLD2`.
   **Por qué NO JLD2, encontrado en vivo**: aunque el shell es minúsculo (unos cuantos
   escalares + un vector), `JLD2.load` era la PRIMERA llamada en toda la construcción de
   `SearchEngine()` que tocaba maquinaria de deserialización genérica/paramétrica — pagaba
   ~8 segundos de compilación JIT de una sola vez por proceso fresco (medido: 8.44s, 98.66% de
   eso siendo compilación). Cambiar a `JSON3`/`ZipArchives` comparte el costo de compilación con
   el que YA paga `VocabIO` unas líneas antes en la misma función de carga, en vez de sumar una
   ruta de deserialización genérica completamente aparte.
3. **Postings + vectores por documento** — en RocksDB, nunca en un archivo (ver abajo).

## RocksDB: layout de column families y claves

`Database` (`src/DB.jl`) envuelve una instancia RocksDB con column families fijas
(`COLUMN_FAMILIES` en `DB.jl`): `default`, `authors`, `references`, `topics`, `fulltext`,
`stats`, `postings`, `docvecs`, `dockeys`, `authorkeys`, `consolidated_authors`. Las 4 CFs que le
importan a `LazyBM25.jl` son `postings`/`docvecs` (compartidas por los 4 índices, particionadas
por `idx_id`) y `dockeys`/`authorkeys` (compartidas por pares de índices que numeran igual).

**Claves de ancho fijo, binarias, sin round-trip por String** (`LazyBM25.jl`):

```julia
postings_key(idx_id::UInt8, tokenID) = vcat(UInt8[idx_id], reinterpret(UInt8, UInt32[tokenID]))
docvec_key(idx_id::UInt8, docID)     = vcat(UInt8[idx_id], reinterpret(UInt8, UInt32[docID]))
```

Solo se hacen lookups puntuales (`get`) contra estas CFs, nunca *prefix scans* — así que el
orden de bytes dentro de la clave no es semánticamente importante, y se usa el orden nativo
(little-endian en esta plataforma) sin más ceremonia. Si algún día se necesitara escanear por
`idx_id` (todas las postings de UN índice, en orden), esta decisión habría que revisitarla —
hoy no hace falta.

Los valores también son binarios compactos: una posting list es un `Vector{UInt32}`
reinterpretado a bytes crudos (`encode_u32vec`/`decode_u32vec`); un vector disperso de
documento (`SparseVecView`) se serializa a mano como `(n::Int32, nnz::Int32, nzind::Vector{Int32},
nzval::Vector{UInt32})` sobre un `IOBuffer`. Nada de JSON ni de un formato genérico para estas
dos CFs — son el volumen alto, el camino caliente de lectura en cada búsqueda.

## El truco de abstracción: `AbstractAdjList`/`AbstractDatabase` lazy

`RocksDBAdjList <: SimilaritySearch.AbstractAdjList{UInt32}` y
`RocksDBDatabase <: SimilaritySearch.AbstractDatabase` implementan solo lo mínimo que
`BM25InvertedFile`'s código de búsqueda necesita (`neighbors`/`neighbors_length` para el primero,
`getindex`/`length` para el segundo) — cada llamada hace UN `RocksDB.get` bajo demanda, decodifica,
y regresa. Son de solo lectura (`add!`/`push_item!` truenan explícitamente con un mensaje claro:
"constrúyelo en memoria y expórtalo, no lo mutes en el lado lazy").

Esto significa que **el código de scoring/búsqueda de `BM25InvertedFile` no sabe ni le importa**
si `adj`/`db` son `Vector`s en RAM o estas estructuras lazy — `assemble_bm25` simplemente
construye un `BM25InvertedFile` normal pasándole estos objetos en el orden posicional que la
librería espera (`voc, bm25, adj, doclens, db, len, query` — no hay constructor con keywords
para inyectar `adj`/`db` custom, así que se depende del orden posicional exacto).

## Camino de escritura: construir en memoria, exportar una vez

`export_to_rocksdb!(db, idx_id, invfile)` NO reemplaza el proceso de indexado — el
`BM25InvertedFile` se construye exactamente como siempre (`BM25InvertedFile(voc)` +
`append_items!(invfile, ctx, texts)`, en memoria, con el mismo algoritmo de indexado de
`TextSearch.jl` sin ningún cambio) y SOLO DESPUÉS, ya completo, se recorre una vez para volcar
`invfile.adj`/`invfile.db` a las CFs `postings`/`docvecs` vía `RocksDB.batch` (una escritura por
lote, no una transacción por entrada). Esto separa completamente "cómo se calcula el índice" de
"dónde vive después" — cualquier mejora futura al algoritmo de indexado de `TextSearch.jl` sigue
funcionando sin tocar `LazyBM25.jl`.

## Gotchas prácticos de RocksDB encontrados en este proyecto

- **`open_database` migra column families sobre una base de datos EXISTENTE** sin necesidad de
  recrearla: lista las CFs actuales (`list_existing_column_families`, vía el API C de RocksDB
  `rocksdb_list_column_families`), calcula la diferencia contra `COLUMN_FAMILIES`, y si faltan
  CFs nuevas (p. ej. tras agregar una feature que necesita una CF que no existía cuando la base
  de datos se creó por primera vez), las crea en una apertura temporal antes de la apertura real
  — evolución de esquema sin migración manual ni borrar y reconstruir todo.
- **El orden de escritura importa cuando hay lectura-antes-de-escritura.** `add_coauthor_link!`
  lee el contador actual antes de incrementarlo — por eso la ingesta de documentos hace UN
  `RocksDB.write!` POR DOCUMENTO (reusando el mismo `WriteBatch` vía `empty!` para no asignar
  miles de batches), en vez de acumular muchos documentos en un solo batch: si dos documentos
  con el mismo par de coautores cayeran en la MISMA ventana sin confirmar, el conteo se
  subestimaría silenciosamente. Los perfiles de autor (sin este patrón de lectura-antes-de-
  escritura) sí se agrupan en lotes de `AUTHOR_BATCH_SIZE=2000` sin este riesgo.
- **Compactar después de una sesión de escritura masiva, no en cada apertura.** `compact_all!`
  se llama una vez al final de `build_search_index` — sin esto, RocksDB acumula archivos de
  write-ahead-log que una apertura posterior tendría que escanear/re-reproducir, convirtiendo lo
  que debería ser una apertura casi instantánea en una de varios segundos.
- **Las claves posicionales (`dockeys`/`authorkeys`) permiten reemplazar un `Vector` eager por
  un `AbstractVector` lazy sin tocar el código que lo consume** (`LazyDocKeys`/`LazyAuthorKeys`
  implementan solo `size`/`getindex`; `length`/`iterate`/etc. salen gratis de la maquinaria
  genérica de `AbstractArray` de Julia) — el mismo patrón de abstracción que `RocksDBAdjList`/
  `RocksDBDatabase`, aplicado a un tipo de dato distinto.
