module Imputation

using ..AuthorConsolidation: AuthorConsolidation
const AC = AuthorConsolidation

export impute_candidates

const IMPUTE_SURNAME_THRESHOLD = 0.9

"""
    _impute_given_surname(nm::AbstractString) -> (given::Vector{String}, content::Vector{String})

`nm`'s given-name tokens and FLATTENED (connector-free) surname content, via
[`AC._split_given_surname`](@ref)/[`AC._surname_content`](@ref) — the same compound-aware split
`PrecisionClustering` and production both use, so a group's surname bucket key here always agrees
with the surname key precision clustering already assigned it.
"""
function _impute_given_surname(nm::AbstractString)
    toks = AC._qgram_name_tokens(nm)
    isempty(toks) && return (String[], String[])
    gs = AC._split_given_surname(toks)
    return (gs.given, AC._surname_content(gs.surname))
end

"""
    _has_bare_initial(nm::AbstractString) -> Bool

True if any given-name token of `nm` is a single character — the ONE case
[`compute_precision_clusters`](@ref) structurally never connects on its own (it deliberately
excludes the bare-initial shortcut), and therefore the only case worth spending this module's
candidate-generation budget on (see [`impute_candidates`](@ref)'s docstring).
"""
function _has_bare_initial(nm::AbstractString)
    given, _ = _impute_given_surname(nm)
    any(t -> length(t) == 1, given)
end

"""
    _impute_edge(name_a, name_b) -> Bool

Purpose-built pairwise test for this module — replaces the earlier reused
`AC._name_cluster_strict_compatible` (production's general-purpose test, surname>=0.5/match>=0.9).
Two differences, both deliberate:

1. **Surname bar raised to `$(IMPUTE_SURNAME_THRESHOLD)`** (precision clustering's own validated
   bar, not production's looser `0.5`) — this module has no oracle downstream to catch a surname
   that's merely "somewhat similar", so it shouldn't lean on a threshold calibrated for a design
   that does.
2. **Every aligned given-name position must be exact or a genuine bare-initial match (same first
   letter) — checked per position, never via the averaged `match` score.** An averaged score can
   launder a real mismatch at one position with a strong match at another; this function has no
   downstream contradiction check to catch that the way `compute_name_clusters`'s oracle does, so
   it must not create the ambiguity in the first place. Extra tokens on the longer side (never
   entering [`AC._align_given_tokens`](@ref)'s pairs at all) are still, as always, never penalized.
"""
function _impute_edge(name_a::AbstractString, name_b::AbstractString)
    r = AC._name_match_score(name_a, name_b)
    r.surname >= IMPUTE_SURNAME_THRESHOLD || return false
    for (ta, tb, _) in r.pairs
        ta == tb && continue
        (length(ta) == 1 && !isempty(tb) && ta[1] == first(tb)) && continue
        (length(tb) == 1 && !isempty(ta) && tb[1] == first(ta)) && continue
        return false
    end
    return true
end

"""
    _coauthor_groups(nm, by_name, name_to_group) -> Set{Int}

Maps `nm`'s raw `coauthors` (literal strings from `Corpus.build_authors_index_data`, themselves
subject to every name-spelling issue this whole module exists to handle) through `name_to_group` --
normalizing coauthor IDENTITY through the SAME clustering rather than comparing raw coauthor
strings directly. A coauthor name absent from `name_to_group` (garbage, or simply outside this
run's corpus slice) is silently skipped, not an error.
"""
function _coauthor_groups(nm::AbstractString, by_name::AbstractDict, name_to_group::AbstractDict)
    haskey(by_name, nm) || return Set{Int}()
    s = Set{Int}()
    for co in get(by_name[nm], "coauthors", String[])
        gi = get(name_to_group, co, nothing)
        gi === nothing || push!(s, gi)
    end
    return s
end

