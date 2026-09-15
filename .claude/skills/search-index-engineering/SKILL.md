---
name: search-index-engineering
description: Guía de diseño y decisiones para construir motores de búsqueda por índice invertido en Julia con SimilaritySearch.jl y TextSearch.jl — perfiles de texto (TextProfile/fit_profile) y pipeline de consulta, qué mantener en RAM vs. cargar perezoso, poda de vocabulario, formatos de serialización, patrones de integración con RocksDB (incluido el canal de observadores :add! para persistencia incremental), el idioma de paralelización @BATCHES (secciones, schedulers, estado por lote), BK-trees (BKT) sobre distancias de edición, resolución de identidad/clustering difuso de entidades (TFIDF + bichromatic_metricjoin) con su techo de escala, y esquemas de ID cortos con resolución de colisiones. Destilado de optimizar el backend BM25 y el dedupe de autores de ReposMx (recuperación de información académica) y de la arquitectura de SimilaritySearchEngine.jl. Úsala para diseñar o depurar cualquier motor de búsqueda o pipeline de deduplicación de entidades basado en estas librerías, no solo este repo.
---

# Ingeniería de índices invertidos y vocabularios

Esta guía viene de una sesión real optimizando el backend de búsqueda de ReposMx (BM25 sobre
SimilaritySearch.jl/TextSearch.jl, ~450k documentos, ~300k autores, ~4M referencias
bibliográficas), actualizada después contra el estado actual de las librerías base y contra la
arquitectura de `SimilaritySearchEngine.jl`. Cada afirmación con números viene de medir con datos
reales, no de teoría. Está pensada para reusarse al diseñar o ajustar **cualquier** motor de
búsqueda sobre estas librerías, no solo ReposMx.

## Estado verificado

Verificado el **2026-09-09** (segunda pasada, ya de tarde) contra los checkouts de desarrollo
en `~/Research/`:

| paquete | versión | HEAD verificado | dónde |
|---|---|---|---|
| `SimilaritySearch.jl` | **1.4.1** | `29b0fc3` (rename `bktree.jl`→`bkt.jl`) | `~/Research/SimilaritySearch.jl` |
| `TextSearch.jl` | **1.1.2** | `e565968` | `~/Research/TextSearch.jl` |
| `SimilaritySearchEngine.jl` | 0.1.0 | `77eff34` | `~/Research/SimilaritySearchEngine.jl` |

`TextSearch` 1.1.2 subió su `[compat]` de `SimilaritySearch = "1.2"` a `"1.4"`: es el primer
release que exige de verdad la línea 1.4, así que cualquier consumidor con un `Manifest.toml`
viejo tiene que re-resolver.

Ambas librerías base se consumen como `dev` (rutas relativas en el `Manifest.toml`), no desde el
registro: cualquier cambio en ellas llega inmediatamente a los proyectos que las usan, sin bump de
versión de por medio. Con una excepción que muerde: **`Manifest.toml` sí congela la versión**, aun
apuntando al mismo `path`. `SimilaritySearchEngine.jl` estuvo resolviendo a `SimilaritySearch`
1.2.0 / `TextSearch` 1.1.1 mientras los checkouts locales ya iban en 1.4.1 / 1.1.2, con un
`[compat]` que permitía ambas — el código nuevo simplemente no se estaba ejecutando. Correr
`Pkg.resolve()` en cada entorno que consume por `path` (subproyectos de app incluidos) es parte
del ciclo, no un paso opcional; y cuando la librería base gana una dependencia (`MultivariateStats`
aquí), la re-resolución es obligatoria o el entorno deja de precompilar.

Una vez resuelto al checkout real, la otra cara: como no hay bump de versión que avise, cualquier
dependencia sobre detalles internos (constructores posicionales, funciones no exportadas) rompe
**en silencio y de inmediato** — ver §7 y §8, donde esto ya pasó una vez.

Proyectos que consumen esto y de dónde salen los hallazgos:

- **ReposMx** (`~/Projects/Repositorios-Institucionales`): recuperación de información académica
  sobre repositorios institucionales mexicanos — documentos, autores, referencias citadas. Dos
  documentos propios alimentan esta guía: `docs/rocksdb_inverted_index.md` (la arquitectura
  resumida en §10) y `experiments/author_matching/textsearch_similaritysearch_notes.md` (notas de
  uso de ambas librerías acumuladas al rediseñar la consolidación de autores — de ahí salen §7.5,
  §7.6, §8.6 y buena parte de §9).
- **`SimilaritySearchEngine.jl`**: la versión empaquetada y generalizada de esa arquitectura —
  ver §11 antes de reimplementarla.

---

## 1. La pregunta correcta: ¿cuántas veces se toca esto por consulta?

Antes de decidir si algo va en RAM (eager) o se carga perezoso (RocksDB u otro almacén de
punto-de-acceso), la pregunta no es "¿qué tan grande es?" — es **¿cuántas veces se consulta por
cada búsqueda del usuario?**

- **Un puñado de veces por consulta** (2-10, del orden de los términos de la query o los
  candidatos sobrevivientes) → candidato perfecto para vivir en un almacén de punto-de-acceso
  (RocksDB, o cualquier KV store), cargado perezosamente `get`-por-`get`. Ejemplos reales:
  - Listas de posteo por término (`adj[tokenID]`).
  - Vector de frecuencias por documento (`db[docID]`), usado solo para los candidatos que
    sobrevivieron el merge, no para todo el corpus.
  - El mapeo posición-interna → identidad externa (`doc_keys[i]`, `author_keys[i]`) — esto se
    pasó por alto la primera vez: es tan "perezoso-able" como las listas de posteo, con el mismo
    patrón exacto (una clase nueva `AbstractVector` con `size`+`getindex` respaldados por
    `RocksDB.get`, y todo lo demás —`length`, `isempty`, iteración— sale gratis de
    `AbstractArray`).
- **Se necesita de forma agregada/global en cada consulta, sin importar cuántos términos tenga
  la query** → tiene que quedarse en RAM. Ejemplo: la tabla de IDF/frecuencia de documento
  (`voc.occs`) y los parámetros globales de BM25 (`avgdoclen`, `k1`, `b`) — aunque son "por
  token", tokenizar la query ya los necesita todos potencialmente, y son baratos (no escalan con
  el tamaño del corpus, solo con el vocabulario).
- **Se escanea el corpus completo, pero rara vez** (paneles de estadísticas, agregados globales)
  → ni "eager en cada arranque" ni "perezoso en cada consulta": **precalcúlalo una vez en tiempo
  de construcción del índice y persístelo** (ver §5). No es ni RAM ni lazy — es un tercer
  régimen.

Antes de tocar código, clasifica cada pieza de estado del índice en una de estas tres categorías.
La mayoría de los errores de diseño vienen de meter algo en la categoría equivocada (ej.: cargar
listas de posteo completas en RAM porque "es lo que siempre se ha hecho", o recalcular un
agregado global en cada request porque nadie se preguntó si podía precalcularse).

## 2. Mide con datos reales antes de elegir formato de serialización

Un formato de serialización genérico de grafo de objetos (JLD2 en Julia; pickle en Python;
equivalentes en otros lenguajes) **no es gratis**, y su costo relativo a un formato hecho a mano
varía muchísimo según la forma de los datos:

- Sobre un `Vocabulary` con un `Dict{String,Int}` de 2.36M entradas: JLD2 genérico costó
  **435MB / ~8s**. Guardar los tokens como `Vector{String}` plano + reconstruir el `Dict` con un
  `enumerate` al cargar costó **38MB / ~2s** — un archivo **~11x** más chico y **~4x** más rápido
  de cargar, con el mismo contenido exacto (verificado campo por campo).
- La causa no es "JLD2 es lento" en abstracto — es que reconstruir un `Dict` de millones de
  entradas desde su representación de tabla hash serializada es inherentemente más caro que
  reconstruirlo desde una lista plana con un solo paso de inserción.

**Regla práctica**: si una estructura tiene un `Dict`/tabla-hash grande como campo interno, no
asumas que el serializador genérico del lenguaje la maneja bien — mide. Si una librería madura ya
tiene su propio formato hecho a mano para ese tipo exacto (ver §8.2, `TextSearch.save_profile`),
**reusa ese formato en vez de reinventarlo** — ya está probado contra los casos raros (regex,
Unicode, etc.).

## 3. RocksDB (o cualquier LSM-tree): el costo de abrir escala con datos sin compactar

Hallazgo real y no obvio: después de mover listas de posteo a RocksDB, el tiempo de carga
**empeoró** en vez de mejorar. La causa no fue el diseño — fueron **36 archivos de WAL sin
aplanar** (hasta 218MB cada uno) acumulados de reconstrucciones repetidas del índice sin
compactar, inflando el directorio de 1.2GB a 3.2GB. `open_database` pasó de 0.03s a 6.5s solo por
eso. Después de una compactación manual (`RocksDB.compact!` sobre cada column family), volvió a
0.03s.

**Regla práctica**: cualquier sesión de escritura masiva a RocksDB (reconstrucción de índice,
ingesta en bloque) debe terminar con una compactación explícita antes de cerrar la conexión de
escritura. No confíes en que RocksDB lo haga solo al reabrir — el costo de abrir escala con el
WAL no compactado, no con los datos "reales" en SST.

## 4. Poda de vocabulario por frecuencia mínima de documento (`min_ndocs`)

Para corpus con cola larga (texto de citas bibliográficas, texto con ruido de OCR, nombres
propios/URLs/DOIs) una fracción enorme del vocabulario son tokens que aparecen en un solo
documento (hapax legomena). Podarlos casi no cuesta calidad de búsqueda:

