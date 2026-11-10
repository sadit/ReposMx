module Indexing

using TextSearch, SimilaritySearch
import RocksDB
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Types: ParagraphHit
using ..Storage: get_repo_dir, load_corpus_records, list_repo_names
using ..Corpus: build_repository_corpus, build_authors_index_data, repair_author_names!, split_into_paragraphs
using ..TextModel: base_profile, refit_corpus_profile, create_textconfig, save_profile, load_profile
using ..DB: Database, open_database, close_database, put_author_profile!, put_topics!,
            put_reference!, set_document_references!, link_author_document!, add_coauthor_link!,
            put_author_id_mapping!, normalize_author_name, rocksdb_handle, compact_all!, precompute_all_statistics!,
            put_consolidated_profile!
using ..EngineIndex: DOCS_CONTENT, DOCS_REFS, AUTHORS_NAME, AUTHORS_PROFILE, engine_workdir, index_profile,
                     build_text_project!, doc_key_of
using ..AuthorConsolidation: build_and_persist, load_all, AUTHOR_NAME_CONFIG, assign_raw_ids
using ..AuthorGrouping: group_authors

export build_search_index, rebuild_authors_index, doc_meta,
       search_document_in_depth, extract_index_text

# Minimum document frequency for a token to survive in the docs_refs vocabulary. Measured on
# real data (10-repo subset): min_ndocs=5 cuts vocsize from 849,793 to 148,225 (~83%) while
# only ~4 documents (out of thousands with real reference text) lose all their searchable
# content to the pruning. docs_refs' vocabulary is uniquely long-tailed (bibliographic text:
# proper nouns, journal names, DOIs, OCR noise), so it gets a more aggressive threshold than
# docs_content/authors_profile below.
const DOCS_REFS_MIN_NDOCS = 5

# Measured on the same 10-repo subset: min_ndocs=3 cuts docs_content from 279,021 to 108,709
# tokens (61%) and authors_profile from 400,698 to 165,733 (59%), in both cases with 0 documents
# losing all their searchable content (validated the same way as DOCS_REFS_MIN_NDOCS: built the
# real BM25InvertedFile and counted doclens==0). authors_name is deliberately left unpruned — it's
# built from a display-name string plus its initials form, not free text, so there's no long tail
# to trim and pruning would just delete real name tokens.
const DOCS_CONTENT_MIN_NDOCS = 3
const AUTHORS_PROFILE_MIN_NDOCS = 3

# Author-profile RocksDB writes have no read-before-write step (unlike coauthor links), so they
# can safely batch across many authors at once instead of one `write!` per document — flushed
# every AUTHOR_BATCH_SIZE profiles to keep any single batch's memory bounded on a large corpus.
const AUTHOR_BATCH_SIZE = 2000

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
    _collect_documents(; data_dir, repos, max_docs)

Shared by `build_search_index` and `rebuild_authors_index`: scans `corpus.jsonl` for the target
repos and returns `(all_docs, docs_content_texts, docs_refs_texts, doc_keys)`. Not the expensive
part of indexing (no tokenization happens here) — safe to redo standalone. The author names of
`all_docs` are repaired with `Corpus.repair_author_names!` before they are returned.
"""
function _collect_documents(; data_dir=DEFAULT_DATA_DIR, repos::Union{Vector{String}, Nothing}=nothing,
                              max_docs::Union{Int, Nothing}=nothing)
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
                "publisher" => get(doc, "publisher", ""),
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
    println("  author names with a lost letter repaired: $(repair_author_names!(all_docs))")
    return all_docs, docs_content_texts, docs_refs_texts, doc_keys
end

"""
    doc_meta(doc) -> Dict{String,Any}

The `meta` of a document in the `docs_content` project: the fields `_collect_documents` keeps,
plus `year`, the first year between 1900 and 2099 found in `date` (an `Int`, or `nothing`). The
year filter of `query_index` compares that integer.
"""
function doc_meta(doc::AbstractDict)
    meta = Dict{String,Any}(string(k) => v for (k, v) in doc)
    m = match(r"\b(19\d\d|20\d\d)\b", string(get(doc, "date", "")))
    meta["year"] = m === nothing ? nothing : parse(Int, m.match)
    return meta
end

"""
    _repos_meta(profile) -> Dict{String,Any}

