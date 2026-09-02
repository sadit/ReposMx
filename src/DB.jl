module DB

using RocksDB, JSON, JSON3, Dates, SHA
import ..Types: get_document_references
using ..Config: DEFAULT_DATA_DIR
using ..Storage: load_metadata_records, load_corpus_records, list_repo_names, get_repo_dir

export Database, open_database, close_database,
       put_document!, get_document, scan_documents, put_xml!, get_xml,
       put_author_profile!, get_author_profile, get_author_documents, get_coauthors, normalize_author_name,
       put_consolidated_profile!, get_consolidated_profile, get_consolidated_id_for_raw,
       get_author_documents_for_group, get_coauthors_for_group,
       put_reference!, get_reference, get_document_references, get_documents_citing_author,
       put_topics!, get_topic_docs, get_topic_authors, intersect_topic_repo_docs, intersect_topic_repo_authors,
       put_facets!, scan_facet, get_documents_by_year, get_documents_by_type, get_documents_by_repo, get_documents_by_keyword,
       put_fulltext!, get_fulltext, put_paragraphs!, get_paragraphs,
       put_stats!, get_stats, compute_detailed_statistics, precompute_all_statistics!,
       ingest_repository_to_db!, ingest_all_to_db!,
       DEFAULT_ROCKSDB_DIR, rocksdb_handle, compact_all!

const DEFAULT_ROCKSDB_DIR = joinpath(DEFAULT_DATA_DIR, "rocksdb")
const COLUMN_FAMILIES = ["default", "authors", "references", "topics", "fulltext", "stats", "postings", "docvecs", "dockeys", "authorkeys", "consolidated_authors"]

"""
    Database

Wrapper around a multi-column-family RocksDB instance.
"""
mutable struct Database
    db::RocksDB.DB
    path::String
    cfs::Dict{String, RocksDB.ColumnFamily}
    is_open::Bool
end

function Base.show(io::IO, d::Database)
    print(io, "ReposMx.DB.Database(path=\"$(d.path)\", open=$(d.is_open), CFs=$(collect(keys(d.cfs))))")
end

"""
    rocksdb_handle(d::Database) -> RocksDB.DB

Returns the raw `RocksDB.DB` handle wrapped by `d`, for modules (e.g. `LazyBM25`) that need
direct column-family access beyond the `Database` convenience API.
"""
rocksdb_handle(d::Database) = d.db

"""
    compact_all!(d::Database)

Forces a full compaction of every column family. Bulk index-building writes (`build_search_index`,
`ingest_repository_to_db!`) accumulate write-ahead-log files that RocksDB only reclaims once their
data is compacted into SST files; left uncompacted, a subsequent `open_database` must scan/replay
all of them, which can turn a near-instant open into a multi-second one. Call this once after a
bulk-write session, not on every read-only open.
"""
function compact_all!(d::Database)
    for cf in keys(d.cfs)
        compact!(d.db; cf)
    end
    return nothing
end

"""
    list_existing_column_families(path::AbstractString)

Lists all column family names present in an existing RocksDB database directory.
"""
function list_existing_column_families(path::AbstractString)
    !isfile(joinpath(path, "CURRENT")) && return String[]
    opts = RocksDB.Options()
    len_ref = Ref{Csize_t}(0)
    list_ptr = RocksDB.checked() do errptr
        RocksDB.Lib.rocksdb_list_column_families(opts.ptr, path, len_ref, errptr)
    end
    n = Int(len_ref[])
    cf_names = String[]
    for i in 1:n
        cf_ptr = unsafe_load(list_ptr, i)
        push!(cf_names, unsafe_string(cf_ptr))
    end
    RocksDB.Lib.rocksdb_list_column_families_destroy(list_ptr, len_ref[])
    return cf_names
end

"""
    open_database(path=DEFAULT_ROCKSDB_DIR; create_if_missing=true, read_only=false)

Opens or creates a RocksDB database configured with all required Column Families.
"""
function open_database(path::AbstractString=DEFAULT_ROCKSDB_DIR; create_if_missing::Bool=true, read_only::Bool=false)
    mkpath(path)
    
    current_file = joinpath(path, "CURRENT")
    
    if !isfile(current_file)
        if !create_if_missing
            error("Database does not exist at '$path'")
        end
        # Initialize default DB and create Column Families
        init_db = opendb(path; create_if_missing=true)
        for cf in COLUMN_FAMILIES
            cf == "default" && continue
            create_column_family(init_db, cf)
        end
        close(init_db)
        existing_cfs = COLUMN_FAMILIES
    else
        existing_cfs = list_existing_column_families(path)
        missing_cfs = setdiff(COLUMN_FAMILIES, existing_cfs)
        if !isempty(missing_cfs) && !read_only
            temp_db = opendb(path; column_families=existing_cfs, read_only=false)
            for mcf in missing_cfs
                create_column_family(temp_db, mcf)
            end
            close(temp_db)
            existing_cfs = union(existing_cfs, COLUMN_FAMILIES)
        end
    end
    
    open_cfs = union(existing_cfs, COLUMN_FAMILIES)
    db_inst = opendb(path; column_families=open_cfs, read_only)
    cf_map = db_inst.column_families
    
    return Database(db_inst, String(path), cf_map, true)