- Vocabulario de referencias bibliográficas real: 849,793 tokens sin podar → **148,225 con
  `min_ndocs=5`** (-83%). Validado con el pipeline completo (`BM25InvertedFile` +
  `append_items!` reales, no solo el vocabulario): de ~5,300 documentos que sí tenían texto de
  referencias, la poda dejó sin contenido buscable a **4 documentos más** de los que ya estaban
  vacíos desde el inicio.
- El mismo patrón se repitió en el índice de contenido de documentos y en el de perfiles de
  autor, con `min_ndocs=3`: 0/60,470 y 3/47,444 documentos perdieron todo su contenido,
  respectivamente.

**Regla práctica**: no decidas el umbral solo mirando cuánto se reduce el `vocsize` — eso es
necesario pero no suficiente. **Construye el índice real con la poda aplicada y cuenta cuántos
documentos terminan con longitud cero** (`doclens[i] == 0`) que no la tuvieran ya sin podar. Si
ese número es una fracción minúscula del total, el umbral es seguro. Sube el umbral hasta que deje
de serlo.

**Regla práctica 2**: no todos los índices del mismo sistema necesitan el mismo umbral, ni
siquiera necesitan poda. El vocabulario de nombres de autor es corto y muy repetido — puede que ya
sea naturalmente pequeño y podar ahí no valga la pena. Mide cada índice por separado — ver
§10.1 para una tabla real de cuatro índices del mismo sistema con umbrales distintos, uno de
ellos sin poda.

**Nota de versión**: `min_ndocs` ya es una keyword de primera clase de `fit_profile` (§8.1). La
receta manual de abajo sigue siendo la correcta cuando solo quieres un vocabulario podado; si
además vas a fitear stopwords, lemas o expansión, deja que la librería ordene las etapas.

## 5. Precalcula y persiste agregados costosos de "todo el corpus"

Si algo necesita escanear el corpus completo (estadísticas globales, paneles de administración)
pero se lee mucho más de lo que cambia, no lo calcules en la primera consulta de cada proceso —
calcúlalo **una vez en tiempo de construcción del índice** y guárdalo en el mismo almacén de
punto-de-acceso que ya usas para todo lo demás (una tabla/CF de "stats" con `put`/`get` por
clave). Si el esquema ya tiene una tabla pensada para esto y nadie la está usando, esa es la señal
de que este paso se saltó por accidente, no que no hacía falta.

Ejemplo real: una función de estadísticas globales tardaba 43-48s la primera vez que se pedía
(escaneo completo de ~450k documentos), cacheada solo en memoria del proceso (se repetía en cada
reinicio del servidor). Precalcularla una vez y guardarla la dejó en milisegundos, siempre —
reusando una tabla de "stats" que ya existía en el esquema pero nunca se poblaba.

## 6. Otros hallazgos puntuales, todos con costo real si se ignoran

- **Contexto de consulta mutable no es seguro entre requests concurrentes.** Si el motor de
  búsqueda expone un objeto de "contexto"/scratch por consulta (buffers reusables para el
  merge/heap de resultados), **nunca lo compartas entre requests** en un servidor con
  concurrencia real (async o multi-hilo) — constrúyelo nuevo por consulta. Es barato (unos pocos
  vectores pequeños), y compartirlo puede corromper resultados de forma intermitente y difícil de
  reproducir. El patrón con nombre para esto es un **pool de contextos** (`ContextPool` +
  `checkout!`/`checkin!` en `SimilaritySearchEngine.jl`): un contexto por consulta en vuelo,
  reciclado en vez de reasignado, y **separado del contexto que usa la inserción** — ver §11.
- **Post-filtros pueden hambrear una ventana de candidatos de tamaño fijo.** Si filtras
  resultados de un top-k después de la búsqueda (por repositorio, tipo, fecha, etc.), un `k` fijo
  puede devolver silenciosamente menos resultados de los pedidos aunque existan más. Ensancha la
  ventana de candidatos geométricamente (`k *= 4` hasta un tope) cuando el filtrado deja menos de
  lo pedido, en vez de asumir que `top * constante` siempre alcanza.
- **Claves de String vs. bytes de ancho fijo.** Cortar un `String` con `k[length(prefix)+1:end]`
  es un bug real si `prefix` puede contener caracteres multi-byte UTF-8 (tildes, ñ) —
  `length` cuenta caracteres, la indexación de `String` en Julia usa bytes. Usa `ncodeunits`, o
  mejor: para cualquier clave usada en un punto de acceso caliente, usa bytes de ancho fijo
  (enteros en binario) en vez de concatenación de strings — evita la clase de bug entera.
- **`WriteBatch` y vistas perezosas no se llevan bien.** Pasar una vista perezosa (`reinterpret`,
  `view`, etc., sin materializar) directo a un `put!` de un batch de escritura puede corromper
  silenciosamente el valor escrito, porque el batch puede no copiar el buffer de inmediato. Siempre
  materializa a un `Vector{UInt8}` concreto antes de pasarlo a un batch (un `put!` fuera de un
  batch, de una sola escritura, sí suele copiar de inmediato — el bug es específico de batches).
- **Verifica identidad de resultados entre dos construcciones independientes del motor**, no solo
  que "compila" o que "no tira error". Construir el motor de búsqueda dos veces seguidas
  (simulando un reinicio de proceso) y comparar que una misma consulta da exactamente los mismos
  resultados (ids, orden, scores) es la prueba de correctness real para cualquier cambio de
  formato de persistencia — sobre todo cuando se depende de construir un tipo con su constructor
  posicional por defecto en vez de uno con keywords (ver §7).

## 7. Sección SimilaritySearch.jl (v1.4.1)

### 7.1 Backends intercambiables: el punto de extensión sigue ahí

- **`InvertedFile`/`BM25InvertedFile` están parametrizados sobre dos interfaces pequeñas e
  intercambiables**: `adj::AbstractAdjList{T}` (listas de posteo) y `db::AbstractDatabase`
  (vector por documento). Este es el punto de extensión real para respaldar un backend perezoso
  propio (RocksDB, lo que sea) sin tocar ni forkear el paquete — solo hace falta implementar:
  - `AbstractAdjList{T}`: `neighbors(adj, i)`, `neighbors_length(adj, i)`, `eachindex(adj)`,
    `add!(adj, i, ids)`. Para un backend de solo-lectura, `add!` puede lanzar error — la
    construcción del índice se sigue haciendo con la implementación en memoria de la librería
    (`AdjList`), y el backend perezoso solo se usa para **leer** después de exportar.
  - `AbstractDatabase`: `getindex(db, i)`, `length(db)`, `push_item!(db, v)`. Mismo patrón.
  - Implementaciones en memoria: `AdjList` (crecible), `AdjDict` (ids dispersos/no contiguos),
    `StaticAdjList` (CSR congelado, solo-lectura rápida); y del lado de `db`, `MatrixDatabase`,
    `BlockMatrixDatabase`, `VectorDatabase`, `SubDatabase` y `MMapMatrixDatabase`
    (memory-mapped). Ese último confirma que el patrón "backend fuera de RAM" es intencional en
    el diseño, no un hack.
- **El propio algoritmo de búsqueda llama a `neighbors`/`getindex` de a uno por término/
  candidato**, no en bloque — antes de asumir que hay que reescribir la búsqueda para soportar un
  backend perezoso, verifica el patrón de acceso real en `search`/`select_posting_lists`/
  `onmatch!`. Casi seguro ya está pidiendo las cosas de la forma correcta.
- **Inyectar `adj`/`db` propios**: `InvertedFile(vocsize, dist; db=...)` y
  `DictInvertedFile(...; db=...)` sí exponen `db` como keyword (pero no `adj`).
  `BM25InvertedFile` **no expone ninguno de los dos** — su constructor público siempre arma un
  `AdjList`/`VectorDatabase` nuevos. Inyectar los propios obliga al constructor posicional por
  defecto de la struct, y **ese orden de campos cambió**: hoy es
  `(voc, bm25, adj, doclens, db, len, query)`, con `query::QueryPipeline` donde antes vivía
  `query_expansion` (§8.4). Es exactamente la ruptura silenciosa que esta guía advertía; con las
  librerías consumidas como `dev` no hay ni siquiera un bump de versión que la anuncie.
  **Fija la versión exacta en `[compat]` (`"=X.Y.Z"`) si dependes de esto**, y ten un test que
  construya el índice y compare resultados (§6).

### 7.2 El canal de observadores: la forma sancionada de persistir incrementalmente

Cambio grande y directamente relevante para cualquier motor con almacenamiento propio. El log se
partió en dos canales separados, ambos en el contexto:

- **`ctx.reporters`** (`AbstractReporter`, `INFORM`): mensajes para leer — progreso, avisos.
  `InformativeLog(dt=2.0)` es el default. **`reporters=[]` silencia todo el árbol de llamadas**
  (los reporters sí viajan a contextos construidos internamente por la librería).
- **`ctx.observers`** (`AbstractObserver`, `OBSERVE`): reacciones a eventos **estructurales**.
  La librería nunca instala uno propio. Hoy existe exactamente un evento: **`:add!`**, con el
  rango contiguo exacto `sp:ep` de ids afectados, emitido igual por `SearchGraph`,
  `ExhaustiveSearch`, `InvertedFile`, `BM25InvertedFile` y `Sat`, venga de `push_item!`,
  `append_items!` o `index!`.

Las garantías del contrato son las que lo hacen usable como **write-ahead log**:

- **Exactamente-una-vez**: cuando una función mutadora delega en otra, solo la que hace la
  mutación emite. Nada de eventos duplicados por delegación.
