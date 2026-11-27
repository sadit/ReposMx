# Plan: RAG web de ReposMx

Fecha: 2026-11-26. Estado: decisiones tomadas el mismo día (sección 7); la fase 0 está hecha y la 1
empezó (sección 6).

## Objetivo

Un demo web de ReposMx con la misma funcionalidad que el demo del RAG ambiental
(`~/Projects/Legistlan/RAG-Medio-Ambiente/sistema/web`, PLAN.md 2.33 de ese proyecto):

- la búsqueda devuelve fuentes y, además, una respuesta corta que redacta un modelo de Qwen por API
  a partir de esas fuentes, con citas a cada una;
- las colecciones se buscan por separado: documentos por contenido, autores por nombre, citas;
- se puede buscar dentro de la producción indexada de un autor, por contenido;
- dos modos de búsqueda: BM25 y densa con Qwen3-Embedding-0.6B. Los documentos se codifican en
  Colab desde la terminal (`colab` CLI, A100 o G4), como en el RAG ambiental.

## 1. El demo del RAG ambiental (lo que se puede reutilizar)

| Pieza | Cómo está allá | Para ReposMx |
|---|---|---|
| Proceso | Julia 1.13, `SimilaritySearchEngine` embebido, Oxygen, sólo en 127.0.0.1 (`sistema/web/sirve.sh`) | igual; la app `reposmx` ya corre en 1.13.3 |
| Colecciones | por colección, un proyecto denso cuantizado (QR + SQ8, `Exhaustive`, coseno) y uno BM25 (`sistema/motor/construye.jl`); se busca una tarea por colección y se mezcla | mismo patrón por colección |
| Perfiles | `colecciones` y `benchmark`, para no mezclar colecciones que repiten documentos | aquí la separación es por tipo de cosa: documentos, autores, citas |
| Consultas densas | Ollama `qwen3-embedding:0.6b-fp16` con la instrucción de consulta antepuesta a mano (`src/ollama.jl`); al arrancar comprueba que reproduce los vectores guardados (coseno mínimo > 0.999) y compara el índice con la búsqueda exacta (`comprueba` en `src/acervo.jl`) | Ollama con una instrucción para el dominio académico, **sin comprobación al arrancar** (decisión 7): Colab se compara una vez con Ollama antes de codificar, y el índice con la exacta en la evaluación |
| Generador | API compatible con OpenAI en flujo (`src/generador.jl`): Qwen Cloud, plan Lite, `qwen3.6-flash`. Configuración en `datos/web/generador.env` (fuera de git). Lee los 6 primeros fragmentos, cita con `[id]` y los fragmentos van como `<fragmento id="N">`. Si la API está saturada, reintenta. Respaldo local: Ollama `qwen3:4b-instruct` | reutilizable casi tal cual; sólo cambia el prompt de sistema |
| Conversación | pasos con su búsqueda, su respuesta y sus fuentes; citas numeradas de corrido; preguntas para seguir tras la marca `<preguntas>` (`src/conversacion.jl`, `estaticos/redaccion.js`) | reutilizable |
| Sesiones de ejemplo | RocksDB del demo, guardadas a mano con `guarda.sh` | reutilizable |
| Dos caras | JSON (`src/api.jl`) y HTML (`src/paginas.jl`, htmx + Alpine + Tailwind) sobre las mismas funciones (`src/acervo.jl`) | igual |
| Codificación masiva | `emb/codifica_v2_cli.sh` (`sube`, `corre`, `baja`) con `emb/codifica_v2_colab.py`: sentence-transformers fp16, lotes por presupuesto de tokens, valida contra vectores locales antes de codificar, vectores fp16 sin normalizar en parquet | reutilizable cambiando las entradas |
| Publicación | Portero-Demos (Caddy en 127.0.0.1:8700) más ngrok, con prefijo `/ambiental` | otro prefijo, por ejemplo `/reposmx` |

Medido allá: Qwen3-Embedding-0.6B codifica de 40 a 48 mil tokens por segundo en A100 y unos 12 mil en
L4 (PLAN.md 2.3 de ese proyecto). En G4 no hay medición.

## 2. Inventario de ReposMx (2026-11-26)

### Datos

| Qué | Cantidad |
|---|---|
| Repositorios | 96 (`repos.json`) |
| Documentos en el corpus | 472,161 |
| Con resumen | 372,153 (369 millones de caracteres, unos 990 por resumen) |
| Títulos | 38 millones de caracteres |
| Con texto completo extraído del PDF | 70,677 (10.1 GB de texto, unos 143 KB por documento) |
| Citas bibliográficas | 3,972,939 |
| Autores | 447,279 perfiles crudos, agrupados en 234,624 consolidados |

