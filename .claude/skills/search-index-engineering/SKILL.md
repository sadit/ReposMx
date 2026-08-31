---
name: search-index-engineering
description: Guía de diseño y decisiones para construir motores de búsqueda por índice invertido en Julia con SimilaritySearch.jl y TextSearch.jl — qué mantener en RAM vs. cargar perezoso, poda de vocabulario, formatos de serialización, patrones de integración con RocksDB. Destilado de optimizar el backend BM25 de ReposMx. Úsala para diseñar o depurar cualquier motor de búsqueda basado en estas librerías, no solo este repo.
---

# Ingeniería de índices invertidos y vocabularios

Esta guía viene de una sesión real optimizando el backend de búsqueda de ReposMx (BM25 sobre
SimilaritySearch.jl/TextSearch.jl, ~450k documentos, ~300k autores, ~4M referencias
bibliográficas). Cada afirmación aquí viene de medir con datos reales, no de teoría — cuando dice
un número, es un número que se midió. Está pensada para reusarse al diseñar o ajustar **cualquier**
motor de búsqueda sobre estas dos librerías, no solo ReposMx.

## Contexto de dónde sale esto

El diseño original guardaba cada índice `BM25InvertedFile` completo (vocabulario + listas de
posteo + vectores de documento) en un solo archivo `.jld2` vía la serialización genérica de
objetos de JLD2. Eso costaba ~450MB en disco y ~16s de carga por índice de tamaño medio. Se separó
en tres piezas con tres tratamientos distintos (perezoso en RocksDB / serialización a mano /
podado), y el resultado final fue **~16s → ~1s** de arranque, con el índice más grande pasando de
~450MB a ~2MB en disco. El resto de este documento explica el razonamiento detrás de cada pieza,
no solo el resultado.

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
tiene su propio formato hecho a mano para ese tipo exacto (ver §4, `TextSearch.save_profile`),
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
sea naturalmente pequeño y podar ahí no valga la pena. Mide cada índice por separado.

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
  reproducir.
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

## 7. Sección SimilaritySearch.jl

- **`InvertedFile`/`BM25InvertedFile` están parametrizados sobre dos interfaces pequeñas e
  intercambiables**: `adj::AbstractAdjList` (listas de posteo) y `db::AbstractDatabase` (vector
  por documento). Este es el punto de extensión real para respaldar un backend perezoso propio
  (RocksDB, lo que sea) sin tocar ni forkear el paquete — solo hace falta implementar:
  - `AbstractAdjList`: `neighbors(adj, i)`, `neighbors_length(adj, i)`, `eachindex(adj)`,
    `add!(adj, i, ids)`. Para un backend de solo-lectura, `add!` puede lanzar error — la
    construcción del índice se sigue haciendo con la implementación en memoria de la librería
    (`AdjList`), y el backend perezoso solo se usa para **leer** después de exportar.
  - `AbstractDatabase`: `getindex(db, i)`, `length(db)`, `push_item!(db, v)`. Mismo patrón:
    solo-lectura para el backend perezoso.
  - Ya existen implementaciones en memoria (`AdjList`, `AdjDict`, `StaticAdjList`,
    `VectorDatabase`) y al menos un precedente de backend no-RAM (`MMapMatrixDatabase`,
    memory-mapped) — confirma que el patrón "backend intercambiable" es intencional en el
    diseño de la librería, no un hack.
  - **Importante**: el `InvertedFile` genérico expone `db=` como keyword en su constructor
    público; `BM25InvertedFile` **no** expone ni `adj=` ni `db=` — su único constructor público
    siempre arma un `AdjList`/`VectorDatabase` nuevos desde cero. Para inyectar un backend propio
    en `BM25InvertedFile` hay que usar el constructor posicional por defecto de la struct (con
    el orden de campos exacto de la versión instalada), lo cual es Julia válido pero frágil ante
    actualizaciones de la librería — **fija la versión exacta** en `[compat]` (`"=X.Y.Z"`, no un
    rango) si dependes de esto.
- **El propio algoritmo de búsqueda ya llama a `neighbors`/`getindex` de a uno por término/
  candidato**, no en bloque — antes de asumir que hay que reescribir el algoritmo de búsqueda
  para soportar un backend perezoso, verifica el patrón de acceso real en el código de
  `search`/`select_posting_lists`/`onmatch!`. Casi seguro ya está pidiendo las cosas de la forma
  correcta para un backend lazy.