- **Rangos exactos y sin huecos**, y todos los índices son append-only (los ids se asignan
  monótonamente y nunca se borran ni se modifican) — así que reproducir el stream de `:add!`
  basta para reconstruir o hacer checkpoint de qué ids están durablemente indexados, sin
  re-derivar estado del índice.
- **Los observers NO viajan a contextos internos** (los reporters sí). Un índice scratch interno
  emite `:add!` con ids de *otro* índice; dejarlos llegar a tus observers corrompería justo esa
  reconstrucción. Hereda observers solo cuando el contexto nuevo maneja el mismo índice.

Consecuencia de diseño: **el patrón "construye todo en memoria y exporta una sola vez al final"
(§11) ya no es la única opción**. Con un observer puedes escribir a tu almacén conforme el índice
crece, y recuperarte de una caída a media construcción. `SimilaritySearchEngine.jl` está montado
sobre esto — sus hooks `(index, sp, ep) -> nothing` son este canal.

### 7.3 API de resultados: `knnqueue` cambió de firma

**Ruptura respecto a lo que decía esta guía antes.** Ya no es `knnqueue(ctx, k)` — la cola se pide
por **tipo**:

```julia
res = knnqueue(KnnSorted, k)      # arreglo ordenado; también KnnHeap, para k grande
search(idx, ctx, query, res)
collect(IdView(res))              # ids;  DistView(res), IdDistView(res)
```

También: `knnqueue(T, ids, dists)` para reusar almacenamiento propio, `knnqueue(T, vec::SparseVector)`,
y `reuse!`, `sortitems!`, `pop_min!`/`pop_max!`, `nearest`, `frontier`, `covradius`, `maxlength`,
`knn_matrices`. Las colas por radio (`RadiusSorted`, `RadiusHeap`) se construyen directo, no vía
`knnqueue`. Sigue valiendo: ensancha `k` para post-filtros restrictivos (§6).

### 7.4 Lo que se agregó y conviene conocer antes de reinventarlo

- **`BKT`** — BK-tree para métricas de valor entero (`Dist.Seqs.Levenshtein`,
  `DamerauLevenshtein`, `LCS`), directamente relevante para dedupe de nombres/entidades (§9).
  Tiene su propia sección: **§7.6**, porque "exacto" tiene letra chica.
- **Distancias de secuencias sobre `String`**: `Levenshtein`/`DamerauLevenshtein`/`LCS` ya
  aceptan `String`/`SubString` directamente (antes exigían `Vector{Char}` para Unicode correcto).
  Ojo con la terminología: la indexación es por *code unit*, no por carácter — el mismo cuidado de
  §6 con las claves de String.
- **`SpatialAccessTree`** (`Sat` y variantes: `PermSat`, `PruningSat`, `BeamSearchSat`,
  `BeamSearchMultiSat`, `PrunParSat`, `BeamSearchParSat`), `PermIndex`, `hsp.jl`, `rerank.jl`.
- **Proyecciones y cuantización**: `ScalarQuant` (`sq/`), `bitsketch`/`bitsketch_corpus`, PCA,
  Hadamard, HBE, y `AnchoredDistantHyperplanes`. Además
  **`index!(G, ctx, Val(:bitsketch); method, nbits, ...)`** es una construcción rápida y **no
  incremental** de un `SearchGraph`: se construye la topología en el espacio proxy de sketches de
  signo bajo `Dist.Bits.Hamming` y se copia (adyacencia + hints) al grafo real, que conserva su
  propia distancia y base de datos. `method` puede ser `:gaussian` (default), `:qr`, `:adh`
  (hiperplanos anclados) o `:external` (sketches ya calculados).
- **Selección de subconjuntos, exportada en el top level**: `fft` (farthest-first traversal),
  `dnet` (red-δ), `randsel`, `multirandsel`, `neardup` (deduplicación por radio ε), más los tipos
  `CenterSelection`/`NearDupSelection`. Antes de escribir tu propio muestreo diverso o tu propio
  near-dup, mira aquí.
- **Paralelismo**: el idioma completo (`@BATCHES` y sus secciones, schedulers, `@batchid()`,
  `beginbatch`, `getminbatch`) es hoy suficientemente grande y suficientemente fácil de usar mal
  como para tener su propia sección: **§7.5**.
- **`MaxMatchError`** — función de error continua y basada en distancia para `optimize_index!`,
  más robusta que las de recall puro cuando los vecindarios de oro tienen dispersión cero.
- **Fragilidad estructural**: `SearchGraph` declara `algo`/`len` como `RefValue` y
  `SearchGraphContext` está parametrizado sobre su campo `neighborhood`. Una razón más para no
  depender de constructores posicionales sin fijar versión.

### 7.5 `@BATCHES`: secciones, schedulers y estado por lote

El idioma de paralelización de la librería (y, por herencia, de ReposMx y del motor). Ya no hay
`Polyester` de por medio: por debajo es `Threads.@threads` con un scheduler seleccionable.

```julia
@BATCHES getminbatch(n) begin
    @BEGIN                                   # una vez, en el scope del llamador
        acc = [Tuple{Int,Int}[] for _ in 1:@nbatches()]
    @BEGINBATCH                              # una vez POR LOTE, ya dentro de su tarea
        dl = Dist.Seqs.DamerauLevenshtein()  # estado mutable fresco: nadie lo comparte
        bctx = beginbatch(ctx, @batchid())   # handle etiquetado, ver abajo
        mine = acc[@batchid()]
    @LOOP for i in 1:n                       # obligatoria
        # ... trabajo, empujar a `mine` ...
    end
    @ENDBATCH                                # una vez por lote, antes de unirse
    @END                                     # una vez, con todos los lotes ya unidos
        edges = reduce(vcat, acc)
end
```

Las secciones son opcionales salvo `@LOOP`, deben ir en ese orden, y los marcadores solo valen
como marcadores top-level dentro del bloque (anidarlos en un `if`/`let` da error explícito).
La forma corta `@BATCHES minbatch for i in range ... end` equivale a usar solo `@LOOP`.

- **`@batchid()`, nunca `Threads.threadid()`.** Los ids de lote son disjuntos y estables bajo
  cualquier scheduler; `threadid()` puede migrar a media ejecución y el resultado es una **carrera
  silenciosa**, no un error. Escribir en `results[@batchid()]` desde `@ENDBATCH` es libre de
  carrera por construcción. Cuando no hay un `@batchid()` alcanzable (una interfaz sin contexto
  como `evaluate(dist, a, b)`), la salida es un pool de buffers por `Channel` — así lo resuelven
  `Levenshtein`/`LCS` en `dist/seqs.jl`.
- **Mintea el estado mutable dentro de `@BEGINBATCH`**, no antes del `@BATCHES` ni una sola vez
  global: distancias con scratch interno, cachés de memoización, contextos de búsqueda. Es el
  patrón que hace innecesarios los locks, y es más barato de razonar que cualquier alternativa.
- **El peligro del handle etiquetado.** El caso insidioso no es indexar mal un arreglo: es pasar
  el *objeto equivocado*. Si un callee re-deriva estado por lote de un objeto compartido varios
  marcos más abajo (`getvstate`/`getbeam` leen `ctx.batchid` dentro de `find_neighborhood!`/
  `search`, no en el sitio del `@BATCHES`), hay que mintear la copia etiquetada una vez
  (`bctx = beginbatch(ctx, @batchid())`) y usar **esa** copia en absolutamente toda llamada hecha
  desde el lote. Que una sola llamada use el objeto original basta para reintroducir la carrera.
- **Scheduler global, con default `:static`** (`get_batch_scheduler`/`set_batch_scheduler!`,
  sembrado del ambiente `SIMSEARCH_BATCH_SCHEDULER`), o por sitio con `scheduler=`:
  - `:static` — una tarea por hilo, sin migración. **Truena de inmediato si un `@BATCHES` se anida
    dentro de otra región ya paralelizada, o se invoca desde un hilo que no es el principal.** Esa
    restricción tiene una consecuencia de diseño que cuesta caro descubrir sola: **dos regiones
    `@BATCHES` no pueden correr concurrentemente**, así que cualquier operación masiva que
    paralelice internamente necesita exclusividad total, no un candado de lectura (§11).
  - `:default`/`:dynamic`, `:greedy` (Julia >= 1.11; tareas que jalan el siguiente lote al
    terminar — la opción natural cuando el costo por lote es muy desigual), `:sequential`
    (desactiva el threading: un solo lote, `@nbatches()==1`, útil para depurar).
  - `:default` y `:greedy` usan tareas migrables: cambiar a ellos es inseguro para cualquier
    código que todavía indexe por `threadid()`.
- **`getminbatch(n[, nt]; blocks_per_thread, maxbatches)`** apunta a ~8 lotes por hilo; con un
  contexto a la mano usa `getminbatch(ctx, n)`, que respeta `ctx.maxbatches`. No adivines el
  número.
- **`@BATCHES` paraleliza ENTRE iteraciones del `@LOOP`, jamás dentro de una.** Si una sola
  iteración concentra un trabajo enorme (un bucket de 17,000 nombres comparado O(n²) contra sí
  mismo), esa iteración cae completa en un lote y domina el tiempo total por muchos hilos que
  haya. Dos salidas: `scheduler=:greedy` si el desbalance es moderado, o una **estrategia
  híbrida** — los elementos chicos todos juntos en un `@LOOP` (muchas iteraciones baratas que se
  reparten bien), y los grandes uno a la vez, cada uno con su propio `@BATCHES` interno que
  reparte su O(n²) entre los mismos hilos. Medido en ReposMx (`compute_precision_clusters`, 93
  repos): 7.7h → 2.3h.