end

"""
    close_database(db::Database)

Closes the RocksDB instance cleanly.
"""
function close_database(d::Database)
    if d.is_open
        close(d.db)
        d.is_open = false
    end
end

Base.close(d::Database) = close_database(d)

# ====================================================================
# 1. Document & Metadata Operations (CF: default)
# ====================================================================

function normalize_id(id::AbstractString)
    return strip(id)
end

function doc_key(repo::AbstractString, doc_id::AbstractString)
    return "doc:$(strip(repo)):$(normalize_id(doc_id))"
end

function xml_key(repo::AbstractString, doc_id::AbstractString)
    return "xml:$(strip(repo)):$(normalize_id(doc_id))"
end

"""
    put_document!(db::Database, repo, doc_id, doc_dict; batch=nothing)

Saves a structured document into the `default` column family.
"""
function put_document!(d::Database, repo::AbstractString, doc_id::AbstractString, doc::AbstractDict; batch=nothing)
    k = doc_key(repo, doc_id)
    v = JSON.json(doc)
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["default"])
    else
        put!(d.db, k, v; cf="default")
    end
end

"""
    get_document(db::Database, repo, doc_id)

Retrieves a structured document from the `default` column family.
"""
function get_document(d::Database, repo::AbstractString, doc_id::AbstractString)
    k = doc_key(repo, doc_id)
    val = get(d.db, k; cf="default")
    val === nothing && return nothing
    return try
        # JSON3's lazy Object is ~2x faster to read than JSON.parse for these blobs (measured
        # on real data) — safe here because every caller only reads fields (`get(doc, k, ...)`),
        # never mutates the returned object in place.
        JSON3.read(val)
    catch
        nothing
    end
end

"""
    scan_documents(f::Function, d::Database; repo::Union{AbstractString, Nothing}=nothing)

Streams every document (optionally scoped to one `repo`) directly via a prefix scan over the
`default` column family's `doc:` keys, calling `f(doc)` for each parsed document dict. Unlike
looking documents up one-by-one via an external `(repo, doc_id)` index, this reads each document
exactly once and needs no such index — the right tool for a full corpus scan (e.g. computing
global statistics), as opposed to `get_document`, which is the right tool for point lookups of a
handful of already-known documents.
"""
function scan_documents(f::Function, d::Database; repo::Union{AbstractString, Nothing}=nothing)
    prefix = repo === nothing ? "doc:" : "doc:$(strip(repo)):"
    iter = DBIterator(d.db; cf="default")
    seek!(iter, prefix)

    while valid(iter)
        k = String(key(iter))
        !startswith(k, prefix) && break
        doc = try JSON3.read(value(iter)) catch; nothing end
        doc !== nothing && f(doc)
        advance!(iter)
    end
    return nothing
end

"""
    put_xml!(db::Database, repo, doc_id, xml_str; batch=nothing)

Stores raw harvested XML metadata in the `default` column family.
"""
function put_xml!(d::Database, repo::AbstractString, doc_id::AbstractString, xml_str::AbstractString; batch=nothing)
    k = xml_key(repo, doc_id)
    if batch !== nothing
        put!(batch, k, xml_str; cf=d.cfs["default"])
    else
        put!(d.db, k, xml_str; cf="default")
    end
end

"""
    get_xml(db::Database, repo, doc_id)

Retrieves raw harvested XML metadata.
"""
function get_xml(d::Database, repo::AbstractString, doc_id::AbstractString)
    k = xml_key(repo, doc_id)
    val = get(d.db, k; cf="default")
    return val !== nothing ? String(val) : nothing
end

# ====================================================================
# 2. Author Operations (CF: authors)
# ====================================================================

function normalize_author_name(name::AbstractString)
    s = strip(name)
    if occursin(",", s)
        parts = split(s, ","; limit=2)
        if length(parts) == 2 && !isempty(strip(parts[1])) && !isempty(strip(parts[2]))
            s = strip(parts[2]) * " " * strip(parts[1])
        end
    end
    return replace(lowercase(strip(s)), r"[^\p{L}\p{N}]+" => "_")
end

