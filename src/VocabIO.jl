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
hand-rolling that logic a second time. This relies on `TextSearch`'s internal shape, not only
its public API, and `Project.toml` does not pin an exact version: the round-trip tests in
`test/runtests.jl` are what detect a change in that shape. Checked against TextSearch 1.3.0.

`_encode_policy` does not include the `TokenPipeline` of the `TextConfig` (its lemmas and
stopwords). `TextSearch.save_profile` stores them as separate artifacts. This format stores them
in `lemmas.json` and `stopwords.json`, which are present only when the pipeline has that stage.
Without them, a vocabulary built from a profile refit with `apply_lemmas=true` is reloaded
without its lemmas. The index then holds `"ministro"`, the query `"ministros"` is not mapped to
it, and the query returns no results. This happened in the index built on 2026-10-24.
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
    pipeline = voc.textconfig.pipeline

    ZipArchives.ZipWriter(path) do w
        ZipArchives.zip_writefile(w, "vocabulary.json", Vector{UInt8}(vocab_json))
        ZipArchives.zip_writefile(w, "policy.json", Vector{UInt8}(policy_json))
        pipeline.lemmas === nothing ||
            ZipArchives.zip_writefile(w, "lemmas.json", Vector{UInt8}(JSON3.write(pipeline.lemmas)))
        pipeline.stopwords === nothing ||
            ZipArchives.zip_writefile(w, "stopwords.json", Vector{UInt8}(JSON3.write(sort!(collect(pipeline.stopwords)))))
    end
    return path
end

"""
    load_vocabulary_zip(path::AbstractString) -> TextSearch.Vocabulary

Reads back a `Vocabulary` written by [`save_vocabulary_zip`](@ref). The `.zip` is read directly
from memory (no extraction to disk). The lemmas and stopwords in `lemmas.json` and
`stopwords.json`, when present, are put back in the `TokenPipeline` of the `TextConfig`.
"""
function load_vocabulary_zip(path::AbstractString)
    buf = read(path)
    zr = ZipArchives.ZipReader(buf)
    vocd = JSON3.read(ZipArchives.zip_readentry(zr, "vocabulary.json"))
    pold = JSON3.read(ZipArchives.zip_readentry(zr, "policy.json"))

    policy = TextSearch._decode_policy(pold)
    names = ZipArchives.zip_names(zr)
    lemmas = "lemmas.json" in names ?
        Dict{String,String}(String(k) => String(v) for (k, v) in pairs(JSON3.read(ZipArchives.zip_readentry(zr, "lemmas.json")))) :
        nothing
    stopwords = "stopwords.json" in names ?
        Set{String}(String.(JSON3.read(ZipArchives.zip_readentry(zr, "stopwords.json")))) :
        nothing
    textconfig = TextSearch.TextConfig(policy.normalization, policy.tokenization,
                                       TextSearch.TokenPipeline(; lemmas, stopwords), policy.language)
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
