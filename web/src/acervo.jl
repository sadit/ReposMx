# El acervo: el índice de ReposMx (BM25 de documentos, autores y referencias, y la base RocksDB) y el proyecto
# denso de las partes de cada documento (docs/plan-rag-web.md), abiertos sólo para leer, y la búsqueda sobre
# ellos. Este archivo no sabe de HTTP: lo usan por igual la cara JSON y la cara HTML.
#
# Tres colecciones que se buscan por separado (decisión del usuario, 2026-11-26):
# - documentos: por significado (el denso: la ficha y las primeras y últimas partes del texto completo) o por
#   palabras (BM25 de la ficha). Dentro de la producción de un autor, la misma búsqueda restringida a sus
#   documentos.
# - autores: BM25 sobre los nombres de los perfiles consolidados; la precisión importa más que el significado.
# - referencias: BM25 sobre la bibliografía de cada documento.
#
# Los archivos de nuestra copia nunca salen de aquí: un resultado lleva metadatos, la liga del registro en su
# repositorio y el texto que lee el modelo, que la página muestra sólo si es de la ficha (ver `publico`).

const Search = ReposMx.Search
const Dense = ReposMx.Dense
const EngineIndex = ReposMx.EngineIndex
const SSE = SimilaritySearchEngine

const MODOS = (:densa, :bm25)
const NOMBRE_SECCION = Dict("ficha" => "ficha del registro", "inicio" => "inicio del texto", "final" => "final del texto")

struct ErrorCodificador <: Exception
    msg::String
end

struct Acervo
    motor::Search.SearchEngine
    denso::Union{Nothing,Dense.DenseIndex}
    cod::Dense.QueryEncoder
    repos::Vector{String}
    unidades::Int                  # del proyecto denso; 0 si no se sabe
    documentos::Int                # con ficha en el denso; 0 si no se sabe
    cti::Vector{Pair{String,Vector{@NamedTuple{name::String, items::Int}}}}   # nivel => valores, de los seguidores
    disciplinas::Vector{@NamedTuple{nombre::String, items::Int, area::String, campo::String}}   # para elegir, por su camino
    metas::Vector{Dict{String,Any}}         # las meta-disciplinas (metadisciplinas.json), por nombre
    meta_docs::Dict{String,Set{String}}     # clave => documentos, para filtrar la búsqueda por palabras
    grafo::Union{Nothing,Dict{String,Any}}  # metadisciplinas_grafo.json, para el mapa
end
tiene_metas(a::Acervo) = !isempty(a.metas)
nombre_meta(a::Acervo, clave) = (i = findfirst(g -> g["clave"] == clave, a.metas); i === nothing ? clave : string(a.metas[i]["nombre"]))

# La clasificación CTI (catálogos de SECIHTI) tal como la declaran los repositorios, por nivel
# (EngineIndex.CTI_FOLLOWERS): se busca en la partición de un seguidor del proyecto, con el mismo puntaje que la
# búsqueda global. Es un metadato declarado; no se infiere para los documentos que no la traen (decisión del
# usuario, 2026-11-26).
const NIVELES_CTI = ["area" => "Área", "campo" => "Campo", "disciplina" => "Disciplina"]
bonito(x::AbstractString) = uppercasefirst(lowercase(x))
sin_tilde(x) = lowercase(Unicode.normalize(String(x); stripmark=true))

tiene_denso(a::Acervo) = a.denso !== nothing
modos(a::Acervo) = tiene_denso(a) ? MODOS : (:bm25,)