The `meta` of an author in the two author projects: the repositories where the author has
documents, which is their partition field. An author without repositories belongs to no
partition.
"""
function _repos_meta(profile::AbstractDict)
    repos = String[string(r) for r in get(profile, "repos", String[]) if !isempty(string(r))]
    return isempty(repos) ? Dict{String,Any}() : Dict{String,Any}("repos" => repos)
end

"""
    _replace_dir!(target, built) -> Nothing

Puts the directory `built` in place of `target`. The previous `target` is renamed first and
removed last, so a failure leaves one of the two in place.
"""
function _replace_dir!(target::AbstractString, built::AbstractString)
    old = target * ".old"
    rm(old; recursive=true, force=true)
    isdir(target) && mv(target, old)
    mv(built, target)
    rm(old; recursive=true, force=true)
    return nothing
end

"""
    _ingest_relations!(db, rdb, all_docs, raw_id_of) -> Nothing

Writes the topics, the author-document links, the coauthor links and the references of every
document. One `WriteBatch` per document: `add_coauthor_link!` reads the current count before it
writes it, so the writes of a document must be committed before the next document reads them.
A batch over several documents would undercount a pair of coauthors that appears twice in it.
"""
function _ingest_relations!(db::Database, rdb, all_docs, raw_id_of::AbstractDict)
    wb = RocksDB.WriteBatch()
    for doc in all_docs
        repo = doc["repo"]
        doc_id = doc["id"]
        put_topics!(db, doc; batch=wb)

        creators = get(doc, "creators", String[])
        for a in creators
            link_author_document!(db, raw_id_of[a], repo, doc_id; role="Autor", year=get(doc, "date", ""), batch=wb)
        end
        contributors = get(doc, "contributors", String[])
        for a in contributors
            link_author_document!(db, raw_id_of[a], repo, doc_id; role="Colaborador / Asesor", year=get(doc, "date", ""), batch=wb)
        end
        all_auth_ids = [raw_id_of[a] for a in vcat(creators, contributors)]
        for x in 1:length(all_auth_ids), y in (x+1):length(all_auth_ids)
            add_coauthor_link!(db, all_auth_ids[x], all_auth_ids[y]; batch=wb)
        end

        doc_refs = get(doc, "references", Dict{String, Any}[])
        if !isempty(doc_refs)
            ref_ids = String[]
            for ref in doc_refs
                ref_id = get(ref, "ref_id", "")
                if !isempty(ref_id)
                    push!(ref_ids, ref_id)
                    put_reference!(db, ref; batch=wb)
                end
            end
            set_document_references!(db, repo, doc_id, ref_ids; batch=wb)
        end

        RocksDB.write!(rdb, wb)
        empty!(wb)
    end
    return nothing
end

"""
    _persist_author_profiles_batched!(db, rdb, authors_data, raw_id_of)

Writes every raw author profile (`put_author_profile!`) and its `name2id` mapping
(`put_author_id_mapping!`) via chunked `RocksDB.WriteBatch`es of `AUTHOR_BATCH_SIZE` authors
instead of one native write per call — safe to batch across many authors at once (unlike the
per-document ingestion loop in `_ingest_relations!`) because neither write reads existing state
first: each key is set exactly once, in any order, so nothing depends on flush timing.
"""
function _persist_author_profiles_batched!(db::Database, rdb, authors_data, raw_id_of::AbstractDict)
    wb = RocksDB.WriteBatch()
    for (i, a) in enumerate(authors_data)
        id = raw_id_of[a["name"]]
        put_author_profile!(db, id, a; batch=wb)
        put_author_id_mapping!(db, a["name"], id; batch=wb)
        if i % AUTHOR_BATCH_SIZE == 0
            RocksDB.write!(rdb, wb)
            empty!(wb)
        end
    end
    RocksDB.write!(rdb, wb)
    return nothing
end

"""
    _consolidated_profiles!(db, rdb, authors_data, raw_id_of, index_dir; reuse_authors) -> Vector{Dict}

