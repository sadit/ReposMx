module PrecisionClustering

using ..AuthorConsolidation: AuthorConsolidation
using ..NameVocabulary: NameVocabulary, Vocabulary, correct_token, _DAMERAU
using SimilaritySearch: SimilaritySearch, @BATCHES, @BEGIN, @BEGINBATCH, @LOOP, @END, @nbatches, @batchid, getminbatch
const AC = AuthorConsolidation
const Dist = SimilaritySearch.Dist

export correct_name, precision_cluster_keys, precision_match_score, precision_edge,
       precision_contradiction, precision_strict_compatible, precision_split,
       compute_precision_clusters

const PRECISION_MATCH_THRESHOLD = 0.9
const PRECISION_SURNAME_THRESHOLD = 0.9
const PRECISION_STRICT_SURNAME_THRESHOLD = 0.5   # matches AC._name_cluster_strict_compatible
const PRECISION_STRICT_MATCH_THRESHOLD = 0.9     # matches AC._name_cluster_strict_compatible
const PRECISION_CONTRADICTION_FLOOR = 0.2        # matches AC._NAME_CLUSTER_CONTRADICTION_FLOOR
const PRECISION_SCORE_METHOD = :damerau

"""
    correct_name(vocab, raw; method=:damerau) -> (; given::Vector{String}, surname::Vector{String})

Splits `raw` into given/surname tokens using the same `AC._surname_span` logic as production
clustering, then corrects each token against `vocab` (see `NameVocabulary.correct_token`) --
EXCEPT surname particles (`AC._SURNAME_PARTICLES`, e.g. "de"/"la"), which pass through unchanged
(they were never in the vocabulary to begin with, see `NameVocabulary.build_name_vocabulary`).
Bare initials also pass through unchanged (`correct_token` is a no-op on them by construction) --
this stage never fabricates a full word out of an initial, it only fixes typos in words that are
ALREADY full words. `method` default matches `NameVocabulary.correct_token`'s own (validated
against the 93-repo vocabulary artifact, see that function's docstring) rather than being pinned
independently -- keep the two in sync if either one's default ever changes again.
"""
function correct_name(vocab::Vocabulary, raw::AbstractString; method::Symbol=:damerau)
    toks = AC._qgram_name_tokens(raw)
    isempty(toks) && return (given=String[], surname=String[])
    span = AC._surname_span(toks)
    given = [first(correct_token(vocab, t, :given; method)) for t in toks[1:first(span)-1]]
    surname = [t in AC._SURNAME_PARTICLES ? t : first(correct_token(vocab, t, :surname; method))
               for t in toks[span]]
    return (given=given, surname=surname)
end

"""
    precision_cluster_keys(corrected) -> Vector{String}

Candidate-bucket keys for [`compute_precision_clusters`](@ref), mirroring
`AC._name_cluster_keys`'s two-key scheme (literal surname head + paternal-surname candidate for
compound-surname truncation) but sourced from an ALREADY-CORRECTED `(given, surname)` pair (see
[`correct_name`](@ref)) instead of re-tokenizing a raw string -- correction only happens once per
name, not once per bucket-key computation.
"""
function precision_cluster_keys(corrected)
    isempty(corrected.surname) && return String[]
    keys = [corrected.surname[end]]
    length(corrected.given) >= 2 && push!(keys, corrected.given[end])
    return unique(keys)
end