"""
    impute_candidates(groups::Vector{Vector{String}}, by_name::AbstractDict) -> Vector{Vector{String}}

Imputation heuristic for the recall stage that follows precision clustering (e.g.
[`PrecisionClustering.compute_precision_clusters`](@ref)), recovering the ONE case it structurally
can't decide on its own: a given name reduced to a bare initial (e.g. `"J. Contreras Perez"` vs
`"Juan Contreras Perez"`). `by_name` is the raw profile dict (as built from
`Corpus.build_authors_index_data`, keyed by raw name) -- needed for its `"coauthors"` field, see
below. This is a from-scratch redesign (2026-09-07) of an earlier clique-based version; see this
project's own memory/design notes for the measurements that motivated it (candidate volume was the
real cost driver, not per-pair cost; the clique requirement over-corrected for an ambiguity that
only actually needs a MUCH more targeted fix).

## Candidate generation: skip the redundant majority

Two groups sharing a bucket key ([`AC._name_cluster_keys`](@ref)) are only ever compared when AT
LEAST ONE has a bare initial ([`_has_bare_initial`](@ref)) -- two "full name" groups are NEVER
compared here, since [`compute_precision_clusters`](@ref) already decided that pair with its own
validated `0.9`/`0.9` threshold; re-deciding it here with a DIFFERENT (and, in the discarded
version, looser) test added cost without adding information. Measured on the real 20-repo corpus:
this was ~98% of candidate-pair volume (5.57M of ~5.57M pairs, only 1,293 ever compatible) for
exactly zero effect on the mined-ground-truth `hard_good` rate.

## Per-edge test: [`_impute_edge`](@ref), always required, no exceptions

## Ambiguous bridges: detected structurally, not by counting initials

The failure mode a clique requirement guarded against (found live on the real 10-repo corpus): a
bare-initial-only group independently satisfies [`_impute_edge`](@ref) against BOTH of two
DIFFERENT real people (e.g. `"A. Barrios"` against `"ABELARDO NUÑEZ BARRIOS"` AND `"Alberto Salazar
Barrios"`) -- each edge is individually unremarkable (only one aligned position, resolved by a
single bare initial), so nothing about counting how many initials align in ONE edge catches this;
the actual signature is that the bridge node's two neighbors do NOT satisfy
[`_impute_edge`](@ref) with EACH OTHER. So: after building the full compatibility graph, an edge
`(a, b)` is marked risky iff `a` has some OTHER neighbor `c` incompatible with `b`, or `b` has some
OTHER neighbor `c` incompatible with `a` (checked directly via [`_impute_edge`](@ref) between `b`/`c`
or `a`/`c` even when that specific pair was never itself a name-based candidate -- two "full name"
groups that only look related through a shared ambiguous bridge were never compared by candidate
generation above, so this is the one place that comparison has to happen). This is deliberately
LOCAL (a node's own immediate neighborhood), not a global clique check over an entire component --
cost stays proportional to how many groups a bare-initial form plausibly matches, not to component
size, and a genuine multi-hop truncation chain (e.g. a prolific author's name recorded as
`"Eric Tellez"`, `"Eric S. Tellez"`, and `"Eric Sadit Tellez Avila"` across different records) is
never penalized just for not being a full clique, AS LONG AS its own links don't conflict with each
other.

A risky edge is kept only if its two groups share at least one COAUTHOR-GROUP in common (see
[`_coauthor_groups`](@ref)) -- otherwise dropped (just that edge, never the rest of the graph).
**Deliberately NOT gated on shared `institutions`/publisher**: repo/publisher metadata is a known
noisy signal on this corpus (the same paper is sometimes captured more than once, by different
people, into different repos -- a known source of duplicate-paper errors tracked separately), so an
institution mismatch must never be allowed to reject an otherwise-good name match; shared
coauthorship, normalized through this run's own clustering, is trusted instead. A risky edge with no
coauthor corroboration is simply dropped, same as a merely-uncorroborated edge always was -- never a
reason to also discard the rest of either endpoint's component the way the old clique check did.

## No clique requirement: plain connected components (union-find)

Final grouping is the connected components of whatever edges survive the risky-edge filter above --
deliberately NOT requiring the resulting component to be a clique. A person's name variants are a
CHAIN relationship (`"Eric S. Tellez"` ~ `"Eric Tellez"` ~ `"Eric Sadit Tellez Avila"`), not
necessarily a set of mutually-direct matches; the ambiguity a clique requirement was trying to catch
is now caught locally (above), so requiring global pairwise agreement on top of that is pure
over-conservatism, not extra safety.

Returns raw-name groups to merge (each proposal is every source group in one component, flattened
together) -- meant to be fed to [`AC.save_imputes`](@ref); this function only proposes, it never
writes anything.
"""
function impute_candidates(groups::Vector{Vector{String}}, by_name::AbstractDict)
    n = length(groups)
    name_to_group = Dict{String,Int}()
    for (gi, g) in enumerate(groups), nm in g
        name_to_group[nm] = gi
    end

    has_initial = [any(_has_bare_initial, g) for g in groups]

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
        for a in gis_v
            has_initial[a] || continue
            for b in gis_v
                b == a && continue
                push!(candidate_pairs, a < b ? (a, b) : (b, a))
            end
        end
    end

    function groups_compatible(a::Int, b::Int)
        a == b && return true
        all(_impute_edge(x, y) for x in groups[a] for y in groups[b])
    end

    compat_adj = Dict{Int,Set{Int}}()
    for (a, b) in candidate_pairs
        groups_compatible(a, b) || continue
        push!(get!(compat_adj, a, Set{Int}()), b)
        push!(get!(compat_adj, b, Set{Int}()), a)
    end

    coauthor_cache = Dict{Int,Set{Int}}()
    function coauthor_groups_of(gi::Int)
        get!(coauthor_cache, gi) do
            s = Set{Int}()
            for nm in groups[gi]
                union!(s, _coauthor_groups(nm, by_name, name_to_group))
            end
            delete!(s, gi)
            s
        end
    end

    to_drop = Set{Tuple{Int,Int}}()
    for (a, nbrs) in compat_adj, b in nbrs
        a < b || continue
        risky = any(c -> c != b && !groups_compatible(b, c), compat_adj[a]) ||
                any(c -> c != a && !groups_compatible(a, c), compat_adj[b])
        if risky && isempty(intersect(coauthor_groups_of(a), coauthor_groups_of(b)))
            push!(to_drop, (a, b))
        end
    end
    for (a, b) in to_drop
        delete!(compat_adj[a], b)
        delete!(compat_adj[b], a)
    end

    parent = collect(1:n)
    function find(x::Int)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    function do_union!(a::Int, b::Int)
        ra, rb = find(a), find(b)
        ra != rb && (parent[ra] = rb)
    end
    for (a, nbrs) in compat_adj, b in nbrs
        do_union!(a, b)
    end

    by_root = Dict{Int,Vector{Int}}()
    for gi in keys(compat_adj)
        isempty(compat_adj[gi]) && continue
        push!(get!(by_root, find(gi), Int[]), gi)
    end

    proposals = Vector{Vector{String}}()
    for (_, gis) in by_root
        length(gis) < 2 && continue
        push!(proposals, vcat((groups[c] for c in gis)...))
    end
    return proposals
end

end # module