The consolidated author profiles, written to `db`. With `reuse_authors=false`, the raw profiles
are grouped again (`AuthorGrouping.group_authors`, about 2.2 hours on the full corpus measured
on 2026-10-26) and the TOML corpus under `index_dir` is rewritten. With `reuse_authors=true`,
the TOML corpus already under `index_dir` is read instead, and an empty corpus is an error. That
is valid only while the corpus has not changed since the grouping: the profiles name raw authors
by their ids, and the ids depend on every raw name.
"""
function _consolidated_profiles!(db::Database, rdb, authors_data, raw_id_of::AbstractDict,
                                 index_dir::AbstractString; reuse_authors::Bool)
    if reuse_authors
        consolidated = load_all(index_dir)
        isempty(consolidated) && error("no hay perfiles consolidados en '$index_dir' para reutilizar; " *
                                       "corre 'reposmx index' sin --reuse-authors")
        println("Reusing $(length(consolidated)) consolidated author profiles from $index_dir"); flush(stdout)
    else
        println("Clustering raw author profiles into consolidated profiles..."); flush(stdout)
        groups = group_authors(authors_data)
        n_groups = build_and_persist(authors_data, groups, index_dir, raw_id_of)
        consolidated = load_all(index_dir)
        println("  $(length(authors_data)) raw profiles -> $(n_groups) consolidated profiles")
    end
    wb = RocksDB.WriteBatch()
    for (i, profile) in enumerate(consolidated)
        put_consolidated_profile!(db, profile; batch=wb)
        if i % AUTHOR_BATCH_SIZE == 0
            RocksDB.write!(rdb, wb)
            empty!(wb)
        end
    end
    RocksDB.write!(rdb, wb)
    return consolidated
end

"""
    _build_author_projects!(workdir, consolidated, profile) -> Nothing

Builds the `authors_name` and `authors_profile` projects under `workdir`, one item per
consolidated profile, in the order of `consolidated`. `profile` is the refitted profile of the
documents: `authors_profile` is tokenized with its `TextConfig`, lemmas included.
"""
function _build_author_projects!(workdir::AbstractString, consolidated::AbstractVector, profile::TextProfile)
    cids = String[a["consolidated_id"] for a in consolidated]
    metas = [_repos_meta(a) for a in consolidated]

    println("Building BM25 for Authors by Name..."); flush(stdout)
    names = String["$(a["name"]) . $(a["name_initials_form"])" for a in consolidated]
    name_voc = Vocabulary(AUTHOR_NAME_CONFIG, names)
    build_text_project!(workdir, AUTHORS_NAME, index_profile(name_voc, nothing), names, cids, metas;
                        partition_by="repos")

    println("Building BM25 for Authors by Semantic Profile & References..."); flush(stdout)
    texts = String[
        "$(a["name"]) . $(join(get(a, "keywords", []), " , ")) . $(join(get(a, "topic_texts", []), " \n ")) . $(join(get(a, "cited_references", []), " \n "))"
        for a in consolidated
    ]
    voc_full = Vocabulary(profile.model.voc.textconfig, texts)
    voc = filter_tokens(t -> t.ndocs >= AUTHORS_PROFILE_MIN_NDOCS, voc_full)
    println("  authors_profile vocabulary pruned by min_ndocs=$AUTHORS_PROFILE_MIN_NDOCS: $(vocsize(voc_full)) -> $(vocsize(voc)) tokens")
    build_text_project!(workdir, AUTHORS_PROFILE, index_profile(voc, profile), texts, cids, metas;
                        partition_by="repos")
    return nothing
end

# Files of the index before it moved into SimilaritySearchEngine projects (docs/plan-motor.md,
# phase 2). A rebuild removes them.
const LEGACY_INDEX_FILES = [
    "$(n)_$(s).zip" for n in ("docs_content", "docs_refs", "authors_name", "authors_profile") for s in ("shell", "vocab")
]

"""
    rebuild_authors_index(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR, repos=nothing, max_docs=nothing)