"""
    _precision_token_score(a, b; method=PRECISION_SCORE_METHOD, dl=_DAMERAU) -> Float64

String-similarity for THIS stage -- used both for a single given-name token pair AND (via
[`precision_match_score`](@ref)) for a whole joined surname phrase -- deliberately WITHOUT
`AC._token_alignment_score`'s bare-initial shortcut (a length-1 token matching ANY word sharing its
first letter). Two methods, kept side by side for empirical comparison (same reasoning as
`NameVocabulary.correct_token`'s own `method` options -- pick by measuring against real corpus runs,
not by assumption):

- `:damerau` (the default) -- restricted Damerau-Levenshtein (`dl`, defaulting to [`_DAMERAU`](@ref)
  imported from `NameVocabulary` -- but see [`compute_precision_clusters`](@ref)'s `@BATCHES` loop
  for why a caller might pass its OWN instance instead), normalized the same way
  `NameVocabulary.correct_token` does: `1 - distance/max(length(a), length(b))`. Needs
  SimilaritySearch >= 1.3.4 for its `AbstractString`-accepting `evaluate` method (`a`/`b` passed
  straight through, no `Vector{Char}` conversion -- see that version's changelog). Removing the
  bare-initial shortcut here works exactly as it did for `:qgram`: a length-1 token compared against
  a longer one costs almost its own length in edits, so the normalized score comes out near `0.0`
  regardless -- no special-casing needed.
- `:qgram` -- `AC._qgram_jaccard(a, b)`, the ORIGINAL scoring for this module, kept only for
  side-by-side comparison while thresholds get retuned for `:damerau` (see
  `experiments/author_matching/tune_clustering_metric.jl`). `dl` is unused for this method.

A single-character token still can never score high here under EITHER method: a q-gram set for it
shares nothing with a multi-character word's padded q-grams (`:qgram`), and its Damerau-Levenshtein
distance to any longer word is at least `length(word) - 1` (`:damerau`) -- both collapse to a score
near `0.0`, which is what makes this stage full-words-only without an explicit initials guard.
"""
function _precision_token_score(a::AbstractString, b::AbstractString; method::Symbol=PRECISION_SCORE_METHOD, dl=_DAMERAU)
    a == b && return 1.0
    if method == :damerau
        d = SimilaritySearch.evaluate(dl, a, b)
        1.0 - d / max(length(a), length(b))
    elseif method == :qgram
        AC._qgram_jaccard(a, b)
    else
        error("unknown score method $method (expected :damerau or :qgram)")
    end
end

"""
    precision_match_score(corrected_a, corrected_b; method=PRECISION_SCORE_METHOD, dl=_DAMERAU) -> (; match, surname, pairs)

Precision-oriented analogue of `AC._name_match_score`, operating on pre-corrected `(given,
surname)` pairs (see [`correct_name`](@ref)): same surname logic (exact / compound-truncation-aware
/ typo-tolerant), same "align the shorter given-name list against the longer, mean score" shape as
`AC._align_given_tokens` -- but scored via [`_precision_token_score`](@ref), so an initials-only
given-name list can never contribute a confident match here (see that function's docstring).
`pairs` (the raw per-position `(token_a, token_b, score)` triples) is exposed for the SAME reason
`AC._name_match_score` exposes it: [`precision_contradiction`](@ref) needs it to catch a hard
per-token mismatch an aggregate score can launder away via a shared incidental token.

The surname-typo comparison only runs when `surname_exact` didn't already resolve `surname` to
`1.0` -- found live while investigating why this scales badly on large surname buckets: EVERY pair
sharing a bucket key ALSO shares the literal surname token in the overwhelmingly common case, so
computing a full string-similarity score there anyway (as an earlier version of this function did,
unconditionally) was pure wasted work in exactly the hot loop that matters most.
"""
function precision_match_score(corrected_a, corrected_b; method::Symbol=PRECISION_SCORE_METHOD, dl=_DAMERAU)
    surname_a, surname_b = corrected_a.surname, corrected_b.surname
    given_a, given_b = corrected_a.given, corrected_b.given
    valid_a = !isempty(surname_a) && length(surname_a[end]) >= 2
    valid_b = !isempty(surname_b) && length(surname_b[end]) >= 2
    surname_exact = (valid_a && valid_b && surname_a == surname_b) ? 1.0 : 0.0
    trunc = 0.0
    length(given_a) == 1 && length(surname_a) == 1 && length(given_b) >= 1 && valid_a &&
        surname_a[1] == given_b[end] && (trunc = 1.0)
    length(given_b) == 1 && length(surname_b) == 1 && length(given_a) >= 1 && valid_b &&
        surname_b[1] == given_a[end] && (trunc = 1.0)
    surname_typo = (surname_exact < 1.0 && valid_a && valid_b) ?
        _precision_token_score(join(surname_a, " "), join(surname_b, " "); method, dl) : 0.0
    surname = max(surname_exact, trunc, surname_typo)

    if isempty(given_a) && isempty(given_b)
        return (match=1.0, surname=surname, pairs=Tuple{String,String,Float64}[])
    elseif isempty(given_a) || isempty(given_b)
        return (match=0.0, surname=surname, pairs=Tuple{String,String,Float64}[])
    end

    shorter, longer = length(given_a) <= length(given_b) ? (given_a, given_b) : (given_b, given_a)
    used = falses(length(longer))
    pairs = Tuple{String,String,Float64}[]
    for st in shorter
        best_j, best_s = 0, -1.0
        for (j, lt) in enumerate(longer)
            used[j] && continue
            s = _precision_token_score(st, lt; method, dl)
            s > best_s && ((best_s, best_j) = (s, j))
        end
        if best_j > 0
            used[best_j] = true
            push!(pairs, (st, longer[best_j], best_s))
        else
            push!(pairs, (st, "", 0.0))
        end
    end
    scores = [p[3] for p in pairs]
    return (match=sum(scores) / length(scores), surname=surname, pairs=pairs)