"""
    put_author_id_mapping!(db::Database, raw_name, id; batch=nothing)

Records `normalize_author_name(raw_name) -> id` so a typed name can be resolved to the short id
that actually keys everything else about that raw profile (see [`get_author_id`](@ref)).
"""
function put_author_id_mapping!(d::Database, raw_name::AbstractString, id::AbstractString; batch=nothing)
    k = "name2id:$(normalize_author_name(raw_name))"
    if batch !== nothing
        put!(batch, k, id; cf=d.cfs["authors"])
    else
        put!(d.db, k, id; cf="authors")
    end
end

"""
    get_author_id(db::Database, raw_name) -> Union{String,Nothing}

Reverse lookup for [`put_author_id_mapping!`](@ref).
"""
function get_author_id(d::Database, raw_name::AbstractString)
    val = get(d.db, "name2id:$(normalize_author_name(raw_name))"; cf="authors")
    return val === nothing ? nothing : String(val)
end

"""
    put_author_profile!(db::Database, author_id, profile_dict; batch=nothing)

Saves an author profile in the `authors` column family, keyed by its short id (see
`AuthorConsolidation.assign_id`) — this function no longer knows anything about names or
normalization, it just stores by whatever id the caller already resolved.
"""
function put_author_profile!(d::Database, author_id::AbstractString, profile::AbstractDict; batch=nothing)
    k = "auth:$author_id"
    v = JSON.json(profile)
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["authors"])
    else
        put!(d.db, k, v; cf="authors")
    end
end

"""
    get_author_profile(db::Database, author_id)

Retrieves an author profile from the `authors` column family by its short id.
"""
function get_author_profile(d::Database, author_id::AbstractString)
    k = "auth:$author_id"
    val = get(d.db, k; cf="authors")
    val === nothing && return nothing
    return try JSON.parse(String(val)) catch; nothing end
end

"""
    link_author_document!(db::Database, author_id, repo, doc_id; role="Autor", year="", batch=nothing)

Links an author to a document in the `authors` column family.
"""
function link_author_document!(d::Database, author_id::AbstractString, repo::AbstractString, doc_id::AbstractString; role="Autor", year="", batch=nothing)
    k = "auth_doc:$author_id:$(strip(repo)):$(normalize_id(doc_id))"
    v = JSON.json(Dict("role" => role, "year" => year))
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["authors"])
    else
        put!(d.db, k, v; cf="authors")
    end
end

"""
    get_author_documents(db::Database, author_id; limit::Int=500)

Returns all documents linked to an author via Prefix Scan.
"""
function get_author_documents(d::Database, author_id::AbstractString; limit::Int=500)
    prefix = "auth_doc:$author_id:"
    results = Dict{String, Any}[]

    iter = DBIterator(d.db; cf="authors")
    seek!(iter, prefix)

    while valid(iter) && length(results) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break

        parts = split(k[ncodeunits(prefix)+1:end], ":"; limit=2)
        if length(parts) == 2
            repo, doc_id = parts[1], parts[2]
            payload = try JSON.parse(String(value(iter))) catch; Dict{String, Any}() end
            payload["repo"] = repo
            payload["doc_id"] = doc_id
            push!(results, payload)
        end
        advance!(iter)
    end

    return results
end

"""
    add_coauthor_link!(db::Database, id_a, id_b; count=1, batch=nothing)

Records an edge in the coauthorship graph, accumulating `count` into whatever is already stored
for this pair (read-before-write) rather than overwriting it — two authors who coauthor 10
documents must end up with count=10, not count=1 from whichever call happened to run last.
Writes **both** directions (`coauth:\$a:\$b` and `coauth:\$b:\$a`) so a prefix scan from either
author's id finds the edge — a single-direction write meant whoever appeared later in a
document's author list never saw coauthors who appeared before them.
"""
function add_coauthor_link!(d::Database, id_a::AbstractString, id_b::AbstractString; count::Int=1, batch=nothing)
    id_a == id_b && return
    for (x, y) in ((id_a, id_b), (id_b, id_a))
        k = "coauth:$x:$y"
        existing = get(d.db, k; cf="authors")
        new_count = (existing === nothing ? 0 : parse(Int, String(existing))) + count
        v = string(new_count)
        if batch !== nothing
            put!(batch, k, v; cf=d.cfs["authors"])
        else
            put!(d.db, k, v; cf="authors")
        end
    end
end

"""
    get_coauthors(db::Database, author_id; limit::Int=50)

Returns top coauthors for an author via Prefix Scan.
"""
function get_coauthors(d::Database, author_id::AbstractString; limit::Int=50)
    prefix = "coauth:$author_id:"
    coauthors = Pair{String, Int}[]

    iter = DBIterator(d.db; cf="authors")
    seek!(iter, prefix)

    while valid(iter) && length(coauthors) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        coauth = k[ncodeunits(prefix)+1:end]
        cnt = try parse(Int, String(value(iter))) catch; 1 end
        push!(coauthors, coauth => cnt)
        advance!(iter)
    end

    sort!(coauthors, by=x->x.second, rev=true)
    return coauthors
