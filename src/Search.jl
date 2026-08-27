module Search

using TextSearch, SimilaritySearch, JSON, JSON3
using ..Types: SearchHit, SearchResponse, AuthorProfile, ParagraphHit, ReferenceRecord
using ..Config: DEFAULT_INDEX_DIR, DEFAULT_DATA_DIR
import ..DB: get_author_documents, get_coauthors, get_document_references
using ..DB: Database, open_database, close_database, get_document, get_author_profile,
            get_reference, get_topic_docs, get_topic_authors,
            intersect_topic_repo_docs, intersect_topic_repo_authors, normalize_author_name
using ..Indexing: load_docs_content_index, load_docs_refs_index, load_authors_name_index,
                    load_authors_profile_index, search_document_in_depth
using ..Wikipedia: explain_concept

export query_index, search_authors, find_similar_authors_by_profile, find_similar_documents_by_references,
       search_references, get_document_references, get_author_documents, get_coauthors,
       get_topic_elements, search_document_paragraphs, get_detailed_statistics, SearchEngine

mutable struct SearchEngine
    db::Union{Database, Nothing}
    docs_content_invfile::Union{BM25InvertedFile, Nothing}
    doc_keys::Vector{Tuple{String, String}}
    docs_refs_invfile::Union{BM25InvertedFile, Nothing}
    authors_name_invfile::Union{BM25InvertedFile, Nothing}
    authors_profile_invfile::Union{BM25InvertedFile, Nothing}
    author_keys::Vector{String}
    index_dir::String
    data_dir::String
    ctx::InvertedFileContext
    
    function SearchEngine(; index_dir=DEFAULT_INDEX_DIR, data_dir=DEFAULT_DATA_DIR)
        db_path = joinpath(data_dir, "rocksdb")
        db = isdir(db_path) ? open_database(db_path; read_only=true) : nothing
        
        content_inv, d_keys = load_docs_content_index(; index_dir)
        refs_inv, _ = load_docs_refs_index(; index_dir)
        auth_name_inv, a_keys = load_authors_name_index(; index_dir)
        auth_prof_inv, _ = load_authors_profile_index(; index_dir)
        
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
            InvertedFileContext()
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
        auth_name_inv, a_keys = load_authors_name_index(; index_dir=engine.index_dir)
        auth_prof_inv, _ = load_authors_profile_index(; index_dir=engine.index_dir)
        engine.authors_name_invfile = auth_name_inv
        engine.authors_profile_invfile = auth_prof_inv
        engine.author_keys = a_keys
    end
end

function ensure_docs_refs_loaded!(engine::SearchEngine)
    if engine.docs_refs_invfile === nothing
        refs_inv, _ = load_docs_refs_index(; index_dir=engine.index_dir)
        engine.docs_refs_invfile = refs_inv
    end
end

