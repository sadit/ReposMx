module LazyBM25

using RocksDB
using SimilaritySearch
using SimilaritySearch.Special.Sparse: SparseVecView
using TextSearch: BM25InvertedFile, vocsize

export RocksDBAdjList, RocksDBDatabase, export_to_rocksdb!, assemble_bm25,
       LazyDocKeys, LazyAuthorKeys, export_dockeys_to_rocksdb!, export_authorkeys_to_rocksdb!,
       DOCS_CONTENT, DOCS_REFS, AUTHORS_NAME, AUTHORS_PROFILE,
       POSTINGS_CF, DOCVECS_CF, DOCKEYS_CF, AUTHORKEYS_CF,
       REPO_POSTINGS_CF, RepoPostingsAdjList, save_repo_table!, load_repo_table,
       export_repo_postings!, assemble_repo_bm25

const DOCS_CONTENT = UInt8(1)
const DOCS_REFS = UInt8(2)
const AUTHORS_NAME = UInt8(3)
const AUTHORS_PROFILE = UInt8(4)

const POSTINGS_CF = "postings"
const DOCVECS_CF = "docvecs"
const DOCKEYS_CF = "dockeys"
const AUTHORKEYS_CF = "authorkeys"
const REPO_POSTINGS_CF = "repo_postings"

# ====================================================================
# Key/value encoding — fixed-width binary, no String round-trips.
# Only point lookups (`get`) happen against these two column families,
# never prefix scans, so byte order within the key is not load-bearing;
# native (little-endian on the platforms this runs on) is used for
# simplicity.
# ====================================================================

postings_key(idx_id::UInt8, tokenID::Integer) =
    vcat(UInt8[idx_id], reinterpret(UInt8, UInt32[UInt32(tokenID)]))

docvec_key(idx_id::UInt8, docID::Integer) =
    vcat(UInt8[idx_id], reinterpret(UInt8, UInt32[UInt32(docID)]))

encode_u32vec(v::AbstractVector{<:Integer}) = Vector{UInt8}(reinterpret(UInt8, Vector{UInt32}(v)))
decode_u32vec(bytes::Vector{UInt8}) = Vector{UInt32}(reinterpret(UInt32, bytes))

function encode_sparsevec(sv)
    nzind = Vector{Int32}(sv.nzind)
    nzval = Vector{UInt32}(sv.nzval)
    io = IOBuffer()
    write(io, Int32(sv.n))
    write(io, Int32(length(nzind)))
    write(io, reinterpret(UInt8, nzind))
    write(io, reinterpret(UInt8, nzval))
    take!(io)
end

function decode_sparsevec(bytes::Vector{UInt8})
    io = IOBuffer(bytes)
    n = read(io, Int32)
    nnz = read(io, Int32)
    nzind = Vector{Int32}(undef, nnz)
    read!(io, nzind)
    nzval = Vector{UInt32}(undef, nnz)
    read!(io, nzval)
    SparseVecView(Int(n), nzind, nzval)
end

# ====================================================================
# Positional keys/values for `doc_keys`/`author_keys` — the arrays mapping a
# BM25 index's internal 1-based document/author id back to (repo, doc_id) or
# a normalized author name. Not partitioned by `idx_id`: docs_content and
# docs_refs share the same doc numbering (built from the same loop in
# `build_search_index`), and authors_name/authors_profile likewise share
# author numbering, so each is stored once regardless of how many of the 4
# BM25 indices reference it.
# ====================================================================

positional_key(id::Integer) = Vector{UInt8}(reinterpret(UInt8, UInt32[UInt32(id)]))

function encode_dockey(repo::AbstractString, doc_id::AbstractString)
    repo_bytes = codeunits(repo)
    io = IOBuffer()
    write(io, Int32(length(repo_bytes)))
    write(io, repo_bytes)
    write(io, codeunits(doc_id))
    take!(io)
end

function decode_dockey(bytes::Vector{UInt8})
    io = IOBuffer(bytes)
    replen = read(io, Int32)
    repo = String(read(io, replen))
    doc_id = String(read(io))
    (repo, doc_id)
end

encode_authorkey(name::AbstractString) = Vector{UInt8}(codeunits(name))
decode_authorkey(bytes::Vector{UInt8}) = String(bytes)

