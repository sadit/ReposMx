module Indexing

using TextSearch, SimilaritySearch
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Types: ParagraphHit, ReferenceRecord
using ..Storage: get_repo_dir, load_corpus_records, list_repo_names
using ..Corpus: build_repository_corpus, build_authors_index_data, build_references_index_data, split_into_paragraphs
using ..TextModel: TextProfile, create_bilingual_profile, get_or_create_bilingual_base_profile,
                    refit_bilingual_profile, create_bilingual_textconfig, save_profile, load_profile
using ..DB: Database, open_database, close_database, put_document!, put_author_profile!, put_topics!,
            put_reference!, set_document_references!, link_author_document!, add_coauthor_link!,
            normalize_author_name, rocksdb_handle, compact_all!, precompute_all_statistics!
using ..LazyBM25: export_to_rocksdb!, assemble_bm25,
                  LazyDocKeys, LazyAuthorKeys, export_dockeys_to_rocksdb!, export_authorkeys_to_rocksdb!,
                  DOCS_CONTENT, DOCS_REFS, AUTHORS_NAME, AUTHORS_PROFILE
using ..VocabIO: save_vocabulary_zip, load_vocabulary_zip
using ..IndexShellIO: save_index_shell_zip, load_index_shell_zip

export build_search_index,
       load_docs_content_index, load_docs_refs_index,
       load_authors_name_index, load_authors_profile_index,
       search_document_in_depth, extract_index_text

# Minimum document frequency for a token to survive in the docs_refs vocabulary. Measured on
# real data (10-repo subset): min_ndocs=5 cuts vocsize from 849,793 to 148,225 (~83%) while
# only ~4 documents (out of thousands with real reference text) lose all their searchable
# content to the pruning. Only docs_refs gets this treatment for now — its vocabulary is
# uniquely long-tailed (bibliographic text: proper nouns, journal names, DOIs, OCR noise);
# docs_content/authors_name/authors_profile have not been profiled the same way yet.
const DOCS_REFS_MIN_NDOCS = 5

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

