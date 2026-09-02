module Search

using TextSearch, SimilaritySearch, JSON, JSON3
using ..Types: SearchHit, SearchResponse, AuthorProfile, ParagraphHit, ReferenceRecord
using ..Config: DEFAULT_INDEX_DIR, DEFAULT_DATA_DIR
import ..DB: get_author_documents, get_coauthors, get_document_references
using ..DB: Database, open_database, close_database, get_document, scan_documents, get_author_profile,
            get_consolidated_profile, get_consolidated_id_for_raw,
            get_author_documents_for_group, get_coauthors_for_group,
            get_reference, get_topic_docs, get_topic_authors,
            intersect_topic_repo_docs, intersect_topic_repo_authors, normalize_author_name,
            get_documents_citing_author, put_stats!, get_stats, compute_detailed_statistics
using ..Indexing: load_docs_content_index, load_docs_refs_index, load_authors_name_index,
                    load_authors_profile_index, search_document_in_depth
using ..Wikipedia: explain_concept

export query_index, search_authors, find_similar_authors_by_profile, find_similar_documents_by_references,
       search_references, get_document_references, get_author_documents, get_coauthors,
       get_topic_elements, search_document_paragraphs, get_detailed_statistics, get_author_network,
       SearchEngine

mutable struct SearchEngine
    db::Union{Database, Nothing}
    docs_content_invfile::Union{BM25InvertedFile, Nothing}
    doc_keys::AbstractVector{Tuple{String, String}}
    docs_refs_invfile::Union{BM25InvertedFile, Nothing}
    authors_name_invfile::Union{BM25InvertedFile, Nothing}
    authors_profile_invfile::Union{BM25InvertedFile, Nothing}
    author_keys::AbstractVector{String}
    index_dir::String
    data_dir::String
    stats_cache::Dict{Union{String, Nothing}, Dict{String, Any}}

    function SearchEngine(; index_dir=DEFAULT_INDEX_DIR, data_dir=DEFAULT_DATA_DIR)
        db_path = joinpath(data_dir, "rocksdb")
        db = @time "open_database" (isdir(db_path) ? open_database(db_path; read_only=true) : nothing)

        # Posting lists / per-document term vectors live in `db` (RocksDB `postings`/`docvecs`
        # column families) and are read lazily on demand — only the small vocab/BM25-params/
        # doclens "shell" is deserialized here.
        content_inv, d_keys = @time "load_docs_content_index" load_docs_content_index(db; index_dir)
        refs_inv, _ = @time "load_docs_refs_index" load_docs_refs_index(db; index_dir)
        auth_name_inv, a_keys = @time "load_authors_name_index" load_authors_name_index(db; index_dir)
        auth_prof_inv, _ = @time "load_authors_profile_index" load_authors_profile_index(db; index_dir)

        new(
            db,
            content_inv,
            d_keys,
            refs_inv,
            auth_name_inv,
            auth_prof_inv,
            a_keys,
            String(index_dir),
            String(data_dir),
            Dict{Union{String, Nothing}, Dict{String, Any}}()
        )
    end
end

function Base.close(engine::SearchEngine)
    if engine.db !== nothing
        close_database(engine.db)
        engine.db = nothing
    end
end

function ensure_authors_loaded!(engine::SearchEngine)
    if engine.authors_name_invfile === nothing || engine.authors_profile_invfile === nothing
        auth_name_inv, a_keys = load_authors_name_index(engine.db; index_dir=engine.index_dir)
        auth_prof_inv, _ = load_authors_profile_index(engine.db; index_dir=engine.index_dir)
        engine.authors_name_invfile = auth_name_inv
        engine.authors_profile_invfile = auth_prof_inv
        engine.author_keys = a_keys
    end
end

function ensure_docs_refs_loaded!(engine::SearchEngine)
    if engine.docs_refs_invfile === nothing
        refs_inv, _ = load_docs_refs_index(engine.db; index_dir=engine.index_dir)
        engine.docs_refs_invfile = refs_inv
    end
end