end

"""
    put_consolidated_profile!(db::Database, profile::AbstractDict; batch=nothing)

Persists a consolidated author profile (see `AuthorConsolidation`) in the `consolidated_authors`
column family, keyed by its own `consolidated_id`, plus a reverse lookup from each of its
`raw_names` back to that id — the raw profiles themselves (`auth:`, in the `authors` CF) are
never touched by this; consolidation is purely an additional layer on top.
"""
function put_consolidated_profile!(d::Database, profile::AbstractDict; batch=nothing)
    cid = profile["consolidated_id"]
    k = "cons:$cid"
    v = JSON.json(profile)
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["consolidated_authors"])
        for raw in profile["raw_names"]
            put!(batch, "raw2cons:$(normalize_author_name(raw))", cid; cf=d.cfs["consolidated_authors"])
        end
    else
        put!(d.db, k, v; cf="consolidated_authors")
        for raw in profile["raw_names"]
            put!(d.db, "raw2cons:$(normalize_author_name(raw))", cid; cf="consolidated_authors")
        end
    end
end

"""
    get_consolidated_profile(db::Database, consolidated_id::AbstractString)

Retrieves a consolidated author profile by its `consolidated_id`.
"""
function get_consolidated_profile(d::Database, consolidated_id::AbstractString)
    val = get(d.db, "cons:$consolidated_id"; cf="consolidated_authors")
    val === nothing && return nothing
    return try JSON.parse(String(val)) catch; nothing end
end

"""
    get_consolidated_id_for_raw(db::Database, raw_name::AbstractString)

Looks up which consolidated group a raw author name belongs to, or `nothing` if it hasn't been
clustered (e.g. the index hasn't been rebuilt since this raw name first appeared).
"""
function get_consolidated_id_for_raw(d::Database, raw_name::AbstractString)
    val = get(d.db, "raw2cons:$(normalize_author_name(raw_name))"; cf="consolidated_authors")
    return val === nothing ? nothing : String(val)
end

"""
    get_author_documents_for_group(db::Database, raw_names::AbstractVector{<:AbstractString}; limit::Int=500)

`get_author_documents` for every raw name in a consolidated group, merged. A consolidated author's
"my documents" view has to union across all its raw variants — `auth_doc:` links stay keyed by
each raw profile's own short id (see `AuthorConsolidation`), never by `consolidated_id`, so each
raw name is first resolved to its id via [`get_author_id`](@ref).
"""
function get_author_documents_for_group(d::Database, raw_names::AbstractVector; limit::Int=500)
    results = Dict{String, Any}[]
    seen = Set{Tuple{String,String}}()
    for raw in raw_names
        id = get_author_id(d, raw)
        id === nothing && continue
        for doc in get_author_documents(d, id; limit)
            key = (doc["repo"], doc["doc_id"])
            key in seen && continue
            push!(seen, key)
            push!(results, doc)
        end
    end
    return results
end

"""
    get_coauthors_for_group(db::Database, raw_names::AbstractVector{<:AbstractString}; limit::Int=50)

`get_coauthors` for every raw name in a consolidated group, with counts summed across raw variants
(excluding coauthor keys that are themselves raw ids inside this same group — those would be
"coauthored with yourself under another spelling"). `coauth:` keys are keyed by raw author id, so
each raw name is first resolved to its id via [`get_author_id`](@ref).
"""
function get_coauthors_for_group(d::Database, raw_names::AbstractVector; limit::Int=50)
    ids = [id for id in (get_author_id(d, r) for r in raw_names) if id !== nothing]
    own_ids = Set(ids)
    totals = Dict{String, Int}()
    for id in ids
        for (coauth, cnt) in get_coauthors(d, id; limit=typemax(Int))
            coauth in own_ids && continue
            totals[coauth] = get(totals, coauth, 0) + cnt
        end
    end
    ranked = sort(collect(totals); by=x -> x.second, rev=true)
    return ranked[1:min(limit, length(ranked))]
end

# ====================================================================
# 3. References & Citation Graph Operations (CF: references)
# ====================================================================

"""
    put_reference!(db::Database, ref_dict; batch=nothing)

Saves a reference record in the `references` column family.
"""
function put_reference!(d::Database, ref::AbstractDict; batch=nothing)
    ref_id = get(ref, "ref_id", "")
    isempty(ref_id) && return
    
    k = "ref:$ref_id"
    v = JSON.json(ref)
    
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["references"])
    else
        put!(d.db, k, v; cf="references")
    end
    
    # Also index cited authors for reverse lookup
    cited_authors = get(ref, "cited_authors", String[])
    for ca in cited_authors
        nca = normalize_author_name(ca)
        !isempty(nca) && length(nca) >= 3 || continue
        cak = "cited_auth:$nca:$ref_id"
        repo = get(ref, "repo", "")
        doc_id = get(ref, "doc_id", "")
        cav = "$repo:$doc_id"
        if batch !== nothing
            put!(batch, cak, cav; cf=d.cfs["references"])
        else
            put!(d.db, cak, cav; cf="references")
        end
    end
