#=
Phase-1 (clustering) candidate replacement using SimilaritySearch's own parallel machinery
(DictInvertedFile + exact Jaccard, via `allknn`) instead of a hand-rolled O(bucket^2) loop.
STATUS: prototype, NOT integrated. See `qgram_oracle_clustering.jl` in this same directory for
the currently-integrated design (`AuthorConsolidation.compute_name_clusters`) this is meant to
eventually replace ONLY at phase 1 -- the oracle (`AC._name_cluster_contradiction` /
`AC._name_cluster_split`) is reused UNCHANGED here, exactly as-is from production.

## Why this exists

`compute_name_clusters`'s phase 1 is a hand-written nested loop, O(bucket^2), single-threaded (see
GitHub issue #2's performance follow-up comment) -- confirmed via a real full-93-repo rebuild that
this does not scale well (a bucket of 12,615-17,789 names costs tens of minutes on its own, even
after memoization). SimilaritySearch's `allknn`/`searchbatch` parallelize automatically across
however many Julia threads are available (verified: `Threads.@threads`-style batching inside
`allknn!`, generic across any `AbstractSearchIndex`). This file rebuilds phase-1 candidate
generation on top of that, keeping everything else (bucketing, the oracle) exactly as validated in
production.

## Design: sets, not pairwise alignment -- and why that's fine now

Earlier this session, a bag-of-q-grams (role-tagged, boundary-marked, `Set`+Jaccard) design was
tried and REJECTED as the FINAL name-matching decision: it let false positives through that the
current pairwise-alignment design (`AC._name_match_score`) correctly rejects (e.g. "MANUEL ALBERTO
CHAVEZ GONZALEZ"/"MARIA ANTONIETA CHAVEZ GONZALEZ" -- identical double surname, different given
name -- scored HIGHER via bag-Jaccard than several genuine truncation matches; verified again here
with the exact same numbers: 0.48 with enrichment, 0.43 without, both above multiple true-positive
scores). That rejection was about using it as the ONLY signal.

The point of *this* file is different: split responsibilities the way the rest of the pipeline
already does -- **phase 1 unites what's plausible (recall), the oracle divides with hard evidence
(precision)**. The Manuel/Maria case is EXACTLY what `AC._name_cluster_contradiction` already
catches (validated, unchanged, real production code) -- letting phase 1 connect them is fine as
long as the oracle still separates them afterward, which it does, because the oracle re-examines
the connected COMPONENT with its own (unchanged, exact, per-token) logic regardless of how that
component was assembled. So `enrich=true` (synthesizing a bare-initial element for every given
token) is used freely here -- it can ONLY help recall at phase 1, since anything it over-connects
is the oracle's job to undo.

The real, still-open question this file's validation targets: does bag-of-q-grams UNDER-connect
anything the current exact pairwise method catches (a recall regression at phase 1), and can the
oracle keep up with whatever (likely larger) components result?

## The stopword problem (why DictInvertedFile specifically needs DF-pruning)