"""
    query_index(engine::SearchEngine, q::AbstractString; top::Int=10, offset::Int=0, repo=nothing, keyword=nothing, doc_type=nothing, year_min=nothing, year_max=nothing, include_wiki=false)

Executes a primary BM25 search over titles, abstracts, keywords and conclusions, with post-filtering
and offset-based pagination.
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
    if engine.docs_content_invfile === nothing || isempty(engine.doc_keys)
        return Dict(
            "query" => q,
            "total_hits" => 0,
            "hits" => [],
            "wiki_concept" => nothing,
            "error" => "Search index not loaded. Run `reposmx prepare-index` first."
        )
    end

    t0 = time()
    has_filters = (repo !== nothing || keyword !== nothing || doc_type !== nothing || year_min !== nothing || year_max !== nothing)
    offset = max(offset, 0)
    needed = offset + top
    # Peek one extra match beyond the requested page so we know whether a next page exists.
    target = needed + 1
    knn_k = target * (has_filters ? 8 : 1)
    max_k = length(engine.doc_keys)
    hits = Dict{String, Any}[]

    # Restrictive post-filters (repo/type/keyword/year) or a deep offset can starve the candidate
    # window; widen it geometrically instead of silently returning fewer than `top` hits.
    while true
        ctx = InvertedFileContext()
        res = search(engine.docs_content_invfile, ctx, q, knnqueue(ctx, knn_k))
        empty!(hits)

        for item in res
            doc_idx = item.id
            (doc_idx < 1 || doc_idx > length(engine.doc_keys)) && continue
            doc_repo, doc_id = engine.doc_keys[doc_idx]

            # 1. Post-filter by repo
            if repo !== nothing && !isempty(repo) && doc_repo != repo
                continue
            end

            # Fetch document metadata directly from RocksDB
            doc = engine.db !== nothing ? get_document(engine.db, doc_repo, doc_id) : nothing
            doc === nothing && continue

            # 2. Post-filter by document type
            dtype = get(doc, "type", "")
            if doc_type !== nothing && !isempty(doc_type) && !occursin(lowercase(doc_type), lowercase(dtype))
                continue
            end

            # 3. Post-filter by keyword/discipline
            kws = get(doc, "keywords", String[])
            if keyword !== nothing && !isempty(keyword)
                kw_match = any(k -> occursin(lowercase(keyword), lowercase(k)), kws)
                !kw_match && continue
            end

            date = get(doc, "date", "")

            # 4. Post-filter by year range
            if year_min !== nothing || year_max !== nothing
                ym = match(r"\b(19\d\d|20\d\d)\b", date)
                ym === nothing && continue
                doc_year = parse(Int, ym.match)
                year_min !== nothing && doc_year < year_min && continue
                year_max !== nothing && doc_year > year_max && continue
            end

            title = get(doc, "title", "")
            creator = get(doc, "creator", "")
            contributor = get(doc, "contributor", "")
            desc = get(doc, "description", "")
            file = get(doc, "file", nothing)
            has_fulltext = get(doc, "has_fulltext", false)
            ref_count = get(doc, "reference_count", 0)

            snippet = if !isempty(desc)
                first(desc, min(300, length(desc))) * (length(desc) > 300 ? "..." : "")
            else
                title
            end

            push!(hits, Dict(
                "doc_idx" => doc_idx,
                "id" => doc_id,
                "repo" => doc_repo,
                "title" => title,
                "creator" => creator,
                "contributor" => contributor,
                "date" => date,
                "description" => desc,
                "keywords" => kws,
                "type" => dtype,
                "file" => file,
                "has_fulltext" => has_fulltext,
                "reference_count" => ref_count,
                "score" => -item.dist,
                "snippet" => snippet
            ))

            length(hits) >= target && break
        end

        (length(hits) < target && knn_k < max_k) || break
        knn_k = min(knn_k * 4, max_k)
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
and only if both miss falls back to the top hit of the `authors_name` BM25 index itself (which is
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
    (engine.authors_name_invfile === nothing || isempty(engine.author_keys)) && return nothing
    ctx = InvertedFileContext()
    res = search(engine.authors_name_invfile, ctx, author_ref, knnqueue(ctx, 1))
    isempty(res) && return nothing
    idx = first(res).id
    (idx < 1 || idx > length(engine.author_keys)) && return nothing
    return get_consolidated_profile(engine.db, engine.author_keys[idx])
end

"""
    search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)