end

"""
    get_reference(db::Database, ref_id)

Retrieves a single reference entry.
"""
function get_reference(d::Database, ref_id::AbstractString)
    k = "ref:$ref_id"
    val = get(d.db, k; cf="references")
    val === nothing && return nothing
    return try JSON.parse(String(val)) catch; nothing end
end

"""
    set_document_references!(db::Database, repo, doc_id, ref_ids; batch=nothing)

Links a document to its list of extracted reference IDs.
"""
function set_document_references!(d::Database, repo::AbstractString, doc_id::AbstractString, ref_ids::Vector{String}; batch=nothing)
    k = "doc_refs:$(strip(repo)):$(normalize_id(doc_id))"
    v = JSON.json(ref_ids)
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["references"])
    else
        put!(d.db, k, v; cf="references")
    end
end

"""
    get_document_references(db::Database, repo, doc_id)

Retrieves all structured reference records cited by a document.
"""
function get_document_references(d::Database, repo::AbstractString, doc_id::AbstractString)
    k = "doc_refs:$(strip(repo)):$(normalize_id(doc_id))"
    val = get(d.db, k; cf="references")
    val === nothing && return Dict{String, Any}[]
    
    ref_ids = try JSON.parse(String(val)) catch; String[] end
    refs = Dict{String, Any}[]
    for rid in ref_ids
        r = get_reference(d, rid)
        r !== nothing && push!(refs, r)
    end
    return refs
end

"""
    get_documents_citing_author(db::Database, norm_author; limit::Int=100)

Finds documents that cite a specific author via reverse citation index.
"""
function get_documents_citing_author(d::Database, norm_author::AbstractString; limit::Int=100)
    prefix = "cited_auth:$(normalize_author_name(norm_author)):"
    results = Dict{String, String}[]
    
    iter = DBIterator(d.db; cf="references")
    seek!(iter, prefix)
    
    while valid(iter) && length(results) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        ref_id = k[ncodeunits(prefix)+1:end]
        doc_loc = String(value(iter))
        push!(results, Dict("ref_id" => ref_id, "cited_in" => doc_loc))
        advance!(iter)
    end
    
    return results
end

# ====================================================================
# 4. Topics & Facet Operations (CF: topics)
# ====================================================================

function normalize_tag(tag::AbstractString)
    return replace(lowercase(strip(tag)), r"[^\p{L}\p{N}]+" => "_")
end

"""
    put_topics!(db::Database, doc_dict; batch=nothing)

Indexes document topics, disciplines, authors, and repos in the `topics` column family.
"""
function put_topics!(d::Database, doc::AbstractDict; batch=nothing)
    repo = strip(get(doc, "repo", ""))
    doc_id = normalize_id(get(doc, "id", ""))
    (isempty(repo) || isempty(doc_id)) && return
    
    cf_topics = d.cfs["topics"]
    
    # 1. By Repo: repo_docs:<repo>:<doc_id>
    k_repo_doc = "repo_docs:$repo:$doc_id"
    batch !== nothing ? put!(batch, k_repo_doc, ""; cf=cf_topics) : put!(d.db, k_repo_doc, ""; cf="topics")
    
    # 2. By Keywords / Topics: topic_doc:<norm_kw>:<repo>:<doc_id>
    kws = get(doc, "keywords", String[])
    creators = get(doc, "creators", String[])
    contributors = get(doc, "contributors", String[])
    all_auths = vcat(creators, contributors)
    
    for kw in kws
        nkw = normalize_tag(kw)
        (!isempty(nkw) && length(nkw) >= 3) || continue
        k_topic_doc = "topic_doc:$nkw:$repo:$doc_id"
        batch !== nothing ? put!(batch, k_topic_doc, ""; cf=cf_topics) : put!(d.db, k_topic_doc, ""; cf="topics")
        
        for a in all_auths
            na = normalize_author_name(a)
            !isempty(na) || continue
            k_topic_auth = "topic_auth:$nkw:$na"
            batch !== nothing ? put!(batch, k_topic_auth, a; cf=cf_topics) : put!(d.db, k_topic_auth, a; cf="topics")
        end
    end
    
    # 3. Authors in Repo: repo_auth:<repo>:<norm_author>
    for a in all_auths
        na = normalize_author_name(a)
        !isempty(na) || continue
        k_repo_auth = "repo_auth:$repo:$na"
        batch !== nothing ? put!(batch, k_repo_auth, a; cf=cf_topics) : put!(d.db, k_repo_auth, a; cf="topics")
    end
