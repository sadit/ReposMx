module Indexing

using Serialization, JSON
using TextSearch, SimilaritySearch
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Types: ParagraphHit, ReferenceRecord
using ..Storage: get_repo_dir, load_corpus_records, list_repo_names
using ..Corpus: build_repository_corpus, build_authors_index_data, build_references_index_data, split_into_paragraphs
using ..TextModel: create_bilingual_textconfig, sample_bilingual_corpus, fit_bilingual_bm25

export build_search_index, build_authors_index, build_references_index,
       load_search_index, load_authors_index, load_references_index,
       search_document_in_depth, extract_index_text

"""
    extract_index_text(doc::Dict)

Combines Title (boosted), Keywords/Subject (boosted), Abstract, and Conclusions for the primary index.
Leaves raw massive fulltext in a separate corpus to prevent vocabulary dilution.
"""
function extract_index_text(doc::Dict)
    parts = String[]
    
    # 1. Title (boosted x3)
    t = get(doc, "title", "")
    if !isempty(t)
        push!(parts, "$t . $t . $t")
    end
    
    # 2. Authors and Creators (boosted x2)
    creators = get(doc, "creators", String[])
    creator_str = !isempty(creators) ? join(creators, " , ") : get(doc, "creator", "")
    if !isempty(creator_str)
        push!(parts, "$creator_str . $creator_str")
    end
    
    # 3. Contributors / Advisors / Directors
    contributors = get(doc, "contributors", String[])
    contrib_str = !isempty(contributors) ? join(contributors, " , ") : get(doc, "contributor", "")
    if !isempty(contrib_str)
        push!(parts, contrib_str)
    end
    
    # 4. Keywords / Disciplines / Subject (boosted x2)
    s = get(doc, "subject", "")
    kws = get(doc, "keywords", String[])
    kw_str = !isempty(kws) ? join(kws, " , ") : s
    if !isempty(kw_str)
        push!(parts, "$kw_str . $kw_str")
    end
    
    # 5. Abstract / Description
    d = get(doc, "description", "")
    if !isempty(d)
        push!(parts, d)
    end
    
    # 6. Conclusions / Final remarks
    c = get(doc, "conclusions", "")
    if !isempty(c)
        push!(parts, c)
    end
    
    return join(parts, " \n ")
end

"""
    build_search_index(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR, repos=nothing, max_docs=nothing)

Builds the primary bilingual search index, authors index, and bibliographic references corpus index.
All sub-corpora are cross-linked via `doc_id` and `repo`.
"""
function build_search_index(;
    data_dir=DEFAULT_DATA_DIR,
    index_dir=DEFAULT_INDEX_DIR,
    repos::Union{Vector{String}, Nothing}=nothing,
    max_docs::Union{Int, Nothing}=nothing
)
    mkpath(index_dir)
    target_repos = repos !== nothing ? repos : list_repo_names(; data_dir)
    
    println("Collecting structured documents from $(length(target_repos)) repositories...")
    
    all_docs = Dict{String, Any}[]
    all_texts = String[]
    
    for r in target_repos
        corpus_path = joinpath(get_repo_dir(r; data_dir), "corpus.jsonl")
        if !isfile(corpus_path)
            build_repository_corpus(r; data_dir)
        end
        
        records = load_corpus_records(r; data_dir)
        for doc in records
            max_docs !== nothing && length(all_docs) >= max_docs && break
            stext = extract_index_text(doc)
            isempty(strip(stext)) && continue
            
            push!(all_docs, Dict(
                "id" => get(doc, "id", ""),
                "repo" => get(doc, "repo", r),
                "title" => get(doc, "title", ""),
                "creator" => get(doc, "creator", ""),
                "creators" => get(doc, "creators", String[]),
                "contributor" => get(doc, "contributor", ""),
                "contributors" => get(doc, "contributors", String[]),
                "date" => get(doc, "date", ""),
                "description" => get(doc, "description", ""),
                "subject" => get(doc, "subject", ""),
                "keywords" => get(doc, "keywords", String[]),
                "type" => get(doc, "type", "Documento"),
                "references" => get(doc, "references", Dict{String, Any}[]),
                "reference_count" => get(doc, "reference_count", 0),
                "file" => get(doc, "file", nothing),
                "fulltext_file" => get(doc, "fulltext_file", nothing),
                "has_fulltext" => get(doc, "has_fulltext", false)
            ))
            push!(all_texts, stext)
        end
        max_docs !== nothing && length(all_docs) >= max_docs && break
    end
    
    println("Total documents ready for primary indexing: $(length(all_docs))")
    isempty(all_docs) && return nothing
    
    # 1. Build Primary Search Index (BM25 bilingüe)
    println("Fitting bilingual TextConfig & BM25 primary index with TextSearch 1.1+...")
    config = create_bilingual_textconfig(nlist=[1, 2])
    voc = Vocabulary(config, all_texts)
    invfile = BM25InvertedFile(voc)
    ctx = InvertedFileContext()
    append_items!(invfile, ctx, all_texts)
    
    index_file = joinpath(index_dir, "bm25.bin")
    docs_file = joinpath(index_dir, "docs.bin")
    
    println("Saving primary index to '$index_file'...")
    serialize(index_file, invfile)
    serialize(docs_file, all_docs)
    
    # 2. Build Authors & Contributors Indices (Name search & Topic/Field search)
    println("Building authors and contributors indices (Name & Topic profiles)...")
    authors_data = build_authors_index_data(all_docs)
    authors_names = [a["name"] for a in authors_data]
    authors_topics = [get(a, "topic_text", a["name"]) for a in authors_data]
    
    # 2a. Name index
    auth_config = TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])
    auth_voc = Vocabulary(auth_config, authors_names)
    auth_invfile = BM25InvertedFile(auth_voc)
    auth_ctx = InvertedFileContext()
    append_items!(auth_invfile, auth_ctx, authors_names)
    
    # 2b. Topic profile index
    topic_config = create_bilingual_textconfig(nlist=[1, 2])
    topic_voc = Vocabulary(topic_config, authors_topics)
    topic_invfile = BM25InvertedFile(topic_voc)
    topic_ctx = InvertedFileContext()
    append_items!(topic_invfile, topic_ctx, authors_topics)
    
    serialize(joinpath(index_dir, "authors_bm25.bin"), auth_invfile)
    serialize(joinpath(index_dir, "authors_topics_bm25.bin"), topic_invfile)
    serialize(joinpath(index_dir, "authors.bin"), authors_data)
    println("Saved $(length(authors_data)) author profiles with topic vectors.")
    
    # 3. Build Bibliographic References Corpus & Index
    println("Building bibliographic references corpus and index...")
    refs_data = build_references_index_data(all_docs)
    refs_texts = [get(r, "text", "") for r in refs_data]
    
    if !isempty(refs_texts)
        ref_config = create_bilingual_textconfig(nlist=[1, 2])
        ref_voc = Vocabulary(ref_config, refs_texts)
        ref_invfile = BM25InvertedFile(ref_voc)
        ref_ctx = InvertedFileContext()
        append_items!(ref_invfile, ref_ctx, refs_texts)
        
        serialize(joinpath(index_dir, "references_bm25.bin"), ref_invfile)
        serialize(joinpath(index_dir, "references.bin"), refs_data)
        println("Saved $(length(refs_data)) bibliographic reference entries with full origin traceability.")
    end
    
    println("Search indices successfully built with $(length(invfile)) items.")
    return (invfile, all_docs)