end

"""
    precision_edge(corrected_a, corrected_b;
                   method=PRECISION_SCORE_METHOD, dl=_DAMERAU,
                   match_threshold=PRECISION_MATCH_THRESHOLD,
                   surname_threshold=PRECISION_SURNAME_THRESHOLD) -> Bool

Connect-or-not test for [`compute_precision_clusters`](@ref)'s union-find phase: both the given-name
alignment AND the surname score must clear their (high, precision-oriented) thresholds. On its own
this is NOT sufficient for correctness -- see [`precision_contradiction`](@ref)'s docstring for a
concrete false-positive this alone lets through regardless of how high the threshold is set.

`dl` lets a caller pass its OWN `DamerauLevenshtein` instance instead of the shared [`_DAMERAU`](@ref)
-- `compute_precision_clusters`'s `@BATCHES` loop does exactly this, minting one per batch (see
that function's docstring for why).
"""
function precision_edge(corrected_a, corrected_b;
                         method::Symbol=PRECISION_SCORE_METHOD, dl=_DAMERAU,
                         match_threshold::Float64=PRECISION_MATCH_THRESHOLD,
                         surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD)
    r = precision_match_score(corrected_a, corrected_b; method, dl)
    r.surname >= surname_threshold && r.match >= match_threshold
end

"""
    precision_contradiction(names, corrected; method=PRECISION_SCORE_METHOD,
                            surname_threshold=PRECISION_SURNAME_THRESHOLD,
                            contradiction_floor=PRECISION_CONTRADICTION_FLOOR)
        -> Union{Tuple{String,String}, Nothing}

Checks EVERY pair in a `precision_edge`-connected component for a hard contradiction: a low DIRECT
surname score between two members, or a per-position given-name mismatch
([`_precision_token_score`](@ref) below `contradiction_floor`) between two full-word tokens.
Mirrors `AC._name_cluster_contradiction` exactly, adapted to pre-corrected tokens.

**`contradiction_floor`'s right value is `method`-dependent, NOT a universal constant -- found live
while validating the `:damerau` switch against the real 10-repo corpus.** `:qgram`'s
`PRECISION_CONTRADICTION_FLOOR=0.2` default assumed two genuinely DIFFERENT same-length words
always score near `0.0` -- true often enough for q-gram Jaccard, but NOT for `:damerau`'s
`1 - distance/max(length)` formula: `"torres"`/`"morales"` (distance 4 of 7) scores `0.571`,
`"alejandra"`/`"alejandro"` (distance 1 of 9, a single letter that happens to flip grammatical
gender) scores `0.889` -- both comfortably above a `0.2` floor despite being unambiguously different
people, letting a transitively-bridged false pair slip through uncaught. See
`experiments/author_matching/tune_clustering_metric.jl` for the floor sweep this was tuned against.

**Not optional -- found live, validating this module against a real 10-repo corpus:** the
truncation rule in [`precision_match_score`](@ref) (a short single-given/single-surname name's
surname equalling a longer name's LAST given-name token) is exactly as valid at `surname=1.0`,
`match=1.0` for `"Carlos González"` <-> `"CARLOS RICARDO GONZALEZ RUIZ"` (an accidental collision --
"gonzalez" is that longer name's paternal-surname CANDIDATE sitting in `given` next to an unrelated
surname "ruiz", not a genuine truncation of it) as it is for the intended case,
`"Victor Torres"` <-> `"Victor Manuel Torres De La Cruz"`. No connect threshold can distinguish
these -- both score perfectly. Left unguarded, a 32-member blob of unrelated "Carlos"/"Ricardo
González ..." people formed via exactly this bridge, chained pairwise through the common surname
"gonzalez". This check is what catches it: `"Carlos González"` vs e.g. `"RICARDO GONZALEZ SANCHEZ"`
(both in that blob) scores a DIRECT surname of ~0 (gonzalez vs sanchez), flagging the whole
component for [`precision_split`](@ref) even though the two never directly connected in phase 1.
"""
function precision_contradiction(names::Vector{String}, corrected;
                                  method::Symbol=PRECISION_SCORE_METHOD,
                                  surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD,
                                  contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR)
    for i in 1:length(names), j in (i+1):length(names)
        r = precision_match_score(corrected[names[i]], corrected[names[j]]; method)
        r.surname >= surname_threshold || return (names[i], names[j])
        for (ta, tb, s) in r.pairs
            if length(ta) > 1 && length(tb) > 1 && s < contradiction_floor
                return (names[i], names[j])
            end
        end
    end
    return nothing