end

"""
    get_topic_docs(db::Database, topic; limit=100)

Returns `(repo, doc_id)` pairs associated with a topic/keyword.
"""
function get_topic_docs(d::Database, topic::AbstractString; limit::Int=100)
    ntopic = normalize_tag(topic)
    prefix = "topic_doc:$ntopic:"
    matches = Pair{String, String}[]
    
    iter = DBIterator(d.db; cf="topics")
    seek!(iter, prefix)
    
    while valid(iter) && length(matches) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        
        tail = k[ncodeunits(prefix)+1:end]
        parts = split(tail, ":"; limit=2)
        if length(parts) == 2
            push!(matches, parts[1] => parts[2])
        end
        advance!(iter)
    end
    return matches
end

"""
    get_topic_authors(db::Database, topic; limit=100)

Returns author names associated with a topic/keyword.
"""
function get_topic_authors(d::Database, topic::AbstractString; limit::Int=100)
    ntopic = normalize_tag(topic)
    prefix = "topic_auth:$ntopic:"
    authors = String[]
    
    iter = DBIterator(d.db; cf="topics")
    seek!(iter, prefix)
    
    while valid(iter) && length(authors) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        auth_name = String(value(iter))
        !isempty(auth_name) && push!(authors, auth_name)
        advance!(iter)
    end
    return unique(authors)
end

"""
    intersect_topic_repo_docs(db::Database, topic, repo; limit=100)

Intersects documents tagged with `topic` that belong to `repo`.
"""
function intersect_topic_repo_docs(d::Database, topic::AbstractString, repo::AbstractString; limit::Int=100)
    ntopic = normalize_tag(topic)
    s_repo = strip(repo)
    prefix = "topic_doc:$ntopic:$s_repo:"
    matches = Pair{String, String}[]
    
    iter = DBIterator(d.db; cf="topics")
    seek!(iter, prefix)
    
    while valid(iter) && length(matches) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        doc_id = k[ncodeunits(prefix)+1:end]
        push!(matches, s_repo => doc_id)
        advance!(iter)
    end
    return matches
end

"""
    intersect_topic_repo_authors(db::Database, topic, repo; limit=100)

Intersects authors active in `topic` who have published in `repo`.
"""
function intersect_topic_repo_authors(d::Database, topic::AbstractString, repo::AbstractString; limit::Int=100)
    topic_auths = get_topic_authors(d, topic; limit=limit*2)
    s_repo = strip(repo)
    results = String[]
    
    for a in topic_auths
        na = normalize_author_name(a)
        k = "repo_auth:$s_repo:$na"
        val = get(d.db, k; cf="topics")
        if val !== nothing
            push!(results, a)
            length(results) >= limit && break
        end
    end
    return results
end

put_facets!(d::Database, doc::AbstractDict; batch=nothing) = put_topics!(d, doc; batch=batch)
get_documents_by_keyword(d::Database, kw::AbstractString; limit=100) = get_topic_docs(d, kw; limit=limit)

# ====================================================================
# 5. Fulltext & Paragraph Operations (CF: fulltext)
# ====================================================================

"""
    put_fulltext!(db::Database, repo, doc_id, text_str; batch=nothing)

Saves raw document text in the `fulltext` column family.
"""
function put_fulltext!(d::Database, repo::AbstractString, doc_id::AbstractString, txt::AbstractString; batch=nothing)
    k = "text:$(strip(repo)):$(normalize_id(doc_id))"
    if batch !== nothing
        put!(batch, k, txt; cf=d.cfs["fulltext"])
    else
        put!(d.db, k, txt; cf="fulltext")
    end
end

"""
    get_fulltext(db::Database, repo, doc_id)

Retrieves full text for a document.
"""
function get_fulltext(d::Database, repo::AbstractString, doc_id::AbstractString)
    k = "text:$(strip(repo)):$(normalize_id(doc_id))"
    val = get(d.db, k; cf="fulltext")
    return val !== nothing ? String(val) : nothing
end

"""
    put_paragraphs!(db::Database, repo, doc_id, paragraphs; batch=nothing)

Stores individual paragraphs with ordinal indexing for In-Depth searches.
"""
function put_paragraphs!(d::Database, repo::AbstractString, doc_id::AbstractString, paragraphs::Vector{String}; batch=nothing)
    cf_ft = d.cfs["fulltext"]
    for (i, p) in enumerate(paragraphs)
        k = "para:$(strip(repo)):$(normalize_id(doc_id)):$(lpad(i, 4, '0'))"
        if batch !== nothing
            put!(batch, k, p; cf=cf_ft)
        else
            put!(d.db, k, p; cf="fulltext")
        end
    end