"""
    LazyDocKeys <: AbstractVector{Tuple{String,String}}

Read-only, RocksDB-backed replacement for the eager `doc_keys::Vector{Tuple{String,String}}`.
Only `size`/`getindex` are implemented; indexing, `length`, `isempty`, and iteration all fall
out of Julia's generic `AbstractArray` machinery, so call sites that used the plain `Vector`
need no changes.
"""
struct LazyDocKeys <: AbstractVector{Tuple{String, String}}
    db::RocksDB.DB
    n::Int
end

Base.size(v::LazyDocKeys) = (v.n,)
function Base.getindex(v::LazyDocKeys, i::Int)
    raw = RocksDB.get(v.db, positional_key(i); cf=DOCKEYS_CF)
    raw === nothing && error("LazyDocKeys: missing entry for docID=$i")
    decode_dockey(raw)
end

"""
    LazyAuthorKeys <: AbstractVector{String}

Read-only, RocksDB-backed replacement for the eager `author_keys::Vector{String}`.
"""
struct LazyAuthorKeys <: AbstractVector{String}
    db::RocksDB.DB
    n::Int
end

Base.size(v::LazyAuthorKeys) = (v.n,)
function Base.getindex(v::LazyAuthorKeys, i::Int)
    raw = RocksDB.get(v.db, positional_key(i); cf=AUTHORKEYS_CF)
    raw === nothing && error("LazyAuthorKeys: missing entry for authorID=$i")
    decode_authorkey(raw)
end

function export_dockeys_to_rocksdb!(db::RocksDB.DB, doc_keys)
    cf = RocksDB.column_families(db)[DOCKEYS_CF]
    RocksDB.batch(db) do b
        for (i, (repo, doc_id)) in enumerate(doc_keys)
            RocksDB.put!(b, positional_key(i), encode_dockey(repo, doc_id); cf=cf)
        end
    end
    return nothing
end

function export_authorkeys_to_rocksdb!(db::RocksDB.DB, author_keys)
    cf = RocksDB.column_families(db)[AUTHORKEYS_CF]
    RocksDB.batch(db) do b
        for (i, name) in enumerate(author_keys)
            RocksDB.put!(b, positional_key(i), encode_authorkey(name); cf=cf)
        end
    end
    return nothing
end

# ====================================================================
# RocksDBAdjList <: AbstractAdjList{UInt32} — read-only, lazy posting lists.
# ====================================================================

struct RocksDBAdjList <: SimilaritySearch.AbstractAdjList{UInt32}
    db::RocksDB.DB
    idx_id::UInt8
    n::Int
end

function SimilaritySearch.neighbors(a::RocksDBAdjList, i)
    raw = RocksDB.get(a.db, postings_key(a.idx_id, i); cf=POSTINGS_CF)
    raw === nothing ? UInt32[] : decode_u32vec(raw)
end

SimilaritySearch.neighbors_length(a::RocksDBAdjList, i) = length(SimilaritySearch.neighbors(a, i))
Base.eachindex(a::RocksDBAdjList) = Base.OneTo(a.n)
Base.length(a::RocksDBAdjList) = a.n
SimilaritySearch.add!(::RocksDBAdjList, args...) =
    error("RocksDBAdjList is read-only; build it via `export_to_rocksdb!` from an in-memory index")

# ====================================================================
# RocksDBDatabase <: AbstractDatabase — read-only, lazy per-document term vectors.
# ====================================================================

struct RocksDBDatabase <: SimilaritySearch.AbstractDatabase
    db::RocksDB.DB
    idx_id::UInt8
    n::Int
end

function Base.getindex(d::RocksDBDatabase, docID::Integer)
    raw = RocksDB.get(d.db, docvec_key(d.idx_id, docID); cf=DOCVECS_CF)
    raw === nothing && error("RocksDBDatabase: missing doc vector for docID=$docID (idx_id=$(d.idx_id))")
    decode_sparsevec(raw)
end

Base.length(d::RocksDBDatabase) = d.n
SimilaritySearch.push_item!(::RocksDBDatabase, v) =
    error("RocksDBDatabase is read-only; build it via `export_to_rocksdb!` from an in-memory index")

# ====================================================================
# Export (write path) — walks an already-built, in-memory BM25InvertedFile
# and persists its `adj`/`db` fields into the shared "postings"/"docvecs"
# column families, prefixed by `idx_id`. Indexing algorithm/scoring code is
# untouched; this only runs once, after `append_items!` has already built
# the in-memory structure exactly as it does today.
# ====================================================================

