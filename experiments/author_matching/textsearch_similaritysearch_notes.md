# Notas de uso: TextSearch.jl y SimilaritySearch.jl

Notas prácticas acumuladas durante el rediseño del pipeline de consolidación de autores
(`src/NameVocabulary.jl`, `src/PrecisionClustering.jl`, `src/AuthorConsolidation.jl`,
`src/Imputation.jl`). No es un tutorial de las librerías — es lo que realmente importó
para este problema (nombres propios, corpus mexicano de repositorios institucionales),
incluyendo los errores concretos que costó encontrar.

## TextSearch.jl

### `TextConfig`/`tokenize` — la tokenización es más agresiva de lo que parece

`AUTHOR_NAME_CONFIG = TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])`
(`AuthorConsolidation.jl`) se usa para TODA la tokenización de nombres en el pipeline.
Comportamientos confirmados empíricamente, no asumidos:

- **`del_punc=true` trata el guión exactamente como un espacio.** `"Sanchez-Martinez"`
  tokeniza idéntico a `"Sanchez Martinez"` (`["sanchez", "martinez"]`). Esto significa que
  insertar un guión en TEXTO CRUDO no logra nada — si se quiere que dos tokens queden
  pegados como una sola unidad (p. ej. un apellido compuesto canónico "de-la-cruz"), hay
  que unirlos DESPUÉS de tokenizar, como un solo elemento de `Vector{String}` que contiene
  un guión literal — nunca como una edición del string antes de tokenizar.
- **`del_punc=true` también desenvuelve paréntesis.** `"Anaya, A. (Alejandro)"` produce
  `"alejandro"` como su propio token (el paréntesis se elimina, el contenido queda). Esto es
  señal útil para nombres en formato de cita (`_qgram_name_tokens` explícitamente NO quita
  paréntesis antes de tokenizar, a diferencia de `_name_tokens` que sí los quita vía
  `_strip_parenthetical` — dos funciones del mismo módulo con esta diferencia deliberada,
  cada una calibrada para su propio consumidor).
- **Cualquier URL se normaliza a un token literal `"url"`; cualquier corrida de dígitos, a
  `"0"`.** Dos nombres-basura DISTINTOS (dos ORCIDs distintos, por ejemplo) colapsan a los
  MISMOS tokens tras tokenizar — la causa raíz de un bug real de producción (un blob de 117
  miembros bajo `full_key`/`initials_key`). La lección: cualquier "nombre" que en realidad
  sea una URL/ORCID/ID debe filtrarse ANTES de tokenizar (ver `AC._is_garbage_name`), nunca
  confiar en que estos van a fallar naturalmente el matching después.
- **No hay protección propia contra "esto no es un nombre".** El tokenizador procesa
  fragmentos de texto largo (oraciones de tesis, citas bibliográficas completas, listas de
  instituciones) sin quejarse — simplemente produce muchísimos tokens. Si el pipeline asume
  "esto es un nombre de persona" (como `_split_given_surname` asume), un campo `creator`
  corrupto con 100+ tokens se parsea como un apellido gigantesco y sin sentido. Encontrado
  en vivo en un corpus real de 50 repos: fragmentos de 600+ caracteres capturados como
  "autor". Solución adoptada: un límite duro de tokens en `_is_garbage_name` (10 tokens) —
  ningún nombre humano real se acerca a eso.

### `Vocabulary`/`VectorModel`/`vectorize_corpus` — el patrón TFIDF clásico

Usado en `AC.compute_similarity_merges` para similitud de CONTENIDO (keywords, tópicos,
referencias citadas, instituciones — nunca el nombre):

```julia
voc = Vocabulary(AUTHOR_NAME_CONFIG, texts)          # vocabulario sobre una lista de textos
model = VectorModel(IdfWeighting(), TfWeighting(), voc)
vecs = vectorize_corpus(model, texts; verbose=false)  # Vector{SVec} disperso
db = VectorDatabase(vecs)
```

Lección de escala (no de la librería, sino de cómo se usa): esto funciona bien para miles de
perfiles, pero construir un `SearchGraph` sobre 300K+ perfiles y correr
`bichromatic_metricjoin` se cuelga por horas sin error ni progreso — no es un límite
documentado de la librería, es simplemente el punto donde este enfoque deja de ser viable
para este volumen de datos. No hay una talla de corpus "segura" conocida; se encontró por
prueba directa, no por documentación.

## SimilaritySearch.jl

### Distancias: `Dist.Seqs.DamerauLevenshtein()` — Metric vs SemiMetric importa

- Es **Damerau-Levenshtein restringida (OSA)**: Levenshtein más transposición de caracteres
  adyacentes como una CUARTA operación de edición, costo 1 (no costo 2, que es lo que cuesta
  simular una transposición como dos sustituciones bajo Levenshtein plano). Esto es lo que
  hace que `"rcuz"` (typo de transposición de `"cruz"`) quede a distancia 1 de `"cruz"`, no 2.
