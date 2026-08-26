# ReposMx 🇲🇽

> **Motor de búsqueda, minería y análisis multicapa para los Repositorios Institucionales y Académicos de México en Julia 1.12.**

`ReposMx` es una plataforma integral diseñada para cosechar, estructurar, clasificar, indexar y explorar de forma ultra rápida (en sub-milisegundos) más de **446,000 registros académicos**, **100,000 documentos PDF**, **3.9 millones de referencias bibliográficas** y **302,000 perfiles de investigadores** provenientes de 93 repositorios institucionales de universidades y centros de investigación de México (CIMAT, ITESO, CIDETEQ, CICESE, CICY, CIDE, CINVESTAV, UNAM, UAM, IPN, UMSNH, etc.).

---

## 🏛️ Características Principales

- **Arquitectura Multicapa con Sub-Corpus Trazables:**
  - **Corpus Principal (Metadatos & Resúmenes):** Indexación balanceada 50/50 bilingüe (Español / Inglés) con ponderación en títulos, materias/disciplinas, resúmenes y conclusiones extraídas de los manuscritos.
  - **Corpus de Autores y Colaboradores:** Perfiles de investigadores, directores y asesores, análisis de redes de coautoría, filiación institucional y perfiles temáticos.
  - **Corpus de Citas y Referencias Bibliográficas:** Citas bibliográficas extraídas de los PDFs con trazabilidad completa de procedencia para análisis de co-citación (*¿quién cita a quién?*).
  - **Corpus de Texto Completo y Búsqueda por Párrafos (In-Depth):** Segmentación semántica de PDFs en párrafos para formular preguntas o búsquedas puntuales dentro de un documento específico mediante micro-índices BM25 al vuelo.
- **Persistencia de Alto Rendimiento con RocksDB (`RocksDB.jl`):**
  - Almacenamiento embebido organizado en **6 Column Families** aisladas (`default`, `authors`, `references`, `facets`, `fulltext`, `stats`).
  - Consultas y filtrado facetado en sub-milisegundos mediante *Prefix Scans* en memoria y disco NVMe.
  - Ingestión transaccional masiva por lotes con `WriteBatch`.
- **Consultas Analíticas Avanzadas:**
  - Búsqueda de autores por **campo del conocimiento o disciplina** (`/topic-authors <tema>`).
  - Detección de autores afines mediante **Acoplamiento Bibliográfico / Bibliographic Coupling** (`/sim-authors <autor>`).
  - Exploración de la bibliografía estructurada de cualquier tesis o artículo (`/refs`).
  - Búsqueda en el corpus de citas bibliográficas (`/cited <autor|obra>`).
- **Integración con Wikipedia (ES / EN):**
  - Detección automática de conceptos clave y generación de tarjetas con explicaciones accesibles y enlaces para democratizar el acceso a conceptos científicos complejos.