"""
Abre el índice de `index_dir` y la base de `data_dir`. Se abre desde el hilo principal: reabrir un proyecto de
texto paraleliza por dentro (`@BATCHES`) y eso no admite correr desde una tarea. Los índices de autores y de
referencias se abren aquí y no en la primera consulta que los pida.
"""
function abre(; data_dir::AbstractString, index_dir::AbstractString, cod::Dense.QueryEncoder, metas_dir::AbstractString="", avisa=println)
    t = @elapsed begin
        motor = Search.SearchEngine(; index_dir, data_dir)
        motor.docs === nothing && error("no hay índice de documentos en $index_dir (reposmx index)")
        Search.ensure_authors_loaded!(motor)
        Search.ensure_docs_refs_loaded!(motor)
    end
    avisa("  BM25 de documentos, autores y referencias: $(round(t; digits=1)) s")
    t = @elapsed denso = Dense.open_dense(index_dir)
    unidades, documentos = 0, 0
    if denso === nothing
        avisa("  sin proyecto denso en $(Dense.dense_workdir(index_dir)): sólo búsqueda por palabras")
    else
        f = joinpath(Dense.dense_dir(index_dir), "proyecto.json")       # lo que dejó build_dense_project
        if isfile(f)
            r = JSON.parse(read(f, String))
            unidades = Int(get(r, "unidades", 0))
            documentos = Int(get(r, "fichas", 0))
        end
        avisa("  denso: $(unidades) partes de $(documentos) documentos, $(round(t; digits=1)) s")
    end
    # los valores de cada nivel, del proyecto en el que se busca por omisión (el denso, sin los tipos que se
    # quedan sólo como metadatos; si no está, el de palabras)
    # los valores de cada nivel, del proyecto en el que se busca por omisión (el denso, sin los tipos que se
    # quedan sólo como metadatos; si no está, el de palabras)
    h = denso === nothing ? motor.docs : denso.handle
    cti = [nivel => Dense.cti_values(h, nivel) for (nivel, _) in NIVELES_CTI]
    avisa("  clasificación CTI declarada: " * join(("$(length(v)) $(n)s" for (n, v) in cti), ", "))
    # para elegir una disciplina llegando por su área y su campo (el árbol de la CTI): cada una con su camino
    caminos = ReposMx.Catalogs.cti_paths()
    disciplinas = sort!([(nombre=x.name, items=x.items, area=first(c), campo=last(c))
                         for x in Dict(cti)["disciplina"] for c in get(caminos, x.name, [("", "")])]; by=x -> (x.area, x.campo, x.nombre))
    # las meta-disciplinas oficiales (metadisciplinas/ en el repositorio: nombres, descripciones y grafo) y la
    # asignación de cada documento (data/index/dense/metadisciplinas_documentos.jsonl, de sus centros); un documento
    # cae en una o dos. La densa tiene su seguidor; la de palabras se filtra aquí.
    dd = Dense.dense_dir(index_dir)
    metas, meta_docs, grafo = Dict{String,Any}[], Dict{String,Set{String}}(), nothing
    if isfile(joinpath(metas_dir, "oficial.json")) && isfile(joinpath(dd, "metadisciplinas_documentos.jsonl"))
        metas = sort!([Dict{String,Any}(String(k) => v for (k, v) in g) for g in JSON.parsefile(joinpath(metas_dir, "oficial.json"))["grupos"]];
                      by=g -> sin_tilde(string(g["nombre"])))
        for l in eachline(joinpath(dd, "metadisciplinas_documentos.jsonl"))
            r = JSON.parse(l)
            for c in r["metadisciplinas"]; push!(get!(Set{String}, meta_docs, string(c)), string(r["documento"])); end
        end
        f = joinpath(metas_dir, "grafo.json")
        isfile(f) && (grafo = Dict{String,Any}(String(k) => v for (k, v) in JSON.parsefile(f)))
        avisa("  meta-disciplinas: $(length(metas))$(grafo === nothing ? "" : ", con grafo")")
    end
    Acervo(motor, denso, cod, sort!(ReposMx.Storage.list_repo_names(; data_dir)), unidades, documentos, cti, disciplinas,
           metas, meta_docs, grafo)
end

function cierra(a::Acervo)
    a.denso === nothing || Dense.close_dense(a.denso)
    close(a.motor)
end

# ---------------------------------------------------------------------------------------------------------
# Documentos

struct Resultado
    repo::String
    doc_id::String                 # la parte ("<repo>:<id>#k") en la densa; el documento en BM25
    documento::String              # "<repo>:<id>"
    puntaje::Float32               # con lo que se ordenó (mayor es mejor)
    similitud::Union{Nothing,Float32}
    bm25::Union{Nothing,Float32}
    seccion::String                # ficha, inicio o final
    titulo::String
    cita::String                   # autores · año · tipo · institución
    liga::String                   # el registro en su repositorio
    resumen::String                # el resumen del registro (metadatos públicos)
    texto::String                  # lo que lee el modelo
end

"El texto de la parte se puede mostrar: los de la ficha son metadatos públicos del registro; los del texto completo, no."
publico(r::Resultado) = r.seccion == "ficha"

struct Autor                       # quién es la producción en la que se busca
    id::String                     # consolidated_id
    nombre::String
    documentos::Vector{String}     # "<repo>:<id>"
end

struct Respuesta
    consulta::String
    modo::Symbol
    repo::String                   # "" = todos
    cti::Union{Nothing,Pair{String,String}}   # nivel => valor; `nothing` = sin filtro
    meta::String                   # clave de la meta-disciplina; "" = sin filtro
    autor::Union{Nothing,Autor}
    resultados::Vector{Resultado}
    ms::Dict{String,Float64}