- **La unión de resultados va secuencial, fuera del `@BATCHES`.** Mutar una estructura compartida
  (el `parent` de un union-find, un `Dict` acumulador) desde varios lotes es una carrera;
  recolectar por lote y aplicar en una pasada final es más simple y más rápido que sincronizar.

### 7.6 `BKT`: BK-tree, y la letra chica de "exacto"

`BKT(dist, db::AbstractDatabase; checkmetric=true)`, construido una vez con `index!(bkt, ctx)`
(paralelo, sobre una carga plana por objeto). **No soporta inserción incremental** — como `Sat`, a
diferencia de `SearchGraph`.

- **Solo métricas de valor entero.** Cada nodo bucketea su subárbol por la distancia *exacta* al
  pivote; de ahí sale la cota `d(q,x) >= |d(q,p) - k|` que poda. Con una distancia continua el
  bucketing degenera (el árbol se vuelve una lista) y la cota deja de valer. **Es un contrato, no
  una verificación**: `index!` redondea a `Int32` y confía — un `BKT` mal alimentado responde sin
  quejarse y pierde vecinos en silencio.
- **`Metric` vs `SemiMetric`, y `checkmetric=false`.** `Dist.Seqs.DamerauLevenshtein` es entera
  pero está tipada `SemiMetric` a propósito: la variante restringida (OSA) viola la desigualdad
  triangular, así que un `BKT` sobre ella puede perder vecinos. El constructor la rechaza; el
  override existe para dos razones muy distintas: la distancia sí es métrica y solo está tipada
  flojo, **o** aceptas conscientemente un índice aproximado.
- **Dos rutas para buscar por Damerau-Levenshtein**, ambas con su costo (números del propio
  benchmark de la librería: diccionario de 20k palabras, 200 consultas con typos):
  1. Llavear el árbol con `DamerauLevenshtein` y `checkmetric=false` → índice **aproximado**;
     recall `1.0` a radio 1, 2 y 3, a **7.9% / 39% / 68%** de un escaneo exhaustivo. Evidencia
     empírica sobre un corpus (palabras cortas, typos latinos), no una garantía.
  2. Llavear con `Levenshtein`, buscar a radio `2r` y filtrar los candidatos con
     `DamerauLevenshtein` → **exacto** sin depender de que OSA sea métrica (`DL <= Lev <= 2*DL`),
     pero el radio doble cuesta poda: **33% / 79% / 107%** — en `r=3` ya es peor que no tener
     índice.
- **Es una estructura de umbral pequeño.** La poda muerde solo cuando el radio del resultado es
  chico frente a la dispersión de la distribución de distancias (la forma exacta de la corrección
  ortográfica: vecinos a 1-2 ediciones, el grueso del corpus mucho más lejos). Con un radio que
  cubre esa dispersión se visita el árbol completo y degenera en escaneo exhaustivo — correcto,
  sin aceleración.
- **Búsqueda**: `search(bkt, ctx, query, RadiusSorted(r))` y de ahí `.ids`/`.dists`;
  `database(bkt, id)` recupera el objeto. El propio query, si está indexado, **no se excluye
  solo** — hay que compararlo a mano.
- **El radio se escoge contra el piso de tu fórmula de score, no "por sentirse suficiente".** Con
  la normalización `1 - d/max(len(a),len(b))` la misma distancia bruta significa cosas distintas
  según el largo: `d=1` en una palabra de 4 letras da 0.75, en una de 12 da 0.917. Para un umbral
  de conexión de 0.9, un radio de 1-2 alcanza; **pero ese mismo radio no es seguro para un umbral
  más permisivo del mismo pipeline** (un piso de contradicción de 0.2): "no encontrado ⇒ lejano"
  solo vale si conoces el rango completo de umbrales que consumen ese resultado. Este fue el
  motivo de rechazar una memoización basada en radio de BKT en ReposMx.
- **Concurrencia**: `search` sobre `BKT` no reserva memoria de trabajo propia, así que un
  `GenericContext` es compartible entre búsquedas concurrentes. Aun así, mintear contexto y
  distancia nuevos por lote (§7.5) es barato y elimina la pregunta.

## 8. Sección TextSearch.jl (v1.1.2)

El cambio conceptual desde la versión anterior de esta guía: **el centro de gravedad ya no es el
`Vocabulary` suelto, es el `TextProfile`**. Casi todo lo que antes había que orquestar a mano
(entrenar vocabulario, podar, elegir pesos, decidir stopwords, guardar/cargar sin JLD2) hoy vive
en la librería, con el orden correcto de las etapas incorporado.

### 8.1 `fit_profile`: el pipeline con el orden ya resuelto

```julia
p = fit_profile(TextConfig(), corpus; min_ndocs=5, stopwords=(; doc_freq_threshold=0.5))
```

`fit_profile(textconfig, corpus; ...) -> TextProfile` destila un corpus en un artefacto portable:
vocabulario y contadores, pesos, conjunto de stopwords, red de expansión de consulta y mapa de
lemas, más un **linaje** (`LineageStep`) que registra cómo se obtuvo cada cosa. Las keywords van
agrupadas por preocupación: `min_ndocs`, `stopwords=(; doc_freq_threshold, reuse)`,
`encoder=(; outdim, scaling, factorization, wordvectors)`,
`expansion=(; k, head_df, max_target_ratio, approx, construction_recall, search_recall)`,
`lemmas=(; apply, algorithm, ...)`.

Lo que hay que internalizar es **por qué son tres pasadas y por qué ese orden** — equivocarse es
silencioso:

1. **Stopwords antes del vocabulario**: se detectan en una pasada sin filtrar cuyo único producto
   es la lista de tokens sobre el umbral, y se quitan *mientras se construye el vocabulario que
   entrena el encoder* — así un token filtrado nunca entra a los contadores, ni a la
   factorización, ni a la red. Es la etapa más cara de un fit: medido sobre 272,466 párrafos de
   Wikipedia en español, 36.5s de 123.2s.
2. **El encoder, y después los lemas**: las familias de lemas salen de agrupar embeddings de
   tokens, así que los embeddings tienen que existir primero.
3. **El vocabulario otra vez, bajo el mapa de lemas** (cuando `lemmas.apply`): un lema es una
   normalización, así que pertenece al `TextConfig`, donde todo consumidor lo aplica igual a
   documentos y consultas, y el idf cuenta la familia de flexiones junta en vez de repartirla
   entre formas. LSI **no** se rehace después: el trabajo de los embeddings era encontrar las
   familias, y ya lo hicieron.

Consecuencia para §4: **`min_ndocs` ya es de primera clase aquí**. La receta manual "construir
vocabulario → `filter_tokens` → `BM25InvertedFile` → `append_items!`" sigue siendo válida y sigue
siendo lo correcto cuando solo se quiere un vocabulario podado sin el resto del perfil, pero si
vas a fitear stopwords/lemas/expansión, no reimplementes el orden: úsalo desde `fit_profile`.

### 8.2 Perfiles portables: guardar, cargar, y **descargar**

`save_profile`/`load_profile`/`zip_profile` siguen siendo la técnica sancionada (JSON3 + zip, no
serialización genérica de objetos — §2). Lo nuevo:

- **`list_remote_profiles()`** y **`download_profile(nickname_or_url)`** — hay perfiles
  preentrenados publicados desde el repo de TextSearch (hay corridas registradas de es, pt, fr,
  it, eu). **Antes de fitear un perfil desde cero para un idioma, revisa si ya existe uno.**
- `merge_profiles`, `refit_profile`, `refit_textconfig`, `fold_lemmas`, `blend_vocabularies`:
  fitear por lotes y fusionar después. La fusión es *exacta* solo si los lotes comparten el
  conjunto de stopwords — para eso está `stopwords=(; reuse=...)`, que le pasa a un lote el
  conjunto ya detectado por otro. Si no, hay que imputar.
- `isbase(p)`/`istuned(p)`, `with_applied(p; ...)`, `AppliedArtifacts`: un perfil *base* puede
  **cargar** un artefacto (red de expansión, mapa de lemas) sin **endosar** su uso. La distinción
  importa en tiempo de construcción del índice (§8.3).

### 8.3 `BM25InvertedFile` desde un perfil: estadísticas prestadas

```julia
idx = BM25InvertedFile(profile)                                   # corrige, no expande
idx = BM25InvertedFile(profile; expansion=true)                   # ...y expande de todos modos
idx = BM25InvertedFile(profile; policy=QueryPolicy(correction=:off))  # consultas literales
```

Este constructor es el punto entero de tener perfiles, y el reparto es preciso:

- **Las estadísticas del scorer son del perfil**: `trainsize` y `avgdoclen` son los del corpus con
  el que se fiteó, y la frecuencia de documento detrás de cada idf se lee de su vocabulario en
  tiempo de búsqueda.
- **Las longitudes de documento son del índice**, las llena `append_items!` conforme llegan.

Eso es lo que permite que **un índice de 20,000 documentos tome prestado el idf y la
normalización por longitud de un perfil fiteado sobre 6,665,754 párrafos**, en vez de inventar
estadísticas con lo poco que tiene. Para un buscador académico con colecciones chicas y
heterogéneas por repositorio (§10), esta es probablemente la mejora de calidad más barata
disponible.

Las dos compuertas son deliberadamente asimétricas: **la expansión la decide el perfil**
(`applied.query_expansion`), porque la red es un artefacto que el perfil puede cargar sin querer
que se use; **la corrección la decide la política**, porque no depende más que del vocabulario,
que todo perfil tiene.

### 8.4 `QueryPipeline` / `QueryPolicy`: cómo se responde una consulta vive en el índice

