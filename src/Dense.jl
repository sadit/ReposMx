"""
    Dense

The dense index of the documents (docs/plan-rag-web.md, sections 3 and 4). Three steps:

1. [`export_units`](@ref) writes, under `<index_dir>/dense/`, the units of every document (its
   record and the first and last parts of its full text, see `Units`) and their distinct texts,
   in shards of JSON lines for Colab.
2. `colab/codifica_cli.sh` encodes the texts with Qwen3-Embedding-0.6B in Colab and brings back
   one file of vectors per shard.
3. [`build_dense_project`](@ref) builds the dense project from the units and the vectors, and
   [`open_dense`](@ref), [`encode_query`](@ref), [`search_dense`](@ref) and
   [`search_among_documents`](@ref) search it.

Layout of `<index_dir>/dense/` (with the other derived data, not among the repositories of
`data_dir`):

| file | content |
|---|---|
| `unidades.jsonl` | one unit per line: `doc_id` (`"<repo>:<id>#<k>"`), `repo`, `id`, `k`, `seccion` (`ficha`, `inicio` or `final`), `sha` |
| `textos/textos-NNNNN.jsonl` | the distinct texts, `{"sha", "texto"}`, `shard_size` per file |
| `vectores/textos-NNNNN.f16` | written by Colab: the vectors of that shard in its order, Float16, 1,024 per text, not normalized |
| `resumen.json` | counts and the options of the export |

A text is identified by the SHA-1 of its UTF-8 bytes, and encoded once however many units share
it. Unit `k = 0` is the record (`Units.record_text`); the parts follow from `k = 1` in the order
of the text.
"""
module Dense

using JSON, SHA, Dates, LinearAlgebra, HTTP
import SimilaritySearchEngine
const SSE = SimilaritySearchEngine
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Storage: list_repo_names, load_corpus_records
using ..Units: record_text, fulltext_units
using ..Corpus: is_text_document
using ..EngineIndex: doc_key_of, CTI_FOLLOWERS, create_partition_followers!

export dense_dir, export_units, DOCS_DENSE, build_dense_project, DenseIndex, open_dense, close_dense,
       QueryEncoder, encode_query, search_dense, search_among_documents, cti_values, METADISCIPLINE_FOLLOWER, DIM

dense_dir(index_dir::AbstractString=DEFAULT_INDEX_DIR) = joinpath(index_dir, "dense")

const SECTION_NAME = Dict(:start => "inicio", :end => "final")

# The units of the documents of one repository, as (doc_id, repo, id, k, section, text).
function _repo_units(repo::AbstractString, data_dir; first_units, last_units, max_chars)
    out = Tuple{String,String,String,Int,String,String}[]
    for doc in load_corpus_records(repo; data_dir)
        id = string(get(doc, "id", ""))
        isempty(id) && continue
        is_text_document(string(something(get(doc, "type", ""), ""))) || continue      # sólo metadatos (Corpus.NON_TEXT_TYPES)
        key = doc_key_of(repo, id)
        rt = record_text(doc)
        isempty(rt) || push!(out, (key * "#0", repo, id, 0, "ficha", rt))
        f = get(doc, "fulltext_file", nothing)
        if get(doc, "has_fulltext", false) == true && f !== nothing && isfile(f)
            parts = fulltext_units(read(f, String); first_units, last_units, max_chars)
            for (k, (s, t)) in enumerate(parts)
                push!(out, ("$key#$k", repo, id, k, SECTION_NAME[s], t))
            end
        end
    end
    return out
end

