module DB

using RocksDB, JSON, Dates, SHA
import ..Types: get_document_references
using ..Config: DEFAULT_DATA_DIR
using ..Storage: load_metadata_records, load_corpus_records, list_repo_names, get_repo_dir

export Database, open_database, close_database,
       put_document!, get_document, put_xml!, get_xml,
       put_author_profile!, get_author_profile, get_author_documents, get_coauthors,
       put_reference!, get_reference, get_document_references, get_documents_citing_author,
       put_facets!, scan_facet, get_documents_by_year, get_documents_by_type, get_documents_by_repo, get_documents_by_keyword,
       put_fulltext!, get_fulltext, put_paragraphs!, get_paragraphs,
       put_stats!, get_stats,
       ingest_repository_to_db!, ingest_all_to_db!,
       DEFAULT_ROCKSDB_DIR

const DEFAULT_ROCKSDB_DIR = joinpath(DEFAULT_DATA_DIR, "rocksdb")
const COLUMN_FAMILIES = ["default", "authors", "references", "facets", "fulltext", "stats"]

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
    open_database(path=DEFAULT_ROCKSDB_DIR; create_if_missing=true, read_only=false)

Opens or creates a RocksDB database configured with all required Column Families.
"""
function open_database(path::AbstractString=DEFAULT_ROCKSDB_DIR; create_if_missing::Bool=true, read_only::Bool=false)
    mkpath(path)
    
    # Check if DB directory has existing CURRENT file (meaning CFs exist)
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
    end
    
    # Open DB with all column families
    db_inst = opendb(path; column_families=COLUMN_FAMILIES, read_only)
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
        JSON.parse(String(val))
    catch
        nothing
    end
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
    return replace(lowercase(strip(name)), r"[^\p{L}\p{N}]+" => "_")
end

"""
    put_author_profile!(db::Database, norm_author, profile_dict; batch=nothing)

Saves an author profile in the `authors` column family.
"""
function put_author_profile!(d::Database, norm_author::AbstractString, profile::AbstractDict; batch=nothing)
    k = "auth:$(normalize_author_name(norm_author))"
    v = JSON.json(profile)
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["authors"])
    else
        put!(d.db, k, v; cf="authors")
    end
end

"""
    get_author_profile(db::Database, norm_author)

Retrieves an author profile from the `authors` column family.
"""
function get_author_profile(d::Database, norm_author::AbstractString)
    k = "auth:$(normalize_author_name(norm_author))"
    val = get(d.db, k; cf="authors")
    val === nothing && return nothing
    return try JSON.parse(String(val)) catch; nothing end
end

"""
    link_author_document!(db::Database, norm_author, repo, doc_id; role="Autor", year="", batch=nothing)

Links an author to a document in the `authors` column family.
"""
function link_author_document!(d::Database, norm_author::AbstractString, repo::AbstractString, doc_id::AbstractString; role="Autor", year="", batch=nothing)
    k = "auth_doc:$(normalize_author_name(norm_author)):$(strip(repo)):$(normalize_id(doc_id))"
    v = JSON.json(Dict("role" => role, "year" => year))
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["authors"])
    else
        put!(d.db, k, v; cf="authors")
    end
end

"""
    get_author_documents(db::Database, norm_author; limit::Int=500)

Returns all documents linked to an author via Prefix Scan.
"""
function get_author_documents(d::Database, norm_author::AbstractString; limit::Int=500)
    prefix = "auth_doc:$(normalize_author_name(norm_author)):"
    results = Dict{String, Any}[]
    
    iter = DBIterator(d.db; cf="authors")
    seek!(iter, prefix)
    
    while valid(iter) && length(results) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        
        parts = split(k[length(prefix)+1:end], ":"; limit=2)
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
    add_coauthor_link!(db::Database, norm_a, norm_b; count=1, batch=nothing)

Records an edge in the coauthorship graph.
"""
function add_coauthor_link!(d::Database, norm_a::AbstractString, norm_b::AbstractString; count::Int=1, batch=nothing)
    a = normalize_author_name(norm_a)
    b = normalize_author_name(norm_b)
    a == b && return
    k = "coauth:$a:$b"
    v = string(count)
    if batch !== nothing
        put!(batch, k, v; cf=d.cfs["authors"])
    else
        put!(d.db, k, v; cf="authors")
    end
end