function export_to_rocksdb!(db::RocksDB.DB, idx_id::UInt8, invfile)
    adj = invfile.adj
    dbdata = invfile.db
    cfs = RocksDB.column_families(db)
    postings_cf = cfs[POSTINGS_CF]
    docvecs_cf = cfs[DOCVECS_CF]

    RocksDB.batch(db) do b
        for i in eachindex(adj)
            posting = SimilaritySearch.neighbors(adj, i)
            isempty(posting) && continue
            RocksDB.put!(b, postings_key(idx_id, i), encode_u32vec(posting); cf=postings_cf)
        end
        for docid in 1:length(dbdata)
            RocksDB.put!(b, docvec_key(idx_id, docid), encode_sparsevec(dbdata[docid]); cf=docvecs_cf)
        end
    end
    return nothing
end

# ====================================================================
# Assemble (read path) — rebuilds a queryable BM25InvertedFile from the
# small JSON/zip "shell" (voc/bm25/doclens/len/query, all cheap & RAM-resident)
# plus lazy RocksDB-backed adj/db. Uses BM25InvertedFile's default
# positional constructor (field order: voc, bm25, adj, doclens, db, len,
# query) since the package exposes no keyword to inject custom adj/db.
# ====================================================================

function assemble_bm25(db::RocksDB.DB, idx_id::UInt8, voc, bm25, doclens, len, query)
    adj = RocksDBAdjList(db, idx_id, vocsize(voc))
    dbdata = RocksDBDatabase(db, idx_id, length(doclens))
    BM25InvertedFile(voc, bm25, adj, doclens, dbdata, Ref(Int64(len)), query)
end

# ====================================================================
# Per-repository posting lists — one small inverted index per repository.
#
# A repository index shares everything with the global index of the same `idx_id` except its
# posting lists: the vocabulary (and with it the document frequency behind every idf), the BM25
# parameters (corpus size, mean document length), the per-document term vectors, the document
# lengths, the query pipeline and the id -> key table. Only `adj` differs. A posting list of
# repository `r` holds the global ids of the documents (or authors) of `r` that contain the
# token, in the same ascending order as the global list.
#
# Because the statistics are the global ones, a document gets the same BM25 score from its
# repository index as from the global index. Searching repository `r` therefore ranks its
# documents as filtering the global results by `r` does, and it evaluates only the documents
# of `r`.
#
# Keys of `repo_postings`: `[idx_id][repo u16][token u32]`, big-endian, so the lists of one
# index and one repository are contiguous. The key `[0x00]` holds the repository table: the
# repository names in the order of their u16 index, shared by every `idx_id`.
# ====================================================================

const REPO_TABLE_KEY = UInt8[0x00]

repo_postings_key(idx_id::UInt8, repo::UInt16, tokenID::Integer) =
    UInt8[idx_id, UInt8(repo >> 8), UInt8(repo & 0xff),
          reinterpret(UInt8, [hton(UInt32(tokenID))])...]

"""
    save_repo_table!(db::RocksDB.DB, repos::AbstractVector{<:AbstractString})

Stores the repository table: `repos[i]` is the repository with index `i` (a `UInt16`) in the keys
of the `repo_postings` column family. One table serves every `idx_id`.
"""
function save_repo_table!(db::RocksDB.DB, repos::AbstractVector{<:AbstractString})
    length(repos) <= typemax(UInt16) || error("too many repositories for a UInt16 index: $(length(repos))")
    any(r -> occursin('\n', r), repos) && error("a repository name contains a newline")
    RocksDB.put!(db, REPO_TABLE_KEY, Vector{UInt8}(codeunits(join(repos, '\n'))); cf=REPO_POSTINGS_CF)
    return nothing
end

"""
    load_repo_table(db::RocksDB.DB) -> Union{Dict{String,UInt16}, Nothing}

Reads the table written by [`save_repo_table!`](@ref): repository name -> index. Returns
`nothing` when the database has no `repo_postings` column family or no table yet, so a caller can
fall back to filtering the global results.
"""
function load_repo_table(db::RocksDB.DB)
    haskey(RocksDB.column_families(db), REPO_POSTINGS_CF) || return nothing
    raw = RocksDB.get(db, REPO_TABLE_KEY; cf=REPO_POSTINGS_CF)
    raw === nothing && return nothing
    names = isempty(raw) ? String[] : split(String(raw), '\n')
    Dict{String,UInt16}(String(r) => UInt16(i) for (i, r) in enumerate(names))