"""
    export_units(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR, repos=nothing, first_units=3, last_units=3,
                 max_chars=2000, shard_size=20_000, force=false) -> Dict

Writes the units and the texts to encode under [`dense_dir`](@ref) (see the module
documentation), replacing a previous export. Returns the summary also written to `resumen.json`.
The vectors of a previous export do not match the new shards, so a previous export that already
has vectors is replaced only with `force=true`.
"""
function export_units(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR, repos::Union{Nothing,Vector{String}}=nothing,
                      first_units::Int=3, last_units::Int=3, max_chars::Int=2000, shard_size::Int=20_000,
                      force::Bool=false)
    vdir = joinpath(dense_dir(index_dir), "vectores")
    force || !isdir(vdir) || isempty(readdir(vdir)) ||
        error("$vdir already has vectors from Colab; pass force=true to replace that export")
    targets = repos === nothing ? list_repo_names(; data_dir) : repos
    per_repo = Vector{Vector{Tuple{String,String,String,Int,String,String}}}(undef, length(targets))
    Threads.@threads :dynamic for i in eachindex(targets)
        per_repo[i] = _repo_units(targets[i], data_dir; first_units, last_units, max_chars)
    end
    dir = dense_dir(index_dir)
    building = dir * ".building"
    rm(building; recursive=true, force=true)
    mkpath(joinpath(building, "textos"))
    seen = Set{String}()
    n_units = 0
    n_chars = 0
    by_section = Dict{String,Int}()
    shard = 0
    in_shard = 0
    tf = nothing
    open(joinpath(building, "unidades.jsonl"), "w") do uf
        for units in per_repo, (doc_id, repo, id, k, section, text) in units
            sha = bytes2hex(sha1(text))
            println(uf, JSON.json(Dict("doc_id" => doc_id, "repo" => repo, "id" => id, "k" => k,
                                       "seccion" => section, "sha" => sha)))
            n_units += 1
            by_section[section] = get(by_section, section, 0) + 1
            sha in seen && continue
            push!(seen, sha)
            n_chars += length(text)
            if tf === nothing || in_shard == shard_size
                tf === nothing || close(tf)
                shard += 1
                in_shard = 0
                tf = open(joinpath(building, "textos", "textos-$(lpad(shard, 5, '0')).jsonl"), "w")
            end
            println(tf, JSON.json(Dict("sha" => sha, "texto" => text)))
            in_shard += 1
        end
    end
    tf === nothing || close(tf)
    summary = Dict{String,Any}(
        "fecha" => string(now()), "repositorios" => length(targets), "unidades" => n_units,
        "por_seccion" => by_section, "textos_distintos" => length(seen), "caracteres" => n_chars,
        "lotes" => shard, "opciones" => Dict("first_units" => first_units, "last_units" => last_units,
                                             "max_chars" => max_chars, "shard_size" => shard_size))
    write(joinpath(building, "resumen.json"), JSON.json(summary, 2))
    old = dir * ".old"
    rm(old; recursive=true, force=true)
    isdir(dir) && mv(dir, old)
    mv(building, dir)
    rm(old; recursive=true, force=true)
    return summary
end

# ---------------------------------------------------------------------------------------------
# The dense project

const DIM = 1024
const DOCS_DENSE = "docs_dense"

"""
    dense_workdir(index_dir) -> String

The engine workdir of the dense project, inside [`dense_dir`](@ref). It is not the workdir of
the four text projects (`EngineIndex.engine_workdir`): `build_search_index` replaces that one
whole.
"""
dense_workdir(index_dir::AbstractString=DEFAULT_INDEX_DIR) = joinpath(dense_dir(index_dir), "engine")

# The vectors of one shard, as columns, and its texts, in the order of the shard.
function _shard(dir::AbstractString, name::AbstractString)
    texts = [JSON.parse(l) for l in eachline(joinpath(dir, "textos", name * ".jsonl")) if !isempty(strip(l))]
    raw = read(joinpath(dir, "vectores", name * ".f16"))
    length(raw) == 2 * DIM * length(texts) ||
        error("$name.f16 has $(length(raw) ÷ (2DIM)) vectors for $(length(texts)) texts")
    return reshape(reinterpret(Float16, raw), DIM, length(texts)), texts
end