"""
    get_coauthors(db::Database, norm_author; limit::Int=50)

Returns top coauthors for an author via Prefix Scan.
"""
function get_coauthors(d::Database, norm_author::AbstractString; limit::Int=50)
    prefix = "coauth:$(normalize_author_name(norm_author)):"
    coauthors = Pair{String, Int}[]
    
    iter = DBIterator(d.db; cf="authors")
    seek!(iter, prefix)
    
    while valid(iter) && length(coauthors) < limit
        k = String(key(iter))
        !startswith(k, prefix) && break
        coauth = k[length(prefix)+1:end]
        cnt = try parse(Int, String(value(iter))) catch; 1 end
        push!(coauthors, coauth => cnt)
        advance!(iter)
    end
    
    sort!(coauthors, by=x->x.second, rev=true)
    return coauthors
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
        ref_id = k[length(prefix)+1:end]
        doc_loc = String(value(iter))
        push!(results, Dict("ref_id" => ref_id, "cited_in" => doc_loc))
        advance!(iter)
    end
    
    return results
end

# ====================================================================
# 4. Facets & Secondary Index Operations (CF: facets)
# ====================================================================

function normalize_tag(tag::AbstractString)
    return replace(lowercase(strip(tag)), r"[^\p{L}\p{N}]+" => "_")
end

"""
    put_facets!(db::Database, doc_dict; batch=nothing)

Indexes document secondary keys in the `facets` column family for fast prefix/range scans.
"""
function put_facets!(d::Database, doc::AbstractDict; batch=nothing)
    repo = strip(get(doc, "repo", ""))
    doc_id = normalize_id(get(doc, "id", ""))
    isempty(repo) || isempty(doc_id) && return
    
    cf_facets = d.cfs["facets"]
    
    # 1. By Repo: repo:<repo>:<doc_id>
    k_repo = "repo:$repo:$doc_id"
    batch !== nothing ? put!(batch, k_repo, ""; cf=cf_facets) : put!(d.db, k_repo, ""; cf="facets")
    
    # 2. By Year: year:<year>:<repo>:<doc_id>
    date_str = get(doc, "date", "")
    m_year = match(r"\b(19\d\d|20\d\d)\b", date_str)
    if m_year !== nothing
        year = m_year.match
        k_year = "year:$year:$repo:$doc_id"
        batch !== nothing ? put!(batch, k_year, ""; cf=cf_facets) : put!(d.db, k_year, ""; cf="facets")
    end
    
    # 3. By Document Type: type:<norm_type>:<repo>:<doc_id>
    raw_type = get(doc, "type", "Documento")
    norm_type = normalize_tag(raw_type)
    if !isempty(norm_type)
        k_type = "type:$norm_type:$repo:$doc_id"
        batch !== nothing ? put!(batch, k_type, ""; cf=cf_facets) : put!(d.db, k_type, ""; cf="facets")
    end
    
    # 4. By Keywords / Disciplines: kw:<norm_kw>:<repo>:<doc_id>
    kws = get(doc, "keywords", String[])
    for kw in kws
        nkw = normalize_tag(kw)
        !isempty(nkw) && length(nkw) >= 3 || continue
        k_kw = "kw:$nkw:$repo:$doc_id"
        batch !== nothing ? put!(batch, k_kw, ""; cf=cf_facets) : put!(d.db, k_kw, ""; cf="facets")
    end
end

"""
    scan_facet(db::Database, prefix; limit=100)

Scans a facet prefix and returns matching `(repo, doc_id)` pairs.
"""
function scan_facet(d::Database, prefix::AbstractString; limit::Int=100)
    pref = endswith(prefix, ":") ? prefix : "$prefix:"
    matches = Pair{String, String}[]
    
    iter = DBIterator(d.db; cf="facets")
    seek!(iter, pref)
    
    while valid(iter) && length(matches) < limit
        k = String(key(iter))
        !startswith(k, pref) && break
        
        tail = k[length(pref)+1:end]
        if startswith(pref, "repo:")
            parts_pref = split(pref, ":")
            repo = parts_pref[2]
            doc_id = tail
            push!(matches, repo => doc_id)
        else
            parts = split(tail, ":"; limit=2)
            if length(parts) == 2
                push!(matches, parts[1] => parts[2])
            end
        end
        advance!(iter)
    end
    
    return matches
end

get_documents_by_year(d::Database, year::Union{Int, AbstractString}; limit=100) = scan_facet(d, "year:$year:"; limit)
get_documents_by_type(d::Database, doc_type::AbstractString; limit=100) = scan_facet(d, "type:$(normalize_tag(doc_type)):"; limit)
get_documents_by_repo(d::Database, repo::AbstractString; limit=100) = scan_facet(d, "repo:$repo:"; limit)
get_documents_by_keyword(d::Database, kw::AbstractString; limit=100) = scan_facet(d, "kw:$(normalize_tag(kw)):"; limit)

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
    
    t1 = time()
    println("=======================================================")
    println("✅ Ingestion complete: $total_ingested documents in $(round(t1 - t0, digits=2))s")
    println("=======================================================")
    return total_ingested
end

end # module DB