### Índices (todos BM25, en `data/index/engine`, 3.1 GB, más RocksDB de 2.5 GB)

| Proyecto | Texto de cada elemento | Partición |
|---|---|---|
| `docs_content` | título ×3, autores ×2, colaboradores, palabras clave ×2, resumen, conclusiones (`extract_index_text`) | `repo` |
| `docs_refs` | los textos de las citas del documento | `repo` |
| `authors_name` | nombre y su forma con iniciales | `repos` |
| `authors_profile` | nombre, palabras clave, temas y citas | `repos` |

No hay vectores densos, ni índice del texto completo. La búsqueda por párrafos dentro de un documento
arma un BM25 en memoria por petición (`search_document_in_depth`).

### Servidor y página actuales

- `src/Server.jl`: HTTP.jl, sirve `assets/` y rutas JSON: `/api/search`, `/api/authors`,
  `/api/authors/{topic,similar,network,docs}`, `/api/references`,
  `/api/document/{references,similar_refs,paragraphs}`, `/api/stats`, `/api/info`, `/api/cli/execute`
  y `/file`.
- `assets/`: JavaScript sin marco, con pestañas de documentos, autores, citas, estadísticas y consola.
- Ya existe la producción de un autor (`get_author_documents`, por los enlaces autor-documento de
  RocksDB), pero no se puede buscar por contenido dentro de ella.
- No hay generación de respuestas, conversación ni sesiones.

### Problemas del demo actual (el 1, 2, 3 y 5 se resolvieron en la fase 0; el 4 se queda por la decisión 3)

1. **`/file?path=` entrega cualquier archivo legible del disco.** La ruta absoluta viene del
   cliente y sólo se comprueba `isfile`. Hay que servir el PDF por `repo` e `id` del documento.
2. **Escucha en `0.0.0.0` por omisión** (`start_server`). El RAG ambiental escucha sólo en
   127.0.0.1 y sale por el portero.
3. **Cada búsqueda de la página manda la consulta a Wikipedia** (`wiki=true` en `assets/js/search.js`).
   La consulta del visitante sale a un servicio externo sin aviso.
4. **`docs_content` indexa los nombres de los autores**, con peso doble. Una búsqueda por contenido
   mezcla documentos *de* una persona con documentos *sobre* el tema. Es justo lo que se quiere
   separar.
5. **No hay liga a la fuente.** El corpus no guarda la URL del registro (el `dc:identifier` http del
   XML OAI); sólo la ruta local del PDF. La respuesta necesita una liga verificable por fuente (como
   `liga` en el RAG ambiental).

### Tipos de documento (2026-11-26)

Contados a partir de todos los `dc:type` de cada registro (`experiments/rag_web/tipos_documento.py`). El
campo `type` del corpus (`Corpus.normalize_doc_type`) los reduce a seis valores y deja la mitad en
«Documento Académico»; es el que muestran hoy la web y los filtros.

| Tipo | Registros | % | Con texto completo | Repositorios | De dónde viene sobre todo |
|---|---:|---:|---:|---:|---|
| Artículo | 76,557 | 16.2 | 17,217 | 75 | |
| Tesis de maestría | 69,821 | 14.8 | 22,679 | 67 | |
| Carta o documento de archivo | 43,537 | 9.2 | 0 | 3 | itesm (43,527) |
| Imagen, mapa, audio o video | 42,992 | 9.1 | 0 | 6 | itesm (39,673): fotografías |
| Sin tipo | 39,249 | 8.3 | 1,542 | 66 | unam-filos (15,227), unam-icmyl (9,441), itesm (7,283) |
| Texto sin especificar | 37,767 | 8.0 | 2,198 | 14 | itesm (22,807), uaaan (10,709) |
| Tesis de licenciatura | 30,799 | 6.5 | 8,554 | 28 | |
| Evento | 26,787 | 5.7 | 0 | 1 | unam-ssn (sismos del Servicio Sismológico Nacional) |
| Otro | 23,257 | 4.9 | 2,708 | 32 | ccg (7,432 datos de ortólogos), contribuciones a periódicos, proyectos terminales |
| Tesis de doctorado | 18,139 | 3.8 | 6,414 | 67 | |
| Tesis (sin nivel) | 11,328 | 2.4 | 463 | 12 | |
| Libro | 10,677 | 2.3 | 1,249 | 56 | |
| Capítulo de libro | 9,947 | 2.1 | 3,486 | 44 | |
| Reporte técnico o informe | 8,919 | 1.9 | 525 | 31 | |
| Tesis de especialidad | 7,757 | 1.6 | 900 | 19 | |
| Conjunto de datos | 6,754 | 1.4 | 0 | 7 | unam-geofisica (6,041), cimmyt-data (623) |
| Ponencia o memoria | 5,302 | 1.1 | 1,444 | 36 | |
| Preprint o documento de trabajo | 1,645 | 0.3 | 825 | 28 | |
| Reseña | 710 | 0.2 | 456 | 17 | |
| Patente | 187 | 0.0 | 17 | 16 | |
| Software | 30 | 0.0 | 0 | 2 | |
| **Total** | **472,161** | 100 | **70,677** | | |