Builds the 4 segregated homogeneous BM25 search indices (vocabulary + shell as JSON/zip,
postings/doc-vectors in RocksDB — see `VocabIO`, `IndexShellIO`, `LazyBM25`), and populates the
RocksDB database with all metadata, author profiles, and references.
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
    docs_content_texts = String[]
    docs_refs_texts = String[]
    doc_keys = Tuple{String, String}[]
    
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
            
            repo = get(doc, "repo", r)
            doc_id = get(doc, "id", "")
            isempty(doc_id) && continue
            
            doc_refs = get(doc, "references", Dict{String, Any}[])
            ref_texts = [get(ref, "text", "") for ref in doc_refs]
            
            clean_doc = Dict(
                "id" => doc_id,
                "repo" => repo,
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
                "references" => doc_refs,
                "reference_count" => length(doc_refs),
                "file" => get(doc, "file", nothing),
                "fulltext_file" => get(doc, "fulltext_file", nothing),
                "has_fulltext" => get(doc, "has_fulltext", false)
            )
            
            push!(all_docs, clean_doc)
            push!(docs_content_texts, stext)
            push!(docs_refs_texts, join(ref_texts, " \n "))
            push!(doc_keys, (repo, doc_id))
        end
        max_docs !== nothing && length(all_docs) >= max_docs && break
    end
    
    println("Total documents ready for indexing: $(length(all_docs))")
    isempty(all_docs) && return nothing
    
    # -------------------------------------------------------------
    # 0. Ingest Documents, Authors, and References to RocksDB
    # -------------------------------------------------------------
    println("Populating RocksDB database backend...")
    db_path = joinpath(data_dir, "rocksdb")
    db = open_database(db_path; create_if_missing=true)
    rdb = rocksdb_handle(db)

    authors_data = build_authors_index_data(all_docs)

    # `db`/`rdb` stay open through the RocksDB metadata ingestion below AND through the
    # 4 BM25 posting-list/docvec exports further down (LazyBM25.export_to_rocksdb! writes
    # into the same RocksDB instance), closing only once at the very end of this function.
    try
        # doc_keys is shared by docs_content_invfile and docs_refs_invfile (built together,
        # same order, in the collection loop above), so it is exported once here rather than
        # once per index.
        export_dockeys_to_rocksdb!(rdb, doc_keys)

        # Ingest documents and topics into RocksDB
        for doc in all_docs
            repo = doc["repo"]
            doc_id = doc["id"]
            put_document!(db, repo, doc_id, doc)
            put_topics!(db, doc)
            
            creators = get(doc, "creators", String[])
            for a in creators
                link_author_document!(db, a, repo, doc_id; role="Autor", year=get(doc, "date", ""))
            end
            contributors = get(doc, "contributors", String[])
            for a in contributors
                link_author_document!(db, a, repo, doc_id; role="Colaborador / Asesor", year=get(doc, "date", ""))
            end
            all_auths = vcat(creators, contributors)
            for x in 1:length(all_auths), y in (x+1):length(all_auths)
                add_coauthor_link!(db, all_auths[x], all_auths[y])
            end
            
            doc_refs = get(doc, "references", Dict{String, Any}[])
            if !isempty(doc_refs)
                ref_ids = String[]
                for ref in doc_refs
                    ref_id = get(ref, "ref_id", "")
                    if !isempty(ref_id)
                        push!(ref_ids, ref_id)
                        put_reference!(db, ref)
                    end
                end
                set_document_references!(db, repo, doc_id, ref_ids)
            end
        end
        
        # Ingest author profiles into RocksDB
        for a in authors_data
            norm_name = normalize_author_name(a["name"])
            a["norm_name"] = norm_name
            put_author_profile!(db, norm_name, a)
        end
        println("RocksDB populated with $(length(all_docs)) docs and $(length(authors_data)) author profiles.")

        # -------------------------------------------------------------
        # 1. Index 1: Documents by Content (docs_content_shell.zip)
        # -------------------------------------------------------------
        println("Fitting bilingual TextProfile & refit for Document Content Index...")
        base_profile = get_or_create_bilingual_base_profile(; verbose=true)
        refitted_profile = refit_bilingual_profile(base_profile, docs_content_texts; verbose=true)

        println("Building BM25 for Documents by Content ($(length(refitted_profile.model.voc)) tokens)...")
        docs_content_invfile = BM25InvertedFile(refitted_profile.model.voc)
        ctx1 = InvertedFileContext()
        append_items!(docs_content_invfile, ctx1, docs_content_texts)

        export_to_rocksdb!(rdb, DOCS_CONTENT, docs_content_invfile)
        save_vocabulary_zip(joinpath(index_dir, "docs_content_vocab.zip"), docs_content_invfile.voc)
        save_index_shell_zip(joinpath(index_dir, "docs_content_shell.zip");
                bm25=docs_content_invfile.bm25,
                doclens=docs_content_invfile.doclens, len=docs_content_invfile.len[],
                query=docs_content_invfile.query)
        save_profile(joinpath(index_dir, "profile"), refitted_profile)
        println("Saved Index 1: docs_content_shell.zip + docs_content_vocab.zip (postings/docvecs in RocksDB)")

        # -------------------------------------------------------------
        # 2. Index 2: Documents by References (docs_refs_shell.zip)
        # -------------------------------------------------------------
        println("Building BM25 for Documents by References...")
        docs_refs_voc_full = Vocabulary(refitted_profile.model.voc.textconfig, docs_refs_texts)
        # Bibliographic reference text is extremely long-tailed (proper nouns, journal names,
        # DOIs/URLs, OCR noise): measured on real data, pruning tokens seen in fewer than
        # DOCS_REFS_MIN_NDOCS documents cuts vocsize by ~83% while costing only ~4 extra documents
        # their entire searchable content (out of thousands that had real reference text) — the
        # rest of the "loss" is documents that had no reference text to begin with either way.
        docs_refs_voc = filter_tokens(t -> t.ndocs >= DOCS_REFS_MIN_NDOCS, docs_refs_voc_full)
        println("  docs_refs vocabulary pruned by min_ndocs=$DOCS_REFS_MIN_NDOCS: $(vocsize(docs_refs_voc_full)) -> $(vocsize(docs_refs_voc)) tokens")
        docs_refs_invfile = BM25InvertedFile(docs_refs_voc)
        ctx2 = InvertedFileContext()
        append_items!(docs_refs_invfile, ctx2, docs_refs_texts)

        export_to_rocksdb!(rdb, DOCS_REFS, docs_refs_invfile)
        save_vocabulary_zip(joinpath(index_dir, "docs_refs_vocab.zip"), docs_refs_invfile.voc)
        save_index_shell_zip(joinpath(index_dir, "docs_refs_shell.zip");
                bm25=docs_refs_invfile.bm25,
                doclens=docs_refs_invfile.doclens, len=docs_refs_invfile.len[],
                query=docs_refs_invfile.query)
        println("Saved Index 2: docs_refs_shell.zip + docs_refs_vocab.zip (postings/docvecs in RocksDB)")

        # -------------------------------------------------------------
        # 3. Index 3: Authors by Name (authors_name_shell.zip)
        # -------------------------------------------------------------
        println("Building BM25 for Authors by Name...")
        authors_names = [a["name"] for a in authors_data]
        author_keys = [normalize_author_name(a["name"]) for a in authors_data]

        # author_keys is shared by authors_name_invfile and authors_profile_invfile (both
        # built from `authors_data` in the same order), so it is exported once here.
        export_authorkeys_to_rocksdb!(rdb, author_keys)

        auth_name_config = TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])
        auth_name_voc = Vocabulary(auth_name_config, authors_names)
        authors_name_invfile = BM25InvertedFile(auth_name_voc)
        ctx3 = InvertedFileContext()
        append_items!(authors_name_invfile, ctx3, authors_names)

        export_to_rocksdb!(rdb, AUTHORS_NAME, authors_name_invfile)
        save_vocabulary_zip(joinpath(index_dir, "authors_name_vocab.zip"), authors_name_invfile.voc)
        save_index_shell_zip(joinpath(index_dir, "authors_name_shell.zip");
                bm25=authors_name_invfile.bm25,
                doclens=authors_name_invfile.doclens, len=authors_name_invfile.len[],
                query=authors_name_invfile.query)
        println("Saved Index 3: authors_name_shell.zip + authors_name_vocab.zip (postings/docvecs in RocksDB)")

        # -------------------------------------------------------------
        # 4. Index 4: Authors by Profile & Citations (authors_profile_shell.zip)
        # -------------------------------------------------------------
        println("Building BM25 for Authors by Semantic Profile & References...")
        authors_profile_texts = [
            "$(a["name"]) . $(join(get(a, "keywords", []), " , ")) . $(join(get(a, "topic_texts", []), " \n ")) . $(join(get(a, "cited_references", []), " \n "))"
            for a in authors_data
        ]

        authors_profile_voc = Vocabulary(refitted_profile.model.voc.textconfig, authors_profile_texts)
        authors_profile_invfile = BM25InvertedFile(authors_profile_voc)
        ctx4 = InvertedFileContext()
        append_items!(authors_profile_invfile, ctx4, authors_profile_texts)

        export_to_rocksdb!(rdb, AUTHORS_PROFILE, authors_profile_invfile)
        save_vocabulary_zip(joinpath(index_dir, "authors_profile_vocab.zip"), authors_profile_invfile.voc)
        save_index_shell_zip(joinpath(index_dir, "authors_profile_shell.zip");
                bm25=authors_profile_invfile.bm25,
                doclens=authors_profile_invfile.doclens, len=authors_profile_invfile.len[],
                query=authors_profile_invfile.query)
        println("Saved Index 4: authors_profile_shell.zip + authors_profile_vocab.zip (postings/docvecs in RocksDB)")

        # Clean up legacy .bin files if present
        for bin_f in ["bm25.bin", "docs.bin", "authors.bin", "authors_bm25.bin", "authors_topics_bm25.bin", "references.bin", "references_bm25.bin"]
            p = joinpath(index_dir, bin_f)
            isfile(p) && rm(p; force=true)
        end

        println("All 4 lazy BM25 indices and RocksDB backend successfully built.")

        println("Precomputing global and per-repo statistics...")
        precompute_all_statistics!(db, length(author_keys))
        println("Statistics precomputed.")

        println("Compacting RocksDB (reclaims write-ahead logs from this bulk-write session)...")
        compact_all!(db)
        println("Compaction complete.")

        return docs_content_invfile
    finally
        close_database(db)
    end