- **`InvertedFileContext`** contiene buffers mutables reusables entre llamadas a `search` — ver
  la nota de concurrencia en §6.
- **`knnqueue(ctx, k)` + `search(idx, ctx, query, knnqueue(...))`** es el patrón de consulta;
  ensancha `k` para post-filtros restrictivos (§6).

## 8. Sección TextSearch.jl

- **`Vocabulary`** tiene un constructor posicional público y estable:
  `Vocabulary(textconfig, token::Vector{String}, occs::Vector{Int32}, ndocs::Vector{Int32},
  token2id::Dict{String,UInt32}, trainsize::Ref{Int64}, numtokens::Ref{Int64})`. Esto es lo que
  usa `TextSearch.load_profile` internamente para reconstruir el vocabulario desde JSON — es la
  vía sancionada (no un hack) para construir un `Vocabulary` desde datos planos propios.
- **`save_profile`/`load_profile`/`zip_profile`** (en `profile.jl`, exportadas) ya implementan
  exactamente el patrón de "JSON3 + zip en vez de serialización genérica" para un `TextProfile`
  completo (vocabulario + pesos + stopwords/lemmas/expansión de consulta). Si solo se necesita el
  `Vocabulary` (sin el resto del perfil, como en índices construidos con
  `Vocabulary(textconfig, corpus)` en vez de `fit_profile`), replica la misma técnica a mano para
  un `Vocabulary` suelto: `tokens`/`occs`/`ndocs`/`trainsize`/`numtokens` a un `vocabulary.json`,
  y el `TextConfig` codificado con las funciones internas (no exportadas, pero accesibles por
  nombre completo) `TextSearch._encode_policy`/`_decode_policy` — no reinventes la codificación
  de regex/diacríticos/emojis a mano, esas funciones ya lo hacen bien.
- **`filter_tokens(pred::Function, voc::Vocabulary)`** (exportada, en `voc.jl`) es la forma
  correcta y segura de podar un vocabulario por cualquier predicado por token (ej.
  `t -> t.ndocs >= min_ndocs`) — devuelve una copia nueva con los IDs de token re-mapeados
  correctamente. Es lo mismo que usa internamente `fit_profile(...; min_ndocs=...)`. Pódalo
  **antes** de construir el `BM25InvertedFile` y llamar `append_items!` (el orden correcto es:
  construir vocabulario → podar → `BM25InvertedFile(voc_podado)` → `append_items!`), no después.
- **Dependencias no exportadas**: varias funciones internas útiles (`_encode_policy`,
  `_decode_policy`) no están en la lista de `export`, pero siguen siendo accesibles por nombre
  completo (`TextSearch._encode_policy(...)`). Julia no impone privacidad real. Usarlas es válido
  y a veces preferible a reinventar la lógica, pero es exactamente la clase de dependencia que
  justifica fijar la versión exacta del paquete en `[compat]`.

## 9. Checklist rápido para una pieza de estado del índice

1. ¿Cuántas veces se toca por consulta típica? (§1) → RAM / perezoso / precalculado.
2. Si es una estructura grande con un `Dict`/tabla-hash interno: ¿mediste el formato de
   serialización con datos reales, o solo asumiste? (§2)
3. Si vive en RocksDB (o similar): ¿hay una compactación explícita al final de cada sesión de
   escritura masiva? (§3)
4. Si es un vocabulario sobre texto con cola larga: ¿probaste podar por `min_ndocs` y mediste el
   impacto real (documentos que quedan sin contenido) contra el corpus real, no solo el tamaño
   del vocabulario? (§4)
5. Si es un agregado de "todo el corpus": ¿se calcula en cada request/arranque, o se precalculó
   una vez y se persistió? (§5)
6. ¿El objeto de contexto/scratch de consulta se comparte entre requests concurrentes? (§6)
7. ¿Las claves usadas en el punto de acceso caliente son bytes de ancho fijo, o concatenación de
   strings con riesgo de offset en UTF-8? (§6)
8. ¿Verificaste identidad de resultados entre dos construcciones independientes del motor después
   del cambio? (§6)