end

cadena(m, k) = (v = get(m, k, ""); v isa AbstractString ? String(strip(v)) : v === nothing ? "" : string(v))

function cita_de(m)
    cs = get(m, "creators", nothing)
    autores = cs isa AbstractVector && !isempty(cs) ? String[strip(string(c)) for c in cs] :
              String[strip(x) for x in split(cadena(m, "creator"), ';') if !isempty(strip(x))]
    a = length(autores) > 4 ? join(first(autores, 3), "; ") * " y otros" : join(autores, "; ")
    año = get(m, "year", nothing)
    join(filter(!isempty, [a, año === nothing ? "" : string(año), cadena(m, "type"), cadena(m, "publisher")]), " · ")
end

function resultado(m, doc_id, documento, puntaje, sim, bm, seccion, texto)
    Resultado(cadena(m, "repo"), doc_id, documento, puntaje, sim, bm, seccion, cadena(m, "title"), cita_de(m),
              cadena(m, "liga"), cadena(m, "description"), texto)
end

"La producción de un autor (por su id consolidado, o lo que mejor se le parezca): sus documentos."
function autor(a::Acervo, ref::AbstractString; limite::Int=5000)
    a.motor.db === nothing && return nothing
    p = Search.resolve_consolidated_profile(a.motor, ref)
    p === nothing && return nothing
    docs = ReposMx.DB.get_author_documents_for_group(a.motor.db, p["raw_names"]; limit=limite)
    Autor(String(p["consolidated_id"]), String(p["name"]),
          unique!([EngineIndex.doc_key_of(d["repo"], d["doc_id"]) for d in docs if !isempty(get(d, "repo", "")) && !isempty(get(d, "doc_id", ""))]))
end

function codifica(a::Acervo, consulta::AbstractString)
    try
        Dense.encode_query(a.cod, consulta)
    catch e
        throw(ErrorCodificador("Ollama no codificó la consulta en $(a.cod.url): $(sprint(showerror, e))"))
    end
end

"""
    busca(acervo, consulta; modo, repo, autor, k, por_documento) -> Respuesta

- `:densa`: el vector de la consulta contra las partes de cada documento (ficha, inicio y final), a lo más
  `por_documento` del mismo documento. Con `autor`, la comparación es exacta contra las partes de sus
  documentos.
- `:bm25`: palabras sobre la ficha (título, resumen, palabras clave y conclusiones del registro).

`repo` limita a un repositorio ("" = todos); con `autor` no se usa.
"""
function busca(a::Acervo, consulta::AbstractString; modo::Symbol=:densa, repo::AbstractString="",
               cti::Union{Nothing,Pair{String,String}}=nothing, meta::AbstractString="", autor::Union{Nothing,Autor}=nothing,
               k::Int=10, por_documento::Int=2)
    autor === nothing || ((cti, meta) = (nothing, ""))     # en la producción de un autor no se filtra por clasificación
    modo in modos(a) || throw(ArgumentError("modo no disponible: $modo"))
    ms = Dict{String,Float64}()
    part = isempty(repo) ? nothing : String(repo)
    resultados = Resultado[]
    if modo == :densa
        ms["codifica"] = 1000 * @elapsed q = codifica(a, consulta)
        ms["busca"] = 1000 * @elapsed hits = autor === nothing ?
            busca_densa(a, q, k, part, cti, meta, por_documento) :
            Dense.search_among_documents(a.denso, q, autor.documentos, k; per_document=por_documento)
        ms["textos"] = 1000 * @elapsed begin
            metas = Dict(something(it.doc_id, "") => it.meta for it in SSE.fetch_items(a.motor.docs, unique([h.document for h in hits])))
            for h in hits
                m = get(metas, h.document, nothing)
                m === nothing && continue
                push!(resultados, resultado(m, h.doc_id, h.document, h.similarity, h.similarity, nothing, h.seccion, h.texto))
            end
        end
    else
        # las cartas, fotografías, sismos y conjuntos de datos se quedan sólo como metadatos (Corpus.NON_TEXT_TYPES):
        # están en el índice de palabras pero no en esta colección ni en lo que lee el modelo
        enmeta = isempty(meta) ? nothing : get(a.meta_docs, meta, Set{String}())
        filtro0 = autor === nothing ? (_, m) -> m !== nothing && ReposMx.Corpus.is_text_document(cadena(m, "type")) :
            let docs = Set(autor.documentos)
                (_, m) -> m !== nothing && ReposMx.Corpus.is_text_document(cadena(m, "type")) &&
                          EngineIndex.doc_key_of(cadena(m, "repo"), cadena(m, "id")) in docs
            end
        filtro = enmeta === nothing ? filtro0 :
            (r, m) -> filtro0(r, m) && EngineIndex.doc_key_of(cadena(m, "repo"), cadena(m, "id")) in enmeta
        ms["busca"] = 1000 * @elapsed hits = cti === nothing ?
            Search._ftsearch(a.motor.docs, consulta, k; partition=autor === nothing ? part : nothing,
                             policy=EngineIndex.QUERY_POLICY, filter=filtro) :
            ftsearch_cti(a, consulta, k, cti, isempty(repo) ? filtro : (r, m) -> filtro(r, m) && cadena(m, "repo") == repo)
        ms["textos"] = 1000 * @elapsed for h in hits
            m = Search._hit_meta(a.motor.docs, h)
            m === nothing && continue
            d = something(h.doc_id, "")
            push!(resultados, resultado(m, d, d, -h.distance, nothing, -h.distance, "ficha", ReposMx.Units.record_text(m)))
        end
    end
    Respuesta(String(consulta), modo, String(repo), cti, String(meta), autor, resultados, ms)