- **`BM25InvertedFile` tiene hoy 7 campos: `(voc, bm25, adj, doclens, db, len, query)`**, con
  `query::QueryPipeline`. El campo `query_expansion` de antes ya no existe. Ver la advertencia de
  §7.1 si inyectas `adj`/`db` por constructor posicional.
- `QueryPolicy(; correction, expansion, expansion_k, negligible_ratio)` — `correction=:off` da
  consultas literales. La política **puede viajar por llamada**, sin reconstruir el pipeline.
- `derive_variants(voc; min_ndocs, maxforms)` produce el mapa de variantes para la corrección
  ortográfica. Se deriva **una vez, al construir el índice**, no por consulta: derivarlo por
  consulta sería lisa y llanamente demasiado lento, y esa es la razón de que el pipeline viva en
  el índice y no en el contexto. Para un perfil que ya pliega mayúsculas y diacríticos, sale
  vacío sin costo.
- API de resolución: `query_tokens(voc, query, qp)`, `ResolvedQuery`, `QueryTerm`, `querybow`,
  `queryvector`, `expand_query!`, y `explain` (en `variants.jl`) para depurar por qué una consulta
  resolvió a lo que resolvió.
- **`TextInvertedFile`** (TF-IDF coseno) y `BM25InvertedFile` pasan ambos por el mismo pipeline de
  consulta. Elegir entre scoring BM25 o coseno ya no cambia el camino de la consulta.

### 8.5 Vocabulary, poda y detalles que siguen valiendo

- **`Vocabulary` conserva su constructor posicional público y estable**:
  `Vocabulary(textconfig, token::Vector{String}, occs::Vector{Int32}, ndocs::Vector{Int32},
  token2id::Dict{String,UInt32}, trainsize::Ref{Int64}, numtokens::Ref{Int64})`. Es lo que usa
  `load_profile` internamente — la vía sancionada para reconstruir un vocabulario desde datos
  planos propios.
- **`filter_tokens(pred, voc)`** (copia, `voc.jl`) y **`filter_tokens!`** (in-place,
  `updatevoc.jl`) son la forma correcta de podar por predicado por token
  (`t -> t.ndocs >= min_ndocs`); remapean los ids correctamente. Poda **antes** de construir el
  `BM25InvertedFile`. También: `merge_voc`, `update_voc!`, `push_token!`, `append_tokens!`,
  `vocabulary_from_thesaurus`, y `table(voc, DataFrame)` para inspeccionarlo.
- **`_encode_policy`/`_decode_policy`** siguen sin exportarse pero siguen accesibles por nombre
  completo — úsalas en vez de reinventar la codificación de regex/diacríticos/emojis. Es
  exactamente la clase de dependencia que justifica fijar la versión exacta en `[compat]`.
- **`db` guarda `SparseVecView{Vector{Int32},Vector{UInt32}}`** (id de token → frecuencia); las
  listas de posteo guardan **solo ids de documento** (`UInt32`), igual que el `InvertedFile`
  genérico — ningún detalle por documento se duplica en los postings.
- **Camino nuevo de construcción**: se puede hacer crecer `db` directamente con `SparseVecView`s
  precalculados (`push_item!(database(idx), docvec)`) y luego llamar `index!(invfile, ctx)` para
  construir los postings desde los vectores ya guardados. `len` es cuántos documentos tienen
  postings, y puede quedar por debajo de `length(database(idx))` mientras no se llame `index!`.
  Útil si ya tienes los vectores materializados (p. ej. recuperados de tu propio almacén) y no
  quieres re-tokenizar. Los `append_items!`/`push_item!` que toman texto crudo siguen fusionados
  (codificar+guardar+registrar en una pasada) por eficiencia.
- `LSI.vectorize!` acepta `topk` para restringir la proyección a los anclajes más pesados;
  `lemma_clusters` agrupa por posición del centro (no por id); las barras de progreso ya no
  extrapolan un ETA a partir de la compilación JIT.

### 8.6 Tokenizar lo que no es texto libre: nombres propios, ids y basura

Todo lo anterior asume documentos. Cuando el "documento" es un nombre de persona, un título
normalizado o cualquier campo corto de identidad, `TextConfig` sigue siendo la herramienta
correcta, pero su normalización es **más agresiva de lo que parece**, y equivocarse aquí produce
bugs que se ven como bugs de matching. Comprobado empíricamente con
`TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])`:

- **`del_punc=true` trata el guión como un espacio**: `"Sanchez-Martinez"` tokeniza idéntico a
  `"Sanchez Martinez"`. Insertar un guión en el texto crudo para "pegar" un apellido compuesto no
  logra nada — hay que unir los tokens **después** de tokenizar, como un solo elemento del
  `Vector{String}` que contenga el guión literal.
- **También desenvuelve paréntesis**: `"Anaya, A. (Alejandro)"` produce `"alejandro"` como token
  propio. Puede ser señal útil (nombres en formato de cita) o ruido, según el consumidor — vale la
  pena tener dos funciones de tokenización deliberadamente distintas antes que una que intente
  servir a ambos.
- **Cualquier URL colapsa al token literal `"url"`, y cualquier corrida de dígitos a `"0"`.** Dos
  valores-basura *distintos* (dos ORCIDs, dos URLs de perfil) producen exactamente los **mismos**
  tokens: en ReposMx eso creó un blob real de 117 "autores" fusionados bajo la misma clave. La
  lección general: cualquier valor que no sea del tipo que el pipeline cree estar procesando debe
  filtrarse **antes** de tokenizar; no confíes en que va a fallar el matching por sí solo — la
  normalización trabaja en tu contra ahí.
- **El tokenizador no tiene ninguna noción de "esto no es un nombre"**: procesa sin quejarse un
  párrafo de tesis o una lista de instituciones capturada por error en el campo `creator`, y
  produce cientos de tokens. Si alguna función río abajo asume "esto es un nombre de persona", un
  campo corrupto se vuelve un apellido gigante. Un límite duro de tokens (10 en ReposMx) es un
  filtro tosco pero efectivo: ningún nombre humano real se le acerca.

## 9. Resolución de identidad / clustering de entidades (dedupe difuso)

Destilada de rediseñar el clustering de perfiles de autor de ReposMx: pasar de
"solo claves de nombre exactas" a "claves de nombre + una señal de similitud de contenido (TFIDF +
`SimilaritySearch.bichromatic_metricjoin`)". El resultado técnico funciona a la primera prueba;
lo que costó fue la parte de **correctness**, no la de API — cada versión del veto pasó una
revisión superficial y falló al medirla contra datos reales, tres veces seguidas.

### 9.1 Una señal de similitud SIEMPRE necesita un veto independiente, y el veto necesita su propia validación empírica

El patrón general: claves exactas (nombre normalizado, hash, lo que sea) para el caso fácil, más
una señal de similitud de contenido para el caso que las claves exactas no alcanzan a ver
(erratas, variantes de formato, campos reordenados). La señal de contenido **siempre** va a
proponer pares que no deberían fusionarse — dos entidades distintas que se parecen mucho en su
contenido por razones legítimas ajenas a ser "la misma cosa" (aquí: coautores frecuentes con
perfiles de tópicos casi idénticos). El veto por nombre existe exactamente para cortar esos casos,
pero **un veto es en sí mismo una heurística que hay que validar con la misma rigurosidad que la
señal principal** — no basta con que "suene razonable".

Tres versiones probadas en este orden, cada una descartada por evidencia real (no por revisión de
código):

1. **Apellido solo** (último token del nombre): dejaba pasar pares como
   `("A. Alberto R. Fernandes", "PATRICIA FERNANDES")` — personas evidentemente distintas que
   comparten un apellido común (a menudo el materno, en la convención
   "Nombre ApellidoPaterno ApellidoMaterno", que es justo el que un criterio de "último token"
   captura).
2. **Apellido + misma primera letra del nombre**: sigue fallando, y de forma más peligrosa —
   `("JHON LEANDRO PEREZ", "JULIO CESAR PEREZ PEREZ")`, `("RIGOBERTO ORTEGA PEREZ",
   "RODOLFO ORTIZ PEREZ")`. Con apellidos muy comunes (Pérez, González, Hernández — omnipresentes
   en el dataset), "misma letra inicial" no discrimina casi nada, y como estas personas suelen ser
   colegas del mismo campo e institución, su contenido (keywords/tópicos) también se parece.
3. **Apellido + primer token de nombre de pila, igual o abreviatura de un solo carácter**
   (`"juan"` ~ `"j"`, pero `"juan"` ≁ `"julio"`): la que funcionó. La diferencia con la versión 2
   no es cosmética — "comparten letra inicial" y "uno es abreviatura literal del otro" son
   comprobaciones completamente distintas en poder discriminante, aunque se lean parecido en
   prosa.

**Regla práctica**: al diseñar un veto/gate para un matcher difuso, junta ejemplos **reales**
(no inventados) de pares que el veto actual deja pasar mal, y ejemplos reales de pares que debería
dejar pasar bien — normalmente saliendo de correr la versión actual contra datos de producción e
inspeccionar los resultados a mano, no de razonar en abstracto. Conviértelos en tests de
regresión permanentes con nombres/institución/campo reales (anonimizados si hace falta), porque
el modo de falla real casi nunca es el que se te ocurre a priori.

### 9.2 El poder discriminante de una heurística de "mismo valor" depende de qué tan común es ese valor

