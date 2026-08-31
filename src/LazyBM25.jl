module LazyBM25

using RocksDB
using SimilaritySearch
using SimilaritySearch.Special.Sparse: SparseVecView
using TextSearch: BM25InvertedFile, vocsize

export RocksDBAdjList, RocksDBDatabase, export_to_rocksdb!, assemble_bm25,
       LazyDocKeys, LazyAuthorKeys, export_dockeys_to_rocksdb!, export_authorkeys_to_rocksdb!,
       DOCS_CONTENT, DOCS_REFS, AUTHORS_NAME, AUTHORS_PROFILE,
       POSTINGS_CF, DOCVECS_CF, DOCKEYS_CF, AUTHORKEYS_CF

const DOCS_CONTENT = UInt8(1)
const DOCS_REFS = UInt8(2)
const AUTHORS_NAME = UInt8(3)
const AUTHORS_PROFILE = UInt8(4)

const POSTINGS_CF = "postings"
const DOCVECS_CF = "docvecs"
const DOCKEYS_CF = "dockeys"
const AUTHORKEYS_CF = "authorkeys"

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
# small JLD2 "shell" (voc/bm25/doclens/len/query, all cheap & RAM-resident)
# plus lazy RocksDB-backed adj/db. Uses BM25InvertedFile's default
# positional constructor (field order: voc, bm25, adj, doclens, db, len,
# query) since the package exposes no keyword to inject custom adj/db.
# ====================================================================

function assemble_bm25(db::RocksDB.DB, idx_id::UInt8, voc, bm25, doclens, len, query)
    adj = RocksDBAdjList(db, idx_id, vocsize(voc))
    dbdata = RocksDBDatabase(db, idx_id, length(doclens))
    BM25InvertedFile(voc, bm25, adj, doclens, dbdata, Ref(Int64(len)), query)
end

end # module LazyBM25