"""
    query_index(engine::SearchEngine, q::AbstractString; top::Int=10, repo=nothing, keyword=nothing, doc_type=nothing, include_wiki=false)

Executes a primary BM25 search over titles, abstracts, keywords and conclusions, with post-filtering.
"""
function query_index(
    engine::SearchEngine,
    q::AbstractString;
    top::Int=10,
    repo::Union{String, Nothing}=nothing,
    keyword::Union{String, Nothing}=nothing,
    doc_type::Union{String, Nothing}=nothing,
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
    knn_k = top * ((repo !== nothing || keyword !== nothing || doc_type !== nothing) ? 8 : 1)
    res = search(engine.docs_content_invfile, engine.ctx, q, knnqueue(engine.ctx, knn_k))
    
    hits = Dict{String, Any}[]
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
        
        title = get(doc, "title", "")
        creator = get(doc, "creator", "")
        contributor = get(doc, "contributor", "")
        date = get(doc, "date", "")
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
        
        length(hits) >= top && break
    end
    
    wiki_info = nothing
    if include_wiki && !isempty(strip(q))
        wiki_info = explain_concept(q)
    end
    
    t1 = time()
    time_ms = round((t1 - t0) * 1000, digits=2)
    
    return Dict(
        "query" => q,
        "total_hits" => length(hits),
        "hits" => hits,
        "wiki_concept" => wiki_info,
        "time_ms" => time_ms
    )
end

"""
    search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)

Searches researcher and advisor profiles by name using the `authors_name_bm25` index.
"""
function search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)
    ensure_authors_loaded!(engine)
    if engine.authors_name_invfile === nothing || isempty(engine.author_keys)
        return Dict("query" => author_query, "total_hits" => 0, "authors" => [], "time_ms" => 0.0)
    end
    
    t0 = time()
    knn_k = top * (repo !== nothing ? 5 : 1)
    res = search(engine.authors_name_invfile, engine.ctx, author_query, knnqueue(engine.ctx, knn_k))
    
    results = Dict{String, Any}[]
    for item in res
        idx = item.id
        (idx < 1 || idx > length(engine.author_keys)) && continue
        norm_name = engine.author_keys[idx]
        
        auth = engine.db !== nothing ? get_author_profile(engine.db, norm_name) : nothing
        auth === nothing && continue
        
        # Post-filter by repo
        auth_repos = get(auth, "repos", String[])
        if repo !== nothing && !isempty(repo) && !(repo in auth_repos)
            continue
        end
        
        push!(results, Dict(
            "name" => auth["name"],
            "norm_name" => norm_name,
            "role" => get(auth, "role", "Autor"),
            "doc_count" => get(auth, "doc_count", 1),
            "repos" => auth_repos,
            "coauthors" => get(auth, "coauthors", String[]),
            "keywords" => get(auth, "keywords", String[]),
            "score" => -item.dist
        ))
        
        length(results) >= top && break
    end
    
    t1 = time()
    return Dict(
        "query" => author_query,
        "total_hits" => length(results),
        "authors" => results,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    find_similar_authors_by_profile(engine::SearchEngine, author_name_or_norm::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)

Finds researchers with similar thematic lines, topics, and bibliography starting from a context author.
"""
function find_similar_authors_by_profile(engine::SearchEngine, author_name_or_norm::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)
    ensure_authors_loaded!(engine)
    if engine.authors_profile_invfile === nothing || isempty(engine.author_keys)
        return Dict("author" => author_name_or_norm, "total_hits" => 0, "similar_authors" => [], "time_ms" => 0.0)
    end
    
    t0 = time()
    norm_target = normalize_author_name(author_name_or_norm)
    target_author = engine.db !== nothing ? get_author_profile(engine.db, norm_target) : nothing
    
    if target_author === nothing
        # Try finding by loose name in author_keys
        idx = findfirst(k -> occursin(norm_target, k) || occursin(k, norm_target), engine.author_keys)
        if idx !== nothing
            norm_target = engine.author_keys[idx]
            target_author = get_author_profile(engine.db, norm_target)
        end
    end
    
    if target_author === nothing
        return Dict("author" => author_name_or_norm, "total_hits" => 0, "similar_authors" => [], "time_ms" => 0.0, "error" => "Autor no encontrado en el acervo")
    end
    
    target_name = get(target_author, "name", author_name_or_norm)
    kws = get(target_author, "keywords", String[])
    topics = get(target_author, "topic_texts", String[])
    refs = get(target_author, "cited_references", String[])
    
    profile_query = "$target_name . $(join(kws, " , ")) . $(join(topics, " \n ")) . $(join(refs, " \n "))"
    
    knn_k = (top + 1) * (repo !== nothing ? 5 : 1)
    res = search(engine.authors_profile_invfile, engine.ctx, profile_query, knnqueue(engine.ctx, knn_k))
    
    results = Dict{String, Any}[]
    for item in res
        idx = item.id
        (idx < 1 || idx > length(engine.author_keys)) && continue
        cand_norm = engine.author_keys[idx]
        cand_norm == norm_target && continue
        
        cand_auth = engine.db !== nothing ? get_author_profile(engine.db, cand_norm) : nothing
        cand_auth === nothing && continue
        
        cand_repos = get(cand_auth, "repos", String[])
        if repo !== nothing && !isempty(repo) && !(repo in cand_repos)
            continue
        end
        
        push!(results, Dict(
            "name" => get(cand_auth, "name", cand_norm),
            "norm_name" => cand_norm,
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
    find_similar_documents_by_references(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString; top::Int=10)

Finds documents sharing bibliographic coupling with a selected context document.
"""
function find_similar_documents_by_references(engine::SearchEngine, repo::AbstractString, doc_id::AbstractString; top::Int=10)
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
    res = search(engine.docs_refs_invfile, engine.ctx, query_str, knnqueue(engine.ctx, top + 1))
    
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
function search_references(engine::SearchEngine, query::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)
    ensure_docs_refs_loaded!(engine)
    if engine.docs_refs_invfile === nothing || isempty(engine.doc_keys) || engine.db === nothing
        return Dict("query" => query, "total_hits" => 0, "references" => [], "time_ms" => 0.0)
    end
    
    t0 = time()
    knn_k = top * (repo !== nothing ? 5 : 1)
    res = search(engine.docs_refs_invfile, engine.ctx, query, knnqueue(engine.ctx, knn_k))
    
    results = Dict{String, Any}[]
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
        
        length(results) >= top && break
    end
    
    t1 = time()
    return Dict(
        "query" => query,
        "total_hits" => length(results),
        "references" => results,
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
    norm_name = normalize_author_name(author_name_or_norm)
    profile = get_author_profile(engine.db, norm_name)
    
    doc_entries = get_author_documents(engine.db, norm_name; limit)
    docs = Dict{String, Any}[]
    
    for de in doc_entries
        repo = get(de, "repo", "")
        doc_id = get(de, "doc_id", "")
        (isempty(repo) || isempty(doc_id)) && continue
        
        doc = get_document(engine.db, repo, doc_id)
        if doc !== nothing
            doc["author_role"] = get(de, "role", "Autor")
            push!(docs, doc)
        end
    end
    
    return Dict(
        "author" => profile !== nothing ? profile["name"] : author_name_or_norm,
        "norm_name" => norm_name,
        "total_documents" => length(docs),
        "documents" => docs
    )
end

"""
    get_coauthors(engine::SearchEngine, author_name_or_norm::AbstractString; limit::Int=50)

Retrieves coauthors and collaboration frequencies from RocksDB.
"""
function get_coauthors(engine::SearchEngine, author_name_or_norm::AbstractString; limit::Int=50)
    engine.db === nothing && return Pair{String, Int}[]
    norm_name = normalize_author_name(author_name_or_norm)
    return get_coauthors(engine.db, norm_name; limit)
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
        doc !== nothing && push!(docs, doc)
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

const GENERIC_TAGS = Set([
    "info:eu-repo", "cti", "classification", "openaccess", "12", "11", "1299", "129999", "110403", "1208", "masterthesis", "doctoralthesis", "bachelorthesis"
])

"""
    get_detailed_statistics(engine::SearchEngine; repo::Union{AbstractString, Nothing}=nothing)

Computes rich statistics globally or for a specific institutional repository.
"""
function get_detailed_statistics(engine::SearchEngine; repo::Union{AbstractString, Nothing}=nothing)
    if isempty(engine.doc_keys) || engine.db === nothing
        return Dict("error" => "No hay índice cargado")
    end
    
    clean_repo = (repo !== nothing && !isempty(strip(repo)) && strip(repo) != "all") ? strip(repo) : nothing
    
    total_docs = 0
    total_files = 0
    total_fulltext = 0
    total_refs = 0
    
    types_count = Dict{String, Int}()
    repos_count = Dict{String, Int}()
    kws_count = Dict{String, Int}()
    years_list = Int[]
    
    for (r, did) in engine.doc_keys
        if clean_repo !== nothing && r != clean_repo
            continue
        end
        
        doc = get_document(engine.db, r, did)
        doc === nothing && continue
        
        total_docs += 1
        
        if get(doc, "file", nothing) !== nothing
            total_files += 1
        end
        
        if get(doc, "has_fulltext", false)
            total_fulltext += 1
        end
        
        rcnt = get(doc, "reference_count", 0)
        total_refs += rcnt
        
        raw_type = get(doc, "type", "Documento")
        norm_type = if occursin(r"(?i)\btesis\b"i, raw_type) || occursin(r"(?i)\bthesis\b"i, raw_type)
            "Tesis"
        elseif occursin(r"(?i)\bart[ií]culo\b"i, raw_type) || occursin(r"(?i)\barticle\b"i, raw_type)
            "Artículo"
        elseif occursin(r"(?i)\blibro\b"i, raw_type) || occursin(r"(?i)\bbook\b"i, raw_type)
            "Libro"
        elseif occursin(r"(?i)\bconferencia\b"i, raw_type) || occursin(r"(?i)\bconference\b"i, raw_type) || occursin(r"(?i)\bponencia\b"i, raw_type)
            "Conferencia / Ponencia"
        else
            "Documento Académico"
        end
        types_count[norm_type] = get(types_count, norm_type, 0) + 1
        repos_count[r] = get(repos_count, r, 0) + 1
        
        kws = get(doc, "keywords", String[])
        for kw in kws
            k_clean = strip(kw)
            isempty(k_clean) && continue
            lowercase(k_clean) in GENERIC_TAGS && continue
            kws_count[k_clean] = get(kws_count, k_clean, 0) + 1
        end
        
        date_str = get(doc, "date", "")
        m = match(r"\b(19\d\d|20\d\d)\b", date_str)
        if m !== nothing
            y = parse(Int, m.match)
            if y >= 1950 && y <= 2030
                push!(years_list, y)
            end
        end
    end
    
    if total_docs == 0
        return Dict("error" => "No se encontraron documentos para el repositorio '$repo'")
    end
    
    sorted_types = sort([Dict("type" => k, "count" => v) for (k, v) in types_count], by=x->x["count"], rev=true)
    sorted_kws = sort([Dict("discipline" => k, "count" => v) for (k, v) in kws_count], by=x->x["count"], rev=true)
    sorted_repos = sort([Dict("repo" => k, "count" => v) for (k, v) in repos_count], by=x->x["count"], rev=true)
    
    year_min = isempty(years_list) ? "N/A" : string(minimum(years_list))
    year_max = isempty(years_list) ? "N/A" : string(maximum(years_list))
    
    return Dict(
        "is_global" => clean_repo === nothing,
        "target_repo" => clean_repo,
        "total_docs" => total_docs,
        "total_files" => total_files,
        "total_fulltext" => total_fulltext,
        "total_references" => total_refs,
        "total_authors" => length(engine.author_keys),
        "year_min" => year_min,
        "year_max" => year_max,
        "types_distribution" => sorted_types,
        "top_disciplines" => sorted_kws[1:min(15, length(sorted_kws))],
        "top_repositories" => sorted_repos
    )
end

end # module Search