"Mismo apellido" es una señal fuerte para un apellido raro y casi nula para uno común. Cualquier
heurística de matching que compare "¿este campo es igual?" sin considerar la frecuencia del valor
en el corpus tiene este mismo punto ciego — funciona bien en la muestra pequeña donde se probó
(donde por azar los valores tienden a ser menos comunes) y falla en producción a mayor escala,
donde los valores comunes dominan. Si no se quiere modelar frecuencia explícitamente (más
complejo), la alternativa más simple y efectiva es **exigir más de un campo compatible
simultáneamente** (aquí: apellido Y nombre de pila, no apellido solo) — cada campo adicional
multiplica el poder discriminante aunque cada uno individualmente sea débil.

### 9.3 Un índice aproximado (grafo/ANN) puede ser sensible al orden de inserción — y ese orden puede no ser determinista sin que se note

Verificado en vivo: la misma función, con los mismos datos de entrada lógicos, dio resultados
*distintos* en dos ejecuciones de `julia` separadas. La causa no fue aleatoriedad del algoritmo de
búsqueda — fue que los datos de entrada llegaban en un orden distinto cada vez, porque venían de
iterar un `Dict{String,...}` construido en ese proceso, y el hashing de `String` en Julia se
inicializa con una semilla aleatoria por proceso por defecto. Un `SearchGraph` (o cualquier índice
de grafo/ANN construido incrementalmente) puede terminar con una estructura distinta según el
orden de inserción, y eso se propaga a qué pares encuentra `bichromatic_metricjoin`.

**Regla práctica**: si el resultado de construir un índice aproximado alimenta algo que necesita
ser reproducible entre corridas (ids derivados por hash, reportes, snapshots comparables), **ordena
explícitamente la entrada por una clave estable** (aquí, por nombre) *dentro* de la función que
construye el índice — no confíes en que el llamador ya lo haga, y no asumas que "mismos datos" implica
"mismo orden" solo porque vinieron de la misma fuente. Verifícalo corriendo la misma función en dos
procesos `julia` separados (no solo dos veces en la misma sesión — un solo proceso reusa la misma
semilla de hash) y comparando el resultado exacto.

### 9.4 Patrón de uso: `bichromatic_metricjoin` para auto-join con umbral adaptativo

Para encontrar pares "suficientemente similares" en un solo conjunto sin fijar un corte de
distancia a mano:

```julia
voc = Vocabulary(config, texts)
model = VectorModel(IdfWeighting(), TfWeighting(), voc)
vecs = vectorize_corpus(model, texts)   # normalize=true por default -> vectores unitarios
db = VectorDatabase(vecs)

G = SearchGraph(SimilaritySearch.Dist.NormCosine(), db)  # NormCosine: asume ya normalizado
ctx = SearchGraphContext()
index!(G, ctx)

pairs = bichromatic_metricjoin(G, ctx, db; k=16)  # (a, b, dist) ya filtrados
```

Firma actual (v1.4.1):
`bichromatic_metricjoin(idxA, ctx, B; k, rank=1, q=0.9, mingroup=8, samedata=database(idxA) === B)`.

- **`samedata` ya se infiere solo** cuando el índice indexa exactamente el mismo `B` — pasarlo a
  mano dejó de ser necesario (sigue aceptándose). Excluye auto-emparejamientos (`a==b`) tanto de
  la votación como del resultado. En un auto-join esto no es cosmético: con el `rank=1` por
  default, no excluirlo haría que el único voto de cada punto fuera su propio self-match a
  distancia cero, dejando cada grupo sin información real y colapsando todos los umbrales al
  fallback.
- El umbral es **adaptativo por punto**: cada `b` que puso a `a` entre sus `rank` mejores
  candidatos *vota* por `a` con su distancia, y el corte de `a` es el cuantil `q` de sus votantes.
  Es una estimación mucho más estable que la lista (posiblemente diminuta) de vecinos de un solo
  `b`, y evita adivinar un umbral de coseno a mano.
- **`rank` es nuevo respecto a lo que decía esta guía** (`<< k`, típicamente 1-3): cuántos
  candidatos de cada `b` votan. El filtro final, en cambio, se aplica contra los `k` candidatos —
  por eso un `b` puede terminar emparejado con varios `a`: esto es un *join*, y el tamaño de la
  salida lo decide el dato, no `k`.
- `k` no tiene buen default independiente de los datos — es una sobreestimación deliberada, hay
  que pasarla explícitamente.
- El fallback tiene **tres niveles**, no uno: un `a` con menos de `mingroup` votantes usa el
  cuantil `q` de las distancias *agrupadas* de todos los `a` que sí llegaron a `mingroup` (gratis,
  y en la escala de distancia correcta); si ni ese conjunto alcanza, cae a una muestra aleatoria
  cruzada de pares `A`-`B`. `mingroup` se acota internamente a >= 1. No asumas que el
  comportamiento a escala de prueba (decenas de items, todo en fallback) predice el de producción.

**Alternativa exacta**: si la señal de similitud entre entidades es distancia de edición sobre el
nombre (no similitud de contenido TFIDF), hoy existe `BKT` — un BK-tree para métricas de valor
entero (`Dist.Seqs.Levenshtein`/`DamerauLevenshtein`/`LCS`, que ya aceptan `String` directamente).
Vale la pena considerarlo antes de montar el join aproximado, o como segunda señal independiente
junto a él; lee **§7.6** antes, porque "exacto" depende de cómo lo llaves y con qué radio.

### 9.5 Esquema de ID corto con resolución de colisiones (alternativa a UUID)

Cuando no hace falta un espacio de hash gigantesco (UUID) sino un id corto y legible, y hay una
partición natural del dominio (aquí, apellido):

1. Particiona por la clave natural (`<partición>`) — reduce drásticamente cuántas entidades
   compiten por el mismo sub-espacio de hash.
2. Dentro de la partición, usa un hash corto (pocos dígitos) del contenido relevante.
3. Antes de aceptar `<partición>_<hash>`, revisa contra un `Set` de ids ya usados. Si choca,
   prueba sufijos `_00`, `_01`, `_02`... hasta encontrar uno libre — no agrandes el hash para
   "casi nunca chocar" (con miles de entidades por partición común, la paradoja del cumpleaños
   garantiza colisiones reales; hay que *resolverlas*, no evitarlas por tamaño de espacio).
4. Procesa las entidades en un **orden fijo** (ordenado por nombre u otra clave estable) para que
   qué entidad "gana" el hash base y cuál recibe el sufijo sea reproducible entre reconstrucciones
   — mismo principio que §9.3.

Reporta cuántos ids necesitaron sufijo (no solo "cuántos ids hay") — es la métrica real de qué
tan ajustado está el espacio de hash al volumen de datos.

### 9.6 El techo de escala del join aproximado, y qué probar en su lugar

El patrón de §9.4 (`Vocabulary` → `VectorModel(IdfWeighting(), TfWeighting())` →
`vectorize_corpus` → `SearchGraph` → `bichromatic_metricjoin`) funciona muy bien para **miles** de
entidades. Construirlo sobre **300K+ perfiles se cuelga por horas, sin error y sin progreso** — no
es un límite documentado de la librería, es el punto donde el enfoque deja de ser viable para ese
volumen. No hay una talla "segura" conocida: se encontró probando, y hay que medirla en cada
dominio antes de comprometerse con el diseño.

Cuando se choca con ese techo, la salida no es un índice más grande sino **particionar primero**
(bloquear por una clave barata: apellido, prefijo, hash de q-gramas) y resolver dentro de cada
bloque. Alternativas medidas en ReposMx, con su desenlace:

- **`DictInvertedFile` + `Dist.Sets.Jaccard()` + `allknn` sobre conjuntos de q-gramas**, en vez de
  comparar nombre contra nombre O(n²) dentro del bucket. Es **más lento que el loop directo para
  buckets chicos** (el costo fijo de construir un índice por bucket no se amortiza) — de ahí, otra
  vez, una estrategia híbrida por tamaño de bucket (§7.5).
- **La poda `max_df` es una palanca de CORRECCIÓN, no solo de velocidad**: podar demasiado
  agresivo destruye información real de nombre de pila, no solo ruido. Trátala como un
  hiperparámetro con validación cruzada, no como un ajuste de rendimiento.
- **`SearchGraph` + `NormCosine` con `MaxMatchError`** como objetivo de tuning: más rápido que un
  escaneo exhaustivo sin podar, pero **más lento que el enfoque podado ya validado**, y con error
  de aproximación real (5-10% de aristas de más/de menos contra el ground truth exacto).
  `MaxMatchError` es un objetivo que el tuner persigue, no una garantía dura. Descartado.
- **Hashear q-gramas a `UInt64` en vez de `String`**: gana 6-14%, no siempre reproducible entre
  corridas. Ajuste fino sobre un diseño ya elegido, nunca una decisión de diseño por sí solo.
- **No toda aceleración necesita una estructura nueva.** Reusar el `BKT` ya construido para
  acelerar el clustering se consideró explícitamente y se descartó: una memoización simple por par
  de palabras daba el mismo beneficio sin ningún riesgo de aproximación (§7.6, la nota del radio).
- **Perfila antes de optimizar, con la herramienta real.** Varias veces la intuición sobre dónde
  estaba el costo resultó equivocada (se creía que en el tamaño del bucket; estaba en `join()` y
  en recomputar contenido por par). `Profile.@profile` + `Profile.print` lo encontró en minutos.

## 10. Arquitectura de un buscador de información académica (caso ReposMx)

Esta sección es el caso completo, no una regla suelta: cómo se conectan las piezas de §1-§8 en un
buscador real de literatura académica (repositorios institucionales: documentos, autores,
referencias citadas). La fuente es `~/Projects/Repositorios-Institucionales/docs/rocksdb_inverted_index.md`.
Lo que sigue es transferible a cualquier dominio donde una entidad tenga varios *campos de
naturaleza lingüística muy distinta*.

