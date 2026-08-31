# ReposMx

**Motor de búsqueda y minería para los repositorios institucionales académicos de México.**

ReposMx cosecha, indexa y explora la producción académica (tesis, artículos, reportes técnicos)
publicada en los repositorios institucionales de universidades y centros de investigación mexicanos
que exponen el protocolo [OAI-PMH](https://www.openarchives.org/pmh/). Sobre ese corpus construye
búsqueda por texto completo (BM25), perfiles de autores con redes de coautoría, un corpus de citas
bibliográficas para análisis de acoplamiento bibliográfico, y búsqueda profunda por párrafos dentro
de los documentos.

Está escrito en [Julia](https://julialang.org/) sobre
[`SimilaritySearch.jl`](https://github.com/sadit/SimilaritySearch.jl),
[`TextSearch.jl`](https://github.com/sadit/TextSearch.jl) y
[`RocksDB.jl`](https://github.com/JuliaDB/RocksDB.jl.git), pensado para correr localmente sin
depender de servicios externos.

> **Sobre los datos:** este repositorio contiene únicamente el código. El corpus cosechado y los
> índices generados **no** se distribuyen aquí — se publicarán más adelante como artefactos
> adjuntos a un *release* de GitHub, una vez que el proceso de cosecha e indexado esté estable.

---

## Qué hace

- **Cosecha incremental** de metadatos vía OAI-PMH y descarga de los PDFs enlazados, con
  extracción de texto (`pdftotext`).
- **Indexación bilingüe (español/inglés)** de título, palabras clave, resumen y conclusiones con
  BM25, más un corpus separado de referencias bibliográficas extraídas de los PDFs.
- **Perfiles de autores**: producción por investigador, roles (autor, asesor, director), y red de
  coautoría.
- **Acoplamiento bibliográfico**: qué autores citan las mismas fuentes, para sugerir
  investigadores afines.
- **Búsqueda profunda por párrafos** dentro de un documento específico.
- **Persistencia embebida con RocksDB**: filtrado facetado (por año, tipo, repositorio,
  disciplina) en sub-milisegundos, sin depender de un servidor de base de datos externo.
- **Tres formas de usarlo**: shell interactiva en terminal, servidor web con API REST, o como
  librería de Julia.

---

## Requisitos

- Julia 1.10 o superior (probado en 1.12).
- `pdftotext` (parte de `poppler-utils`) para la extracción de texto de PDFs.

## Instalación

Clona el repositorio e instala las dependencias:

```bash
git clone https://github.com/sadit/ReposMx.git
cd ReposMx
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

### Como aplicación de Julia (recomendado)

ReposMx está empaquetado como una [Julia App](https://pkgdocs.julialang.org/v1/apps/), lo que te
da un comando `reposmx` instalado en tu `PATH`:

```bash
julia -e 'using Pkg; Pkg.Apps.develop(path=".")'
```

Asegúrate de que `~/.julia/bin` esté en tu `PATH`:

```bash
export PATH="$HOME/.julia/bin:$PATH"
```

A partir de aquí puedes invocar `reposmx` desde cualquier directorio. Si prefieres no instalarlo
globalmente, cualquier comando de este README funciona igual anteponiendo
`julia --project=. -m ReposMx` en lugar de `reposmx`.

---

## Mini manual

### 1. Preparar los datos

El ciclo de vida completo, repositorio por repositorio (usa las claves de `repos.json`, por
ejemplo `cimat`, `cicese`, `unam-iztacala`):

```bash
# Cosecha metadatos + descarga PDFs + extrae texto
reposmx update-db cimat cicese

# Construye el corpus estructurado y los índices de búsqueda
reposmx prepare-index cimat cicese

# Puebla la base de datos embebida (RocksDB) con documentos, autores, citas y facetas
reposmx populate-db cimat cicese

# Tubería equivalente a update-db + prepare-index en un solo paso
reposmx update-all cimat cicese
```

Sin argumentos de repositorio, estos comandos operan sobre todo el catálogo en `repos.json`.
También existen los pasos individuales por si necesitas re-ejecutar solo uno:
`harvest`, `download`, `parse`, `build-corpus`, `index`.

### 2. Consultar el estado

```bash
reposmx status        # cobertura por repositorio: registros cosechados, PDFs, documentos en corpus
reposmx info           # estadísticas globales del corpus
reposmx info cimat     # estadísticas de un repositorio específico
```

### 3. Buscar

Búsqueda directa desde terminal:

```bash
reposmx search "redes neuronales" --top 10
```

O el modo interactivo, que mantiene los índices en memoria para respuestas instantáneas:

```bash
reposmx
# equivalente: reposmx shell
```

Dentro de la shell:

| Comando | Qué hace |
| :--- | :--- |
| `<texto>` (escribir directo) | Busca en títulos, palabras clave, resúmenes y conclusiones. |
| `/doc <N>` | Abre la ficha completa del resultado `N`. |
| `/find <consulta>` | Busca por párrafos dentro del documento abierto. |
| `/in <N> <consulta>` | Busca por párrafos dentro del resultado `N`. |
| `/author <nombre>` | Busca perfiles de investigadores. |
| `/topic-authors <tema>` | Autores que más han publicado sobre un tema. |
| `/sim-authors <autor>` | Autores afines por acoplamiento bibliográfico. |
| `/cited <autor\|obra>` | Documentos que citan a un autor u obra dados. |
| `/refs [N]` | Bibliografía citada por un documento. |
| `/repo <nombre\|all>`, `/type <...>`, `/tag <...>` | Filtran las consultas siguientes. |
| `/top <N>` | Cambia el número de resultados devueltos. |
| `/wiki <on\|off>`, `/explain <concepto>` | Tarjetas de contexto desde Wikipedia (ES/EN). |
| `/status`, `/info [repo]` | Cobertura y estadísticas, sin salir de la shell. |
| `/? [comando]` | Ayuda general o de un comando específico. |
| `/exit` | Salir. |

### 4. Servidor web y API

```bash
reposmx serve --port 8000
```

Abre `http://localhost:8000` para la interfaz web (búsqueda, autores, citas, estadísticas y una
consola en el navegador que replica los comandos de la shell).

Endpoints principales del API REST:

```
GET /api/search?q=...&repo=...&doc_type=...&top=10
GET /api/authors?q=...&top=10
GET /api/authors/topic?q=...&top=10
GET /api/authors/similar?q=...&top=10
GET /api/references?q=...&repo=...&top=10
GET /api/document/references?doc_idx=123
GET /api/document/paragraphs?doc_idx=123&q=...
GET /api/info?repo=...
GET /api/stats
```

### 5. Como librería de Julia

```julia
using ReposMx

db = open_database()

doc = get_document(db, "cimat", "1008/100")
theses_2023 = get_documents_by_year(db, "2023"; limit=10)
auth_docs = get_author_documents(db, "Alfinio Flores")
refs = get_document_references(db, "cimat", "1008/100")

close_database(db)
```

---

## Estructura del proyecto

```
ReposMx/
├── bin/                 # Ejecutables reposmx / reposmx-server
├── src/
│   ├── ReposMx.jl        # Módulo raíz
│   ├── Config.jl         # Rutas y catálogo de repositorios
│   ├── OAI.jl             # Cosechador OAI-PMH
│   ├── Downloader.jl      # Descarga de PDFs
│   ├── Parser.jl          # Extracción de texto
│   ├── Corpus.jl          # Construcción de sub-corpus (documentos, autores, citas)
│   ├── TextModel.jl       # Modelo de texto bilingüe
│   ├── Indexing.jl        # Construcción de índices BM25
│   ├── DB.jl              # Persistencia embebida (RocksDB)
│   ├── Search.jl          # Motor de búsqueda
│   ├── Wikipedia.jl       # Tarjetas de contexto (ES/EN)
│   ├── TUI.jl             # Shell interactiva
│   ├── Server.jl          # Servidor HTTP y API
│   └── CLI.jl             # Despachador de subcomandos
├── assets/               # Frontend de la interfaz web
├── repos.json             # Catálogo de repositorios institucionales (OAI-PMH endpoints)
└── data/                  # Corpus e índices generados localmente (no se distribuye en git)
```

## Licencia

[MIT](LICENSE) — Copyright (c) 2024-2026 Eric S. Tellez.