end

"""
    precision_strict_compatible(corrected_a, corrected_b;
                                 surname_threshold=PRECISION_STRICT_SURNAME_THRESHOLD,
                                 match_threshold=PRECISION_STRICT_MATCH_THRESHOLD,
                                 contradiction_floor=PRECISION_CONTRADICTION_FLOOR) -> Bool

Must-link test for [`precision_split`](@ref) -- same thresholds as
`AC._name_cluster_strict_compatible` (surname `>= 0.5`, match `>= 0.9`; validated there against a
mined ground truth, not re-derived here), PLUS the same per-position floor
[`precision_contradiction`](@ref) uses.

**The floor check here is not redundant with [`precision_contradiction`](@ref)'s -- found live
while validating the `:damerau` switch, a real gap, not a stylistic mirror.** `precision_contradiction`
only decides WHETHER to trigger [`precision_split`](@ref) at all; once triggered, the actual
re-partitioning used to rely SOLELY on the aggregate `match`/`surname` scores here, with no
per-position floor of its own -- so a pair like `"Alejandra ... González"`/`"Alejandro ...
González"` (surname exact, but the discriminating given-name pair scores only `0.889` under
`:damerau`, masked by a shared exact `"sanchez"` token pulling the AVERAGE to `0.944`) got correctly
FLAGGED by `precision_contradiction`, sent to `precision_split`, and then immediately RE-MERGED right
back together by this exact function, since its aggregate score alone still cleared `0.9` --
raising `contradiction_floor` alone (this function's caller) could never fix that pair no matter how
high, because this function never looked at per-position scores at all until now.
"""
function precision_strict_compatible(corrected_a, corrected_b;
                                      method::Symbol=PRECISION_SCORE_METHOD,
                                      surname_threshold::Float64=PRECISION_STRICT_SURNAME_THRESHOLD,
                                      match_threshold::Float64=PRECISION_STRICT_MATCH_THRESHOLD,
                                      contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR)
    r = precision_match_score(corrected_a, corrected_b; method)
    r.surname >= surname_threshold || return false
    r.match >= match_threshold || return false
    for (ta, tb, s) in r.pairs
        length(ta) > 1 && length(tb) > 1 && s < contradiction_floor && return false
    end
    return true
end

"""
    precision_split(names, corrected) -> Vector{Vector{String}}

Greedy re-partition of a contradiction-flagged component, mirroring `AC._name_cluster_split`
exactly (same greedy, order-dependent must-link-to-every-existing-member behavior, same known
limitation -- see that function's docstring).
"""
function precision_split(names::Vector{String}, corrected; method::Symbol=PRECISION_SCORE_METHOD,
                          contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR)
    clusters = Vector{Vector{String}}()
    for nm in sort(names)
        placed = false
        for c in clusters
            if all(m -> precision_strict_compatible(corrected[nm], corrected[m]; method, contradiction_floor), c)
                push!(c, nm)
                placed = true
                break
            end
        end
        placed || push!(clusters, [nm])
    end
    return clusters
end

