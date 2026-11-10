module Search

using TextSearch, JSON, JSON3
import SimilaritySearchEngine
const SSE = SimilaritySearchEngine
using ..Config: DEFAULT_INDEX_DIR, DEFAULT_DATA_DIR
import ..DB: get_author_documents, get_coauthors, get_document_references
using ..DB: Database, open_database, close_database, get_author_profile,
            get_consolidated_profile, get_consolidated_id_for_raw,
            get_author_documents_for_group, get_coauthors_for_group,
            get_topic_docs, get_topic_authors,
            intersect_topic_repo_docs, intersect_topic_repo_authors, normalize_author_name,
            get_documents_citing_author, get_stats
using ..EngineIndex: DOCS_CONTENT, DOCS_REFS, AUTHORS_NAME, AUTHORS_PROFILE, QUERY_POLICY, TOKENS_POLICY,
                     open_index, doc_key_of, split_doc_key
using ..Indexing: search_document_in_depth
using ..Wikipedia: explain_concept

export query_index, search_authors, find_similar_authors_by_profile, find_similar_documents_by_references,
       search_references, get_document_references, get_author_documents, get_coauthors,
       get_topic_elements, search_document_paragraphs, get_detailed_statistics, get_author_network,
       get_document, informative_tokens, SearchEngine

"""
    SearchEngine(; index_dir=DEFAULT_INDEX_DIR, data_dir=DEFAULT_DATA_DIR)

The four text indices (`EngineIndex`), opened read-only, and the RocksDB of ReposMx. A field is
`nothing` when that part has not been built. `docs_content` is opened here; the other three are
opened by the first query that needs them (`ensure_authors_loaded!`, `ensure_docs_refs_loaded!`).
"""
mutable struct SearchEngine
    db::Union{Database, Nothing}
    docs::Union{SSE.EmbeddedEngine, Nothing}
    refs::Union{SSE.EmbeddedEngine, Nothing}
    authors_name::Union{SSE.EmbeddedEngine, Nothing}
    authors_profile::Union{SSE.EmbeddedEngine, Nothing}
    index_dir::String
    data_dir::String
    stats_cache::Dict{Union{String, Nothing}, Dict{String, Any}}

    function SearchEngine(; index_dir=DEFAULT_INDEX_DIR, data_dir=DEFAULT_DATA_DIR)
        db_path = joinpath(data_dir, "rocksdb")
        db = @time "open_database" (isdir(db_path) ? open_database(db_path; read_only=true) : nothing)
        docs = @time "open docs_content" open_index(index_dir, DOCS_CONTENT)
        new(db, docs, nothing, nothing, nothing, String(index_dir), String(data_dir),
            Dict{Union{String, Nothing}, Dict{String, Any}}())
    end
end

function Base.close(engine::SearchEngine)
    for f in (:docs, :refs, :authors_name, :authors_profile)
        h = getfield(engine, f)
        h === nothing || SSE.close_project!(h)
        setfield!(engine, f, nothing)
    end
    if engine.db !== nothing
        close_database(engine.db)
        engine.db = nothing
    end
end

function ensure_authors_loaded!(engine::SearchEngine)
    engine.authors_name === nothing && (engine.authors_name = open_index(engine.index_dir, AUTHORS_NAME))
    engine.authors_profile === nothing && (engine.authors_profile = open_index(engine.index_dir, AUTHORS_PROFILE))
    return nothing
end

function ensure_docs_refs_loaded!(engine::SearchEngine)
    engine.refs === nothing && (engine.refs = open_index(engine.index_dir, DOCS_REFS))
    return nothing
end

"""
    get_document(engine::SearchEngine, repo, doc_id) -> Union{Dict{String,Any},Nothing}

The metadata of a document, read from the `meta` of `docs_content`. `nothing` when the index is
not built or holds no such document.
"""
function get_document(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString)
    engine.docs === nothing && return nothing
    items = SSE.fetch_items(engine.docs, [doc_key_of(repo, doc_id)])
    return isempty(items) ? nothing : first(items).meta