end

"""
    RepoPostingsAdjList <: AbstractAdjList{UInt32}

Read-only posting lists of one repository for one index, read lazily from the `repo_postings`
column family. The ids are global, so the rest of the global index works with it unchanged.
"""
struct RepoPostingsAdjList <: SimilaritySearch.AbstractAdjList{UInt32}
    db::RocksDB.DB
    idx_id::UInt8
    repo::UInt16
    n::Int
end

function SimilaritySearch.neighbors(a::RepoPostingsAdjList, i)
    raw = RocksDB.get(a.db, repo_postings_key(a.idx_id, a.repo, i); cf=REPO_POSTINGS_CF)
    raw === nothing ? UInt32[] : decode_u32vec(raw)
end

SimilaritySearch.neighbors_length(a::RepoPostingsAdjList, i) = length(SimilaritySearch.neighbors(a, i))
Base.eachindex(a::RepoPostingsAdjList) = Base.OneTo(a.n)
Base.length(a::RepoPostingsAdjList) = a.n
SimilaritySearch.add!(::RepoPostingsAdjList, args...) =
    error("RepoPostingsAdjList is read-only; build it via `export_repo_postings!`")

"""
    assemble_repo_bm25(global_index::BM25InvertedFile, db::RocksDB.DB, idx_id::UInt8, repo::UInt16)

The index of repository `repo`: the fields of `global_index` (not copied) with the posting lists
of `repo` in place of the global ones. Building it reads nothing from disk, so a caller can build
one per query.
"""
function assemble_repo_bm25(g::BM25InvertedFile, db::RocksDB.DB, idx_id::UInt8, repo::UInt16)
    adj = RepoPostingsAdjList(db, idx_id, repo, length(g.adj))
    BM25InvertedFile(g.voc, g.bm25, adj, g.doclens, g.db, g.len, g.query)
end

"""
    export_repo_postings!(db::RocksDB.DB, idx_id::UInt8, adj, repos_of; flush_ids=4_000_000) -> Int

Splits every posting list of `adj` (the global lists of index `idx_id`) by repository and writes
the parts to the `repo_postings` column family. `repos_of(id)` returns the repository indices
(`UInt16`) of the global id `id`: one for a document, possibly several for an author. The lists
of `idx_id` written before are deleted first, so a repository that disappeared, or a table that
changed order, leaves nothing stale. Writes in batches of about `flush_ids` ids. Returns the
number of ids written.
"""
function export_repo_postings!(db::RocksDB.DB, idx_id::UInt8, adj, repos_of; flush_ids::Int=4_000_000)
    cf = RocksDB.column_families(db)[REPO_POSTINGS_CF]
    _delete_index_range!(db, cf, idx_id)

    parts = Dict{UInt16,Vector{UInt32}}()
    wb = RocksDB.WriteBatch()
    pending = 0
    total = 0
    for tokenID in eachindex(adj)
        posting = SimilaritySearch.neighbors(adj, tokenID)
        isempty(posting) && continue
        for v in values(parts)
            empty!(v)
        end
        for id in posting
            for r in repos_of(id)
                push!(get!(() -> UInt32[], parts, r), id)
            end
        end
        for (r, ids) in parts
            isempty(ids) && continue
            RocksDB.put!(wb, repo_postings_key(idx_id, r, tokenID), encode_u32vec(ids); cf=cf)
            pending += length(ids)
        end
        if pending >= flush_ids
            RocksDB.write!(db, wb)
            empty!(wb)
            total += pending
            pending = 0
        end
    end
    RocksDB.write!(db, wb)
    return total + pending
end

# Deletes every key of `idx_id` in `repo_postings`: the range [ [idx_id], [idx_id + 1] ).
# RocksDB.jl wraps no range deletion, so this calls the C API the same way its own
# `delete!(::WriteBatch, key; cf)` does.
function _delete_index_range!(db::RocksDB.DB, cf, idx_id::UInt8)
    lo = UInt8[idx_id]
    hi = UInt8[idx_id + 0x01]
    wb = RocksDB.WriteBatch()
    GC.@preserve lo hi begin
        RocksDB.Lib.rocksdb_writebatch_delete_range_cf(wb.ptr, cf.ptr, pointer(lo), sizeof(lo), pointer(hi), sizeof(hi))
    end
    RocksDB.write!(db, wb)
    return nothing
end

end # module LazyBM25
