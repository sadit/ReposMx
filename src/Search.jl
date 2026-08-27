module Search

using TextSearch, SimilaritySearch, JSON, JSON3
using ..Types: SearchHit, SearchResponse, AuthorProfile, ParagraphHit, ReferenceRecord
import ..Types: get_document_references
using ..Config: DEFAULT_INDEX_DIR
using ..Indexing: load_search_index, load_authors_index, load_references_index, search_document_in_depth
using ..Wikipedia: explain_concept

export query_index, search_authors, search_authors_by_topic, find_similar_authors_by_references,
       search_references, get_document_references, search_document_paragraphs, get_detailed_statistics, SearchEngine

mutable struct SearchEngine
    invfile::Union{BM25InvertedFile, Nothing}
    docs::Union{Vector{Dict{String, Any}}, Nothing}
    docs_by_id::Union{Dict{String, Dict{String, Any}}, Nothing}
    authors_invfile::Union{BM25InvertedFile, Nothing}
    authors_topic_invfile::Union{BM25InvertedFile, Nothing}
    authors_data::Union{Vector{Dict{String, Any}}, Nothing}
    references_invfile::Union{BM25InvertedFile, Nothing}
    references_data::Union{Vector{Dict{String, Any}}, Nothing}
    index_dir::String
    ctx::InvertedFileContext
    
    function SearchEngine(; index_dir=DEFAULT_INDEX_DIR)
        invfile, docs = load_search_index(; index_dir)
        new(invfile, docs, nothing, nothing, nothing, nothing, nothing, nothing, String(index_dir), InvertedFileContext())
    end
end

function get_doc_by_id(engine::SearchEngine, doc_id::AbstractString)
    if engine.docs_by_id === nothing && engine.docs !== nothing
        d_map = Dict{String, Dict{String, Any}}()
        sizehint!(d_map, length(engine.docs))
        for d in engine.docs
            id = get(d, "id", "")
            !isempty(id) && (d_map[id] = d)
        end
        engine.docs_by_id = d_map
    end
    return engine.docs_by_id !== nothing ? get(engine.docs_by_id, doc_id, nothing) : nothing
end

function ensure_authors_loaded!(engine::SearchEngine)
    if engine.authors_invfile === nothing || engine.authors_data === nothing
        auth_inv, auth_topic_inv, auth_data = load_authors_index(; index_dir=engine.index_dir)
        engine.authors_invfile = auth_inv
        engine.authors_topic_invfile = auth_topic_inv
        engine.authors_data = auth_data
    end
end

function ensure_references_loaded!(engine::SearchEngine)
    if engine.references_invfile === nothing || engine.references_data === nothing
        refs_inv, refs_data = load_references_index(; index_dir=engine.index_dir)
        engine.references_invfile = refs_inv
        engine.references_data = refs_data
    end
end

"""
    query_index(engine::SearchEngine, q::AbstractString; top::Int=10, repo=nothing, keyword=nothing, doc_type=nothing, include_wiki=false)

Executes a primary BM25 search over titles, abstracts, keywords and conclusions, with optional facet filters.
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
    if engine.invfile === nothing || engine.docs === nothing
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
    res = search(engine.invfile, engine.ctx, q, knnqueue(engine.ctx, knn_k))
    
    hits = Dict{String, Any}[]
    for item in res
        doc_id = item.id
        (doc_id < 1 || doc_id > length(engine.docs)) && continue
        doc = engine.docs[doc_id]
        
        # 1. Filter by repo
        doc_repo = get(doc, "repo", "")
        if repo !== nothing && !isempty(repo) && doc_repo != repo
            continue
        end
        
        # 2. Filter by document type (Tesis, Artículo, Libro...)
        dtype = get(doc, "type", "")
        if doc_type !== nothing && !isempty(doc_type) && !occursin(lowercase(doc_type), lowercase(dtype))
            continue
        end
        
        # 3. Filter by keyword/discipline
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
            "doc_idx" => doc_id,
            "id" => get(doc, "id", ""),
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
    search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10)

Searches author and contributor profiles by name.
"""
function search_authors(engine::SearchEngine, author_query::AbstractString; top::Int=10)
    ensure_authors_loaded!(engine)
    if engine.authors_invfile === nothing || engine.authors_data === nothing
        return Dict("query" => author_query, "total_hits" => 0, "authors" => [], "time_ms" => 0.0)
    end
    
    t0 = time()
    res = search(engine.authors_invfile, engine.ctx, author_query, knnqueue(engine.ctx, top))
    
    results = Dict{String, Any}[]
    for item in res
        idx = item.id
        (idx < 1 || idx > length(engine.authors_data)) && continue
        auth = engine.authors_data[idx]
        push!(results, Dict(
            "name" => auth["name"],
            "role" => auth["role"],
            "doc_count" => auth["doc_count"],
            "repos" => auth["repos"],
            "coauthors" => auth["coauthors"],
            "keywords" => auth["keywords"],
            "score" => -item.dist
        ))
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
    search_authors_by_topic(engine::SearchEngine, topic_query::AbstractString; top::Int=10)