Las tesis suman 137,844 (29 %) y los artículos 76,557 (16 %). Cerca de una cuarta parte no es producción
académica en texto (cartas, fotografías, sismos, conjuntos de datos), y casi todo eso viene de itesm, unam-ssn y
unam-geofisica; su ficha sí está en la densa.

## 3. Colecciones y modos

| Colección | Para qué | Modo |
|---|---|---|
| Documentos | por contenido: la ficha (título, autores, palabras clave, resumen) y las primeras y últimas partes del texto completo | **densa** (`docs_dense`) |
| Autores | por nombre | BM25 (`authors_name`): aquí la precisión importa |
| Referencias | obras citadas | BM25 (`docs_refs`, `search_references`): aquí la precisión importa |
| Perfil de autor | autores por tema | después: centroide de los vectores de sus documentos, medido (sección 5) |

BM25 se activa de inicio sólo donde la precisión es lo principal: autores y referencias. En el
contenido el modo es la densa. `docs_content` sigue existiendo (con los autores dentro, decisión 3)
y lo usan la línea de comandos y la página actual.

**Producción de un autor.** Primero se elige el autor en la colección de autores; después se busca
por contenido sólo en sus documentos. La producción de un autor es chica (de decenas a cientos de
documentos), así que se compara el coseno exacto contra los vectores de sus unidades
(`Dense.search_among_documents`, con los `Float32` que el proyecto conserva), sin índice. Los
documentos del autor salen de RocksDB (`get_author_documents_for_group`).

**Respuesta redactada.** Se busca en documentos (o en la producción de un autor). El generador lee
los N primeros resultados como `<fragmento id>` con título, autores, año, repositorio y texto, y
cita `[id]`. Cada fuente se cita con sus metadatos y la **liga al registro en su repositorio**; no
se comparten los archivos (decisión 8). La página muestra las fuentes de inmediato y la respuesta
llega en flujo. En la colección de autores no se redacta: se listan.

## 4. Unidades densas y Colab

Decisión 2: en la densa sólo entran la ficha de cada documento y, del texto completo, las primeras y
las últimas partes, que es donde están el resumen, la introducción, la discusión y las conclusiones.
La bibliografía no se codifica: sus referencias ya se extraen (`Corpus.extract_document_references`)
y se buscan con BM25.

- **Partes** (`src/Units.jl`): párrafos consecutivos hasta 2,000 caracteres, sin solape. El cuerpo
  empieza en el encabezado de resumen o introducción (si está en el primer 30 %) y termina en el de
  bibliografía (si está en el último 40 %). Se toman las 3 primeras unidades y las 3 desde el
  encabezado de conclusiones (o de discusión) en la segunda mitad, o las 3 últimas si no lo hay.
  Un encabezado vale sólo si lo sigue prosa (así no cuentan los del índice). Medido en 3,000
  documentos (`experiments/rag_web/mide_secciones.jl`): introducción en 61 %, conclusiones en 57 %,
  bibliografía en 60 %, ninguno de resumen, introducción ni conclusiones en 25 %.
- **Exportación** (`reposmx export-units`, `src/Dense.jl`, 2026-11-26): 829,090 unidades (457,219
  fichas, 205,047 de inicio y 166,824 de final), 729,103 textos distintos, 981 millones de
  caracteres, en 37 lotes en `data/index/dense/`.