### 10.1 Índices segregados y homogéneos, uno por naturaleza de texto

La decisión de diseño de fondo: **no un índice con todos los campos, sino varios índices
homogéneos e independientes, cada uno con su propio vocabulario**, para no diluir el vocabulario
de uno con el ruido léxico del otro.

| índice | contenido | poda |
|---|---|---|
| `docs_content` | título / keywords / resumen / conclusiones | `min_ndocs=3` (279,021→108,709 tokens, -61%; 0 docs sin contenido) |
| `docs_refs` | texto de las referencias citadas | `min_ndocs=5` (849,793→148,225, -83%) |
| `authors_name` | nombre del autor + su forma de iniciales | **sin poda** |
| `authors_profile` | perfil bilingüe del autor (keywords/tópicos) | `min_ndocs=3` (400,698→165,733, -59%) |

Los dos extremos de la tabla son la lección: el texto de referencias bibliográficas es **la cola
más larga que vas a encontrar** (nombres propios, revistas, DOIs, ruido de OCR) y aguanta una poda
agresiva; un nombre de autor normalizado **no es texto libre**, no tiene cola larga que recortar, y
podarlo solo destruiría entradas legítimas. Mismo sistema, misma librería, decisiones opuestas —
por eso §4 insiste en medir cada índice por separado.

**Numeración compartida**: `docs_content` y `docs_refs` comparten la misma numeración de documento;
`authors_name` y `authors_profile`, la de autor. Por eso `doc_keys`/`author_keys` (posición interna
→ identidad externa) se exportan **una vez por numeración, no una vez por índice**. Reconocer qué
índices comparten numeración es lo que evita duplicar el mapeo más grande del sistema.

### 10.2 Tres capas de persistencia, una por costo real

Cada índice se parte en tres piezas con vidas y costos de carga muy distintos:

1. **Vocabulario** → un `.zip` propio (JSON3 + ZipArchives, la técnica de §2/§8.2).
2. **"Shell"** → otro `.zip`: el resto de campos pequeños del `BM25InvertedFile` (parámetros BM25,
   `doclens::Vector{Int32}`, `len`, el `QueryPipeline`) como `shell.json` vía JSON3, **no JLD2**.
   El shell es minúsculo, así que la razón no es el tamaño: `JLD2.load` era la **primera** llamada
   de toda la construcción del motor que tocaba maquinaria de deserialización genérica/paramétrica,
   y pagaba ~8s de compilación JIT de una sola vez por proceso fresco (medido: 8.44s, 98.66% de eso
   compilación). Pasar a JSON3 **comparte el costo de compilación con el que ya paga el cargador de
   vocabulario unas líneas antes**, en vez de sumar una ruta de deserialización aparte.
   *Esta es la interacción entre esta guía y `julia-app-compile-latency`: el criterio de formato no
   es solo bytes y segundos de I/O, es también "¿introduzco una segunda maquinaria de
   deserialización cuyo JIT nadie más amortiza?".*
3. **Postings + vectores por documento** → RocksDB, nunca un archivo.

### 10.3 Claves y valores binarios de ancho fijo

```julia
postings_key(idx_id::UInt8, tokenID) = vcat(UInt8[idx_id], reinterpret(UInt8, UInt32[tokenID]))
docvec_key(idx_id::UInt8, docID)     = vcat(UInt8[idx_id], reinterpret(UInt8, UInt32[docID]))
```

Las column families `postings`/`docvecs` son **compartidas por los 4 índices y particionadas por
`idx_id`** — un byte de prefijo en vez de una CF por índice. Solo se hacen lookups puntuales
(`get`), nunca *prefix scans*, así que el orden de bytes no es semánticamente importante y se usa
el nativo sin ceremonia. **Deja escrito ese supuesto**: si algún día hace falta escanear todas las
postings de un índice en orden, la decisión hay que revisitarla.

Los valores también son binarios compactos: una posting list es un `Vector{UInt32}` reinterpretado
a bytes crudos; un vector disperso de documento se serializa a mano como
`(n::Int32, nnz::Int32, nzind::Vector{Int32}, nzval::Vector{UInt32})` sobre un `IOBuffer`. Nada de
JSON para estas dos CFs — son el volumen alto y el camino caliente de cada búsqueda. (El
contraste con el shell de §10.2 es el punto: distinta pieza, distinto régimen, distinto formato.)

### 10.4 Gotchas de RocksDB con costo real

- **Migración de column families al abrir**: listar las CFs existentes (`rocksdb_list_column_families`
  vía el API C), calcular la diferencia contra el esquema esperado, y crear las que falten en una
  apertura temporal antes de la apertura real. Da evolución de esquema sin migración manual ni
  borrar y reconstruir — agregar una feature que necesita una CF nueva no invalida las bases
  existentes.
- **El orden de escritura importa cuando hay lectura-antes-de-escritura.** Un contador de
  co-autoría lee el valor actual antes de incrementarlo, así que la ingesta hace **un `write!` por
  documento** (reusando el mismo `WriteBatch` vía `empty!` para no asignar miles): si dos
  documentos con el mismo par de coautores cayeran en la misma ventana sin confirmar, el conteo se
  subestimaría en silencio. Los perfiles de autor, que no tienen ese patrón, sí se agrupan en lotes
  de 2000. **La regla no es "batch más grande es mejor": es "el tamaño del batch lo fija el patrón
  de lectura, no el throughput".**
- **Compactar una vez al final de la construcción**, no en cada apertura (§3).
- **Claves posicionales perezosas**: `LazyDocKeys`/`LazyAuthorKeys` implementan solo `size` y
  `getindex`; `length`/`iterate`/todo lo demás sale gratis de `AbstractArray`. Mismo patrón que el
  backend perezoso de §7.1, aplicado a un tipo de dato distinto.

### 10.5 Construir en memoria, exportar una vez — y la alternativa nueva

El camino de escritura de ReposMx **no reemplaza el proceso de indexado**: el `BM25InvertedFile` se
construye exactamente como siempre (`BM25InvertedFile(voc)` + `append_items!`, en memoria, con el
algoritmo de TextSearch sin cambios) y **solo después**, ya completo, se recorre una vez para
volcar `adj`/`db` a RocksDB. Esto separa por completo "cómo se calcula el índice" de "dónde vive
después": cualquier mejora futura al indexado de TextSearch sigue funcionando sin tocar la capa
perezosa. Sigue siendo un buen default.

Lo que cambió: **hoy existe el canal de observadores (§7.2)**. Con un `AbstractObserver` en
`ctx.observers` se puede persistir *conforme el índice crece*, con rangos `sp:ep` exactos y
garantía de exactamente-una-vez — es decir, con checkpoint y recuperación ante caídas a media
construcción, que la exportación única no da. Elige a conciencia: exportación única si la
construcción cabe en memoria y en una sesión; observador si no, o si necesitas reanudar.

### 10.6 Lo que un buscador académico tiene y otros no

Cuatro rasgos del dominio (repositorios institucionales cosechados por OAI-PMH) que cambian el
diseño, no solo los datos. Valen para cualquier corpus con autoría, citas y metadatos capturados
por terceros:

- **La identidad de autor es un subsistema, no un post-proceso.** El mismo investigador aparece
  con decenas de grafías (`"PEREZ PEREZ, JUAN C."`, `"Juan Carlos Pérez"`, el nombre dentro de un
  paréntesis de cita, un ORCID en el campo `creator`), y la calidad de todo lo que se construye
  encima —perfiles, red de coautoría, acoplamiento bibliográfico— está acotada por ella. En
  ReposMx ocupa cuatro módulos encadenados: vocabulario de nombres con corrección ortográfica →
  clustering de precisión → id consolidado → imputación de los casos que ninguna señal resolvió.
  Presupuéstalo como componente de primera clase desde el diseño.
- **Los ids de entidad tienen que sobrevivir a la reconstrucción del índice.** Un `consolidated_id`
  que cambia en cada rebuild rompe enlaces externos, TOMLs de correcciones manuales y cualquier
  análisis previo. El modelo que funcionó: **el id del grupo ES el id de su líder**, y elegir
  líder es la misma decisión que elegir id, con una tabla de líderes de la corrida anterior que da
  continuidad cuando el grupo cambia de forma. Mismo principio de reproducibilidad que §9.3/§9.5.
- **Con datos capturados por terceros, el humano en el ciclo es parte del sistema.** Las
  correcciones manuales viven en un TOML versionado (fusiones forzadas, separaciones forzadas,
  imputaciones), no en el código ni en la base — el pipeline las lee en cada reconstrucción. Un
  matcher difuso sobre metadatos reales nunca llega al 100%; el diseño tiene que tener dónde
  aterrizar esa última fracción sin parchar heurísticas.
- **Un umbral duplicado en dos módulos es un bug esperando.** Encontrado dos veces en el mismo
  pipeline: una prueba marcaba un par como contradicción y otra, con su propio umbral más
  permisivo, lo volvía a fusionar en silencio — "marcar y deshacer". Si dos comprobaciones del
  mismo módulo deciden sobre lo mismo, sus umbrales se derivan uno del otro (una constante
  nombrada), no se copian con valores independientes "razonables".

Y un recordatorio de §10.1 con nombre de dominio: en este corpus los cuatro índices son
`docs_content`, `docs_refs`, `authors_name` y `authors_profile` — el texto de citas es la cola más
larga que vas a ver, y el nombre de autor no es texto libre. La tabla de podas de §10.1 es el
resumen de esa asimetría.

## 11. `SimilaritySearchEngine.jl`: revisa antes de reimplementar