end

"""
    load_docs_content_index(db::Database; index_dir=DEFAULT_INDEX_DIR)

Loads the vocabulary from its `.zip` (via `VocabIO.load_vocabulary_zip`) plus the small shell —
BM25 params/doc lengths/query pipeline — from its own `.zip` (via
`IndexShellIO.load_index_shell_zip`; see that module's docstring for why this replaced a JLD2
`jldsave`/`JLD2.load` round-trip), and assembles a `BM25InvertedFile` whose posting lists and
per-document term vectors are read lazily from RocksDB (`postings`/`docvecs` column families)
instead of being deserialized eagerly into RAM.
"""
function load_docs_content_index(db::Union{Database, Nothing}; index_dir=DEFAULT_INDEX_DIR)
    f = joinpath(index_dir, "docs_content_shell.zip")
    vf = joinpath(index_dir, "docs_content_vocab.zip")
    (db === nothing || !isfile(f) || !isfile(vf)) && return (nothing, Tuple{String, String}[])
    d = load_index_shell_zip(f)
    voc = load_vocabulary_zip(vf)
    rdb = rocksdb_handle(db)
    invfile = assemble_bm25(rdb, DOCS_CONTENT, voc, d.bm25, d.doclens, d.len, d.query)
    return (invfile, LazyDocKeys(rdb, length(d.doclens)))