end

"""
    _hit_meta(h, hit) -> Union{Dict{String,Any},Nothing}

The `meta` of a search result of the project `h`, read by its internal id.
"""
_hit_meta(h::SSE.EmbeddedEngine, hit::SSE.SearchResult) = SSE.get_meta(h.project, hit._id; lazy=false)

"""
    _partition(repo) -> Union{String,Nothing}

The partition a repository filter names, or `nothing` for no filter.
"""
_partition(repo) = (repo === nothing || isempty(repo)) ? nothing : String(repo)

"""
    _ftsearch(h, query, k; partition, policy, filter) -> Vector{SearchResult}

`ftsearch` with the two rules ReposMx needs on top of it:

- A repository the partition table does not hold has no documents or authors, so it answers
  no results, as before the engine. `UnknownPartition` is caught only for that reason.
- With a `filter`, the candidate budget starts at `8k` and grows 4 times while the page is short
  and the engine reports that the budget stopped the search (`SearchStats.candidates`). The
  results are then those of the unbounded filtered search.
"""
function _ftsearch(h::SSE.EmbeddedEngine, query, k::Int; partition::Union{Nothing,String},
                   policy::QueryPolicy, filter)
    try
        filter === nothing && return SSE.ftsearch(h, query, k; partition, policy)
        stats = SSE.SearchStats()
        budget = 8k
        while true
            hits = SSE.ftsearch(h, query, k; partition, policy, filter, candidates=budget, stats)
            (length(hits) >= k || stats.candidates < budget) && return hits
            budget *= 4
        end
    catch e
        e isa SSE.UnknownPartition || rethrow()
        return SSE.SearchResult[]
    end
end

"""
    _document_filter(; keyword, doc_type, year_min, year_max) -> Union{Function,Nothing}

The predicate over the `meta` of a document for the filters of `query_index`, or `nothing`
when no filter is given. The type and the keyword match as substrings without regard to case.
A year range keeps only documents whose `meta["year"]` is known and inside the range.
"""
function _document_filter(; keyword, doc_type, year_min, year_max)
    kw = (keyword === nothing || isempty(keyword)) ? nothing : lowercase(keyword)
    dt = (doc_type === nothing || isempty(doc_type)) ? nothing : lowercase(doc_type)
    (kw === nothing && dt === nothing && year_min === nothing && year_max === nothing) && return nothing
    return function (record, meta)
        meta === nothing && return false
        dt === nothing || occursin(dt, lowercase(string(get(meta, "type", "")))) || return false
        if kw !== nothing
            any(k -> occursin(kw, lowercase(string(k))), get(meta, "keywords", String[])) || return false
        end
        if year_min !== nothing || year_max !== nothing
            y = get(meta, "year", nothing)
            y === nothing && return false
            year_min !== nothing && y < year_min && return false
            year_max !== nothing && y > year_max && return false
        end
        return true
    end
end

