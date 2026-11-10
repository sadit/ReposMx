# Índices de texto y base de datos

Notas de arquitectura sobre dónde guarda ReposMx sus índices de búsqueda, sus documentos y sus
relaciones entre autores, citas y tópicos. Desde el 2026-11-10 los cuatro índices de texto son
proyectos de [`SimilaritySearchEngine.jl`](https://github.com/sadit/SimilaritySearchEngine.jl)
(el motor). Antes eran índices BM25 escritos a mano sobre el RocksDB de ReposMx (`LazyBM25.jl`,
`VocabIO.jl`, `IndexShellIO.jl`). El plan de la migración está en `docs/plan-motor.md`.

## Disposición en disco

```
data/index/engine/docs_content/      proyecto del motor: documentos por contenido
data/index/engine/docs_refs/         proyecto del motor: documentos por sus referencias
data/index/engine/authors_name/      proyecto del motor: autores por nombre
data/index/engine/authors_profile/   proyecto del motor: autores por perfil
data/index/profile/                  perfil de texto reajustado al corpus
data/index/authors_consolidated/     perfiles de autor consolidados (TOML)
data/repos/rocksdb/                  RocksDB de ReposMx
```

Cada proyecto del motor tiene su propio RocksDB. El RocksDB de ReposMx guarda lo que el motor no
cubre: perfiles de autor crudos y consolidados (CF `authors`, `consolidated_authors`), enlaces
de autor a documento y de coautoría, referencias (`references`), tópicos (`topics`) y
estadísticas precalculadas (`stats`).

## Los cuatro proyectos

| proyecto | texto de cada elemento | `doc_id` | `meta` | partición |
|---|---|---|---|---|
| `docs_content` | `extract_index_text`: título ×3, autores ×2, colaboradores, palabras clave ×2, resumen, conclusiones | `"<repo>:<id>"` | el documento completo, más `year` | `repo` |
| `docs_refs` | los textos de las referencias del documento | `"<repo>:<id>"` | `repo` | `repo` |
| `authors_name` | `"<nombre> . <forma con iniciales>"` | id consolidado | `repos` | `repos` |
| `authors_profile` | nombre, palabras clave, tópicos y referencias citadas | id consolidado | `repos` | `repos` |

- Los cuatro son `FullTextEngine` con `BM25InvertedFile`.
- Los elementos de `docs_content` y `docs_refs` siguen el orden del corpus. Los de los dos
  proyectos de autores siguen el orden de `authors_consolidated`.
- Un documento sin referencias tiene un texto vacío en `docs_refs`. Nunca aparece en una
  búsqueda, y conserva el orden de los elementos.
- `doc_id` es único en cada proyecto. El nombre de un repositorio no contiene `:`, y
  `EngineIndex.split_doc_key` separa las dos partes aunque el id del documento contenga `:`.
- `docs_content` es el único lugar donde se guardan los documentos. `Search.get_document` los lee
  con `fetch_items`. Antes estaban en la CF `default` del RocksDB de ReposMx, bajo
  `doc:<repo>:<id>`.

## Vocabularios

Cada proyecto recibe su vocabulario como perfil (`BaseProfile`), construido en
`EngineIndex.index_profile`:

| proyecto | vocabulario | poda |
|---|---|---|
| `docs_content` | el perfil `es` reajustado al corpus (`refit_corpus_profile`) | `ndocs >= 3` |
| `docs_refs` | `Vocabulary` con el `TextConfig` del perfil reajustado | `ndocs >= 5` |
| `authors_name` | `Vocabulary(AUTHOR_NAME_CONFIG, nombres)` | sin poda |
| `authors_profile` | `Vocabulary` con el `TextConfig` del perfil reajustado | `ndocs >= 3` |

Un `TextProfile` construye su tokenizador con sus propias stopwords y sus propios lemas. Un
perfil hecho solo con el vocabulario tokenizaría sin los lemas con los que se contó ese
vocabulario. Por eso `index_profile` copia las stopwords y los lemas del perfil reajustado, y
verifica que el tokenizador resultante sea igual al del vocabulario. El perfil no lleva red de
expansión.

Los umbrales de poda vienen de mediciones sobre un subconjunto de 10 repositorios, documentadas
en las constantes `DOCS_REFS_MIN_NDOCS`, `DOCS_CONTENT_MIN_NDOCS` y `AUTHORS_PROFILE_MIN_NDOCS`
de `Indexing.jl`.

## Consultas

- Una consulta escrita por una persona usa `QueryPolicy(correction=:auto, expansion=false)`
  (`EngineIndex.QUERY_POLICY`).
- Antes del motor, ReposMx corregía solo las formas que difieren en mayúsculas y acentos y que se
  calculan desde el token escrito. El motor también usa el mapa de variantes que deriva del
  vocabulario. Por eso algunas consultas en mayúsculas y sin acentos encuentran ahora la forma
  acentuada: `REMOCION` se busca como `remoción`.
- `find_similar_authors_by_profile` y `find_similar_documents_by_references` convierten un texto
  largo en una consulta con sus 16 tokens de idf más alto (`Search.informative_tokens`). El motor
  recibe la lista de tokens y la busca sin tokenizarla otra vez, con
  `QueryPolicy(correction=:off, expansion=false)`. Unir los tokens en una cadena cambiaría algunos:
  un tokenizador que reemplaza dígitos convierte `A2` en `A0`.

## Filtros

- Un filtro de repositorio busca en la partición de ese repositorio. La partición tiene sus
  propias listas de postings y comparte el vocabulario, las estadísticas de BM25 y los vectores
  de documento con el índice global. Por eso un documento recibe el mismo puntaje en la
  partición y en el índice global.
- Un repositorio que el proyecto no tiene da cero resultados. `Search._ftsearch` atrapa
  `UnknownPartition` solo para eso.
- Los filtros de tipo, palabra clave y años son un predicado sobre el `meta` de cada candidato
  (`Search._document_filter`). El motor examina los mejores `candidates` resultados en orden de
  puntaje y devuelve los primeros que cumplen el predicado. `_ftsearch` empieza con un
  presupuesto de `8k` candidatos y lo multiplica por 4 mientras la página no se llena y el motor
  informa que el presupuesto detuvo la búsqueda (`SearchStats.candidates`).

## Construcción

- `reposmx index` (`Indexing.build_search_index`) construye los cuatro proyectos en
  `data/index/engine.building` y el RocksDB en `data/repos/rocksdb.building`. Al terminar, cada
  uno reemplaza al anterior. Una falla deja el índice y la base anteriores.
- Construir desde cero corrige dos defectos de la construcción anterior. Los conteos de
  coautoría ya no se suman a los de la construcción previa. Un documento que sale del corpus ya no
  deja claves.
- `reposmx index --reuse-authors` lee los perfiles consolidados que ya existen en
  `data/index/authors_consolidated` en lugar de agrupar otra vez los perfiles crudos. La
  agrupación tardó 2.2 horas el 2026-10-26. Esto es válido mientras el corpus no cambie, porque
  los perfiles nombran a los autores crudos por sus ids, y los ids dependen de todos los nombres.
- `reposmx consolidate-authors` (`Indexing.rebuild_authors_index`) agrupa otra vez los autores y
  reconstruye solo `authors_name` y `authors_profile`, en `data/index/engine.authors`.
- Las estadísticas (`stat:global`, `stat:repo:<repo>`) se calculan durante la construcción, con
  todos los documentos en memoria. El motor no tiene una operación que lea todos sus elementos.
- `populate-db` y `split-index` se eliminaron. `index` hace el trabajo de los dos.

## Notas de RocksDB que siguen vigentes

- `open_database` agrega a una base existente las column families que le faltan, en una apertura
  temporal antes de la apertura real. En modo de solo lectura abre solo las que existen, porque
  RocksDB no abre en ese modo una column family que no existe.
- `add_coauthor_link!` lee el contador actual antes de incrementarlo. Por eso la ingesta escribe
  un `WriteBatch` por documento (`Indexing._ingest_relations!`). Un lote con varios documentos
  contaría de menos un par de coautores que aparece dos veces en él. Los perfiles de autor no
  leen antes de escribir, y se escriben en lotes de `AUTHOR_BATCH_SIZE = 2000`.
- `compact_all!` se llama una vez al final de una construcción. Sin la compactación, la siguiente
  apertura tiene que reproducir el registro de escritura anticipada de toda la sesión.