Casi todo lo de §10 dejó de tener que escribirse a mano: `SimilaritySearchEngine.jl`
(`~/Research/SimilaritySearchEngine.jl`) es un motor embebido, transaccional y persistente que
empaqueta exactamente esa arquitectura. **Antes de escribir otro backend perezoso sobre RocksDB,
verifica si este motor ya cubre el caso.**

Lo que ya trae, mapeado contra las secciones de esta guía:

- **Engine × Backend, desacoplados** — el *engine* declara el dominio del payload
  (`DenseEngine`, `SparseEngine`, `FullTextEngine`) y el *backend* la estructura de indexado
  (`SearchGraph`, `ExhaustiveSearch`, `ParallelExhaustiveSearch`, `InvertedFile`,
  `BM25InvertedFile`, `TextInvertedFile`). Items tipados: `DenseItem`, `SparseItem`, `TextItem`.
- **Staging separado del indexado** (§10.5): `append_items!` hace durable de inmediato; la
  construcción cara (grafo, vocabulario de texto completo) se difiere a un `index!` explícito.
- **Persistencia híbrida** (§10.2-§10.3): column families de RocksDB + archivos de vectores
  memory-mapped (`dense_vectors.mmapdb`), con `IndexEngine` agnóstico de RocksDB — habla con la
  persistencia solo por hooks estructurales `(index, sp, ep) -> nothing`, que son el canal de
  observadores de §7.2.
- **Concurrencia resuelta con nombre propio** (§6): `ReadWriteLock` (`read_lock`/`write_lock`) por
  colección, y `ContextPool` + `checkout!`/`checkin!` para los contextos de búsqueda —
  deliberadamente separado del contexto que usa la inserción.
- **Perfiles de texto de primera clase** (§8): `DefaultProfile`, `BaseProfile`, `FitFromCorpus`,
  `QueryPolicy`, `DEFAULT_PROFILE_NICKNAMES`, `train_profile`.
- **Borrados lógicos** (`delete_item!`) sin reconstruir el índice, **calibración a recall objetivo**
  (`calibrate!`, `minrecall`), y las operaciones sobre el conjunto completo expuestas en proceso:
  `allknn`, `fft`, `dnet`, `neardup`, `closestpairs`, `bichromatic_kclosestpairs`.

Su `manual/architecture.qmd` documenta el mapa de submódulos, el modelo de concurrencia y el
layout en disco.

### 11.1 Cuatro lecciones de conectarlo contra la 1.4.1 (todas medidas, ninguna teórica)

Transferibles a cualquier motor que envuelva estas librerías con su propia persistencia:

- **Un candado de lectura no alcanza para una operación masiva que paralelice por dentro.** Las
  seis operaciones sobre el conjunto completo (`allknn`, `fft`, `dnet`, `neardup`, `closestpairs`,
  `bichromatic_kclosestpairs`) usan `@BATCHES` internamente, y con el scheduler `:static` por
  default **dos regiones `@BATCHES` no pueden coexistir** por más disciplinada que sea la política
  de candados (§7.5). Necesitan exclusividad total (candado de escritura) — lo que, de rebote,
  permite reusar el contexto del backend directamente, sin `ContextPool`, igual que la inserción.
- **La separación staging/indexado crea un estado intermedio legal que los escaneos globales no
  toleran.** `closestpairs` compara el índice contra `database(idx)`: itera sobre el conteo
  *staged* (crece en cuanto corre `append_items!`) mientras lee una lista de adyacencia
  dimensionada por el conteo *conectado* (solo crece en el siguiente `index!`) → `BoundsError`
  desde dentro de la librería. No es un problema de concurrencia: pasaba igual en un solo hilo. Si
  tu motor difiere el indexado, **cada operación sobre el conjunto completo necesita un guardia
  explícito de "no hay backlog pendiente"** que rechace con claridad en vez de tronar adentro.
- **Un test de concurrencia real encuentra lo que la inspección no.** Los dos bugs anteriores los
  cazó una prueba que mete tráfico simultáneo por ambos lados (8 lectores + un escritor
  intercalando `append_items!`/`index!`); una batería secuencial nunca los habría tocado.
- **En el camino de restauración, prefiere las entradas por lote de la librería.** Reproducir
  objetos guardados con `push_item!` uno por uno es secuencial por contrato (su propio docstring
  se declara no thread-safe); `append_items!(idx, ctx, ::AbstractDatabase, n)` es el punto de
  entrada por lote y es paralelo por dentro: 7.0s → 1.5s (~4.6x) al reabrir un proyecto de texto
  completo de 50K items. El mismo criterio aplica al bucle de lecturas puntuales contra RocksDB
  que rehidrata un `SearchGraph` (~2.2x a 200K items): `AbstractAdjList.add!` documenta ser
  thread-safe (candado propio) y el `get` de RocksDB no comparte estado mutable entre llamadas —
  pero **redimensiona la adyacencia a su tamaño final antes**, para que ningún `add!` tenga que
  crecerla bajo carga y su candado solo proteja el append.

## 12. Checklist rápido

**Antes de escribir nada**

0. ¿`SimilaritySearchEngine.jl` ya cubre este caso? (§11) ¿Y hay un `TextProfile` preentrenado
   para este idioma en `list_remote_profiles()`? (§8.2)

**Por cada pieza de estado del índice**

1. ¿Cuántas veces se toca por consulta típica? (§1) → RAM / perezoso / precalculado.
2. Si es una estructura grande con un `Dict`/tabla-hash interno: ¿mediste el formato de
   serialización con datos reales, o solo asumiste? (§2) ¿Y consideraste que un formato nuevo
   introduce una maquinaria de deserialización cuyo JIT nadie más amortiza? (§10.2)
3. Si vive en RocksDB (o similar): ¿hay una compactación explícita al final de cada sesión de
   escritura masiva? (§3) ¿El tamaño del batch lo fija el patrón de lectura-antes-de-escritura y
   no el throughput? (§10.4)
4. Si es un vocabulario sobre texto con cola larga: ¿probaste podar por `min_ndocs` y mediste el
   impacto real (documentos que quedan sin contenido) contra el corpus real? ¿Por índice, por
   separado? (§4, §10.1)
5. Si es un agregado de "todo el corpus": ¿se calcula en cada request/arranque, o se precalculó
   una vez y se persistió? (§5)
6. ¿El objeto de contexto/scratch de consulta se comparte entre requests concurrentes, o hay un
   pool? (§6, §11)
7. ¿Las claves del punto de acceso caliente son bytes de ancho fijo? Si el layout supone "solo
   lookups puntuales, nunca prefix scans", ¿está escrito? (§6, §10.3)
8. ¿Verificaste identidad de resultados entre dos construcciones independientes del motor después
   del cambio? (§6)

**Si paralelizas**

8b. ¿Indexas estado por lote con `@batchid()` (nunca `threadid()`), lo minteas dentro de
    `@BEGINBATCH`, y pasas el handle etiquetado (`beginbatch(ctx, @batchid())`) a **todas** las
    llamadas del lote? (§7.5)
8c. ¿Hay una sola iteración que concentre el trabajo? `@BATCHES` no parte una iteración: o
    `scheduler=:greedy`, o estrategia híbrida. (§7.5)
8d. ¿Tu operación masiva paraleliza por dentro? Entonces necesita exclusividad, no un candado de
    lectura — y un guardia de "sin backlog" si el motor difiere el indexado. (§11.1)

**Al depender de las librerías base**

9. ¿Dependes de un constructor posicional o de una función no exportada? Entonces `[compat]` con
   versión exacta (`"=X.Y.Z"`) y un test que lo ejerza — con las librerías en `dev` no hay bump de
   versión que te avise. El orden de campos de `BM25InvertedFile` ya cambió una vez. (§7.1, §8.4)
10. ¿Estás construyendo a mano un pipeline de fit (stopwords → vocabulario → encoder → lemas)? El
    orden ya está resuelto en `fit_profile`, y equivocarse es silencioso. (§8.1)
11. ¿Tu índice pequeño está inventando su propio idf en vez de tomar prestadas las estadísticas de
    un perfil grande? (§8.3)
12. Si persistes mientras indexas: ¿usas el canal de observadores `:add!` con sus garantías, o
    exportas una vez al final? Decídelo, no lo dejes al azar. (§7.2, §10.5)

**Si hay matching difuso o dedupe**

13. ¿Validaste el veto contra ejemplos reales buenos Y malos sacados de correr la versión actual
    contra datos de producción, no solo contra casos que imaginaste? (§9.1)
14. ¿La heurística depende de qué tan común es el valor comparado (apellido, tag, categoría)? Si
    sí, ¿se probó contra los valores más frecuentes del corpus? (§9.2)
15. Si el resultado de un índice aproximado alimenta algo que debe ser reproducible: ¿se ordena la
    entrada por una clave estable *dentro* de la función, y se verificó en dos procesos separados?
    (§9.3)
16. Si la señal es distancia de edición sobre nombres, ¿consideraste `BKT` en vez de, o junto a,
    el join aproximado — y elegiste llaveado y radio a conciencia? (§9.4, §7.6)
17. ¿El radio/umbral que fijaste sirve para **todos** los umbrales río abajo que consumen ese
    resultado, o solo para el que tenías en mente? (§7.6)
18. ¿Estás tokenizando algo que no es texto libre (nombres, ids)? Filtra la basura **antes** de
    tokenizar: URLs y dígitos colapsan a tokens idénticos. (§8.6)
19. ¿Mediste dónde deja de escalar el join aproximado en tu dominio, o asumiste que aguanta?
    Particiona antes de agrandar el índice. (§9.6)