"""
    query_index(engine::SearchEngine, q::AbstractString; top::Int=10, offset::Int=0, repo=nothing, keyword=nothing, doc_type=nothing, year_min=nothing, year_max=nothing, include_wiki=false)

Executes a primary BM25 search over titles, abstracts, keywords and conclusions, with filters
and offset-based pagination. A repository filter searches that repository's partition; the
other filters are a predicate over each candidate's metadata (`_document_filter`).
"""
function query_index(
    engine::SearchEngine,
    q::AbstractString;
    top::Int=10,
    offset::Int=0,
    repo::Union{String, Nothing}=nothing,
    keyword::Union{String, Nothing}=nothing,
    doc_type::Union{String, Nothing}=nothing,
    year_min::Union{Int, Nothing}=nothing,
    year_max::Union{Int, Nothing}=nothing,
    include_wiki::Bool=false
)
    if engine.docs === nothing
        return Dict(
            "query" => q,
            "total_hits" => 0,
            "hits" => [],
            "wiki_concept" => nothing,
            "error" => "Search index not loaded. Run `reposmx prepare-index` first."
        )
    end

    t0 = time()
    offset = max(offset, 0)
    needed = offset + top
    # Peek one extra match beyond the requested page so we know whether a next page exists.
    target = needed + 1
    filter = _document_filter(; keyword, doc_type, year_min, year_max)
    res = _ftsearch(engine.docs, q, target; partition=_partition(repo), policy=QUERY_POLICY, filter)

    hits = Dict{String, Any}[]
    for item in res
        doc = _hit_meta(engine.docs, item)
        doc === nothing && continue
        title = get(doc, "title", "")
        desc = get(doc, "description", "")
        snippet = if !isempty(desc)
            first(desc, min(300, length(desc))) * (length(desc) > 300 ? "..." : "")
        else
            title
        end

        push!(hits, Dict(
            "doc_idx" => Int(item._id),
            "id" => doc["id"],
            "repo" => doc["repo"],
            "title" => title,
            "creator" => get(doc, "creator", ""),
            "contributor" => get(doc, "contributor", ""),
            "date" => get(doc, "date", ""),
            "description" => desc,
            "keywords" => get(doc, "keywords", String[]),
            "type" => get(doc, "type", ""),
            "file" => get(doc, "file", nothing),
            "has_fulltext" => get(doc, "has_fulltext", false),
            "reference_count" => get(doc, "reference_count", 0),
            "score" => -item.distance,
            "snippet" => snippet
        ))
    end

    has_more = length(hits) > needed
    page_hits = offset >= length(hits) ? Dict{String, Any}[] : hits[(offset + 1):min(needed, length(hits))]

    wiki_info = nothing
    if include_wiki && offset == 0 && !isempty(strip(q))
        wiki_info = explain_concept(q)
    end

    t1 = time()
    time_ms = round((t1 - t0) * 1000, digits=2)

    return Dict(
        "query" => q,
        "offset" => offset,
        "total_hits" => length(page_hits),
        "has_more" => has_more,
        "hits" => page_hits,
        "wiki_concept" => wiki_info,
        "time_ms" => time_ms
    )
end

"""
    resolve_consolidated_profile(engine::SearchEngine, author_ref::AbstractString)

Resolves `author_ref` — a short id (`AuthorConsolidation.assign_id`), a raw author string, or
anything close to one — to its consolidated profile. Tries `author_ref` directly as an id first
(cheap: a non-id string just misses, no format detection needed since ids and names never
collide in shape); then falls back to an exact raw-name lookup (`get_consolidated_id_for_raw`);
and only if both miss falls back to the top hit of the `authors_name` index itself (which is
exactly what it exists for: resolving an imprecise or partial name to the right author).
"""
function resolve_consolidated_profile(engine::SearchEngine, author_ref::AbstractString)
    engine.db === nothing && return nothing

    profile = get_consolidated_profile(engine.db, author_ref)
    profile !== nothing && return profile

    cid = get_consolidated_id_for_raw(engine.db, author_ref)
    profile = cid === nothing ? nothing : get_consolidated_profile(engine.db, cid)
    profile !== nothing && return profile

    ensure_authors_loaded!(engine)
    engine.authors_name === nothing && return nothing
    res = SSE.ftsearch(engine.authors_name, author_ref, 1; policy=QUERY_POLICY)
    isempty(res) && return nothing
    return get_consolidated_profile(engine.db, first(res).doc_id)
end