end

"""
    get_paragraphs(db::Database, repo, doc_id; limit=200)

Retrieves all paragraphs of a document in order.
"""
function get_paragraphs(d::Database, repo::AbstractString, doc_id::AbstractString; limit::Int=200)
    prefix = "para:$(strip(repo)):$(normalize_id(doc_id)):"
    paras = String[]
    
    iter = DBIterator(d.db; cf="fulltext")
    seek!(iter, prefix)
    
    while valid(iter) && length(paras) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        push!(paras, String(value(iter)))
        advance!(iter)
    end
    
    return paras
end

# ====================================================================
# 6. Statistics Operations (CF: stats)
# ====================================================================

"""
    put_stats!(db::Database, key, stats_dict)

Stores precomputed repository or global summary statistics.
"""
function put_stats!(d::Database, stat_key::AbstractString, stats::AbstractDict)
    k = "stat:$stat_key"
    v = JSON.json(stats)
    put!(d.db, k, v; cf="stats")
end

"""
    get_stats(db::Database, key)

Retrieves precomputed statistics.
"""
function get_stats(d::Database, stat_key::AbstractString)
    k = "stat:$stat_key"
    val = get(d.db, k; cf="stats")
    val === nothing && return nothing
    return try JSON.parse(String(val)) catch; nothing end
end

const GENERIC_TAGS = Set([
    "info:eu-repo", "cti", "classification", "openaccess", "12", "11", "1299", "129999", "110403", "1208", "masterthesis", "doctoralthesis", "bachelorthesis"
])

"""
    compute_detailed_statistics(db::Database, n_authors::Int, clean_repo::Union{AbstractString,Nothing}, repo)

Full-corpus scan computing rich statistics globally or for a specific institutional repository —
the logic behind both `get_detailed_statistics` (Search module, live/cached fallback) and
`precompute_all_statistics!` (called once from `build_search_index`). Lives here rather than in
the Search module because it only depends on `Database`/`scan_documents`, and `Indexing.jl`
(which needs `precompute_all_statistics!`) is compiled before `Search.jl`.
"""
function compute_detailed_statistics(db::Database, n_authors::Int, clean_repo::Union{AbstractString, Nothing}, repo)
    total_docs = 0
    total_files = 0
    total_fulltext = 0
    total_refs = 0

    types_count = Dict{String, Int}()
    repos_count = Dict{String, Int}()
    kws_count = Dict{String, Int}()
    years_list = Int[]
    years_count = Dict{Int, Int}()
    authors_tally = Dict{String, Dict{String, Any}}()

    # Streams document blobs directly from RocksDB (scoped to `clean_repo` when given, via a
    # `doc:<repo>:` prefix scan) instead of going through the BM25 index's positional
    # `doc_keys`/`get_document` pair — this is the only place in the codebase that needs every
    # document exactly once, so it reads each one exactly once instead of twice.
    scan_documents(db; repo=clean_repo) do doc
        r = get(doc, "repo", "")
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
                years_count[y] = get(years_count, y, 0) + 1
            end
        end

        for (a, role) in Iterators.flatten((
            (a => "Autor" for a in get(doc, "creators", String[])),
            (a => "Colaborador / Asesor" for a in get(doc, "contributors", String[]))
        ))
            na = normalize_author_name(a)
            isempty(na) && continue
            entry = get!(authors_tally, na) do
                Dict{String, Any}("name" => a, "role" => role, "repo" => r, "count" => 0)
            end
            entry["count"] += 1
        end
    end

    if total_docs == 0
        return Dict("error" => "No se encontraron documentos para el repositorio '$repo'")
    end

    sorted_types = sort([Dict("type" => k, "count" => v) for (k, v) in types_count], by=x->x["count"], rev=true)
    sorted_kws = sort([Dict("discipline" => k, "count" => v) for (k, v) in kws_count], by=x->x["count"], rev=true)
    sorted_repos = sort([Dict("repo" => k, "count" => v) for (k, v) in repos_count], by=x->x["count"], rev=true)
    sorted_authors = sort(collect(values(authors_tally)), by=x->x["count"], rev=true)

    year_min = isempty(years_list) ? "N/A" : string(minimum(years_list))
    year_max = isempty(years_list) ? "N/A" : string(maximum(years_list))
    years_histogram = [[y, c] for (y, c) in sort(collect(years_count); by=first)]

    return Dict(
        "is_global" => clean_repo === nothing,
        "target_repo" => clean_repo,
        "total_docs" => total_docs,
        "total_files" => total_files,
        "total_fulltext" => total_fulltext,
        "total_references" => total_refs,
        "total_authors" => n_authors,
        "year_min" => year_min,
        "year_max" => year_max,
        "years_histogram" => years_histogram,
        "types_distribution" => sorted_types,
        "top_disciplines" => sorted_kws[1:min(15, length(sorted_kws))],
        "top_repositories" => sorted_repos,
        "top_researchers" => sorted_authors[1:min(15, length(sorted_authors))]
    )