Re-runs author clustering and rebuilds only the `authors_name` and `authors_profile` projects —
not `docs_content`/`docs_refs`, which is the expensive part of `build_search_index` (re-tokenizing
the whole document corpus). Meant to be re-run after editing `author_overrides.toml`: overrides
only change grouping, and grouping only affects these two indices. Requires that
`build_search_index` has already run at least once: it reuses the refitted profile saved under
`<index_dir>/profile`, and it writes into the existing RocksDB of ReposMx. The two projects are
built in a separate directory and replace the previous ones at the end.
"""
function rebuild_authors_index(;
    data_dir=DEFAULT_DATA_DIR,
    index_dir=DEFAULT_INDEX_DIR,
    repos::Union{Vector{String}, Nothing}=nothing,
    max_docs::Union{Int, Nothing}=nothing
)
    profile_path = joinpath(index_dir, "profile")
    isdir(profile_path) ||
        error("No hay un perfil de texto guardado en '$profile_path'. Corre 'reposmx prepare-index' " *
              "al menos una vez antes de usar 'reposmx consolidate-authors'.")
    profile = load_profile(profile_path)

    all_docs, _, _, _ = _collect_documents(; data_dir, repos, max_docs)
    isempty(all_docs) && return nothing

    authors_data = build_authors_index_data(all_docs)
    println("Raw author profiles: $(length(authors_data))"); flush(stdout)
    raw_id_of, n_raw_collisions = assign_raw_ids(authors_data)
    println("  raw ids needing disambiguation: $n_raw_collisions / $(length(authors_data))"); flush(stdout)

    workdir = engine_workdir(index_dir)
    building = workdir * ".authors"
    rm(building; recursive=true, force=true)
    mkpath(building)
    db = open_database(joinpath(data_dir, "rocksdb"); create_if_missing=true)
    rdb = rocksdb_handle(db)
    n_groups = 0
    try
        _persist_author_profiles_batched!(db, rdb, authors_data, raw_id_of)
        consolidated = _consolidated_profiles!(db, rdb, authors_data, raw_id_of, index_dir; reuse_authors=false)
        n_groups = length(consolidated)
        _build_author_projects!(building, consolidated, profile)
        precompute_all_statistics!(db, all_docs, n_groups)
        compact_all!(db)
    finally
        close_database(db)
    end
    for name in (AUTHORS_NAME, AUTHORS_PROFILE)
        _replace_dir!(joinpath(workdir, name), joinpath(building, name))
    end
    rm(building; recursive=true, force=true)
    println("Listo: $(length(authors_data)) perfiles raw -> $n_groups consolidados.")
    return nothing
end

"""
    build_search_index(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR, repos=nothing,
                         max_docs=nothing, reuse_authors=false)

Builds the four text indices as `SimilaritySearchEngine` projects under
`<index_dir>/engine/` (see `EngineIndex`), and the RocksDB of ReposMx under
`<data_dir>/rocksdb`: raw and consolidated author profiles, author-document and coauthor links,
references, topics and statistics. The documents themselves are stored in the `meta` of
`docs_content`.

Both are built from scratch in new directories, which replace the previous ones at the end. A
failure leaves the previous index and database in place. Building from scratch also means that
nothing from a previous build survives: the coauthor counts are not added to the counts of the
previous build, and a document removed from the corpus leaves no keys.