Searches researcher and advisor profiles by name using the `authors_name_bm25` index.
"""
function search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10, offset::Int=0, repo::Union{String, Nothing}=nothing)
    ensure_authors_loaded!(engine)
    if engine.authors_name_invfile === nothing || isempty(engine.author_keys)
        return Dict("query" => author_query, "total_hits" => 0, "authors" => [], "time_ms" => 0.0)
    end

    t0 = time()
    offset = max(offset, 0)
    needed = offset + top
    target = needed + 1
    knn_k = target * (repo !== nothing ? 5 : 1)
    max_k = length(engine.author_keys)
    results = Dict{String, Any}[]

    while true
        ctx = InvertedFileContext()
        res = search(engine.authors_name_invfile, ctx, author_query, knnqueue(ctx, knn_k))
        empty!(results)

        for item in res
            idx = item.id
            (idx < 1 || idx > length(engine.author_keys)) && continue
            cid = engine.author_keys[idx]

            auth = engine.db !== nothing ? get_consolidated_profile(engine.db, cid) : nothing
            auth === nothing && continue

            # Post-filter by repo
            auth_repos = get(auth, "repos", String[])
            if repo !== nothing && !isempty(repo) && !(repo in auth_repos)
                continue
            end

            push!(results, Dict(
                "name" => auth["name"],
                "consolidated_id" => cid,
                "role" => get(auth, "role", "Autor"),
                "doc_count" => get(auth, "doc_count", 1),
                "repos" => auth_repos,
                "coauthors" => get(auth, "coauthors", String[]),
                "keywords" => get(auth, "keywords", String[]),
                "score" => -item.dist
            ))

            length(results) >= target && break
        end

        (length(results) < target && knn_k < max_k) || break
        knn_k = min(knn_k * 4, max_k)
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
    top_informative_bow(idx, text::AbstractString; top_k_tokens::Int) -> BOW

Tokenizes `text` against `idx`'s own vocabulary/query pipeline and keeps only the
`top_k_tokens` *rarest* tokens (lowest document frequency in `idx.voc`, i.e. highest IDF) —
the rest are dropped before the query ever reaches `search`.

This exists for the "turn a whole profile/reference-list into a query" pattern
(`find_similar_authors_by_profile`, `find_similar_documents_by_references`): those queries are
built from dozens of keywords/topic summaries/references, most of which are common words that
barely move a BM25 score but still cost a full posting-list evaluation each. IDF is exactly BM25's
own measure of "how much does this token matter" (`log(N/ndocs)`, monotonic in `ndocs`), so
keeping the lowest-`ndocs` tokens keeps the ones that actually drive the ranking.

Returns a [`BOW`](@ref) (`Dict{UInt32,Int32}`, vocabulary ids -> presence), which `search` accepts
directly — no re-tokenization round trip.
"""
function top_informative_bow(idx, text::AbstractString; top_k_tokens::Int)
    resolved = query_tokens(idx.voc, text, idx.query)
    bow = querybow(idx.voc, resolved)
    length(bow) <= top_k_tokens && return bow
    ids = sort(collect(keys(bow)); by=id -> idx.voc.ndocs[id])
    keep = Set(@view ids[1:top_k_tokens])
    BOW(id => cnt for (id, cnt) in bow if id in keep)
end