end

"""
    load_docs_refs_index(db::Database; index_dir=DEFAULT_INDEX_DIR)
"""
function load_docs_refs_index(db::Union{Database, Nothing}; index_dir=DEFAULT_INDEX_DIR)
    f = joinpath(index_dir, "docs_refs_shell.zip")
    vf = joinpath(index_dir, "docs_refs_vocab.zip")
    (db === nothing || !isfile(f) || !isfile(vf)) && return (nothing, Tuple{String, String}[])
    d = load_index_shell_zip(f)
    voc = load_vocabulary_zip(vf)
    rdb = rocksdb_handle(db)
    invfile = assemble_bm25(rdb, DOCS_REFS, voc, d.bm25, d.doclens, d.len, d.query)
    return (invfile, LazyDocKeys(rdb, length(d.doclens)))
end

"""
    load_authors_name_index(db::Database; index_dir=DEFAULT_INDEX_DIR)
"""
function load_authors_name_index(db::Union{Database, Nothing}; index_dir=DEFAULT_INDEX_DIR)
    f = joinpath(index_dir, "authors_name_shell.zip")
    vf = joinpath(index_dir, "authors_name_vocab.zip")
    (db === nothing || !isfile(f) || !isfile(vf)) && return (nothing, String[])
    d = load_index_shell_zip(f)
    voc = load_vocabulary_zip(vf)
    rdb = rocksdb_handle(db)
    invfile = assemble_bm25(rdb, AUTHORS_NAME, voc, d.bm25, d.doclens, d.len, d.query)
    return (invfile, LazyAuthorKeys(rdb, length(d.doclens)))
end

"""
    load_authors_profile_index(db::Database; index_dir=DEFAULT_INDEX_DIR)
"""
function load_authors_profile_index(db::Union{Database, Nothing}; index_dir=DEFAULT_INDEX_DIR)
    f = joinpath(index_dir, "authors_profile_shell.zip")
    vf = joinpath(index_dir, "authors_profile_vocab.zip")
    (db === nothing || !isfile(f) || !isfile(vf)) && return (nothing, String[])
    d = load_index_shell_zip(f)
    voc = load_vocabulary_zip(vf)
    rdb = rocksdb_handle(db)
    invfile = assemble_bm25(rdb, AUTHORS_PROFILE, voc, d.bm25, d.doclens, d.len, d.query)
    return (invfile, LazyAuthorKeys(rdb, length(d.doclens)))
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
