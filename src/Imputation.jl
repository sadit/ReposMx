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
    _surname_words(nm::AbstractString) -> Vector{String}

The surname words of `nm` ([`_impute_given_surname`](@ref)) with two letters or more. Words of one
letter are dropped, because the split sometimes takes a middle initial as a surname
(`"S. V Koshevaya"`).
"""
_surname_words(nm::AbstractString) = filter(w -> length(w) >= 2, _impute_given_surname(nm)[2])

"""
    _first_surname_agrees(name_a, name_b) -> Bool

False when the two surnames have a different number of words and the shorter one matches only
the last word of the longer one, written with a hyphen. A name usually omits its second surname,
not its first: `"Juan Icaza"` is not a short form of `"María J. Anchustegui-Icaza"`.

Without a hyphen, a match on the last word is accepted. The split cannot tell a second given name
from a first surname: in `"LILIANA INES HOMILKA"` it takes `"Ines"` as the first surname, and
`"L. Homilka"` is the same person. The wrong matches of this shape seen on 2026-10-26 also leave
out a first given name (`"Jorge A. Sayago Valerio"` and `"Angelo Valerio"`), so
[`_weak_match`](@ref) handles them.
"""
function _first_surname_agrees(name_a::AbstractString, name_b::AbstractString)
    ca, cb = _surname_words(name_a), _surname_words(name_b)
    (isempty(ca) || isempty(cb) || length(ca) == length(cb) || ca[1] == cb[1]) && return true
    longer_name = length(ca) > length(cb) ? name_a : name_b
    return ca[end] == cb[end] && !occursin('-', longer_name)
end

"""
    _weak_match(name_a, name_b) -> Bool

True when the alignment of given names leaves out the first given name of the name with more
given names. `"Francisco J. Grajeda-Sandoval"` and `"Jonathan Grajeda"` match only through `"J."`;
`"Karla G. Ramírez-Morales"` and `"Gerardo Ramírez Morales"` match only through `"G."`. The same
shape also describes one person who uses a middle name: `"Jesús A. Carrasco Ochoa"` and
`"Ariel Carrasco"`. [`impute_candidates`](@ref) keeps such an edge only when the two groups share a
coauthor.
"""
function _weak_match(name_a::AbstractString, name_b::AbstractString)
    ga, gb = _impute_given_surname(name_a)[1], _impute_given_surname(name_b)[1]
    (isempty(ga) || isempty(gb) || length(ga) == length(gb)) && return false
    longer = length(ga) > length(gb) ? ga : gb
    pairs = AC._name_match_score(name_a, name_b).pairs
    return !any(p -> p[2] == longer[1], pairs)
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

Two more rules, added 2026-10-26 after a review of the 2,755 proposals of the 93-repo corpus:

3. **Both names must have a given name.** A bare surname (`"Rivero"`) has no given-name pairs, so
   rule 2 accepted it against every person with that surname. It then joined `"M. Rivero"`,
   `"R. Rivero"` and `"Valentín Rivero Gajá"` into one group. 329 proposals had a bare surname.
4. **A shorter surname must match the first surname of the longer one** (see
   [`_first_surname_agrees`](@ref)). `AC._name_match_score` also accepts a match on the last
   surname, so `"Gonzalo Camacho"` matched `"Luis G. Barragán-Camacho"` through the initial `"G."`.
   `first_surname=false` skips this rule; [`impute_candidates`](@ref) applies it to a pair of
   groups as a whole.
"""
function _impute_edge(name_a::AbstractString, name_b::AbstractString; first_surname::Bool=true)
    r = AC._name_match_score(name_a, name_b)
    r.surname >= IMPUTE_SURNAME_THRESHOLD || return false
    isempty(r.pairs) && return false
    first_surname && !_first_surname_agrees(name_a, name_b) && return false
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

## Rules for a pair of groups (2026-10-26)

Two groups are compatible when every pair of their names passes [`_impute_edge`](@ref) without
its first-surname rule, and at least one pair passes [`_first_surname_agrees`](@ref). The second
condition is checked on one pair only, because a group often holds a variant without the first
surname: the group of `"Flor Isela Retana Rentería"` also holds `"Flor Rentería"`.

An edge between two groups whose name pairs are all [`_weak_match`](@ref) is kept only when the
groups share a coauthor group. Without that rule, `"Jonathan Grajeda"` joined
`"Francisco J. Grajeda-Sandoval"`, and `"Karla G. Ramírez-Morales"` joined
`"Gerardo Ramírez Morales"`.