"""
    build_dense_project(; index_dir=DEFAULT_INDEX_DIR, allow_partial=false, samplesize=200_000) -> Dict

Builds the project [`DOCS_DENSE`](@ref) under [`dense_workdir`](@ref) from the units and the
vectors of the export. Each unit is a `DenseItem` with its vector normalized, its `doc_id`
(`"<repo>:<id>#<k>"`) and a `meta` with `repo`, `id`, `k`, `seccion` and `texto`. The document
itself (title, authors, link) stays in `docs_content`, keyed by `"<repo>:<id>"`.

The index is the one of the dense collections of the environmental RAG: exact search over
vectors quantized to 8 bits with a global range and a QR rotation, cosine distance. The project
is partitioned by `repo`, and keeps the `Float32` vectors (`keep_vectors`), which
[`search_among_documents`](@ref) compares exactly. `samplesize` vectors estimate the range.

Each unit carries the CTI classification of its document (`areas`, `campos`, `disciplinas`, from the
corpus), and the project gets the partition followers of `EngineIndex.CTI_FOLLOWERS`. When the meta-disciplines
exist, each unit carries those of its document (`metadisciplinas`) and the project gets
[`METADISCIPLINE_FOLLOWER`](@ref).

The units of the documents that are not academic work in text (`Corpus.NON_TEXT_TYPES`, by the `type`
of the corpus in `data_dir`) are left out: those documents stay only in the text indices, with their
metadata. An export made before that rule may hold them; they are skipped here.

A unit whose text has no vector yet is an error, unless `allow_partial=true` (to try the
pipeline with some shards). The project is built in a new directory that replaces the previous
one at the end. Returns a summary, also written to `<dense_dir>/proyecto.json`.
"""
function build_dense_project(; index_dir=DEFAULT_INDEX_DIR, data_dir=DEFAULT_DATA_DIR, allow_partial::Bool=false,
                             samplesize::Int=200_000)
    dir = dense_dir(index_dir)
    excluded, cti = _corpus_facts(data_dir)
    metas = _metadisciplines(dir)          # "<repo>:<id>" => meta-disciplinas (experiments/rag_web/metadisciplinas.jl)
    names = sort([n[1:end-6] for n in readdir(joinpath(dir, "textos")) if endswith(n, ".jsonl")])
    have = filter(n -> isfile(joinpath(dir, "vectores", n * ".f16")), names)
    length(have) == length(names) || allow_partial ||
        error("only $(length(have)) of $(length(names)) shards have vectors; pass allow_partial=true to build with them")
    vec_of = Dict{String,Tuple{Int,Int}}()       # sha -> (shard, column)
    shards = Matrix{Float16}[]
    text_of = Dict{String,String}()
    for n in have
        V, texts = _shard(dir, n)
        push!(shards, V)
        for (j, t) in enumerate(texts)
            vec_of[t["sha"]] = (length(shards), j)
            text_of[t["sha"]] = t["texto"]
        end
    end
    workdir = dense_workdir(index_dir)
    building = workdir * ".building"
    rm(building; recursive=true, force=true)
    mkpath(building)
    spec = SSE.DenseVectors(SSE.Dist.Cosine(); index=SSE.Exhaustive(),
                            storage=SSE.Quantized(SSE.SQ(8; range=SSE.GlobalRange(samplesize=samplesize));
                                                  rotation=SSE.QRRotation(), keep_vectors=true))
    h = SSE.create_project(building, DOCS_DENSE, spec; partitions=SSE.PartitionBy("repo"))
    n_units = n_missing = n_excluded = n_fichas = 0
    t_append = t_index = t_followers = 0.0
    try
        batch = SSE.DenseItem[]
        flush_batch() = (t_append += @elapsed SSE.append_items!(h, batch); empty!(batch))
        for l in eachline(joinpath(dir, "unidades.jsonl"))
            isempty(strip(l)) && continue
            u = JSON.parse(l)
            if doc_key_of(u["repo"], u["id"]) in excluded
                n_excluded += 1
                continue
            end
            loc = get(vec_of, u["sha"], nothing)
            if loc === nothing
                n_missing += 1
                continue
            end
            v = Vector{Float32}(view(shards[loc[1]], :, loc[2]))
            nv = norm(v)
            (isfinite(nv) && nv > 0) || error("null or invalid vector for $(u["doc_id"])")
            v ./= nv
            meta = Dict{String,Any}("repo" => u["repo"], "id" => u["id"], "k" => u["k"], "seccion" => u["seccion"],
                                    "texto" => text_of[u["sha"]])
            key = doc_key_of(u["repo"], u["id"])
            c = get(cti, key, nothing)
            c === nothing || ((meta["areas"], meta["campos"], meta["disciplinas"]) = c)
            md = get(metas, key, nothing)
            md === nothing || (meta["metadisciplinas"] = md)
            push!(batch, SSE.DenseItem(v; doc_id=u["doc_id"], meta))
            n_units += 1
            u["k"] == 0 && (n_fichas += 1)
            length(batch) == 20_000 && flush_batch()
        end
        isempty(batch) || flush_batch()
        t_index = @elapsed SSE.index!(h)
        t_followers = @elapsed create_partition_followers!(h, isempty(metas) ? CTI_FOLLOWERS : [CTI_FOLLOWERS; METADISCIPLINE_FOLLOWER])
    finally
        SSE.close_project!(h)
    end
    old = workdir * ".old"
    rm(old; recursive=true, force=true)
    isdir(workdir) && mv(workdir, old)
    mv(building, workdir)
    rm(old; recursive=true, force=true)
    summary = Dict{String,Any}("fecha" => string(now()), "unidades" => n_units, "fichas" => n_fichas, "sin_vector" => n_missing,
                               "excluidas_por_tipo" => n_excluded,
                               "lotes_con_vectores" => length(have), "lotes" => length(names),
                               "segundos" => Dict("append" => round(t_append; digits=1), "index" => round(t_index; digits=1),
                                                 "seguidores" => round(t_followers; digits=1)))
    write(joinpath(dir, "proyecto.json"), JSON.json(summary, 2))
    return summary