Finds researchers specializing in a given knowledge field, discipline or topic.
"""
function search_authors_by_topic(engine::SearchEngine, topic_query::AbstractString; top::Int=10)
    ensure_authors_loaded!(engine)
    target_inv = engine.authors_topic_invfile !== nothing ? engine.authors_topic_invfile : engine.authors_invfile
    if target_inv === nothing || engine.authors_data === nothing
        return Dict("query" => topic_query, "total_hits" => 0, "authors" => [], "time_ms" => 0.0)
    end
    
    t0 = time()
    res = search(target_inv, engine.ctx, topic_query, knnqueue(engine.ctx, top))
    t1 = time()
    
    hits = Dict{String, Any}[]
    for item in res
        idx = item.id
        (idx < 1 || idx > length(engine.authors_data)) && continue
        auth = engine.authors_data[idx]
        push!(hits, Dict(
            "name" => get(auth, "name", ""),
            "role" => get(auth, "role", "Autor"),
            "doc_count" => get(auth, "doc_count", 0),
            "repos" => get(auth, "repos", String[]),
            "coauthors" => get(auth, "coauthors", String[]),
            "keywords" => get(auth, "keywords", String[]),
            "score" => round(-item.dist, digits=2)
        ))
    end
    
    return Dict(
        "query" => topic_query,
        "total_hits" => length(hits),
        "authors" => hits,
        "time_ms" => round((t1 - t0) * 1000, digits=2)
    )
end

"""
    find_similar_authors_by_references(engine::SearchEngine, author_name::AbstractString; top::Int=10)

