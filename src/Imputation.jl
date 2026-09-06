module Imputation

using ..AuthorConsolidation: AuthorConsolidation
const AC = AuthorConsolidation

export impute_candidates

"""
    impute_candidates(groups::Vector{Vector{String}}) -> Vector{Vector{String}}

Imputation heuristic for the recall stage that follows precision clustering (e.g.
`PrecisionClustering.compute_precision_clusters`, which defers anything initials-only or below its
0.9 precision bar). Finds sets of DIFFERENT final groups that are plausibly the same person under
PRODUCTION's own strict reconnection test, [`AC._name_cluster_strict_compatible`](@ref) (surname
`>= 0.5`, match `>= 0.9`, INCLUDING the bare-initial shortcut precision clustering deliberately
excludes) -- already validated against a mined ground truth (FP~=0.14%/FN~=0.14%, per that
function's own docstring), so this reuses proven production evidence rather than inventing a new
scoring function. This specifically recovers the case precision clustering can never handle on its
own: an initials-only variant of a full name (e.g. `"J. Contreras Perez"` vs `"Juan Contreras
Perez"`) -- `AC._name_cluster_strict_compatible`'s bare-initial shortcut scores that pair a perfect
match, something no initial-blind scoring ever can.

Candidate buckets come from [`AC._name_cluster_keys`](@ref) over every member of every group (the
SAME bucketing production clustering itself uses) -- two groups are only ever compared if some
member of each shares a bucket key, so this stays cheap at real corpus scale. Garbage names/groups
never become candidates: [`AC._is_garbage_name`](@ref) already excludes them from bucket
assignment (same guard `AC._name_cluster_keys`'s own caller in production applies).

## Why pairwise-only proposals (the first version of this function) are NOT safe here

An earlier version of this function proposed EVERY pairwise-compatible pair of groups independently
and left transitive closure to whoever consumed the proposals. That is unsound for THIS specific
consumer: [`AC.compute_groups`](@ref) treats every `impute` entry as an unconditional forced edge,
identical to a human-curated `merge` -- plain BFS, never re-checked by the oracle. Concretely, on
the real 10-repo corpus, an ambiguous bare-initial-only group like `"A. Barrios"`/`"Barrios, A."`
independently strict-matches BOTH `"ABELARDO NUÑEZ BARRIOS"` and `"Alberto Salazar Barrios"` --
each pairwise proposal is individually defensible (the initial really could be either), but a plain
union/BFS over both proposals silently bridges two DIFFERENT real people through the ambiguous
node. This is the EXACT bare-initial-bridging failure mode that motivated replacing `initials_key`
and then excluding bare-initial matching from `PrecisionClustering` in the first place -- just
recurring one layer up, between GROUPS instead of raw names. Confirmed live: pairwise-only
proposals introduced 97 new false-positive pairs against the mined "bad" ground truth (10-repo
corpus), 69 of which were pure transitive-bridging artifacts like the Barrios case (also seen with
`"A. F. Ponce"` bridging `"ADRIANA FUENTES PONCE"`/`"Aldo Ponce"`, `"J. Fernando Ayala-Zavala"`
bridging `"JESUS FERNANDO AYALA ZAVALA"`/`"Julio Zavala"`, and `"C. A. Brizuela Rodríguez"`
bridging `"CARLOS ALBERTO BRIZUELA RODRIGUEZ"`/`"Centeotl Aragón Rodríguez"`).

## The fix: require the merged supergroup to be a CLIQUE, not just chain-connected

Build the full pairwise-compatibility graph over candidate groups (an edge only where
`_name_cluster_strict_compatible` holds for EVERY cross-pair of raw names between the two groups),
take its connected components, and only emit a proposal for a component that is a full clique --
every pair of groups within it directly compatible, not merely reachable through a chain. This
rules out ambiguous bridges by construction: `"A. Barrios"` cannot be in the same clique as both
Abelardo's and Alberto's groups, because THOSE two are not compatible with each other. A component
that is not a clique is dropped ENTIRELY (no proposal at all for any group in it) rather than
guessing which side the ambiguous node belongs to -- consistent with this whole pipeline's
precision-first philosophy, and deliberately more conservative than production's own
`_name_cluster_split` (which greedily assigns an ambiguous node to whichever sub-cluster it meets
first): `impute`'s edges get no further oracle review once written, unlike `_name_cluster_split`'s
output, so there is no second chance to catch a wrong greedy guess here.

Re-validated on the real 10-repo corpus after this fix: proposals dropped from 252 (pairwise-only)
to 122 (33 ambiguous components rejected outright, ranging in size from 3 to 12 groups -- a real,
measured recall cost, not free), while new false positives against the mined "bad" set dropped from
97 to 27 -- and every one of those 27 residual "hits" was confirmed BY HAND to be a genuine
same-person match (full-name/abbreviation spelling variants, e.g. `"CLARA ELIZABETH GALINDO
SANCHEZ"` / `"Clara E. Galindo-Sánchez"`) mislabeled as "bad" by `mine_ground_truth.jl`'s own
auto-labeler, exactly the "known residual label noise" class that script's docstring already warns
about -- i.e. zero remaining GENUINE false positives found at 10-repo scale. As a side effect, the
clique requirement also rejected a real (if rare) production-inherited scoring bug found live during
this validation: `"DANIEL M. GARCIA LOPEZ"` vs `"DANIEL MARTINEZ LOPEZ"` scores a perfect
`_name_cluster_strict_compatible` match only because `_surname_span` misparses the first name's
surname as just `"lopez"` (leaving `"garcia"` stranded as a given-name-position token), letting the
bare initial `"m"` in that stranded run match `"martinez"` via the bare-initial shortcut -- two
different people, saved only because this pair also happened to sit in a non-clique component with
a third group.

**Known, deliberately-not-yet-tackled refinement**: a non-clique component is currently dropped
WHOLESALE, even when most of its groups (excluding the one ambiguous bridge) would form a valid
sub-clique on their own. Recovering that sub-clique (rather than discarding everyone in the
component) is the natural next lever if a future corpus run shows real merges being missed because
of one noisy member -- deliberately left alone for now rather than guessing at the right
partitioning rule without evidence it's needed.

Returns raw-name groups to merge (each proposal is every source group in one clique, flattened
together) -- meant to be fed to [`AC.save_imputes`](@ref); this function only proposes, it never
writes anything.
"""
function impute_candidates(groups::Vector{Vector{String}})
    buckets = Dict{String,Set{Int}}()
    for (gi, g) in enumerate(groups), nm in g
        AC._is_garbage_name(nm) && continue
        for k in AC._name_cluster_keys(nm)
            push!(get!(buckets, k, Set{Int}()), gi)
        end
    end

    candidate_pairs = Set{Tuple{Int,Int}}()
    for (_, gis) in buckets
        gis_v = collect(gis)
        length(gis_v) < 2 && continue
        for i in 1:length(gis_v), j in (i+1):length(gis_v)
            a, b = gis_v[i], gis_v[j]
            push!(candidate_pairs, a < b ? (a, b) : (b, a))
        end
    end

    compat_adj = Dict{Int,Set{Int}}()
    for (a, b) in candidate_pairs
        all_strict = all(AC._name_cluster_strict_compatible(x, y) for x in groups[a] for y in groups[b])
        all_strict || continue
        push!(get!(compat_adj, a, Set{Int}()), b)
        push!(get!(compat_adj, b, Set{Int}()), a)
    end

    visited = Set{Int}()
    proposals = Vector{Vector{String}}()
    for gi in keys(compat_adj)
        gi in visited && continue
        comp = Int[]
        queue = [gi]
        push!(visited, gi)
        while !isempty(queue)
            cur = popfirst!(queue)
            push!(comp, cur)
            for nb in compat_adj[cur]
                if !(nb in visited)
                    push!(visited, nb)
                    push!(queue, nb)
                end
            end
        end
        length(comp) < 2 && continue
        is_clique = all(b in compat_adj[a] for a in comp for b in comp if a != b)
        is_clique || continue
        push!(proposals, vcat((groups[c] for c in comp)...))
    end
    return proposals
end

end # module