"""
    find_similar_authors_by_profile(engine::SearchEngine, author_name_or_norm::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing, top_k_tokens::Int=16)

Finds researchers with similar thematic lines, topics, and bibliography starting from a context
author. The query is the target's own profile (name + keywords + topic summaries + cited
references) trimmed to its `top_k_tokens` most informative tokens (see
[`top_informative_bow`](@ref)) — a full untrimmed profile can run into the hundreds of distinct
tokens, most contributing nothing to the ranking.
"""
function find_similar_authors_by_profile(engine::SearchEngine, author_name_or_norm::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing, top_k_tokens::Int=16)
    ensure_authors_loaded!(engine)
    if engine.authors_profile_invfile === nothing || isempty(engine.author_keys)
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
    profile_query = top_informative_bow(engine.authors_profile_invfile, profile_text; top_k_tokens)

    knn_k = (top + 1) * (repo !== nothing ? 5 : 1)
    ctx = InvertedFileContext()
    res = search(engine.authors_profile_invfile, ctx, profile_query, knnqueue(ctx, knn_k))
    
    results = Dict{String, Any}[]
    for item in res
        idx = item.id
        (idx < 1 || idx > length(engine.author_keys)) && continue
        cand_cid = engine.author_keys[idx]
        cand_cid == target_cid && continue

        cand_auth = engine.db !== nothing ? get_consolidated_profile(engine.db, cand_cid) : nothing
        cand_auth === nothing && continue

        cand_repos = get(cand_auth, "repos", String[])
        if repo !== nothing && !isempty(repo) && !(repo in cand_repos)
            continue
        end

        push!(results, Dict(
            "name" => get(cand_auth, "name", cand_cid),
            "consolidated_id" => cand_cid,
            "role" => get(cand_auth, "role", "Autor"),
            "doc_count" => get(cand_auth, "doc_count", 1),
            "repos" => cand_repos,
            "keywords" => get(cand_auth, "keywords", String[]),
            "score" => -item.dist
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
[`top_informative_bow`](@ref)) — a document with dozens of references can otherwise touch hundreds
of distinct tokens (proper nouns, journal names, DOIs), most of them irrelevant to the ranking.
"""
function find_similar_documents_by_references(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString; top::Int=10, top_k_tokens::Int=16)
    ensure_docs_refs_loaded!(engine)
    if engine.docs_refs_invfile === nothing || isempty(engine.doc_keys) || engine.db === nothing
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
        doc = get_document(engine.db, repo, doc_id)
        if doc !== nothing
            push!(ref_texts, get(doc, "description", ""))
        end
    end
    
    query_str = join(ref_texts, " \n ")
    query_bow = top_informative_bow(engine.docs_refs_invfile, query_str; top_k_tokens)
    ctx = InvertedFileContext()
    res = search(engine.docs_refs_invfile, ctx, query_bow, knnqueue(ctx, top + 1))
    
    target_key = (String(repo), String(doc_id))
    results = Dict{String, Any}[]
    for item in res
        idx = item.id
        (idx < 1 || idx > length(engine.doc_keys)) && continue
        cand_key = engine.doc_keys[idx]
        cand_key == target_key && continue
        
        cand_doc = get_document(engine.db, cand_key[1], cand_key[2])
        cand_doc === nothing && continue
        
        push!(results, Dict(
            "id" => cand_key[2],
            "repo" => cand_key[1],
            "title" => get(cand_doc, "title", ""),
            "creator" => get(cand_doc, "creator", ""),
            "date" => get(cand_doc, "date", ""),
            "type" => get(cand_doc, "type", "Documento"),
            "reference_count" => get(cand_doc, "reference_count", 0),
            "score" => -item.dist
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
    search_references(engine::SearchEngine, query::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)

Searches across the citations corpus to discover who cites a specific author, book, paper or theory.
"""
function search_references(engine::SearchEngine, query::AbstractString; top::Int=10, offset::Int=0, repo::Union{String, Nothing}=nothing)
    ensure_docs_refs_loaded!(engine)
    if engine.docs_refs_invfile === nothing || isempty(engine.doc_keys) || engine.db === nothing
        return Dict("query" => query, "total_hits" => 0, "references" => [], "time_ms" => 0.0)
    end

    t0 = time()
    offset = max(offset, 0)
    needed = offset + top
    target = needed + 1
    knn_k = target * (repo !== nothing ? 5 : 1)
    max_k = length(engine.doc_keys)
    results = Dict{String, Any}[]

    while true
        ctx = InvertedFileContext()
        res = search(engine.docs_refs_invfile, ctx, query, knnqueue(ctx, knn_k))
        empty!(results)

        for item in res
            idx = item.id
            (idx < 1 || idx > length(engine.doc_keys)) && continue
            doc_repo, doc_id = engine.doc_keys[idx]

            if repo !== nothing && !isempty(repo) && doc_repo != repo
                continue
            end

            doc = get_document(engine.db, doc_repo, doc_id)
            doc === nothing && continue

            doc_refs = get(doc, "references", Dict{String, Any}[])

            push!(results, Dict(
                "doc_id" => doc_id,
                "doc_title" => get(doc, "title", ""),
                "repo" => doc_repo,
                "creator" => get(doc, "creator", ""),
                "total_references" => length(doc_refs),
                "sample_references" => first(doc_refs, 3),
                "score" => -item.dist
            ))

            length(results) >= target && break
        end

        (length(results) < target && knn_k < max_k) || break
        knn_k = min(knn_k * 4, max_k)
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
    doc = get_document(engine.db, repo, doc_id)
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

        doc = get_document(engine.db, repo, doc_id)
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

            doc = get_document(engine.db, citing_repo, citing_doc_id)
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
        doc = get_document(engine.db, r, did)
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
    doc = get_document(engine.db, repo, doc_id)
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

Computes rich statistics globally or for a specific institutional repository.
"""
function get_detailed_statistics(engine::SearchEngine; repo::Union{AbstractString, Nothing}=nothing)
    if isempty(engine.doc_keys) || engine.db === nothing
        return Dict("error" => "No hay índice cargado")
    end

    clean_repo = (repo !== nothing && !isempty(strip(repo)) && strip(repo) != "all") ? strip(repo) : nothing

    # Computing this requires a full RocksDB scan over every document (up to ~450k
    # random-access reads), so cache the result per repo filter for the engine's lifetime.
    cached = get(engine.stats_cache, clean_repo, nothing)
    cached !== nothing && return cached

    # Precomputed at index-build time (`precompute_all_statistics!`, run once from
    # `build_search_index`) when available — a single RocksDB get instead of a full corpus scan.
    persisted = get_stats(engine.db, clean_repo === nothing ? "global" : "repo:$clean_repo")
    if persisted !== nothing
        engine.stats_cache[clean_repo] = persisted
        return persisted
    end

    stats = compute_detailed_statistics(engine.db, length(engine.author_keys), clean_repo, repo)
    !haskey(stats, "error") && (engine.stats_cache[clean_repo] = stats)
    return stats
end

end # module Search