"""
    compute_precision_clusters(raw_names, vocab; correct_method=:damerau, method=PRECISION_SCORE_METHOD,
                               match_threshold=PRECISION_MATCH_THRESHOLD,
                               surname_threshold=PRECISION_SURNAME_THRESHOLD,
                               contradiction_floor=PRECISION_CONTRADICTION_FLOOR) -> Vector{Vector{String}}

Precision-first replacement for `AC.compute_name_clusters`: corrects every name once (see
[`correct_name`](@ref), controlled by `correct_method` -- the VOCABULARY correction method, kept
independent from `method` below), buckets by corrected surname ([`precision_cluster_keys`](@ref)),
connects pairs within a bucket via union-find using [`precision_edge`](@ref) (high thresholds, no
bare-initial shortcut, string-similarity scored by `method` -- see [`_precision_token_score`](@ref)),
THEN checks every resulting component for a [`precision_contradiction`](@ref) and
[`precision_split`](@ref)s it if found -- this last step is required for correctness, not an extra
safety margin (see [`precision_contradiction`](@ref)'s docstring for the concrete false-positive it
catches that no connect threshold alone can). A name whose given-name list is entirely bare initials
never connects to anything here regardless of how well its surname matches -- it stays a singleton
group, to be picked up by a later, separately-designed imputation stage (not part of this module).

`correct_method` and `method` are deliberately two separate knobs: the first controls whether/how a
TYPO gets fixed against the vocabulary before anything else happens (gated on the token's own
popularity, see `NameVocabulary.correct_token`); the second controls how two ALREADY-corrected
strings that still differ get scored against each other during clustering itself (no popularity
gate -- every established spelling variant correction deliberately leaves untouched still needs
SOME tolerance here, or it would never connect to anything).

Garbage names (`AC._is_garbage_name`) are never bucketed -- they fall through to singleton groups
via the union-find default, same guard as `AC.compute_name_clusters`.

**The within-bucket connect phase runs in parallel via `SimilaritySearch.@BATCHES`** (this
project's parallelization idiom, since it already depends on that package for it -- see
`@BATCHES`'s own docstring for the full mechanics). Each batch mints its OWN
`Dist.Seqs.DamerauLevenshtein()` instance in `@BEGINBATCH` (rather than sharing [`_DAMERAU`](@ref)
across threads) and appends `(idx_a, idx_b)` pairs to a `@batchid()`-indexed edge list -- `@batchid()`
rather than `Threads.threadid()` specifically because it is stable and disjoint under EVERY
scheduler (`Threads.threadid()` can alias/migrate under the non-`:static` ones). The union-find
itself stays sequential, applied AFTER all batches join: `parent` is plain, unsynchronized mutable
state, so mutating it from multiple concurrent batches would race -- collecting edges in parallel
and unioning them in one single-threaded pass afterward sidesteps that entirely, at the cost of a
small (empirically ~19s -> ~7s, 16 threads, real 10-repo corpus) but real win over doing the O(bucket²)
comparisons themselves sequentially. `precision_contradiction`/`precision_split` afterward stay
sequential -- they are not the bottleneck this addressed.
"""
function compute_precision_clusters(raw_names::Vector{String}, vocab::Vocabulary;
                                     correct_method::Symbol=:damerau,
                                     method::Symbol=PRECISION_SCORE_METHOD,
                                     match_threshold::Float64=PRECISION_MATCH_THRESHOLD,
                                     surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD,
                                     contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR)
    n = length(raw_names)
    n == 0 && return Vector{Vector{String}}()
    idx = Dict(nm => i for (i, nm) in enumerate(raw_names))
    corrected = Dict(nm => correct_name(vocab, nm; method=correct_method) for nm in raw_names if !AC._is_garbage_name(nm))

    candidate_buckets = Dict{String,Vector{String}}()
    for nm in raw_names
        haskey(corrected, nm) || continue
        for k in precision_cluster_keys(corrected[nm])
            push!(get!(candidate_buckets, k, String[]), nm)
        end
    end
    buckets = collect(values(candidate_buckets))

    minbatch = getminbatch(length(buckets))
    per_batch_edges = Vector{Vector{Tuple{Int,Int}}}()
    @BATCHES minbatch begin
        @BEGIN
            per_batch_edges = [Tuple{Int,Int}[] for _ in 1:@nbatches()]
        @BEGINBATCH
            dl = Dist.Seqs.DamerauLevenshtein()
            edges = per_batch_edges[@batchid()]
        @LOOP for bi in eachindex(buckets)
            bucket = unique(buckets[bi])
            length(bucket) < 2 && continue
            for i in 1:length(bucket), j in (i+1):length(bucket)
                a, b = bucket[i], bucket[j]
                precision_edge(corrected[a], corrected[b]; method, dl, match_threshold, surname_threshold) &&
                    push!(edges, (idx[a], idx[b]))
            end
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
    for edges in per_batch_edges, (a, b) in edges
        uf_union!(a, b)
    end

    by_root = Dict{Int,Vector{String}}()
    for nm in raw_names
        push!(get!(by_root, uf_find(idx[nm]), String[]), nm)
    end

    groups = Vector{Vector{String}}()
    for (_, comp) in by_root
        if length(comp) == 1
            push!(groups, comp)
            continue
        end
        cx = precision_contradiction(comp, corrected; method, surname_threshold, contradiction_floor)
        if cx === nothing
            push!(groups, comp)
        else
            append!(groups, precision_split(comp, corrected; method, contradiction_floor))
        end
    end
    return groups
end

end # module
