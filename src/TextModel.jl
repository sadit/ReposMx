module TextModel

using TextSearch

export TextProfile,
       base_profile,
       refit_corpus_profile,
       create_textconfig,
       save_profile,
       load_profile

"""
    create_textconfig(; nlist=[1], del_diac=false, del_punc=true, lc=false)

Returns a `TextConfig` with the normalization of the published TextSearch profiles: case and
diacritics are preserved, punctuation is removed, numbers and URLs are grouped.
"""
function create_textconfig(; nlist=[1], del_diac=false, del_punc=true, lc=false)
    return TextConfig(
        del_diac=del_diac,
        del_dup=false,
        del_punc=del_punc,
        group_num=true,
        group_url=true,
        lc=lc,
        nlist=nlist
    )
end

"""
    base_profile(language::AbstractString="es"; verbose=true) -> TextProfile

Loads the published TextSearch profile for `language`, downloading it to `~/.textsearch/profiles`
the first time.

The corpus is mostly Spanish: of 461,723 documents, about 80% declare Spanish and about 7%
English (2026-10-24). Until TextSearch 1.1 this module merged the `es` and `en` profiles into one
bilingual profile. TextSearch 1.3 refuses to merge profiles of different languages, because the
result is a model of neither. The Spanish profile is the base, and [`refit_corpus_profile`](@ref)
adds the English tokens of the corpus with the corpus's own counts.
"""
function base_profile(language::AbstractString="es"; verbose::Bool=true)
    path = TextSearch.download_profile(language)
    verbose && println("Loading the '$language' profile from: $path")
    return TextSearch.load_profile(path)
end

"""
    refit_corpus_profile(base::TextProfile, corpus::Vector{String};
                         apply_lemmas=true, extend_lemmas=false, verbose=true, kwargs...) -> TextProfile

Refits `base` to `corpus` with `TextSearch.refit_profile`. Since TextSearch 1.2, the refit keeps
every token that occurs in `corpus`, and a token that only the base has is kept when the base saw
it in at least `min_ndocs` documents. By default `min_ndocs` is the threshold the base was fitted
with, so the refit keeps the whole base vocabulary. `kappa` sets only the weight of the base. Its
default is the number of documents in `corpus`, so the base and the corpus have the same weight.
`kwargs` are passed to `refit_profile`.
"""
function refit_corpus_profile(
    base::TextProfile,
    corpus::Vector{String};
    apply_lemmas::Bool=true,
    extend_lemmas::Bool=false,
    verbose::Bool=true,
    kwargs...
)
    return TextSearch.refit_profile(base, corpus; apply_lemmas, extend_lemmas, verbose, kwargs...)
end

end # module TextModel