"""
    search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10, offset::Int=0, repo::Union{String, Nothing}=nothing)

Searches researcher and advisor profiles by name using the `authors_name` index. A repository
filter searches that repository's partition: the authors with documents in it.
"""
function search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10, offset::Int=0, repo::Union{String, Nothing}=nothing)
    ensure_authors_loaded!(engine)
    if engine.authors_name === nothing
        return Dict("query" => author_query, "total_hits" => 0, "authors" => [], "time_ms" => 0.0)
    end

    t0 = time()
    offset = max(offset, 0)
    needed = offset + top
    target = needed + 1
    res = _ftsearch(engine.authors_name, author_query, target; partition=_partition(repo),
                    policy=QUERY_POLICY, filter=nothing)
    results = Dict{String, Any}[]
    for item in res
        cid = item.doc_id
        auth = engine.db !== nothing ? get_consolidated_profile(engine.db, cid) : nothing
        auth === nothing && continue
        push!(results, Dict(
            "name" => auth["name"],
            "consolidated_id" => cid,
            "role" => get(auth, "role", "Autor"),
            "doc_count" => get(auth, "doc_count", 1),
            "repos" => get(auth, "repos", String[]),
            "coauthors" => get(auth, "coauthors", String[]),
            "keywords" => get(auth, "keywords", String[]),
            "score" => -item.distance
        ))
    end

    has_more = length(results) > needed
    page = offset >= length(results) ? Dict{String, Any}[] : results[(offset + 1):min(needed, length(results))]

    t1 = time()
    return Dict(
        "query" => author_query,
        "offset" => offset,
        "total_hits" => length(page),
        "has_more" => has_more,
        "authors" => page,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    informative_tokens(h, text::AbstractString; top_k_tokens::Int) -> Vector{String}

Tokenizes `text` against the vocabulary of the project `h` and keeps only the `top_k_tokens`
*rarest* tokens (lowest document frequency, i.e. highest IDF) — the rest are dropped before the
query ever reaches `ftsearch`, which searches the list as it is (`TOKENS_POLICY`).

This exists for the "turn a whole profile/reference-list into a query" pattern
(`find_similar_authors_by_profile`, `find_similar_documents_by_references`): those queries are
built from dozens of keywords/topic summaries/references, most of which are common words that
barely move a BM25 score but still cost a full posting-list evaluation each. IDF is exactly BM25's
own measure of "how much does this token matter" (`log(N/ndocs)`, monotonic in `ndocs`), so
keeping the lowest-`ndocs` tokens keeps the ones that actually drive the ranking.

The text is resolved with a `QueryPipeline()` without a variant map, as the indices of ReposMx
did before the engine. The result is a list of tokens rather than a string because tokenizing a
token again can change it (`A2` becomes `A0`).
"""
function informative_tokens(h::SSE.EmbeddedEngine, text::AbstractString; top_k_tokens::Int)
    voc = SSE.text_profile(h).model.voc
    bow = querybow(voc, query_tokens(voc, text, QueryPipeline()))
    ids = collect(keys(bow))
    if length(ids) > top_k_tokens
        ids = sort(ids; by=id -> voc.ndocs[id])[1:top_k_tokens]
    end
    return String[voc.token[id] for id in ids]
end

"""
    find_similar_authors_by_profile(engine::SearchEngine, author_name_or_norm::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing, top_k_tokens::Int=16)

Finds researchers with similar thematic lines, topics, and bibliography starting from a context
author. The query is the target's own profile (name + keywords + topic summaries + cited
references) trimmed to its `top_k_tokens` most informative tokens (see
[`informative_tokens`](@ref)) — a full untrimmed profile can run into the hundreds of distinct
tokens, most contributing nothing to the ranking. A repository filter searches that
repository's partition.
"""
function find_similar_authors_by_profile(engine::SearchEngine, author_name_or_norm::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing, top_k_tokens::Int=16)
    ensure_authors_loaded!(engine)
    if engine.authors_profile === nothing
        return Dict("author" => author_name_or_norm, "total_hits" => 0, "similar_authors" => [], "time_ms" => 0.0)
    end

    t0 = time()
    target_author = resolve_consolidated_profile(engine, author_name_or_norm)

    if target_author === nothing
        return Dict("author" => author_name_or_norm, "total_hits" => 0, "similar_authors" => [], "time_ms" => 0.0, "error" => "Autor no encontrado en el acervo")
    end

    target_cid = target_author["consolidated_id"]
    target_name = get(target_author, "name", author_name_or_norm)
    kws = get(target_author, "keywords", String[])
    topics = get(target_author, "topic_texts", String[])
    refs = get(target_author, "cited_references", String[])

    profile_text = "$target_name . $(join(kws, " , ")) . $(join(topics, " \n ")) . $(join(refs, " \n "))"
    tokens = informative_tokens(engine.authors_profile, profile_text; top_k_tokens)
    res = _ftsearch(engine.authors_profile, tokens, top + 1; partition=_partition(repo),
                    policy=TOKENS_POLICY, filter=nothing)

    results = Dict{String, Any}[]
    for item in res
        cand_cid = item.doc_id
        cand_cid == target_cid && continue

        cand_auth = engine.db !== nothing ? get_consolidated_profile(engine.db, cand_cid) : nothing
        cand_auth === nothing && continue

        push!(results, Dict(
            "name" => get(cand_auth, "name", cand_cid),
            "consolidated_id" => cand_cid,
            "role" => get(cand_auth, "role", "Autor"),
            "doc_count" => get(cand_auth, "doc_count", 1),
            "repos" => get(cand_auth, "repos", String[]),
            "keywords" => get(cand_auth, "keywords", String[]),
            "score" => -item.distance
        ))

        length(results) >= top && break
    end

    t1 = time()
    return Dict(
        "target_author" => target_name,
        "total_hits" => length(results),
        "similar_authors" => results,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    find_similar_documents_by_references(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString; top::Int=10, top_k_tokens::Int=16)

Finds documents sharing bibliographic coupling with a selected context document. The query is the
document's own reference list trimmed to its `top_k_tokens` most informative tokens (see
[`informative_tokens`](@ref)) — a document with dozens of references can otherwise touch hundreds
of distinct tokens (proper nouns, journal names, DOIs), most of them irrelevant to the ranking.
"""
function find_similar_documents_by_references(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString; top::Int=10, top_k_tokens::Int=16)
    ensure_docs_refs_loaded!(engine)
    if engine.refs === nothing || engine.docs === nothing || engine.db === nothing
        return Dict("doc_id" => doc_id, "total_hits" => 0, "similar_documents" => [], "time_ms" => 0.0)
    end

    t0 = time()
    doc_refs = get_document_references(engine.db, repo, doc_id)
    ref_texts = String[]
    for r in doc_refs
        if r isa AbstractDict
            push!(ref_texts, get(r, "text", ""))
        elseif r isa AbstractString
            push!(ref_texts, r)
        end
    end

    if isempty(ref_texts)
        # Fallback to document abstract/description
        doc = get_document(engine, repo, doc_id)
        if doc !== nothing
            push!(ref_texts, get(doc, "description", ""))
        end
    end

    query_str = join(ref_texts, " \n ")
    tokens = informative_tokens(engine.refs, query_str; top_k_tokens)
    res = SSE.ftsearch(engine.refs, tokens, top + 1; policy=TOKENS_POLICY)

    target_key = doc_key_of(repo, doc_id)
    results = Dict{String, Any}[]
    for item in res
        item.doc_id == target_key && continue
        cand_repo, cand_id = split_doc_key(item.doc_id)
        cand_doc = get_document(engine, cand_repo, cand_id)
        cand_doc === nothing && continue

        push!(results, Dict(
            "id" => cand_id,
            "repo" => cand_repo,
            "title" => get(cand_doc, "title", ""),
            "creator" => get(cand_doc, "creator", ""),
            "date" => get(cand_doc, "date", ""),
            "type" => get(cand_doc, "type", "Documento"),
            "reference_count" => get(cand_doc, "reference_count", 0),
            "score" => -item.distance
        ))

        length(results) >= top && break
    end

    t1 = time()
    return Dict(
        "context_doc" => "$repo:$doc_id",
        "total_hits" => length(results),
        "similar_documents" => results,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    search_references(engine::SearchEngine, query::AbstractString; top::Int=10, offset::Int=0, repo::Union{String, Nothing}=nothing)

Searches across the citations corpus to discover who cites a specific author, book, paper or
theory. A repository filter searches that repository's partition.
"""
function search_references(engine::SearchEngine, query::AbstractString; top::Int=10, offset::Int=0, repo::Union{String, Nothing}=nothing)
    ensure_docs_refs_loaded!(engine)
    if engine.refs === nothing || engine.docs === nothing
        return Dict("query" => query, "total_hits" => 0, "references" => [], "time_ms" => 0.0)
    end

    t0 = time()
    offset = max(offset, 0)
    needed = offset + top
    target = needed + 1
    res = _ftsearch(engine.refs, query, target; partition=_partition(repo), policy=QUERY_POLICY, filter=nothing)

    results = Dict{String, Any}[]
    for item in res
        doc_repo, doc_id = split_doc_key(item.doc_id)
        doc = get_document(engine, doc_repo, doc_id)
        doc === nothing && continue

        doc_refs = get(doc, "references", Dict{String, Any}[])

        push!(results, Dict(
            "doc_id" => doc_id,
            "doc_title" => get(doc, "title", ""),
            "repo" => doc_repo,
            "creator" => get(doc, "creator", ""),
            "total_references" => length(doc_refs),
            "sample_references" => first(doc_refs, 3),
            "score" => -item.distance
        ))
    end

    has_more = length(results) > needed
    page = offset >= length(results) ? Dict{String, Any}[] : results[(offset + 1):min(needed, length(results))]

    t1 = time()
    return Dict(
        "query" => query,
        "offset" => offset,
        "total_hits" => length(page),
        "has_more" => has_more,
        "references" => page,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    get_document_references(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString)

Retrieves all bibliographic references cited by a specific document from RocksDB.
"""
function get_document_references(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString)
    engine.db === nothing && return Dict("error" => "Base de datos no disponible", "references" => [])
    doc = get_document(engine, repo, doc_id)
    doc === nothing && return Dict("error" => "Documento no encontrado", "references" => [])
    
    refs = get_document_references(engine.db, repo, doc_id)
    if isempty(refs)
        refs = get(doc, "references", Dict{String, Any}[])
    end
    
    return Dict(
        "doc_id" => doc_id,
        "doc_title" => get(doc, "title", ""),
        "repo" => repo,
        "total_references" => length(refs),
        "references" => refs
    )
end

"""
    get_author_documents(engine::SearchEngine, author_name_or_norm::AbstractString; limit::Int=100)

Retrieves all publications registered for an author from RocksDB.
"""
function get_author_documents(engine::SearchEngine, author_name_or_norm::AbstractString; limit::Int=100)
    engine.db === nothing && return Dict("error" => "Base de datos no disponible", "documents" => [])
    profile = resolve_consolidated_profile(engine, author_name_or_norm)
    profile === nothing && return Dict("error" => "Autor no encontrado en el acervo", "documents" => [])

    doc_entries = get_author_documents_for_group(engine.db, profile["raw_names"]; limit)
    docs = Dict{String, Any}[]

    for de in doc_entries
        repo = get(de, "repo", "")
        doc_id = get(de, "doc_id", "")
        (isempty(repo) || isempty(doc_id)) && continue

        doc = get_document(engine, repo, doc_id)
        if doc !== nothing
            # get_document returns a read-only JSON3.Object; copy into a mutable Dict before
            # adding the extra field (also required to push! into `docs::Vector{Dict{String,Any}}`).
            doc_dict = Dict{String, Any}(string(k) => v for (k, v) in pairs(doc))
            doc_dict["author_role"] = get(de, "role", "Autor")
            push!(docs, doc_dict)
        end
    end

    return Dict(
        "author" => profile["name"],
        "consolidated_id" => profile["consolidated_id"],
        "total_documents" => length(docs),
        "documents" => docs
    )
end

"""
    get_coauthors(engine::SearchEngine, author_name_or_norm::AbstractString; limit::Int=50)

Retrieves coauthors and collaboration frequencies from RocksDB, aggregated across every raw name
variant in the resolved author's consolidated group. `coauth:` edges are keyed by raw author id
(see `AuthorConsolidation`), so each id is resolved back to its raw profile's display name here —
callers (the TUI) get names, not ids, in this list.
"""
function get_coauthors(engine::SearchEngine, author_name_or_norm::AbstractString; limit::Int=50)
    engine.db === nothing && return Pair{String, Int}[]
    profile = resolve_consolidated_profile(engine, author_name_or_norm)
    profile === nothing && return Pair{String, Int}[]
    by_id = get_coauthors_for_group(engine.db, profile["raw_names"]; limit)
    return [(let p = get_author_profile(engine.db, id); p === nothing ? id : p["name"] end) => cnt
            for (id, cnt) in by_id]
end

"""
    get_author_network(engine::SearchEngine, author_name_or_norm::AbstractString; limit_coauthors::Int=15, limit_citations::Int=15)

Builds a small graph centered on a resolved author, combining coauthorship edges (RocksDB `authors` CF)
and citation edges (who cites this author, resolved via the `references` CF reverse index), for
network visualization.
"""
function get_author_network(engine::SearchEngine, author_name_or_norm::AbstractString; limit_coauthors::Int=15, limit_citations::Int=15)
    engine.db === nothing && return Dict("error" => "Base de datos no disponible", "nodes" => [], "edges" => [])

    target_profile = resolve_consolidated_profile(engine, author_name_or_norm)
    target_profile === nothing && return Dict("error" => "Autor no encontrado en el acervo", "nodes" => [], "edges" => [])

    target_cid = target_profile["consolidated_id"]
    target_name = get(target_profile, "name", author_name_or_norm)
    own_raw_keys = Set(normalize_author_name(r) for r in target_profile["raw_names"])

    nodes = Dict{String, Dict{String, Any}}()
    nodes[target_cid] = Dict("id" => target_cid, "name" => target_name, "kind" => "target")

    edges = Dict{Tuple{String, String, String}, Int}()

    # Coauthorship edges, aggregated across every raw name variant in the target's group
    for (coauth_norm, cnt) in get_coauthors_for_group(engine.db, target_profile["raw_names"]; limit=limit_coauthors)
        if !haskey(nodes, coauth_norm)
            cand = get_author_profile(engine.db, coauth_norm)
            cand_name = cand !== nothing ? get(cand, "name", coauth_norm) : coauth_norm
            nodes[coauth_norm] = Dict("id" => coauth_norm, "name" => cand_name, "kind" => "coauthor")
        end
        key = (coauth_norm, target_cid, "coauthor")
        edges[key] = get(edges, key, 0) + cnt
    end

    # Citation edges: authors of documents that cite the target author, aggregated across raw variants
    citer_count = 0
    for raw in target_profile["raw_names"]
        for entry in get_documents_citing_author(engine.db, raw; limit=limit_citations * 4)
            loc = get(entry, "cited_in", "")
            parts = split(loc, ":"; limit=2)
            length(parts) != 2 && continue
            citing_repo, citing_doc_id = parts[1], parts[2]
            (isempty(citing_repo) || isempty(citing_doc_id)) && continue

            doc = get_document(engine, citing_repo, citing_doc_id)
            doc === nothing && continue

            for creator in get(doc, "creators", String[])
                citer_norm = normalize_author_name(creator)
                (citer_norm in own_raw_keys || isempty(citer_norm)) && continue

                if !haskey(nodes, citer_norm)
                    citer_count >= limit_citations && continue
                    nodes[citer_norm] = Dict("id" => citer_norm, "name" => creator, "kind" => "citer")
                    citer_count += 1
                end
                key = (citer_norm, target_cid, "cites")
                edges[key] = get(edges, key, 0) + 1
            end
        end
    end

    edges_list = [Dict("source" => s, "target" => t, "kind" => k, "weight" => w) for ((s, t, k), w) in edges]

    return Dict(
        "target_author" => target_name,
        "target_norm" => target_cid,
        "nodes" => collect(values(nodes)),
        "edges" => edges_list
    )
end

"""
    get_topic_elements(engine::SearchEngine, topic::AbstractString; repo::Union{String, Nothing}=nothing, limit::Int=50)

Performs set queries (listing and intersection) for documents and authors tagged with a given topic.
"""
function get_topic_elements(engine::SearchEngine, topic::AbstractString; repo::Union{String, Nothing}=nothing, limit::Int=50)
    engine.db === nothing && return Dict("error" => "Base de datos no disponible")
    
    t0 = time()
    doc_pairs = if repo !== nothing && !isempty(repo)
        intersect_topic_repo_docs(engine.db, topic, repo; limit)
    else
        get_topic_docs(engine.db, topic; limit)
    end
    
    authors = if repo !== nothing && !isempty(repo)
        intersect_topic_repo_authors(engine.db, topic, repo; limit)
    else
        get_topic_authors(engine.db, topic; limit)
    end
    
    docs = Dict{String, Any}[]
    for (r, did) in doc_pairs
        doc = get_document(engine, r, did)
        # get_document returns a read-only JSON3.Object; copy into a mutable Dict to match
        # `docs::Vector{Dict{String,Any}}`'s concrete element type.
        doc !== nothing && push!(docs, Dict{String, Any}(string(k) => v for (k, v) in pairs(doc)))
    end
    
    t1 = time()
    return Dict(
        "topic" => topic,
        "repo_filter" => repo,
        "total_docs" => length(docs),
        "documents" => docs,
        "total_authors" => length(authors),
        "authors" => authors,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    search_document_paragraphs(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString, query::AbstractString; top::Int=5)

Searches inside the full text or abstract of a specific document in context.
"""
function search_document_paragraphs(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString, query::AbstractString; top::Int=5)
    engine.db === nothing && return Dict("error" => "Base de datos no disponible", "hits" => [])
    doc = get_document(engine, repo, doc_id)
    doc === nothing && return Dict("error" => "Documento no encontrado", "hits" => [])
    
    fulltext_path = get(doc, "fulltext_file", nothing)
    fulltext = if fulltext_path !== nothing && isfile(fulltext_path)
        try read(fulltext_path, String) catch; "" end
    else
        get(doc, "description", "")
    end
    
    isempty(strip(fulltext)) && return Dict("error" => "No hay texto completo disponible para este documento", "hits" => [])
    
    t0 = time()
    p_hits = search_document_in_depth(fulltext, query; top)
    t1 = time()
    
    formatted_hits = [
        Dict(
            "paragraph_num" => h.paragraph_num,
            "section" => h.section,
            "text" => h.text,
            "score" => h.score
        )
        for h in p_hits
    ]
    
    return Dict(
        "doc_title" => get(doc, "title", ""),
        "doc_id" => doc_id,
        "repo" => repo,
        "query" => query,
        "total_paragraphs_matched" => length(formatted_hits),
        "hits" => formatted_hits,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    get_detailed_statistics(engine::SearchEngine; repo::Union{AbstractString, Nothing}=nothing)

The statistics of the whole corpus or of one institutional repository, as the last build
computed them.
"""
function get_detailed_statistics(engine::SearchEngine; repo::Union{AbstractString, Nothing}=nothing)
    engine.db === nothing && return Dict("error" => "No hay índice cargado")

    clean_repo = (repo !== nothing && !isempty(strip(repo)) && strip(repo) != "all") ? strip(repo) : nothing

    cached = get(engine.stats_cache, clean_repo, nothing)
    cached !== nothing && return cached

    # Computed once while the index is built (`precompute_all_statistics!`), which is when every
    # document is in memory. The documents live in the engine, which has no operation that
    # reads all of its items, so there is no fallback that computes them here.
    persisted = get_stats(engine.db, clean_repo === nothing ? "global" : "repo:$clean_repo")
    persisted === nothing && return Dict("error" => clean_repo === nothing ?
        "No hay estadísticas precalculadas. Corre 'reposmx index'." :
        "No se encontraron documentos para el repositorio '$repo'")
    engine.stats_cache[clean_repo] = persisted
    return persisted
end

end # module Search