end

"""
    METADISCIPLINE_FOLLOWER

The partition follower of the meta-disciplines (groups of keywords by meaning, named by an LLM; built by
`experiments/rag_web/metadisciplinas.jl` into `<dense_dir>/metadisciplinas_documentos.jsonl`): a document is in
one or two of them. The project gets it when that file exists.
"""
const METADISCIPLINE_FOLLOWER = ["metadisciplina" => "metadisciplinas"]

# The meta-disciplines of each document: "<repo>:<id>" => keys ("M001", ...); empty when there is no file.
function _metadisciplines(dir)
    f = joinpath(dir, "metadisciplinas_documentos.jsonl")
    out = Dict{String,Vector{String}}()
    isfile(f) || return out
    for l in eachline(f)
        r = JSON.parse(l)
        out[string(r["documento"])] = String[string(x) for x in r["metadisciplinas"]]
    end
    return out
end

# From the corpus: the documents that are not academic work in text, as "<repo>:<id>", and the CTI
# classification of each document that declares one ("<repo>:<id>" => (areas, campos, disciplinas)).
function _corpus_facts(data_dir)
    excluded = Set{String}()
    cti = Dict{String,NTuple{3,Vector{String}}}()
    lista(doc, k) = (v = get(doc, k, nothing); v isa AbstractVector ? String[string(x) for x in v] : String[])
    for repo in list_repo_names(; data_dir), doc in load_corpus_records(repo; data_dir)
        key = doc_key_of(repo, string(get(doc, "id", "")))
        is_text_document(string(something(get(doc, "type", ""), ""))) || push!(excluded, key)
        a, c, d = lista(doc, "areas"), lista(doc, "campos"), lista(doc, "disciplinas")
        isempty(a) && isempty(c) && isempty(d) || (cti[key] = (a, c, d))
    end
    return excluded, cti
end

"""
    DenseIndex

The open dense project, read-only. [`open_dense`](@ref) opens it and [`close_dense`](@ref)
closes it.
"""
struct DenseIndex
    handle::SSE.EmbeddedEngine
end

"""
    open_dense(index_dir=DEFAULT_INDEX_DIR) -> Union{DenseIndex,Nothing}

Opens the dense project read-only, or returns `nothing` when it has not been built.
"""
function open_dense(index_dir::AbstractString=DEFAULT_INDEX_DIR)
    w = dense_workdir(index_dir)
    isdir(joinpath(w, DOCS_DENSE)) || return nothing
    return DenseIndex(SSE.open_project(w, DOCS_DENSE; read_only=true))
