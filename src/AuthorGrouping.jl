"""
    AuthorGrouping

Groups raw author names into one group per person, for `Indexing` to roll up into consolidated
profiles (`AuthorConsolidation.build_and_persist`). Four steps:

1. `NameVocabulary.build_name_vocabulary` counts given-name and surname tokens over all names.
2. `PrecisionClustering.compute_precision_clusters` corrects each name against that vocabulary and
   joins two names only when both their given names and their surnames match.
3. `Imputation.impute_candidates` proposes to join a name with a bare initial
   (`"J. Contreras Perez"`) to the group of the full name (`"Juan Contreras Perez"`).
4. `AuthorConsolidation.compute_groups` applies those proposals and the hand-written
   `merge`/`split` overrides.

This module exists because `AuthorConsolidation` is loaded before the three modules of steps 1 to
3, which use it.

Measured on the 93-repo corpus (446,650 raw names, 2026-09-09): step 2 took 2.3 hours.
"""
module AuthorGrouping

using ..AuthorConsolidation: AuthorConsolidation
using ..NameVocabulary: build_name_vocabulary
using ..PrecisionClustering: compute_precision_clusters
using ..Imputation: impute_candidates
const AC = AuthorConsolidation

export group_names, group_authors

_log(msg) = (println(msg); flush(stdout))

"""
    group_names(raw_names, by_name, overrides) -> (; groups, imputes)

Runs the four steps of this module over `raw_names`. `by_name` maps each raw name to its raw
profile; `Imputation` reads its `"coauthors"`. `overrides` is the result of
`AuthorConsolidation.load_overrides`; its `imputes` are ignored and replaced by the proposals of
this run, which are returned as `imputes`.
"""
function group_names(raw_names::Vector{String}, by_name::AbstractDict, overrides)
    t = time()
    vocab = build_name_vocabulary(raw_names)
    _log("  name vocabulary: $(round(time() - t, digits=1))s")
    t = time()
    clusters = compute_precision_clusters(raw_names, vocab)
    _log("  precision clusters: $(length(clusters)) from $(length(raw_names)) names, $(round(time() - t, digits=1))s")
    t = time()
    imputes = impute_candidates(clusters, by_name)
    _log("  imputation: $(length(imputes)) proposals, $(round(time() - t, digits=1))s")
    groups = AC.compute_groups(clusters, (; overrides.merges, overrides.splits, imputes))
    return (; groups, imputes)
end

"""
    group_authors(authors_data; overrides_path=AuthorConsolidation.DEFAULT_AUTHOR_OVERRIDES_TOML) -> Vector{Vector{String}}

Groups the raw profiles `authors_data` (as returned by `Corpus.build_authors_index_data`) with
[`group_names`](@ref), using the hand-written overrides in `overrides_path`. It writes the
imputation proposals of this run to the `impute` section of that file
(`AuthorConsolidation.save_imputes`), for review.
"""
function group_authors(authors_data::Vector{<:AbstractDict};
                       overrides_path::AbstractString=AC.DEFAULT_AUTHOR_OVERRIDES_TOML)
    by_name = Dict{String,Any}(a["name"] => a for a in authors_data)
    raw_names = sort!(collect(keys(by_name)))
    (; groups, imputes) = group_names(raw_names, by_name, AC.load_overrides(overrides_path))
    AC.save_imputes(imputes, overrides_path)
    return groups
end

end # module AuthorGrouping