Finds researchers with bibliographic coupling (authors that cite similar literature and references).
"""
function find_similar_authors_by_references(engine::SearchEngine, author_name::AbstractString; top::Int=10)
    ensure_authors_loaded!(engine)
    ensure_references_loaded!(engine)
    if engine.authors_data === nothing || engine.references_invfile === nothing || engine.docs === nothing
        return Dict("author" => author_name, "total_hits" => 0, "similar_authors" => [], "time_ms" => 0.0)
    end
    
    t0 = time()
    # 1. Locate the target author record
    clean_target = lowercase(strip(author_name))
    auth_idx = findfirst(a -> occursin(clean_target, lowercase(a["name"])), engine.authors_data)
    
    if auth_idx === nothing
        return Dict("author" => author_name, "total_hits" => 0, "similar_authors" => [], "time_ms" => 0.0, "error" => "Autor no encontrado")
    end
    
    target_author = engine.authors_data[auth_idx]
    target_name = target_author["name"]
    cited_refs = get(target_author, "cited_references", String[])
    
    # If no explicit references stored for author, use keywords and topics as proxy
    query_str = if !isempty(cited_refs)
        join(cited_refs[1:min(15, length(cited_refs))], " \n ")
    else
        get(target_author, "topic_text", target_name)
    end
    
    # 2. Search citations corpus with author's references
    res = search(engine.references_invfile, engine.ctx, query_str, knnqueue(engine.ctx, top * 10))
    
    # 3. Aggregate authors of citing documents
    author_scores = Dict{String, Float64}()
    author_shared_refs = Dict{String, Int}()
    
    for item in res
        r_idx = item.id
        (r_idx < 1 || r_idx > length(engine.references_data)) && continue
        ref = engine.references_data[r_idx]
        doc_id = get(ref, "doc_id", "")
        
        doc = get_doc_by_id(engine, doc_id)
        doc === nothing && continue
        
        doc_creators = get(doc, "creators", String[])
        for c in doc_creators
            c == target_name && continue
            author_scores[c] = get(author_scores, c, 0.0) + (-item.dist)
            author_shared_refs[c] = get(author_shared_refs, c, 0) + 1
        end
    end
    
    # Sort candidate authors
    ranked = sort(collect(author_scores), by=x->x[2], rev=true)
    results = Dict{String, Any}[]
    
    for (candidate_name, score) in ranked[1:min(top, length(ranked))]
        c_idx = findfirst(a -> a["name"] == candidate_name, engine.authors_data)
        c_data = c_idx !== nothing ? engine.authors_data[c_idx] : nothing
        
        push!(results, Dict(
            "name" => candidate_name,
            "role" => c_data !== nothing ? c_data["role"] : "Autor",
            "doc_count" => c_data !== nothing ? c_data["doc_count"] : 1,
            "repos" => c_data !== nothing ? c_data["repos"] : String[],
            "keywords" => c_data !== nothing ? c_data["keywords"] : String[],
            "shared_citation_matches" => author_shared_refs[candidate_name],
            "similarity_score" => round(score, digits=2)
        ))
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
    search_references(engine::SearchEngine, query::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)

Searches across the citations corpus to discover who cites a specific author, book, paper or theory.
Returns references with full origin traceability back to the citing document and repo.
"""
function search_references(engine::SearchEngine, query::AbstractString; top::Int=10, repo::Union{String, Nothing}=nothing)
    ensure_references_loaded!(engine)
    if engine.references_invfile === nothing || engine.references_data === nothing
        return Dict("query" => query, "total_hits" => 0, "references" => [], "time_ms" => 0.0)
    end
    
    t0 = time()
    knn_k = top * (repo !== nothing ? 5 : 1)
    res = search(engine.references_invfile, engine.ctx, query, knnqueue(engine.ctx, knn_k))
    
    results = Dict{String, Any}[]
    for item in res
        idx = item.id
        (idx < 1 || idx > length(engine.references_data)) && continue
        ref = engine.references_data[idx]
        
        if repo !== nothing && !isempty(repo) && get(ref, "repo", "") != repo
            continue
        end
        
        push!(results, Dict(
            "ref_id" => get(ref, "ref_id", ""),
            "doc_id" => get(ref, "doc_id", ""),
            "doc_title" => get(ref, "doc_title", ""),
            "repo" => get(ref, "repo", ""),
            "ref_num" => get(ref, "ref_num", 0),
            "text" => get(ref, "text", ""),
            "year" => get(ref, "year", ""),
            "authors" => get(ref, "authors", String[]),
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
    get_document_references(engine::SearchEngine, doc_id_or_idx::Union{Integer, AbstractString})

Retrieves all bibliographic references cited by a specific document.
"""
function get_document_references(engine::SearchEngine, doc_id_or_idx::Union{Integer, AbstractString})
    doc = if doc_id_or_idx isa Integer
        idx = Int(doc_id_or_idx)
        (idx >= 1 && idx <= length(engine.docs)) ? engine.docs[idx] : nothing
    else
        found_idx = findfirst(d -> d["id"] == String(doc_id_or_idx), engine.docs)
        found_idx !== nothing ? engine.docs[found_idx] : nothing
    end
    
    doc === nothing && return Dict("error" => "Documento no encontrado", "references" => [])
    
    refs = get(doc, "references", Dict{String, Any}[])
    return Dict(
        "doc_id" => get(doc, "id", ""),
        "doc_title" => get(doc, "title", ""),
        "repo" => get(doc, "repo", ""),
        "total_references" => length(refs),
        "references" => refs
    )
end

"""
    search_document_paragraphs(engine::SearchEngine, doc_id_or_idx::Union{Integer, AbstractString}, query::AbstractString; top::Int=5)

Searches inside the full text of a long document, returning the most relevant paragraphs and sections.
"""
function search_document_paragraphs(engine::SearchEngine, doc_id_or_idx::Union{Integer, AbstractString}, query::AbstractString; top::Int=5)
    doc = if doc_id_or_idx isa Integer
        idx = Int(doc_id_or_idx)
        (idx >= 1 && idx <= length(engine.docs)) ? engine.docs[idx] : nothing
    else
        found_idx = findfirst(d -> d["id"] == String(doc_id_or_idx), engine.docs)
        found_idx !== nothing ? engine.docs[found_idx] : nothing
    end
    
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
        "doc_id" => get(doc, "id", ""),
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

Computes rich, faceted statistics globally or for a specific institutional repository.
"""
function get_detailed_statistics(engine::SearchEngine; repo::Union{AbstractString, Nothing}=nothing)
    ensure_authors_loaded!(engine)
    if engine.docs === nothing || isempty(engine.docs)
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
    
    # Filter docs according to repo
    for doc in engine.docs
        doc_repo = get(doc, "repo", "")
        if clean_repo !== nothing && doc_repo != clean_repo
            continue
        end
        
        total_docs += 1
        
        if get(doc, "file", nothing) !== nothing
            total_files += 1
        end
        
        if get(doc, "has_fulltext", false)
            total_fulltext += 1
        end
        
        rcnt = get(doc, "reference_count", 0)
        total_refs += rcnt
        
        # Publication type
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
        
        # Repository distribution
        repos_count[doc_repo] = get(repos_count, doc_repo, 0) + 1
        
        # Keywords / Disciplines
        kws = get(doc, "keywords", String[])
        for kw in kws
            k_clean = strip(kw)
            isempty(k_clean) && continue
            lowercase(k_clean) in GENERIC_TAGS && continue
            kws_count[k_clean] = get(kws_count, k_clean, 0) + 1
        end
        
        # Years
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
    
    # Sort types
    sorted_types = sort([Dict("type" => k, "count" => v) for (k, v) in types_count], by=x->x["count"], rev=true)
    
    # Sort disciplines / keywords
    sorted_kws = sort([Dict("discipline" => k, "count" => v) for (k, v) in kws_count], by=x->x["count"], rev=true)
    
    # Sort repositories
    sorted_repos = sort([Dict("repo" => k, "count" => v) for (k, v) in repos_count], by=x->x["count"], rev=true)
    
    # Top authors for target repo or global
    top_authors = Dict{String, Any}[]
    if engine.authors_data !== nothing
        filtered_authors = filter(engine.authors_data) do a
            clean_repo === nothing || (clean_repo in get(a, "repos", String[]))
        end
        sort!(filtered_authors, by=a->a["doc_count"], rev=true)
        for a in filtered_authors[1:min(12, length(filtered_authors))]
            push!(top_authors, Dict(
                "name" => a["name"],
                "role" => a["role"],
                "doc_count" => a["doc_count"],
                "repos" => a["repos"],
                "keywords" => a["keywords"][1:min(4, length(a["keywords"]))]
            ))
        end
    end
    
    year_min = isempty(years_list) ? "N/A" : string(minimum(years_list))
    year_max = isempty(years_list) ? "N/A" : string(maximum(years_list))
    
    return Dict(
        "is_global" => clean_repo === nothing,
        "target_repo" => clean_repo,
        "total_docs" => total_docs,
        "total_files" => total_files,
        "total_fulltext" => total_fulltext,
        "total_references" => total_refs,
        "total_authors" => engine.authors_data !== nothing ? length(engine.authors_data) : 0,
        "year_min" => year_min,
        "year_max" => year_max,
        "types_distribution" => sorted_types,
        "top_disciplines" => sorted_kws[1:min(15, length(sorted_kws))],
        "top_repositories" => sorted_repos,
        "top_authors" => top_authors
    )
end

end # module Search