end

close_dense(d::DenseIndex) = SSE.close_project!(d.handle)

# ---------------------------------------------------------------------------------------------
# Queries

"""
    QUERY_INSTRUCTION

What Qwen3-Embedding is told before a query. The documents were encoded without an
instruction, as the model asks. To be measured with the test set (docs/plan-rag-web.md,
section 5).
"""
const QUERY_INSTRUCTION = "Instruct: Dada una pregunta o un tema, recupera fragmentos de tesis, artículos y otros documentos académicos que lo traten\nQuery: "

"""
    QueryEncoder(url="http://127.0.0.1:11434", model="qwen3-embedding:0.6b-fp16"; max_cache=2000)

Encodes queries with Ollama, the same model the documents were encoded with in Colab
(`colab/codifica_colab.py` checks once, before encoding, that both give the same vectors). The
instruction is prepended by hand, and Ollama adds the end-of-text token itself. Repeated queries
come from a small cache.
"""
struct QueryEncoder
    url::String
    model::String
    cache::Dict{String,Vector{Float32}}
    lock::ReentrantLock
    max_cache::Int
end

QueryEncoder(url::AbstractString="http://127.0.0.1:11434", model::AbstractString="qwen3-embedding:0.6b-fp16"; max_cache::Int=2000) =
    QueryEncoder(String(rstrip(url, '/')), String(model), Dict{String,Vector{Float32}}(), ReentrantLock(), max_cache)

"""
    encode_query(enc, query) -> Vector{Float32}

The normalized vector of `query`, with [`QUERY_INSTRUCTION`](@ref) in front.
"""
function encode_query(enc::QueryEncoder, query::AbstractString)
    key = String(query)
    v = lock(() -> get(enc.cache, key, nothing), enc.lock)
    v === nothing || return v
    body = JSON.json(Dict("model" => enc.model, "input" => [QUERY_INSTRUCTION * key], "truncate" => true,
                          "options" => Dict("num_ctx" => 4096)))
    resp = HTTP.post(enc.url * "/api/embed", ["Content-Type" => "application/json"], body;
                     connect_timeout=5, request_timeout=60, status_exception=false)
    resp.status == 200 || error("Ollama answered $(resp.status) at $(enc.url): $(first(String(resp.body), 300))")
    e = JSON.parse(String(resp.body))["embeddings"]
    v = Float32.(only(e))
    n = norm(v)
    (length(v) == DIM && isfinite(n) && n > 0) || error("invalid query vector (dimension $(length(v)), norm $n)")
    v ./= n
    lock(enc.lock) do
        length(enc.cache) >= enc.max_cache && empty!(enc.cache)
        enc.cache[key] = v
    end
    return v
end