- **Es un `SemiMetric`, no un `Metric`** — no satisface estrictamente la desigualdad
  triangular. Esto importa DIRECTAMENTE para `BKT` (ver abajo), que depende de la
  desigualdad triangular para podar su búsqueda.
- **`SimilaritySearch.evaluate(dl, a, b)` acepta `AbstractString` directo desde la versión
  1.3.4** — antes de eso, solo tenía el método genérico que indexa por posición
  (`a[i]`/`b[i]`), lo cual truena con `StringIndexError` en contenido UTF-8 multi-byte (este
  corpus tiene nombres en cirílico/CJK reales). Si se ve ese error, la corrección NO es
  convertir a `Vector{Char}` manualmente (funciona, pero es trabajo extra) — es simplemente
  actualizar la versión de la librería.
- **La normalización de score debe decidirse con cuidado**: `1 - distancia/max(len(a),len(b))`
  hace que la MISMA distancia bruta signifique algo distinto según el largo del token — una
  distancia de 1 en una palabra de 4 letras es un cambio enorme (score 0.75), la misma
  distancia en una de 12 letras es casi nada (score 0.917). Para un umbral fijo (0.9, 0.2,
  etc.) que se aplica a palabras de largos MUY distintos, esto genera comportamiento
  contraintuitivo si no se piensa explícitamente — ver la nota de "radio del BKT" abajo.

### `BKT` — el índice de árbol BK, agregado a mitad de esta investigación

`SimilaritySearch.BKT(dist, db::VectorDatabase; checkmetric=false)` es un tipo real,
agregado por el autor de la librería DURANTE este trabajo (antes había que implementar un
BK-tree a mano). Construcción paralela automática vía `index!(bkt, ctx)`.

- **`checkmetric=false` es necesario para usar una `SemiMetric` como `DamerauLevenshtein`**
  — `BKT` normalmente exige un `Metric` verdadero (para que la poda por desigualdad
  triangular sea válida). El propio docstring de la librería documenta, con benchmark
  propio (diccionario de 20k palabras, 200 queries de typos), que usar `:damerau` con
  `checkmetric=false` no pierde NADA de recall (1.0) a radio 1, 2 y 3, a 7.9%/39%/68% del
  costo de un escaneo exhaustivo. Es una aproximación empíricamente segura para ESTE tipo de
  dato (palabras cortas, alfabeto latino/typos comunes), no una garantía universal.