- **Codificación** (`colab/codifica_cli.sh` y `colab/codifica_colab.py`, la receta del RAG
  ambiental): unos 280 millones de tokens, del orden de 1.6 h de A100. Antes de codificar, Colab se
  compara una vez con 64 vectores de Ollama (`validacion.jsonl`); si el coseno mínimo no pasa de
  0.999, no codifica.
- **Proyecto** (`Dense.build_dense_project`): `docs_dense` en `data/index/dense/engine/` (no junto a
  los otros cuatro: `index` reemplaza esa carpeta entera). Exhaustivo sobre vectores cuantizados a 8
  bits con rango global y rotación QR, coseno, particionado por repositorio, y conserva los vectores
  `Float32` para las comparaciones exactas. Unos 0.4 GB de códigos más 3.4 GB de vectores en disco.
- El corpus es bilingüe (español e inglés); Qwen3-Embedding es multilingüe. La instrucción de
  consulta (`Dense.QUERY_INSTRUCTION`) se mide con el conjunto de prueba.

## 5. Evaluación (las dos cuentas)

ReposMx no tiene un conjunto de prueba de relevancia de documentos. Propuesta, en el estilo de las
secciones 2.13 y 2.14 del RAG ambiental:

- **Búsqueda de un documento conocido**: el título, o una paráfrasis, como consulta; el documento de
  origen debe salir en los primeros k.
- **Preguntas generadas** con Qwen a partir de resúmenes de una muestra estratificada por
  repositorio y por disciplina. Se marcan los errores del modelo (acuerdo 14 de allá: operar bajo el
  supuesto de error).
- Cada medición densa reporta lado a lado el índice cuantizado y la búsqueda exacta sobre los mismos
  vectores, con el tiempo por consulta. Esto es parte de la evaluación, no del arranque del servicio.
- Perfil denso de autor (centroide): con autores de producción conocida, si la consulta por tema los
  encuentra contra `authors_profile`; y la brecha de similitud al vecino más cercano entre consultas y
  centroides (diagnóstico de fuera de distribución, notas globales).

## 6. Fases

| Fase | Contenido | Estado |
|---|---|---|
| 0. Higiene | sin `/file` ni rutas locales en la API web (`Server.PRIVATE_KEYS`); escucha en 127.0.0.1; Wikipedia sólo si se pide; `liga` del registro en el corpus y en `docs_content` (94 % de los registros la traen) | hecha (2026-11-26) |
| 1. Densa de documentos | partes (`Units`), exportación, codificación en Colab, proyecto `docs_dense`, consultas con Ollama | hecha (2026-11-26): 37 lotes en Colab (A100, colab/orquesta.sh; copia en Drive con colab/drive.sh), proyecto `docs_dense` de 701,588 partes de 329,717 documentos; índice contra exacta: recuperación@10 = 1.0 en 30 consultas (experiments/rag_web/denso_vs_exacta.jl), 116 ms contra 67 ms |
| 2. Cara web | módulo calcado de AmbientalWeb: colecciones (documentos densa; autores y referencias BM25), producción de autor, generador por la API de Qwen con citas y fuentes, respuesta en flujo | en curso: `web/` (ReposMxWeb) arriba en 127.0.0.1:8790/reposmx; documentos por palabras mientras no esté el denso; conversación con respuesta y preguntas para seguir; cuatro temas de color a prueba |
| 3. Evaluación | conjunto de prueba (sección 5), índice contra exacta | pendiente |
| 4. Perfil denso de autor | centroides, medidos | pendiente |
| 5. Conversación y publicación | pasos, preguntas para seguir, sesiones de ejemplo, `/reposmx` en Portero-Demos | pendiente |

## 7. Decisiones (2026-11-26)

1. **Forma del demo web**: una cara nueva calcada de AmbientalWeb (Oxygen, htmx, Alpine y Tailwind,
   con su generador, conversación y `redaccion.js`), sobre las funciones de ReposMx. La API JSON
   actual se conserva.
2. **Texto completo**: en la densa sólo las primeras partes y las del final de cada documento
   (resumen, introducción, discusión y conclusiones), además de extraer la bibliografía.
3. **Los autores se quedan en el índice de contenido** (`docs_content` y la ficha densa).
4. **Cupo de Qwen Cloud**: la misma llave y el mismo plan que el demo ambiental; es un demo de bajo
   uso.
5. **Publicación**: `/reposmx` bajo el mismo portero (Portero-Demos) y la misma dirección de ngrok.
6. **BM25 de inicio sólo donde la precisión es lo principal**: autores y referencias. En lo demás,
   la densa.