end

"""
    precompute_all_statistics!(db::Database, n_authors::Int)

Computes global and per-repo statistics once and persists them into RocksDB's `stats` column
family (`put_stats!`), so `get_detailed_statistics` can serve them via a single point lookup
instead of a full corpus scan. Requires a read-write `db` — called from `build_search_index`
(which already holds one) at the end of an index rebuild, not from a live (read-only)
`SearchEngine`.
"""
function precompute_all_statistics!(db::Database, n_authors::Int)
    global_stats = compute_detailed_statistics(db, n_authors, nothing, nothing)
    haskey(global_stats, "error") && return nothing
    put_stats!(db, "global", global_stats)

    for r in global_stats["top_repositories"]
        repo_name = r["repo"]
        repo_stats = compute_detailed_statistics(db, n_authors, repo_name, repo_name)
        !haskey(repo_stats, "error") && put_stats!(db, "repo:$repo_name", repo_stats)
    end
    return nothing
end

# ====================================================================
# 7. Batch Ingestion & Database Population
# ====================================================================

"""
    ingest_repository_to_db!(db::Database, repo; data_dir=DEFAULT_DATA_DIR, batch_size=1000)

Populates RocksDB with records, metadata, facets, authors, and references from `data/repos/<repo>/`.
"""
function ingest_repository_to_db!(d::Database, repo::AbstractString; data_dir=DEFAULT_DATA_DIR, batch_size::Int=1000)
    rdir = get_repo_dir(repo; data_dir)
    records = load_corpus_records(repo; data_dir)
    isempty(records) && return 0
    
    println("[$repo] Ingesting $(length(records)) documents into RocksDB...")
    
    # 1. Ingest Documents, Facets, and Fulltext in batches
    count = 0
    total = length(records)
    
    i = 1
    while i <= total
        chunk = records[i:min(i + batch_size - 1, total)]
        
        batch(d.db) do b
            for doc in chunk
                doc_id = get(doc, "id", "")
                isempty(doc_id) && continue
                
                # Document metadata in default CF
                put_document!(d, repo, doc_id, doc; batch=b)
                
                # Secondary indexes in facets CF
                put_facets!(d, doc; batch=b)
                
                # Authors in authors CF
                creators = get(doc, "creators", String[])
                for auth in creators
                    link_author_document!(d, auth, repo, doc_id; role="Autor", year=get(doc, "date", ""), batch=b)
                end
                
                contributors = get(doc, "contributors", String[])
                for contrib in contributors
                    link_author_document!(d, contrib, repo, doc_id; role="Colaborador / Asesor", year=get(doc, "date", ""), batch=b)
                end
                
                # Coauthorship links
                all_authors = vcat(creators, contributors)
                for x in 1:length(all_authors), y in (x+1):length(all_authors)
                    add_coauthor_link!(d, all_authors[x], all_authors[y]; batch=b)
                end
                
                # References in references CF
                refs = get(doc, "references", Dict{String, Any}[])
                if !isempty(refs)
                    ref_ids = String[]
                    for ref in refs
                        ref_id = get(ref, "ref_id", "")
                        if !isempty(ref_id)
                            push!(ref_ids, ref_id)
                            put_reference!(d, ref; batch=b)
                        end
                    end
                    set_document_references!(d, repo, doc_id, ref_ids; batch=b)
                end
                
                count += 1
            end
        end
        
        i += batch_size
    end
    
    println("[$repo] Successfully ingested $count records into RocksDB.")
    return count
end

"""
    ingest_all_to_db!(db::Database; data_dir=DEFAULT_DATA_DIR, repos=nothing)

Populates RocksDB across all or specified repositories.
"""
function ingest_all_to_db!(d::Database; data_dir=DEFAULT_DATA_DIR, repos=nothing)
    target_repos = repos !== nothing ? repos : list_repo_names(; data_dir)
    println("=======================================================")
    println("  💾 Ingesting data into RocksDB for $(length(target_repos)) repositories")
    println("=======================================================")
    
    total_ingested = 0
    t0 = time()
    
    for r in target_repos
        total_ingested += ingest_repository_to_db!(d, r; data_dir)
    end
    
    println("Compacting RocksDB (reclaims write-ahead logs from this bulk-write session)...")
    compact_all!(d)

    t1 = time()
    println("=======================================================")
    println("✅ Ingestion complete: $total_ingested documents in $(round(t1 - t0, digits=2))s")
    println("=======================================================")
    return total_ingested
end

end # module DB