"""
    search_dense(d, qvec, k; repo=nothing, cti=nothing, per_document=2) -> Vector{NamedTuple}

The `k` units nearest to `qvec`, at most `per_document` of the same document (0: no limit),
in one repository's partition when `repo` is given. `cti = nivel => valor` (`"area"`, `"campo"` or
`"disciplina"`, see `EngineIndex.CTI_FOLLOWERS`, or `"metadisciplina"`) searches the partition of that
follower; with `repo` too, the repository is a filter over the meta. `filter(record, meta)` restricts further. A repository or a CTI value without items gives no
results. Each result has `doc_id` (of the unit), `document` (`"<repo>:<id>"`), `similarity` (cosine),
`seccion`, `k` and `texto`.
"""
function search_dense(d::DenseIndex, qvec::AbstractVector{<:Real}, k::Int; repo::Union{Nothing,AbstractString}=nothing,
                      cti::Union{Nothing,Pair}=nothing, filter=nothing, per_document::Int=2)
    n = per_document > 0 ? max(5k, 50) : k
    q = Vector{Float32}(qvec)
    hits = try
        if cti === nothing
            filter === nothing ? SSE.search(d.handle, q, n; partition=repo === nothing ? nothing : String(repo)) :
                SSE.search(d.handle, q, n; partition=repo === nothing ? nothing : String(repo), filter, candidates=20n)
        else
            v = SSE.open_follower(d.handle, string(first(cti), "=", last(cti)))
            f = repo === nothing ? filter :
                filter === nothing ? (_, m) -> m !== nothing && get(m, "repo", "") == repo :
                (r, m) -> m !== nothing && get(m, "repo", "") == repo && filter(r, m)
            f === nothing ? SSE.search(v, q, n) : SSE.search(v, q, n; filter=f, candidates=20n)
        end
    catch e
        e isa SSE.UnknownPartition || rethrow()
        SSE.SearchResult[]
    end
    chosen = SSE.SearchResult[]
    count = Dict{String,Int}()
    for r in hits
        (r.deleted || r.doc_id === nothing) && continue
        doc = _document_of(r.doc_id)
        per_document > 0 && get(count, doc, 0) >= per_document && continue
        count[doc] = get(count, doc, 0) + 1
        push!(chosen, r)
        length(chosen) == k && break
    end
    return _results(d, Tuple{String,Float32}[(r.doc_id, 1 - r.distance) for r in chosen])
end

"""
    cti_values(h, nivel) -> Vector{@NamedTuple{name::String, items::Int}}

The values of the CTI level `nivel` (`"area"`, `"campo"`, `"disciplina"`) in the project `h` (dense or
text), with how many items each holds; empty when the project has no such follower.
"""
function cti_values(h::SSE.EmbeddedEngine, nivel::AbstractString)
    f = try
        SSE.open_follower(h, String(nivel))
    catch e
        e isa SSE.UnknownFollower || rethrow()
        return @NamedTuple{name::String, items::Int}[]
    end
    return [(name=p.name, items=p.items) for p in SSE.partitions(f)]
end

_document_of(unit_id::AbstractString) = String(first(rsplit(unit_id, '#'; limit=2)))

function _results(d::DenseIndex, scored::Vector{Tuple{String,Float32}})
    isempty(scored) && return NamedTuple[]
    meta = Dict(something(it.doc_id, "") => it.meta for it in SSE.fetch_items(d.handle, [String(u) for (u, _) in scored]))
    return [(doc_id=String(u), document=_document_of(u), similarity=Float32(s),
             seccion=string(get(get(meta, u, Dict()), "seccion", "")), k=Int(get(get(meta, u, Dict()), "k", 0)),
             texto=string(get(get(meta, u, Dict()), "texto", ""))) for (u, s) in scored]
end

"""
    search_among_documents(d, qvec, documents, k; max_units=7, per_document=2) -> Vector{NamedTuple}

The `k` units nearest to `qvec` among the units of `documents` (`"<repo>:<id>"`, for example the
production of an author), compared exactly with the kept `Float32` vectors. A document has
units `#0` to `#max_units - 1` at most. The results are those of [`search_dense`](@ref).
"""
function search_among_documents(d::DenseIndex, qvec::AbstractVector{<:Real}, documents::AbstractVector{<:AbstractString}, k::Int;
                                max_units::Int=7, per_document::Int=2)
    ids = [string(doc, "#", j) for doc in documents for j in 0:max_units-1]
    items = SSE.fetch_items(d.handle, ids)
    q = Vector{Float32}(qvec)
    scored = Tuple{String,Float32}[]
    for it in items
        (it.doc_id === nothing || !(it.payload isa AbstractVector)) && continue
        push!(scored, (it.doc_id, dot(q, it.payload)))
    end
    sort!(scored; by=last, rev=true)
    chosen = Tuple{String,Float32}[]
    count = Dict{String,Int}()
    for (u, s) in scored
        doc = _document_of(u)
        per_document > 0 && get(count, doc, 0) >= per_document && continue
        count[doc] = get(count, doc, 0) + 1
        push!(chosen, (u, s))
        length(chosen) == k && break
    end
    return _results(d, chosen)
end

end # module Dense