- **Múltiples Interfaces de Acceso:**
  - **TUI Interactiva (Shell REPL con [`Term.jl`](https://github.com/FedeClaudi/Term.jl)):** Formato visual colorido con tablas, paneles y sistema de ayuda contextual (`/?` y `/? <cmd>`).
  - **Servidor Web y API REST (`HTTP.jl`):** Interfaz web moderna con pestañas de documentos, autores, citas y visor integrado de PDFs.
  - **CLI Scriptable:** Subcomandos modulares y tuberías todo-en-uno (`update-all`, `update-db`, `prepare-index`, `populate-db`, etc.).

---

## 🧱 Arquitectura del Sistema

```text
                                 ┌─────────────────────────────────┐
                                 │   Cosecha OAI-PMH & Archivos    │
                                 │ (Metadata XML + Descarga PDFs)  │
                                 └────────────────┬────────────────┘
                                                  │
                                                  ▼
                                 ┌─────────────────────────────────┐
                                 │      Extracción y Parsing       │
                                 │ (pdftotext, Dublin Core XML)    │
                                 └────────────────┬────────────────┘
                                                  │
                 ┌────────────────────────────────┼─────────────────────────────────┐
                 │                                │                                 │
                 ▼                                ▼                                 ▼
     ┌───────────────────────┐        ┌───────────────────────┐         ┌───────────────────────┐
     │    CORPUS PRINCIPAL   │        │   CORPUS DE AUTORES   │         │    CORPUS DE CITAS    │
     │ (Metadatos/Resúmenes) │        │   Y COLABORADORES     │         │ (Referencias Bibliog.)│
     ├───────────────────────┤        ├───────────────────────┤         ├───────────────────────┤
     │ • Title (peso 3.0)    │        │ • Nombre normalizado  │         │ • ref_id (único)      │
     │ • Keywords/Disciplinas│        │ • Rol (Autor/Asesor)  │         │ • doc_id & doc_title  │
     │ • Abstract/Resumen    │        │ • Perfil temático     │         │ • repo institucional  │
     │ • Conclusiones PDF    │        │ • Citas bibliográficas│         │ • Cita íntegra y año  │
     └───────────┬───────────┘        └───────────┬───────────┘         └───────────┬───────────┘
                 │                                │                                 │
                 ├────────────────────────────────┴─────────────────────────────────┤
                 ▼                                                                  ▼
     ┌───────────────────────┐                                          ┌───────────────────────┐
     │   Índices BM25 / NLP  │                                          │ Base de Datos Embebida│
     │ (Similarity / Text)   │                                          │      (`RocksDB.jl`)   │
     ├───────────────────────┤                                          ├───────────────────────┤
     │ • bm25.bin            │                                          │ • 6 Column Families   │
     │ • authors_topics.bin  │                                          │ • Filtros y Facetas   │
     │ • references_bm25.bin │                                          │ • Red de Coautoría    │
     └───────────┬───────────┘                                          └───────────┬───────────┘
                 │                                                                  │
                 └────────────────────────────────┬─────────────────────────────────┘
                                                  │
                       ┌──────────────────────────┴──────────────────────────┐
                       │                                                     │
                       ▼                                                     ▼
          ┌─────────────────────────┐                           ┌─────────────────────────┐
          │ Shell Interactivo (TUI) │                           │   Servidor Web y API    │
          │     (`Term.jl REPL`)    │                           │    (`reposmx-server`)   │
          └─────────────────────────┘                           └─────────────────────────┘
```

---

## 🗄️ Base de Datos Embebida (RocksDB)

`ReposMx` incorpora persistencia estructurada mediante **RocksDB** (`src/DB.jl`), permitiendo realizar consultas puntuales, filtrado por rangos y exploración de relaciones en sub-milisegundos sin requerir servidores de bases de datos externos.

### 🏛️ Column Families (Espacios de Nombres)

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ROCKSDB DATABASE                               │
├──────────────┬──────────────┬──────────────┬──────────────┬─────────────────┤
│   default    │   authors    │  references  │    facets    │    fulltext     │
│ (Metadata/   │  (Perfiles y │ (Citas y     │  (Filtros y  │   (Párrafos y   │
│  Documentos) │  Coautoría)  │  Grafos)     │   Rangos)    │  Texto Plano)   │
└──────────────┴──────────────┴──────────────┴──────────────┴─────────────────┘
```

| Column Family | Llaves Principales | Valor (Payload) | Caso de Uso |
| :--- | :--- | :--- | :--- |
| **`default`** | `doc:<repo>:<doc_id>`<br>`xml:<repo>:<doc_id>` | JSON estructurado del documento<br>String XML original | Recuperación directa de la ficha del documento y preservación de metadatos OAI. |
| **`authors`** | `auth:<norm_name>`<br>`auth_doc:<norm_name>:<repo>:<doc_id>`<br>`coauth:<norm_a>:<norm_b>` | JSON del Perfil<br>`{"role": "Autor"}`<br>`Int32` (conteo de coautorías) | Consulta de producción académica, directores de tesis y grafo de coautoría. |
| **`references`**| `ref:<ref_id>`<br>`doc_refs:<repo>:<doc_id>`<br>`cited_auth:<norm_author>:<ref_id>` | JSON de la cita bibliográfica<br>`Vector{String}` (IDs de citas)<br>`<repo>:<doc_id>` | Trazabilidad de citas, bibliografía citada y grafo de acoplamiento bibliográfico. |
| **`facets`** | `repo:<repo>:<doc_id>`<br>`year:<year>:<repo>:<doc_id>`<br>`type:<norm_type>:<repo>:<doc_id>`<br>`kw:<norm_kw>:<repo>:<doc_id>` | `""` (clave de índice) | **Prefix Scan instantáneo:** extrae todos los documentos de un año, tipo de publicación, materia o institución. |
| **`fulltext`** | `text:<repo>:<doc_id>`<br>`para:<repo>:<doc_id>:<idx>` | Texto completo<br>String del párrafo | Acceso a textos extensos y soporte para fragmentos relevantes. |
| **`stats`** | `stat:global`<br>`stat:repo:<repo>` | JSON consolidado de métricas | Panoramas estadísticos inmediatos (`reposmx info`). |

### 🛠️ Ejemplo de Uso Programático en Julia

```julia
using ReposMx

# Abrir base de datos embebida
db = open_database()

# 1. Recuperar documento por ID
doc = get_document(db, "cimat", "1008/100")
println(doc["title"])

# 2. Filtrado instantáneo por facetas (Prefix Scans)
theses_2023 = get_documents_by_year(db, "2023"; limit=10)
theses = get_documents_by_type(db, "tesis"; limit=10)
cimat_docs = get_documents_by_repo(db, "cimat"; limit=10)

# 3. Consultar publicaciones de un autor y sus roles
auth_docs = get_author_documents(db, "Alfinio Flores")

# 4. Consultar referencias bibliográficas de un documento
refs = get_document_references(db, "cimat", "1008/100")

# Cerrar conexión limpia
close_database(db)
```

---

## 🚀 Requisitos e Instalación

### Requisitos
- **Julia 1.10 - 1.12+**
- **pdftotext** (incluido en `poppler-utils` para extracción eficiente de PDFs)

---

### 📦 Instalación como Paquete / Aplicación Julia

`ReposMx` es un paquete y aplicación ejecutable estándar de Julia. Puedes instalarlo en tu entorno global o de desarrollo mediante el gestor de paquetes de Julia (`Pkg`):

#### Opción 1: Modo Desarrollo (`Pkg.develop`)
```julia
using Pkg
Pkg.develop(path="/ruta/a/Repositorios-Institucionales")
```
o desde el REPL de Julia presionando `]` :
```julia
pkg> dev /ruta/a/Repositorios-Institucionales
```

#### Opción 2: Instalación Directa (`Pkg.add`)
```julia
using Pkg
Pkg.add(url="https://github.com/sadit/Repositorios-Institucionales")
```

---

### 🖥️ Ejecución de la Aplicación

Una vez instalado en tu entorno de Julia, puedes ejecutar `ReposMx` de tres formas:

1. **Como comando ejecutable en tu terminal (Recomendado):**
   ```bash
   # Instala el launcher 'reposmx' en ~/.julia/bin o ~/.local/bin
   julia --project=. -m ReposMx install-cli
   
   # Ahora puedes usar 'reposmx' desde cualquier terminal:
   reposmx
   reposmx search "redes neuronales"
   reposmx info cimat
   ```

2. **Como módulo ejecutable de Julia 1.12 (`julia -m`):**
   ```bash
   julia -m ReposMx
   julia -m ReposMx search "inteligencia artificial"
   julia -m ReposMx info
   julia -m ReposMx serve --port 8000
   ```

3. **Desde el script local del repositorio:**
   ```bash
   ./bin/reposmx
   ./bin/reposmx search "inteligencia artificial"
   ```

---

## 💻 Subcomandos del CLI (`reposmx`)

El ejecutable `reposmx` incluye subcomandos para la gestión del ciclo de vida de los repositorios, la base de datos y la búsqueda.

```bash
# Ver ayuda general de subcomandos
reposmx --help
```

### Subcomandos Principales de Flujo

| Subcomando | Descripción |
| :--- | :--- |
| `reposmx` *(sin argumentos)* | Inicia directamente el **Shell Interactivo de Búsqueda (Term.jl)**. |
| `reposmx update-db [repos...]` | **1.** Cosecha incremental OAI-PMH + **2.** Descarga de PDFs + **3.** Extracción de texto. |
| `reposmx prepare-index [repos...]` | Construye el corpus estructurado y genera todos los índices bilingües y sub-corpus. |
| `reposmx populate-db [repos...]` | Puebla la base de datos embebida **RocksDB** (documentos, autores, citas, facetas). |
| `reposmx update-all [repos...]` | Tubería todo-en-uno: ejecuta `update-db` seguido de `prepare-index`. |
| `reposmx serve [--port N]` | Lanza el servidor HTTP y la interfaz web interactiva. |
| `reposmx info [repo]` | Muestra el informe estadístico detallado global o por repositorio. |
| `reposmx status` | Muestra el tablero de cobertura (registros cosechados, archivos descargados y documentos en corpus). |
| `reposmx install-cli` | Instala el script ejecutable `reposmx` en el `PATH` del usuario. |

### Subcomandos Modulares

```bash
# Cosechar metadatos vía OAI-PMH de repositorios específicos
reposmx harvest cimat centrogeo infotec

# Descargar PDFs enlazados
reposmx download cimat

# Extraer texto de los PDFs
reposmx parse cimat

# Construir corpus estructurado (metadatos, conclusiones y referencias)
reposmx build-corpus cimat

# Generar índices invertidos BM25
reposmx index cimat centrogeo

# Poblar la base de datos embebida RocksDB
reposmx populate-db cimat centrogeo infotec

# Búsqueda directa por terminal
reposmx search "sistemas de información geográfica" --top 5
```

---

## 🔍 Shell Interactivo (`Term.jl`)

Inicia el shell de búsqueda en cualquier momento:

```bash
reposmx
# o
reposmx shell
```

El índice BM25 y las estructuras de datos permanecen cargados en memoria RAM, permitiendo realizar consultas instantáneas en **< 5 milisegundos**.

```text
╭──── 🔍 ReposMx Shell ────────────────────────────────────────────────────────╮
│  ReposMx - Buscador Interactivo de Repositorios de México                    │
│  • Documentos indexados: 446,857                                             │
│  • Autores e investigadores: 302,857                                         │
│  • Citas / Referencias bibliográficas: 3,916,529                             │
│  • Repositorios disponibles: 93                                              │
╰──────────────────────────────────────────────────────────────────────────────╯
```

### Comandos del Shell

| Comando | Acción |
| :--- | :--- |
| **`/?`** o **/help** | Despliega la lista general de comandos organizada por categorías. |
| **`/? <comando>`** | Muestra la **ayuda específica, sintaxis y ejemplos** del comando consultado (ej. `/? info`, `/? topic-authors`, `/? sim-authors`, `/? find`). |
| **`/info [repo]`** | **Estadísticas detalladas:** informe global o por repositorio con desglose de publicaciones, disciplinas, autores y tipos. |
| **`<texto>`** *(escribir directo)* | Búsqueda global en títulos, keywords, resúmenes y conclusiones con score BM25. |
| **/doc <N>** | Abre la ficha detallada, autores, colaboradores, tipo de documento y abstract completo del resultado #N. |
| **/find <consulta>** | **Búsqueda profunda por párrafos:** segmenta el PDF actual en párrafos y rankea los pasajes relevantes. |
| **/in <N> <consulta>** | Busca párrafos dentro del documento resultado #N. |
| **/author <nombre>** | Busca perfiles de investigadores por nombre, número de publicaciones, coautores y repositorios. |
| **/topic-authors <tema>** | **Rankea autores por campo de conocimiento:** identifica a los investigadores que más han publicado en un tema. |
| **/sim-authors <autor>** | **Acoplamiento bibliográfico:** encuentra autores que citan las mismas fuentes, metodologías y referencias. |
| **/cited <autor\|obra>** | **Búsqueda en citas:** localiza qué tesis y artículos del repositorio citan a un autor, libro o revista. |
| **/refs [N]** | Muestra la lista de referencias bibliográficas citadas por el documento #N o el actual. |
| **/repo <nombre\|all>** | Filtra todas las consultas al repositorio institucional indicado (ej. `/repo cimat` o `/repo all`). |
| **/type <tesis\|articulo\|all>** | Filtra por tipología de documento (Tesis, Artículo, Libro, Reporte Técnico). |
| **/tag <keyword\|all>** | Filtra por palabra clave o disciplina. |
| **/top <N>** | Cambia la cantidad de resultados devueltos (ej. `/top 5`, `/top 20`). |
| **/wiki <on\|off>** | Activa o desactiva las tarjetas explicativas de conceptos de Wikipedia. |
| **/explain <concepto>** | Consulta directamente una explicación en Wikipedia (ej. `/explain aprendizaje profundo`). |
| **/status** o **/repos** | Tabla con el estado de los repositorios cosechados. |
| **/clear** | Limpia la pantalla de la terminal. |
| **/exit** o **quit** | Sale del buscador interactivo. |

---

## 🌐 Servidor Web e Interfaz Gráfica

Para lanzar la aplicación web y el API:

```bash
reposmx serve --port 8000
```

Accede desde tu navegador a `http://localhost:8000`.

### Funcionalidades de la Web UI
1. **Pestaña Documentos y Publicaciones:** Búsqueda facetada con filtros de repositorio, tipo de publicación (`Tesis`, `Artículo`, `Libro`) y tarjetas automáticas de conceptos Wikipedia.
2. **Pestaña Autores e Investigadores:** Búsqueda de personas académicas, número de publicaciones y redes de coautoría.
3. **Pestaña Corpus de Citas / Referencias:** Búsqueda bibliográfica con trazabilidad de origen.
4. **Búsqueda en Párrafos (In-Depth):** Botón *🔍 Buscar en párrafos* en cada tarjeta para consultar fragmentos dentro de un PDF extenso.
5. **Visor de Referencias:** Botón *📚 Referencias* para inspeccionar la bibliografía citada de cualquier trabajo.
6. **Visor de PDFs:** Enlace directo para abrir o descargar el documento original.

### Endpoints del API REST

- `GET /api/search?q=...&repo=...&doc_type=...&top=10`
- `GET /api/authors?q=...&top=10`
- `GET /api/references?q=...&repo=...&top=10`
- `GET /api/document/references?doc_idx=123`
- `GET /api/document/paragraphs?doc_idx=123&q=...`
- `GET /api/info?repo=...`
- `GET /api/stats`
- `GET /file?path=...`

---

## 📁 Estructura del Proyecto

```text
Repositorios-Institucionales/
├── bin/
│   ├── reposmx                 # Ejecutable del CLI y TUI
│   └── reposmx-server          # Ejecutable del servidor Web/HTTP
├── src/
│   ├── ReposMx.jl              # Módulo raíz del paquete
│   ├── Types.jl                # Tipos de datos (Record, AuthorProfile, ReferenceRecord, etc.)
│   ├── Config.jl               # Rutas estándar y catálogo de repositorios
│   ├── Storage.jl              # Gestión de almacenamiento por repositorio en disco
│   ├── OAI.jl                  # Cosechador OAI-PMH incremental
│   ├── Downloader.jl           # Descargador concurrente de PDFs y documentos
│   ├── Parser.jl               # Extracción de texto estructurado (pdftotext, PDFIO)
│   ├── Corpus.jl               # Construcción de sub-corpus (Metadatos, Autores, Citas, Párrafos)
│   ├── TextModel.jl            # Modelo bilingüe 50/50 español-inglés (TextConfig)
│   ├── DB.jl                   # Persistencia embebida RocksDB y Column Families
│   ├── Wikipedia.jl            # Integración de resúmenes de Wikipedia (ES/EN)
│   ├── Indexing.jl             # Generación de índices BM25 y micro-índices de párrafos
│   ├── Search.jl               # Motor de búsqueda (BM25, autores, citas, acoplamiento)
│   ├── TUI.jl                  # Shell interactivo con Term.jl y ayuda contextual
│   ├── Server.jl               # Servidor HTTP y aplicación web moderna
│   └── CLI.jl                  # Despachador de subcomandos
├── data/
│   ├── repos/                  # Un directorio por repositorio (metadata.jsonl, corpus.jsonl, files, text)
│   ├── index/                  # Índices serializados binarios (bm25.bin, authors.bin, references.bin)
│   └── rocksdb/                # Base de datos embebida RocksDB (6 Column Families)
├── repos.json                  # Catálogo oficial de repositorios institucionales
├── Project.toml                # Manifiesto de dependencias en Julia 1.12
└── README.md                   # Documentación completa del proyecto
```

---

## 📄 Licencia

Desarrollado bajo licencia de código abierto para la investigación y democratización del acceso a la producción académica y científica de México.
