module VocabIO

using JSON3
using ZipArchives
using TextSearch

export save_vocabulary_zip, load_vocabulary_zip

"""
    save_vocabulary_zip(path::AbstractString, voc::TextSearch.Vocabulary)

Serializes `voc` into a small `.zip` archive of plain JSON files (`vocabulary.json` +
`policy.json`), mirroring the hand-written encoding `TextSearch.save_profile` already uses for
its own `TextProfile` type — deliberately NOT a generic object-graph dump (unlike JLD2's default
struct serialization, which is what `Indexing.jl` used before this module existed).

Measured on the real `docs_refs` vocabulary (2,359,232 tokens, the largest of the 4 indices):
JLD2's generic serialization of the same `Vocabulary` took 435.67 MB on disk and ~8s to
deserialize; this format takes 38.05 MB and ~2s — roughly an 11x size and 4x load-time
reduction. The difference is *how* it's stored, not what: JLD2 has to walk and reconstruct the
whole nested `Vocabulary`/`TextConfig` object graph, rehashing a multi-million-entry
`token2id::Dict` in the process, while this format stores only `token::Vector{String}` (plus
small numeric arrays) and rebuilds `token2id` with a single `enumerate` pass on load — exactly
what `TextSearch.load_profile` already does for `vocabulary.json`.

Reuses `TextSearch`'s own (unexported) `_encode_policy`/`_decode_policy` to encode/decode the
`TextConfig` faithfully (regex patterns, emoji set, normalization/tokenization flags) instead of
hand-rolling that logic a second time — the same reason `Project.toml` pins `TextSearch` to an
exact version (`=1.1.1`): this relies on `TextSearch`'s internal shape, not just its public API,
so an upstream update could silently break it without that pin.
"""
function save_vocabulary_zip(path::AbstractString, voc::TextSearch.Vocabulary)
    vocab_json = JSON3.write(Dict(
        "tokens" => voc.token,
        "occs" => voc.occs,
        "ndocs" => voc.ndocs,
        "trainsize" => voc.trainsize[],
        "numtokens" => voc.numtokens[],
    ))
    policy_json = JSON3.write(TextSearch._encode_policy(voc.textconfig))

    ZipArchives.ZipWriter(path) do w
        ZipArchives.zip_writefile(w, "vocabulary.json", Vector{UInt8}(vocab_json))
        ZipArchives.zip_writefile(w, "policy.json", Vector{UInt8}(policy_json))
    end
    return path
end

"""
    load_vocabulary_zip(path::AbstractString) -> TextSearch.Vocabulary

Reads back a `Vocabulary` written by [`save_vocabulary_zip`](@ref). The `.zip` is read directly
from memory (no extraction to disk).
"""
function load_vocabulary_zip(path::AbstractString)
    buf = read(path)
    zr = ZipArchives.ZipReader(buf)
    vocd = JSON3.read(ZipArchives.zip_readentry(zr, "vocabulary.json"))
    pold = JSON3.read(ZipArchives.zip_readentry(zr, "policy.json"))

    textconfig = TextSearch._decode_policy(pold)
    tokens = String.(vocd[:tokens])
    tok2id = Dict{String, UInt32}(tok => UInt32(i) for (i, tok) in enumerate(tokens))

    TextSearch.Vocabulary(
        textconfig,
        tokens,
        Int32.(vocd[:occs]),
        Int32.(vocd[:ndocs]),
        tok2id,
        Ref{Int64}(Int64(vocd[:trainsize])),
        Ref{Int64}(Int64(vocd[:numtokens])),
    )
end

end # module VocabIO
