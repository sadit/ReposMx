module Imputation

using ..AuthorConsolidation: AuthorConsolidation
const AC = AuthorConsolidation

export impute_candidates

"""
    impute_candidates(groups::Vector{Vector{String}}) -> Vector{Vector{String}}

First heuristic for the imputation stage (deliberately minimal, meant to be tightened/loosened as
real corpus runs show what's actually needed -- see the module docstring in
`PrecisionClustering.jl` and the current plan's Pieza D2 note).

Finds pairs of DIFFERENT final groups (as produced by e.g.
`PrecisionClustering.compute_precision_clusters`, which defers anything initials-only or below its
0.9 precision bar) that are plausibly the same person under PRODUCTION's own strict reconnection
test, [`AC._name_cluster_strict_compatible`](@ref) (surname `>= 0.5`, match `>= 0.9`, INCLUDING the
bare-initial shortcut precision clustering deliberately excludes) -- already validated against a
mined ground truth (FP~=0.14%/FN~=0.14%, per that function's own docstring), so this reuses proven
production evidence rather than inventing a new scoring function. This specifically recovers the
case precision clustering can never handle on its own: an initials-only variant of a full name
(e.g. `"J. Contreras Perez"` vs `"Juan Contreras Perez"`) -- `AC._name_cluster_strict_compatible`'s
bare-initial shortcut scores that pair a perfect match, something no initial-blind scoring ever can.

Candidate buckets come from [`AC._name_cluster_keys`](@ref) over every member of every group (the
SAME bucketing production clustering itself uses) -- two groups are only ever compared if some
member of each shares a bucket key, so this stays cheap at real corpus scale.

**ACCEPTANCE requires EVERY cross-pair between the two groups' members to pass** -- a deliberately
conservative starting bar, not a proven-optimal one: groups compared here are usually small
(precision clustering's own observed max size on the real 10-repo corpus was 6), so requiring
unanimous agreement is not yet a heavy cost, but this is the first knob to revisit if real corpus
runs show correct merges being missed because of one noisy member.

Garbage names/groups never become candidates: [`AC._is_garbage_name`](@ref) already excludes them
from bucket assignment (same guard `AC._name_cluster_keys`'s own caller in production applies).

Returns raw-name groups to merge (each proposal is the two source groups flattened together) --
meant to be fed to [`AC.save_imputes`](@ref) after review, not applied blindly; this function only
proposes, it never writes anything.
"""
function impute_candidates(groups::Vector{Vector{String}})
    buckets = Dict{String,Set{Int}}()
    for (gi, g) in enumerate(groups), nm in g
        AC._is_garbage_name(nm) && continue
        for k in AC._name_cluster_keys(nm)
            push!(get!(buckets, k, Set{Int}()), gi)
        end
    end

    proposals = Vector{Vector{String}}()
    seen_pairs = Set{Tuple{Int,Int}}()
    for (_, gis) in buckets
        gis_v = collect(gis)
        length(gis_v) < 2 && continue
        for i in 1:length(gis_v), j in (i+1):length(gis_v)
            a, b = gis_v[i], gis_v[j]
            pair = a < b ? (a, b) : (b, a)
            pair in seen_pairs && continue
            push!(seen_pairs, pair)
            all_strict = all(AC._name_cluster_strict_compatible(x, y) for x in groups[a] for y in groups[b])
            all_strict || continue
            push!(proposals, vcat(groups[a], groups[b]))
        end
    end
    return proposals
end

end # module