A `DictInvertedFile` degrades in *performance* (not correctness) when an element's posting list
covers most of the collection -- every query touches that whole list during the merge. Within one
surname bucket, the surname's OWN q-grams are shared by (approximately) every member BY
CONSTRUCTION (that's the bucketing key) -- exactly the "stopword" pattern IR systems prune for.
`prune_stopword_elements` drops any element whose in-bucket document frequency exceeds `max_df`
before building the index. This is a performance fix only, applied per-bucket (document frequency
is a collection-relative concept) -- it does not change correctness since a saturated element
(present in nearly everyone) carries ~zero discriminating power there anyway.

## Generic index construction (the ask: keep this swappable for SearchGraph later)

`build_name_index` takes the same `Vector{Set{String}}` representation and dispatches on
`backend`. `:dictinvfile` is implemented (exact Jaccard, see `has_exact_fastpath` in
SimilaritySearch's own docs for `InvertedFile`). `:searchgraph` is a reserved, unimplemented
extension point -- trying it would need a `SemiMetric` SearchGraph can traverse (native
`Dist.Sets.Jaccard()` should work directly, since it's already a proper `Metric`) and gives up
`DictInvertedFile`'s current exactness for approximate (faster at larger scale, unvalidated) search.

## Two real bugs found and fixed while validating this (both live in THIS file)

1. **Dual-role tagging applied without real ambiguity.** The "duda" token (the one that might be a
   middle given name OR a paternal surname) is `given[end]` -- but that's only an actual ambiguity
   when `length(given) >= 2`. With `length(given) == 1` (e.g. `"Victor Torres"`, a plain "Nombre
   Apellido" record), the one given token is unambiguously a given name, never a surname candidate
   -- tagging it `:s` too polluted the surname-side set with given-name content for no reason
   (found live: this alone made `"Victor Torres"` fail to match its own full form `"Victor Manuel
   Torres De La Cruz"`, among other truncation cases). Fixed: dual-tag only fires for
   `length(given) >= 2`.
2. **`prune_stopword_elements`'s fractional `max_df` was meaningless on small buckets.** With
   `n=2`, ANY element shared by both names has `df=1.0` -- `max_df=0.5` pruned every bit of real
   signal, including the surname q-grams that are usually the entire reason two names share a
   bucket (found live: gutted a 2-member "torres" bucket to zero overlap). Fixed: skip pruning
   entirely below `min_n` (default 50) -- small buckets are cheap enough for exact search anyway,
   so there was never a performance reason to prune them.

A third gap (NOT a bug in this file) was found via the comparison this file's validation runs
against production: `AC._name_cluster_contradiction` used to skip a pair when its direct surname
score was low, instead of treating that AS the contradiction -- see the "surname mismatch" fix in
`AuthorConsolidation.jl`'s git history (committed separately, real production hardening, unrelated
to whether this file is ever integrated).

## Validation results (real 10-repo corpus, 19,543 raw names, production oracle fix applied)

- Hand-picked regression set (the same cases in `test/runtests.jl`'s `_plausibly_same_person`
  tests, re-expressed as cluster-membership checks): 0/12 failures, matching production exactly.
- End-to-end group comparison against `AC.compute_name_clusters` on the full 10-repo corpus:
  16,697 groups (v2) vs 16,625 (production) -- 430 groups differ (down from ~3,877 before the
  oracle fix above). Spot-checking the remaining differences surfaced a THIRD, separate, still-
  OPEN production bug this file did not introduce and does not fix: two bare initials each
  independently matching a different given-name token by coincidental shared first letter (e.g.
  `"ARTURO REYES RAMIREZ"` vs `"R. A. Smith Ramírez"` -- production merges them, matching `"R."`
  against `"Reyes"`'s first letter and `"A."` against `"Arturo"`'s, entirely coincidentally, then
  reinforced by an exact surname match; this file's bag representation does NOT make the same
  mistake here, i.e. v2's answer looks more correct in this specific case). Filed separately -- see
  GitHub issue #3.
- **Speed: NOT yet a win at this scale.** 54.1s (v2) vs 44.2s (production, phase1+oracle combined)
  on the 10-repo corpus -- v2 is SLOWER here. Root cause: building a fresh `DictInvertedFile` per
  bucket has fixed overhead (allocation, batch-scheduling setup) that only pays off for large
  buckets; with 5,835 buckets and only a handful actually large, that overhead dominates for the
  many small ones. NEXT STEP (not yet implemented): a hybrid `compute_name_clusters` that only
  routes buckets above some size threshold (e.g. a few hundred) through `bucket_edges_invfile`,
  keeping the current direct/memoized loop for everything smaller -- untested whether this actually
  wins even on the pathological full-93-repo buckets (12,615-17,789 members) that motivated this
  file in the first place; that comparison has not been run yet (would need reloading the full
  93-repo corpus, ~2 minutes just for `_collect_documents`).
=#

using ReposMx
using SimilaritySearch
using SimilaritySearch.InvertedFiles: DictInvertedFile, getcontext
const AC = ReposMx.AuthorConsolidation
const Q = 4

# ============================================================
# Representation: role-tagged (:g given / :s surname), dual-tagged for the paternal-surname-
# candidate token, boundary-marked character q-grams. Reuses AC's own (unchanged) tokenization /
# compound-surname detection so this stays consistent with the production tokenizer.
# ============================================================

function _qgrams_padded(t::AbstractString; q::Int=Q)
    padded = collect("^" * t * "\$")
    length(padded) < q && return String[String(padded)]
    return [String(padded[i:i+q-1]) for i in 1:(length(padded)-q+1)]
end

"""
    name_qgram_set(raw; q=Q, enrich=true) -> Set{String}

See module docstring for why `enrich=true` is safe (even desirable) here, unlike when this same
representation was tried as a FINAL decision metric.
"""
function name_qgram_set(raw::AbstractString; q::Int=Q, enrich::Bool=true)
    toks = AC._qgram_name_tokens(raw)
    isempty(toks) && return Set{String}()
    span = AC._surname_span(toks)
    given = toks[1:first(span)-1]
    surname = toks[span]
    elems = String[]
    for t in given
        for g in _qgrams_padded(t; q); push!(elems, g * ":g"); end
        enrich && length(t) > 1 && push!(elems, "^" * string(first(t)) * "\$:g")
    end
    surname_str = join(surname, " ")
    for g in _qgrams_padded(surname_str; q); push!(elems, g * ":s"); end
    if length(given) >= 2
        # dual-role ("duda"): only a REAL ambiguity when there's a given token besides this one --
        # a single given name (length(given) == 1, e.g. "Victor Torres") has no ambiguity at all,
        # it's unambiguously the given name, never a paternal-surname candidate. Tagging it :s too
        # in that case pollutes the surname-side set with given-name content for no reason (found
        # live: inflated a false match risk for "Victor Torres" against unrelated "victor"-sharing
        # names, and wasted signal that should have stayed on the :g side only).
        t = given[end]
        for g in _qgrams_padded(t; q); push!(elems, g * ":s"); end
        enrich && length(t) > 1 && push!(elems, "^" * string(first(t)) * "\$:s")
    end
    return Set(elems)
end

"""
    prune_stopword_elements(sets; max_df=0.5, min_n=50) -> (pruned_sets, stopword_set)

Drops any element whose document frequency (fraction of `sets` containing it) exceeds `max_df` --
see module docstring's "stopword problem" section. A PERFORMANCE fix for `DictInvertedFile`'s
posting-list merge cost, not a correctness change for a LARGE collection (a near-universal element
has ~no discriminating power there anyway) -- but a fractional threshold is meaningless on a small
one: with `n=2`, any element shared by both names already has `df=1.0`, so `max_df=0.5` would
prune every bit of real signal, including the surname q-grams that are usually the WHOLE reason
two names share a bucket (found live: gutted the only two members of a "torres" bucket down to
zero overlap). Skip pruning entirely below `min_n` -- small buckets are cheap enough for exact
search anyway, so there's no performance reason to prune them in the first place.
"""
function prune_stopword_elements(sets::Vector{Set{String}}; max_df::Float64=0.5, min_n::Int=50)
    n = length(sets)
    (n == 0 || n < min_n) && return sets, Set{String}()
    df = Dict{String,Int}()
    for s in sets, e in s
        df[e] = get(df, e, 0) + 1
    end
    stop = Set(k for (k, v) in df if v / n > max_df)
    isempty(stop) && return sets, stop
    return [setdiff(s, stop) for s in sets], stop
end

"""
    build_name_index(sets; backend=:dictinvfile, dist=Dist.Sets.Jaccard()) -> (index, context)

Generic index construction over the same `Vector{Set{String}}` representation, dispatched by
`backend` -- kept swappable on purpose (see module docstring). `:searchgraph` is a placeholder for
a future, unvalidated attempt; only `:dictinvfile` is implemented and validated here.
"""
function build_name_index(sets::Vector{Set{String}}; backend::Symbol=:dictinvfile, dist=Dist.Sets.Jaccard())
    if backend == :dictinvfile
        db = VectorDatabase(sets)
        idx = DictInvertedFile(String, dist)
        ctx = getcontext(idx)
        append_items!(idx, ctx, db)
        return idx, ctx
    elseif backend == :searchgraph
        error("backend=:searchgraph is a reserved, unimplemented extension point -- see module docstring")
    else
        error("unknown backend $backend")
    end
end

"""
    bucket_edges_invfile(names; q=Q, enrich=true, max_df=0.5, k=64, thr=0.3) -> Vector{Tuple{Int,Int}}

Phase-1 candidate edges (index pairs into `names`) within one bucket, via `allknn` over a
DictInvertedFile with exact Jaccard (parallel by default). `k` approximates a threshold/range
query (SimilaritySearch's inverted-file `search` is k-NN shaped, not radius-shaped) -- generous by
design, oversized relative to any expected true-cluster size, then filtered by `thr` afterward.
"""
function bucket_edges_invfile(names::Vector{String}; q::Int=Q, enrich::Bool=true, max_df::Float64=0.5,
                               k::Int=64, thr::Float64=0.3)
    n = length(names)
    n < 2 && return Tuple{Int,Int}[]
    sets_raw = [name_qgram_set(nm; q, enrich) for nm in names]
    sets, _stop = prune_stopword_elements(sets_raw; max_df)
    idx, ctx = build_name_index(sets)
    kk = min(k, n - 1)
    ids, dists = allknn(idx, ctx, kk + 1)  # +1: each point is trivially its own nearest neighbor
    edges = Tuple{Int,Int}[]
    for j in 1:n, r in 1:size(ids, 1)
        i = ids[r, j]
        (i == 0 || Int(i) == j) && continue
        sim = 1.0 - dists[r, j]
        sim >= thr || continue
        a, b = minmax(Int(i), j)
        push!(edges, (a, b))
    end
    return unique(edges)
end

"""
    compute_name_clusters_v2(raw_names; kwargs...) -> Vector{Vector{String}}

Drop-in comparison for `AC.compute_name_clusters`: SAME bucketing (`AC._name_cluster_keys`), SAME
oracle (`AC._name_cluster_contradiction` / `AC._name_cluster_split`, both unmodified production
code) -- ONLY phase 1's connection mechanism differs (DictInvertedFile+allknn here vs. the
hand-rolled exact loop in production).
"""
function compute_name_clusters_v2(raw_names::Vector{String}; q::Int=Q, enrich::Bool=true,
                                   max_df::Float64=0.5, k::Int=64, thr::Float64=0.3)
    n = length(raw_names)
    n == 0 && return Vector{Vector{String}}()
    idx_of = Dict(nm => i for (i, nm) in enumerate(raw_names))

    # garbage (ORCID/URL) "names" collapse to identical degenerate tokens under this tokenizer --
    # production's _name_match_score guards against this with an explicit is_garbage check inside
    # the pairwise score itself; a set/Jaccard representation has no equivalent per-pair override
    # point, so the guard has to happen at bucket-membership time instead: never let a garbage name
    # enter a bucket at all, so it can never be compared to anything and falls through to its own
    # singleton group via the union-find's untouched-node default (same as production).
    candidate_buckets = Dict{String,Vector{String}}()
    for nm in raw_names
        AC._is_garbage_name(nm) && continue
        for key in AC._name_cluster_keys(nm)
            push!(get!(candidate_buckets, key, String[]), nm)
        end
    end

    parent = collect(1:n)
    function uf_find(x)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    function uf_union!(a, b)
        ra, rb = uf_find(a), uf_find(b)
        ra != rb && (parent[ra] = rb)
    end

    for (_, bucket) in candidate_buckets
        bucket = unique(bucket)
        length(bucket) < 2 && continue
        for (bi, bj) in bucket_edges_invfile(bucket; q, enrich, max_df, k, thr)
            uf_union!(idx_of[bucket[bi]], idx_of[bucket[bj]])
        end
    end

    by_root = Dict{Int,Vector{String}}()
    for nm in raw_names
        push!(get!(by_root, uf_find(idx_of[nm]), String[]), nm)
    end

    groups = Vector{Vector{String}}()
    for (_, comp) in by_root
        if length(comp) == 1
            push!(groups, comp)
            continue
        end
        cx = AC._name_cluster_contradiction(comp)
        if cx === nothing
            push!(groups, comp)
        else
            append!(groups, AC._name_cluster_split(comp))
        end
    end
    return groups
end