`reuse_authors=true` reads the consolidated author profiles already under `index_dir` instead of
grouping the raw profiles again (see `_consolidated_profiles!`).
"""
function build_search_index(;
    data_dir=DEFAULT_DATA_DIR,
    index_dir=DEFAULT_INDEX_DIR,
    repos::Union{Vector{String}, Nothing}=nothing,
    max_docs::Union{Int, Nothing}=nothing,
    reuse_authors::Bool=false
)
    mkpath(index_dir)
    all_docs, docs_content_texts, docs_refs_texts, doc_keys = _collect_documents(; data_dir, repos, max_docs)
    isempty(all_docs) && return nothing

    authors_data = build_authors_index_data(all_docs)
    for a in authors_data
        a["norm_name"] = normalize_author_name(a["name"])
    end
    raw_id_of, n_raw_collisions = assign_raw_ids(authors_data)
    println("  raw ids needing disambiguation: $n_raw_collisions / $(length(authors_data))")

    workdir = engine_workdir(index_dir)
    building = workdir * ".building"
    db_path = joinpath(data_dir, "rocksdb")
    db_building = db_path * ".building"
    rm(building; recursive=true, force=true)
    rm(db_building; recursive=true, force=true)
    mkpath(building)

    println("Populating RocksDB database backend...")
    db = open_database(db_building; create_if_missing=true)
    rdb = rocksdb_handle(db)
    try
        _ingest_relations!(db, rdb, all_docs, raw_id_of)
        _persist_author_profiles_batched!(db, rdb, authors_data, raw_id_of)
        println("RocksDB populated with $(length(all_docs)) docs and $(length(authors_data)) author profiles.")

        println("Refitting the Spanish TextProfile to the corpus for the Document Content Index...")
        refitted = refit_corpus_profile(base_profile("es"), docs_content_texts; verbose=true)
        keys = String[doc_key_of(r, id) for (r, id) in doc_keys]

        content_voc = filter_tokens(t -> t.ndocs >= DOCS_CONTENT_MIN_NDOCS, refitted.model.voc)
        println("  docs_content vocabulary pruned by min_ndocs=$DOCS_CONTENT_MIN_NDOCS: $(vocsize(refitted.model.voc)) -> $(vocsize(content_voc)) tokens")
        println("Building BM25 for Documents by Content ($(vocsize(content_voc)) tokens)..."); flush(stdout)
        build_text_project!(building, DOCS_CONTENT, index_profile(content_voc, refitted), docs_content_texts,
                            keys, [doc_meta(d) for d in all_docs]; partition_by="repo")

        println("Building BM25 for Documents by References..."); flush(stdout)
        refs_voc_full = Vocabulary(refitted.model.voc.textconfig, docs_refs_texts)
        refs_voc = filter_tokens(t -> t.ndocs >= DOCS_REFS_MIN_NDOCS, refs_voc_full)
        println("  docs_refs vocabulary pruned by min_ndocs=$DOCS_REFS_MIN_NDOCS: $(vocsize(refs_voc_full)) -> $(vocsize(refs_voc)) tokens")
        build_text_project!(building, DOCS_REFS, index_profile(refs_voc, refitted), docs_refs_texts, keys,
                            [Dict{String,Any}("repo" => r) for (r, _) in doc_keys]; partition_by="repo")

        consolidated = _consolidated_profiles!(db, rdb, authors_data, raw_id_of, index_dir; reuse_authors)
        _build_author_projects!(building, consolidated, refitted)

        println("Precomputing global and per-repo statistics...")
        precompute_all_statistics!(db, all_docs, length(consolidated))
        println("Compacting RocksDB (reclaims write-ahead logs from this bulk-write session)...")
        compact_all!(db)
        save_profile(joinpath(index_dir, "profile"), refitted)
    finally
        close_database(db)
    end

    _replace_dir!(workdir, building)
    _replace_dir!(db_path, db_building)
    for f in LEGACY_INDEX_FILES
        rm(joinpath(index_dir, f); force=true)
    end
    println("The 4 engine projects and the RocksDB backend were built.")
    return nothing
end

"""
    search_document_in_depth(fulltext::AbstractString, query::AbstractString; top::Int=5)

Performs an on-the-fly paragraph-level search inside a specific long document.
Returns the top relevant paragraphs and sections matching the query.
"""
function search_document_in_depth(fulltext::AbstractString, query::AbstractString; top::Int=5)
    paragraphs = split_into_paragraphs(fulltext)
    isempty(paragraphs) && return ParagraphHit[]
    
    config = create_textconfig(nlist=[1, 2])
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