## Components, checked pairwise

Final grouping is the connected components of whatever edges survive the filters above. Each
component is then checked pairwise: every two of its groups must pass `groups_compatible`. A
component that fails loses, in this order, the weak edges kept by a shared coauthor, and then the
risky edges kept by a shared coauthor. After each step the check is repeated on each remaining
piece. A piece that still fails is not proposed.

The pairwise check was added on 2026-10-26. Without it, 106 of 2,755 proposals of the 93-repo corpus
joined two names that fail [`_impute_edge`](@ref) directly. The links between them were risky
edges that a shared coauthor kept. The largest one joined 30 names, among them
`"Pranil Man Singh Pradhan"`, `"Paramjit Singh Gill"`, `"P. Singh"` and `"J. Singh"`. The
variants of one person usually pass the check: `"Eric Tellez"`, `"Eric S. Tellez"` and
`"Eric Sadit Tellez Avila"` are compatible two by two.

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
        all(_impute_edge(x, y; first_surname=false) for x in groups[a] for y in groups[b]) &&
            any(_first_surname_agrees(x, y) for x in groups[a] for y in groups[b])
    end
    groups_weak(a::Int, b::Int) = all(_weak_match(x, y) for x in groups[a] for y in groups[b])

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

    share_coauthor(a, b) = !isempty(intersect(coauthor_groups_of(a), coauthor_groups_of(b)))
    weak_kept = Set{Tuple{Int,Int}}()
    for (a, nbrs) in compat_adj, b in collect(nbrs)
        (a < b && groups_weak(a, b)) || continue
        if share_coauthor(a, b)
            push!(weak_kept, (a, b))
        else
            delete!(compat_adj[a], b)
            delete!(compat_adj[b], a)
        end
    end

    to_drop = Set{Tuple{Int,Int}}()
    risky_kept = Set{Tuple{Int,Int}}()
    for (a, nbrs) in compat_adj, b in nbrs
        a < b || continue
        risky = any(c -> c != b && !groups_compatible(b, c), compat_adj[a]) ||
                any(c -> c != a && !groups_compatible(a, c), compat_adj[b])
        risky || continue
        push!(share_coauthor(a, b) ? risky_kept : to_drop, (a, b))
    end
    for (a, b) in to_drop
        delete!(compat_adj[a], b)
        delete!(compat_adj[b], a)
    end

    compat_cache = Dict{Tuple{Int,Int},Bool}()
    compatible(a, b) = get!(() -> groups_compatible(a, b), compat_cache, minmax(a, b))
    is_clique(gis) = all(compatible(gis[i], gis[j]) for i in eachindex(gis) for j in i+1:lastindex(gis))
    function cut!(gis, edges)
        inside = Set(gis)
        for (a, b) in edges
            (a in inside && b in inside) || continue
            delete!(compat_adj[a], b)
            delete!(compat_adj[b], a)
        end
        return _components(compat_adj, gis)
    end
    proposals = Vector{Vector{String}}()
    for gis in _components(compat_adj)
        pieces = [gis]
        for edges in (weak_kept, risky_kept)
            all(is_clique, pieces) && break
            pieces = vcat((is_clique(p) ? [p] : cut!(p, edges) for p in pieces)...)
        end
        for p in pieces
            length(p) >= 2 && is_clique(p) && push!(proposals, vcat((groups[c] for c in p)...))
        end
    end
    return proposals
end

"""
    _components(adj, nodes=keys(adj)) -> Vector{Vector{Int}}

Connected components of the graph `adj` (node -> set of neighbors), restricted to `nodes`. Each
component is sorted. Nodes without neighbors form components of size 1.
"""
function _components(adj::AbstractDict{Int,Set{Int}}, nodes=keys(adj))
    inside = Set{Int}(nodes)
    seen = Set{Int}()
    comps = Vector{Vector{Int}}()
    for s in sort!(collect(inside))
        s in seen && continue
        comp = Int[]
        stack = [s]
        push!(seen, s)
        while !isempty(stack)
            x = pop!(stack)
            push!(comp, x)
            for y in get(adj, x, Set{Int}())
                (y in inside && y ∉ seen) || continue
                push!(seen, y)
                push!(stack, y)
            end
        end
        push!(comps, sort!(comp))
    end
    return comps
end

end # module