7. **Sin verificación de los embeddings al arrancar.**
8. **Los archivos no se comparten**: no hay forma de descargarlos desde la web. Se citan las fuentes
   (metadatos y liga al registro en su repositorio). Nuestra copia es para trabajar y analizar.
9. **Privacidad**: la consulta, las respuestas previas y los fragmentos salen hacia Qwen Cloud, y la
   página lo dice. No se guarda el texto de las consultas.
10. **Texto de las partes**: la página muestra la ficha (metadatos públicos) y el resumen del registro; las
    partes del texto completo las lee el modelo pero no se muestran (confirmado por el usuario, 2026-11-26).
    `REPOSMX_MOSTRAR_TEXTO=1` existe sólo para uso local.
11. **Aspecto**: tipo Solarized, quizá oscuro; se prueban cuatro temas (Solarized claro y oscuro, pizarra,
    clásico) con un selector en la barra y luego se decide (2026-11-26).
12. **Tipos de documento** (2026-11-26): el corpus clasifica con todos los `dc:type` de cada registro
    (`Corpus.DOC_TYPE_RULES`, tabla de la sección 2). Las cartas y documentos de archivo, las imágenes y
    demás medios, los eventos (sismos) y los conjuntos de datos (`Corpus.NON_TEXT_TYPES`) se quedan sólo como
    metadatos: en el corpus y en el índice de palabras, pero no en la densa ni en la colección de documentos
    de la web ni en lo que lee el modelo.
13. **Clasificación CTI por seguidores** (2026-11-26): el corpus guarda el área, el campo y la disciplina
    que declara cada repositorio (catálogos CTI de SECIHTI; `Catalogs.cti_levels`: campo y disciplina por el
    prefijo del código, área por el catálogo de campos). `docs_content` y `docs_dense` tienen un
    `PartitionFollower` por nivel (`EngineIndex.CTI_FOLLOWERS`, `disjoint=false`); la web filtra por
    cualquiera. Cobertura: área 29 %, campo 11 %, disciplina 7 % de los registros.
14. **La CTI segmenta, no se aprende** (2026-11-26): sirve para partir los índices tal como la declaran los
    repositorios, pero no como dato para entrenar ni para predecirla; quien publica tampoco sabe bien dónde
    poner su investigación. Se probó y se descartó inferirla (experiments/rag_web/cti_inferencia.jl):
    acierto 0.77 / 0.70 / 0.50 en área / campo / disciplina con vecinos, y peor con prototipos limpios; sólo
    el 51 % de las disciplinas declaradas coincide con su vecindario. Siguiente idea: las palabras clave
    (74 % de cobertura) como objetivo, para sacar meta-disciplinas.
15. **Meta-disciplinas** (2026-11-26; experiments/rag_web/metadisciplinas.jl): las palabras clave del vocabulario
    limpio (vocabulario_palabras_clave.py: 18,400 palabras de ≥ 5 documentos y ≥ 2 repositorios, sin nombres CTI,
    con los acentos rotos reparados) se representan por el promedio de los vectores de sus documentos; se quitan
    las dispersas (el 15 % menos coherente de las frecuentes: "mexico", "maestria", "general"); k-means esférico
    con K = 120 sembrado con `fft` de SimilaritySearch; `qwen3.8-flash` nombra cada grupo (español e inglés),
    lo describe y dice si es temático. Quedan 113 (se quitan los no temáticos y los de < 200 documentos). Cada
    documento de texto va al centro más cercano por su ficha, y al segundo si está a menos de 0.01 (18 % en dos).
    El denso tiene el seguidor `metadisciplina` (`Dense.METADISCIPLINE_FOLLOWER`); la web lo filtra (lista con
    filtro en Documentos) y tiene `/mapa`: el grafo (3 vecinos por centro y 3 pares con más documentos
    compartidos por nodo; 287 aristas) en canvas con D3, para navegar y buscar dentro de una meta-disciplina.
    Los nombres cambian de una corrida a otra (k-means y el modelo), así que la del 2026-11-26 (19:39) quedó como
    la oficial (indicación del usuario): `metadisciplinas/` en el repositorio (nombres, descripciones, centros,
    grafo y vocabulario; ver su README), copia en Drive. La asignación de los documentos sale de esos centros
    (`experiments/rag_web/asigna_metadisciplinas.jl`, que reproduce la de la corrida en el 100 % de los 329,717);
    el experimento ya sólo escribe en `data/index/dense/metadisciplinas-corrida/`.