end

"""
    load_search_index(; index_dir=DEFAULT_INDEX_DIR)

Loads the precomputed primary BM25 index and document metadata.
"""
function load_search_index(; index_dir=DEFAULT_INDEX_DIR)
    index_file = joinpath(index_dir, "bm25.bin")
    docs_file = joinpath(index_dir, "docs.bin")
    
    if !isfile(index_file) || !isfile(docs_file)
        return (nothing, nothing)
    end
    
    invfile = deserialize(index_file)
    docs = deserialize(docs_file)
    return (invfile, docs)
end

"""
    load_authors_index(; index_dir=DEFAULT_INDEX_DIR)

Loads author/contributor profiles and index.
"""
function load_authors_index(; index_dir=DEFAULT_INDEX_DIR)
    auth_idx_file = joinpath(index_dir, "authors_bm25.bin")
    auth_topic_file = joinpath(index_dir, "authors_topics_bm25.bin")
    auth_data_file = joinpath(index_dir, "authors.bin")
    
    if !isfile(auth_idx_file) || !isfile(auth_data_file)
        return (nothing, nothing, nothing)
    end
    
    auth_inv = deserialize(auth_idx_file)
    auth_topic_inv = isfile(auth_topic_file) ? deserialize(auth_topic_file) : nothing
    auth_data = deserialize(auth_data_file)
    return (auth_inv, auth_topic_inv, auth_data)
end

"""
    load_references_index(; index_dir=DEFAULT_INDEX_DIR)

Loads bibliographic references corpus and index.
"""
function load_references_index(; index_dir=DEFAULT_INDEX_DIR)
    ref_idx_file = joinpath(index_dir, "references_bm25.bin")
    ref_data_file = joinpath(index_dir, "references.bin")
    
    if !isfile(ref_idx_file) || !isfile(ref_data_file)
        return (nothing, nothing)
    end
    
    ref_inv = deserialize(ref_idx_file)
    ref_data = deserialize(ref_data_file)
    return (ref_inv, ref_data)
end

"""
    search_document_in_depth(fulltext::AbstractString, query::AbstractString; top::Int=5)

Performs an on-the-fly paragraph-level search inside a specific long document.
Returns the top relevant paragraphs and sections matching the query.
"""
function search_document_in_depth(fulltext::AbstractString, query::AbstractString; top::Int=5)
    paragraphs = split_into_paragraphs(fulltext)
    isempty(paragraphs) && return ParagraphHit[]
    
    config = create_bilingual_textconfig(nlist=[1, 2])
    voc = Vocabulary(config, paragraphs)
    invfile = BM25InvertedFile(voc)
    ctx = InvertedFileContext()
    append_items!(invfile, ctx, paragraphs)
    
    res = search(invfile, ctx, query, knnqueue(ctx, top))
    
    hits = ParagraphHit[]
    for item in res
        p_idx = item.id
        (p_idx < 1 || p_idx > length(paragraphs)) && continue
        
        txt = paragraphs[p_idx]
        score = -item.dist
        
        section = if occursin(r"(?i)\bconclusi"i, first(txt, 150))
            "Conclusiones"
        elseif occursin(r"(?i)\b(resumen|abstract)\b"i, first(txt, 150))
            "Resumen"
        elseif occursin(r"(?i)\bintroducci"i, first(txt, 150))
            "Introducción"
        elseif occursin(r"(?i)\bmetodolog"i, first(txt, 150))
            "Metodología"
        elseif occursin(r"(?i)\bresultad"i, first(txt, 150))
            "Resultados"
        else
            "Párrafo #$p_idx"
        end
        
        push!(hits, ParagraphHit(p_idx, section, txt, Float32(score)))
    end
    
    return hits
end

end # module Indexing