end

"La densa con los filtros: la meta-disciplina por su seguidor y, si además hay disciplina, ésta como filtro del meta."
function busca_densa(a::Acervo, q, k, part, cti, meta, por_documento)
    isempty(meta) && return Dense.search_dense(a.denso, q, k; repo=part, cti, per_document=por_documento)
    f = cti === nothing ? nothing : let campo = Dict(ReposMx.EngineIndex.CTI_FOLLOWERS)[first(cti)], v = last(cti)
        (_, m) -> m !== nothing && v in get(m, campo, String[])
    end
    Dense.search_dense(a.denso, q, k; repo=part, cti="metadisciplina" => String(meta), filter=f, per_document=por_documento)
end

"BM25 en la partición `cti` (nivel => valor) del seguidor de `docs_content`; sin resultados si el valor no existe."
function ftsearch_cti(a::Acervo, consulta, k, cti, filtro)
    try
        v = SSE.open_follower(a.motor.docs, string(first(cti), "=", last(cti)))
        SSE.ftsearch(v, consulta, k; policy=EngineIndex.QUERY_POLICY, filter=filtro, candidates=max(20k, 200))
    catch e
        e isa SSE.UnknownPartition || rethrow()
        SSE.SearchResult[]
    end
end

# ---------------------------------------------------------------------------------------------------------
# Autores y referencias: listas, sin respuesta redactada.

"Perfiles de autor por nombre (BM25 sobre `authors_name`)."
function busca_autores(a::Acervo, consulta::AbstractString; repo::AbstractString="", k::Int=20)
    t = @elapsed r = Search.search_authors(a.motor, consulta; top=k, repo=isempty(repo) ? nothing : String(repo))
    r["authors"], 1000t
end

struct ConReferencias
    documento::String
    titulo::String
    cita::String
    liga::String
    total::Int                     # referencias del documento
    coinciden::Vector{String}      # las que comparten más palabras con la consulta
    bm25::Float32
end

palabras(s) = Set(w for w in split(lowercase(Unicode.normalize(String(s); stripmark=true)), r"[^\p{L}\p{N}]+") if length(w) > 2)

"Documentos cuya bibliografía coincide con la consulta (BM25 sobre `docs_refs`), con las referencias que mejor coinciden."
function busca_referencias(a::Acervo, consulta::AbstractString; repo::AbstractString="", k::Int=20, por_documento::Int=3)
    t = @elapsed begin
        hits = Search._ftsearch(a.motor.refs, consulta, k; partition=isempty(repo) ? nothing : String(repo),
                                policy=EngineIndex.QUERY_POLICY, filter=nothing)
        keys = [something(h.doc_id, "") for h in hits]
        metas = Dict(something(it.doc_id, "") => it.meta for it in SSE.fetch_items(a.motor.docs, keys))
        q = palabras(consulta)
        out = ConReferencias[]
        for (h, key) in zip(hits, keys)
            m = get(metas, key, nothing)
            m === nothing && continue
            refs = [cadena(r, "text") for r in get(m, "references", []) if r isa AbstractDict]
            filter!(!isempty, refs)
            puntos = [length(intersect(q, palabras(r))) for r in refs]
            orden = sortperm(puntos; rev=true)
            coinciden = [refs[i] for i in first(orden, por_documento) if puntos[i] > 0]
            push!(out, ConReferencias(key, cadena(m, "title"), cita_de(m), cadena(m, "liga"), length(refs), coinciden, -h.distance))
        end
    end
    out, 1000t
end
