"""
    IndexShellIO

Persistence for the "shell" of a `TextSearch.BM25InvertedFile` — the small part that is neither the
vocabulary nor the bulk postings. A search index in this project is stored in three pieces, each
with its own medium chosen by size and access pattern:

| piece | where | written by |
|---|---|---|
| vocabulary | a `.zip` on disk | `VocabIO` |
| posting lists, per-document term vectors | RocksDB (`postings`/`docvecs` CFs), read lazily | `LazyBM25` |
| shell: BM25 params, doc lengths, index length, query pipeline | a `.zip` on disk | this module |

The shell is a few scalars, one `Vector{Int32}` and a handful of `Union{Nothing,Dict}` fields, so
its size is not what matters. What matters is the deserialization machinery it pulls in:
[`save_index_shell_zip`](@ref)/[`load_index_shell_zip`](@ref) encode it as one `shell.json` inside a
`.zip`, via `JSON3`/`ZipArchives`, precisely so loading it costs nothing beyond what
`VocabIO.load_vocabulary_zip` already pays a few lines earlier in the same loader — see
[`save_index_shell_zip`](@ref)'s docstring for the ~8s per-process JIT tax that the JLD2 round-trip
it replaced used to add to a cold `SearchEngine()`.

Because JSON has no notion of the Julia types involved, each field is encoded and decoded field by
field (`_encode_bm25`/`_decode_bm25`, `_encode_query`/`_decode_query`) rather than reflected over
generically. That is the deliberate tradeoff: a `TextSearch.BM25Scorer` or `QueryPipeline` field
added upstream will NOT appear here on its own and has to be threaded through both directions by
hand.
"""
module IndexShellIO

using JSON3
using ZipArchives
using TextSearch

export save_index_shell_zip, load_index_shell_zip

"""
    save_index_shell_zip(path::AbstractString; bm25, doclens, len, query)

Serializes the small "shell" of a `BM25InvertedFile` — everything except the vocabulary
(handled by [`VocabIO`](@ref)) and the posting lists / doc vectors (handled by `LazyBM25`,
which lives in RocksDB) — as a single `shell.json` inside a `.zip`, same pattern as
`VocabIO.save_vocabulary_zip`.

This replaces what used to be a `jldsave(...; bm25, doclens, len, query)` call. The shell is tiny
either way (a few scalars, one `Vector{Int32}`, a handful of `Union{Nothing,Dict}` fields), so the
size/load-time win here is not the point — `JLD2.load` was the *first* call in the whole
`SearchEngine()` construction path to touch a genuinely generic/parametric deserialization
machinery, and paid an ~8s one-time JIT compilation tax for it on every fresh process (measured:
`load_docs_content_index` cost 8.44s, 98.66% of which was compilation, while the other 3 loaders —
same code, already-compiled — cost tens of milliseconds). Routing through `JSON3`/`ZipArchives`
instead means that cost is shared with (not added on top of) what `VocabIO.load_vocabulary_zip`
already pays a few lines earlier in the same load function, instead of pulling in JLD2's entirely
separate, much heavier generic object-graph reconstruction path.
"""
function save_index_shell_zip(path::AbstractString; bm25::TextSearch.BM25Scorer, doclens::AbstractVector{Int32},
                                len::Integer, query::TextSearch.QueryPipeline)
    shell_json = JSON3.write(Dict(
        "bm25" => _encode_bm25(bm25),
        "doclens" => doclens,
        "len" => Int64(len),
        "query" => _encode_query(query),
    ))
    ZipArchives.ZipWriter(path) do w
        ZipArchives.zip_writefile(w, "shell.json", Vector{UInt8}(shell_json))
    end
    return path
end

"""
    load_index_shell_zip(path::AbstractString) -> (; bm25, doclens, len, query)

Reads back a shell written by [`save_index_shell_zip`](@ref).
"""
function load_index_shell_zip(path::AbstractString)
    buf = read(path)
    zr = ZipArchives.ZipReader(buf)
    d = JSON3.read(ZipArchives.zip_readentry(zr, "shell.json"))
    (
        bm25=_decode_bm25(d[:bm25]),
        doclens=Int32.(d[:doclens]),
        len=Int64(d[:len]),
        query=_decode_query(d[:query]),
    )
end

function _encode_bm25(bm25::TextSearch.BM25Scorer)
    Dict(
        "k1_plus_1" => bm25.k1_plus_1,
        "k1_mult_1_min_b" => bm25.k1_mult_1_min_b,
        "k1_mult_b_div_avg_doc_len" => bm25.k1_mult_b_div_avg_doc_len,
        "delta" => bm25.δ,
        "trainsize" => bm25.trainsize,
    )
end

function _decode_bm25(d)
    TextSearch.BM25Scorer(
        Float32(d[:k1_plus_1]),
        Float32(d[:k1_mult_1_min_b]),
        Float32(d[:k1_mult_b_div_avg_doc_len]),
        Float32(d[:delta]),
        Int32(d[:trainsize]),
    )
end

_decode_strvec_dict(::Nothing) = nothing
_decode_strvec_dict(d) = Dict{String,Vector{String}}(String(k) => String.(v) for (k, v) in pairs(d))

_decode_distances(::Nothing) = nothing
_decode_distances(d) = Dict{String,Vector{Float32}}(String(k) => Float32.(v) for (k, v) in pairs(d))

function _encode_query(qp::TextSearch.QueryPipeline)
    Dict(
        "policy" => Dict(
            "correction" => String(qp.policy.correction),
            "expansion" => qp.policy.expansion,
            "expansion_k" => qp.policy.expansion_k,
            "negligible_ratio" => qp.policy.negligible_ratio,
        ),
        "variants" => qp.variants,
        "expansion_network" => qp.expansion,
        "distances" => qp.distances,
    )
end

function _decode_query(d)
    p = d[:policy]
    policy = TextSearch.QueryPolicy(
        correction=Symbol(p[:correction]),
        expansion=p[:expansion],
        expansion_k=p[:expansion_k],
        negligible_ratio=p[:negligible_ratio],
    )
    TextSearch.QueryPipeline(
        policy=policy,
        variants=_decode_strvec_dict(get(d, :variants, nothing)),
        expansion=_decode_strvec_dict(get(d, :expansion_network, nothing)),
        distances=_decode_distances(get(d, :distances, nothing)),
    )
end

end # module IndexShellIO