- **El radio de búsqueda debe escogerse en función de qué tan bajo puede llegar tu fórmula
  de score, no arbitrariamente.** Con la normalización `1 - d/maxlen` y un umbral de conexión
  de 0.9, un radio de 1 alcanza para casi cualquier largo de palabra realista (`d<=1` da
  score`>=0.9` para palabras de 10+ letras); ir más allá de radio 2 casi nunca aporta nada
  para ESTE umbral específico, y si el radio se usa como filtro de candidatos antes de
  puntuar exacto, un radio demasiado angosto puede dar FALSOS NEGATIVOS para un umbral más
  permisivo en otra parte del mismo pipeline (encontrado al diseñar, no en producción: un
  radio pensado para el umbral de conexión 0.9 NO sirve de manera segura para el piso de
  contradicción 0.2 del mismo módulo — un par apenas fuera del radio no es "seguramente
  lejano" para un umbral tan bajo).
- **`GenericContext` es compartible entre búsquedas concurrentes** (la propia librería lo
  documenta: `search` con `BKT` no reserva memoria de trabajo propia) — pero por seguridad
  adicional (y siguiendo el patrón ya establecido en este código para `dl`/`cache`), se
  prefiere mintear un `GenericContext` Y una instancia de distancia NUEVA por lote/hilo en
  vez de compartir una sola global, para que ningún búfer interno se comparta entre hilos
  bajo ninguna circunstancia — barato de hacer, elimina la duda por completo.
- **`search(bkt, ctx, query, RadiusSorted(radio))` devuelve `.ids`/`.dists`**; usar
  `database(bkt, id)` para recuperar el objeto original. El propio query, si está en el
  árbol, se excluye manualmente comparando `cand == query` (la librería no lo excluye sola).

### `@BATCHES`/`@BEGIN`/`@BEGINBATCH`/`@LOOP`/`@END` — el idioma de paralelización de este proyecto

Patrón establecido y reusado en varios módulos (`NameVocabulary.Vocabulary`,
`PrecisionClustering.compute_precision_clusters`):

```julia
per_batch_edges = Vector{Vector{Tuple{Int,Int}}}()
@BATCHES minbatch begin
    @BEGIN
        per_batch_edges = [Tuple{Int,Int}[] for _ in 1:@nbatches()]
    @BEGINBATCH
        dl = Dist.Seqs.DamerauLevenshtein()      # estado mutable FRESCO por lote
        cache = Dict{Tuple{String,String},Float64}()
        bedges = per_batch_edges[@batchid()]
    @LOOP for i in eachindex(items)
        # ... trabajo, empujar a bedges ...
    end
end
```

- **`@batchid()` es estable y disjunto bajo CUALQUIER scheduler; `Threads.threadid()` NO lo
  es** bajo schedulers no-`:static` (puede alternar/migrar de hilo a mitad de ejecución) —
  usar siempre `@batchid()` para indexar estructuras per-lote, nunca `threadid()`.
- **Cualquier estado mutable que no deba compartirse entre lotes se mintea dentro de
  `@BEGINBATCH`**, no antes del `@BATCHES` ni una sola vez global — este es el patrón que
  hace que compartir un `Dict` de caché, una instancia de distancia, o un contexto de
  búsqueda sea seguro sin necesitar locks: cada lote tiene el suyo, nadie escribe la
  estructura de otro.
- **`@BATCHES` paraleliza SOLO entre iteraciones del `@LOOP`, nunca dentro de UNA
  iteración.** Si una sola iteración representa una cantidad de trabajo enorme (un bucket de
  17,000 nombres comparado O(n²) contra sí mismo), esa iteración entera cae en UN solo lote
  y domina el tiempo total sin importar cuántos hilos haya disponibles. La solución adoptada
  en este proyecto (`compute_precision_clusters`) fue una estrategia HÍBRIDA: los elementos
  pequeños se procesan todos juntos en un `@LOOP` (muchas iteraciones baratas, se reparten
  bien); los elementos grandes se procesan UNO A LA VEZ, pero cada uno con su PROPIO
  `@BATCHES` interno que reparte su trabajo O(n²) entre los mismos hilos.
- **La unión de resultados (union-find, acumulación de listas) se hace SIEMPRE después,
  secuencial, fuera de `@BATCHES`** — mutar una estructura compartida (como `parent` de
  union-find) desde varios lotes concurrentes causa condiciones de carrera; es más barato y
  más simple recolectar resultados por lote y aplicarlos en una sola pasada al final que
  sincronizar la mutación en vivo.
- **`getminbatch(n)`** da un tamaño de lote razonable dado el número de elementos — usarlo en
  vez de adivinar un número fijo.

### Otras estructuras probadas y su destino

- **`DictInvertedFile` + `Dist.Sets.Jaccard()` + `allknn`**: alternativa a la comparación
  exacta O(n²) dentro de un bucket, usando conjuntos de q-gramas en vez de comparar nombre
  contra nombre. Con poda `max_df` (una palanca de CORRECCIÓN, no solo de velocidad — podar
  demasiado agresivo destruye información real de nombre de pila, no solo ruido). Más lento
  que el loop directo para buckets chicos (el costo fijo de construir un índice por bucket
  no se paga solo hasta buckets grandes) — de ahí la estrategia híbrida por tamaño, la misma
  idea que terminó aplicándose también al enfoque de comparación directa.
- **`SearchGraph` + `Dist.NormCosine()`/`MaxMatchError`**: probado como alternativa a
  `DictInvertedFile` sin poda. Más rápido que un escaneo exhaustivo sin podar, pero más
  lento que el enfoque podado ya validado, y con error de aproximación real (5-10% de
  aristas de más/de menos contra el ground truth exacto) — `MaxMatchError` es un objetivo de
  optimización que el tuner busca, no una garantía dura.
- **Hashear q-gramas a `UInt64` en vez de mantenerlos como `String`**: gana modestamente
  (6-14%, no siempre reproducible entre corridas) — vale la pena solo como ajuste fino
  sobre un diseño ya elegido, no como decisión de diseño por sí sola.

## Lecciones generales (no específicas de ninguna librería, pero encontradas usándolas)

1. **Medir antes de optimizar, con la herramienta real, no con estimación de mano.** Varias
   veces la intuición sobre "dónde está el costo" resultó incompleta o equivocada (se asumió
   que el costo estaba en el tamaño de bucket cuando en realidad estaba en `join()`/
   recomputar `_surname_content` por par) — el perfilador de muestreo de Julia
   (`Profile.@profile` + `Profile.print`) encontró en minutos lo que la estimación manual no
   explicaba en varias iteraciones.
2. **Una aproximación "no encontrado = lejos" solo es segura si se conoce el rango de
   umbrales que consumen ese resultado.** Rechazada explícitamente una versión basada en
   radio de BKT para memoización por esta razón — ver la nota de radio arriba.
3. **El patrón "mintear estado mutable fresco por lote" es más simple y más rápido de
   razonar que cualquier alternativa con locks** — se usó consistentemente para distancias,
   contextos de búsqueda, y cachés de memoización a lo largo de todo este trabajo.
4. **Reusar infraestructura ya construida (BKT del vocabulario) en vez de construir una
   nueva estructura de índice para cada problema nuevo** fue considerado explícitamente
   (para acelerar `PrecisionClustering`) pero DESCARTADO cuando el análisis mostró que una
   memoización simple por par de palabras (sin ningún índice) alcanzaba el mismo beneficio
   con menos riesgo de aproximación — no toda aceleración necesita una estructura de datos
   nueva.
