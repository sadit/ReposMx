module PrecisionClustering

using ..AuthorConsolidation: AuthorConsolidation
using ..NameVocabulary: NameVocabulary, Vocabulary, correct_token
const AC = AuthorConsolidation

export correct_name, precision_cluster_keys, precision_match_score, precision_edge,
       precision_contradiction, precision_strict_compatible, precision_split,
       compute_precision_clusters

const PRECISION_MATCH_THRESHOLD = 0.9
const PRECISION_SURNAME_THRESHOLD = 0.9
const PRECISION_STRICT_SURNAME_THRESHOLD = 0.5   # matches AC._name_cluster_strict_compatible
const PRECISION_STRICT_MATCH_THRESHOLD = 0.9     # matches AC._name_cluster_strict_compatible
const PRECISION_CONTRADICTION_FLOOR = 0.2        # matches AC._NAME_CLUSTER_CONTRADICTION_FLOOR

"""
    correct_name(vocab, raw; method=:qgram) -> (; given::Vector{String}, surname::Vector{String})

Splits `raw` into given/surname tokens using the same `AC._surname_span` logic as production
clustering, then corrects each token against `vocab` (see `NameVocabulary.correct_token`) --
EXCEPT surname particles (`AC._SURNAME_PARTICLES`, e.g. "de"/"la"), which pass through unchanged
(they were never in the vocabulary to begin with, see `NameVocabulary.build_name_vocabulary`).
Bare initials also pass through unchanged (`correct_token` is a no-op on them by construction) --
this stage never fabricates a full word out of an initial, it only fixes typos in words that are
ALREADY full words.
"""
function correct_name(vocab::Vocabulary, raw::AbstractString; method::Symbol=:qgram)
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
    _precision_token_score(a, b) -> Float64

Given-name token compatibility for THIS stage: exact match, or [`AC._qgram_jaccard`](@ref) --
deliberately WITHOUT `AC._token_alignment_score`'s bare-initial shortcut (a length-1 token matching
ANY word sharing its first letter). Removing that shortcut is what makes this stage full-words-only:
a q-gram set for a single-character token can never share a 4-gram with a multi-character word's
padded q-grams, so any initial-vs-full-word comparison scores `0.0` here -- the same effect as
explicitly excluding initials, achieved by just not special-casing them.
"""
_precision_token_score(a::AbstractString, b::AbstractString) = a == b ? 1.0 : AC._qgram_jaccard(a, b)

"""
    precision_match_score(corrected_a, corrected_b) -> (; match, surname, pairs)

Precision-oriented analogue of `AC._name_match_score`, operating on pre-corrected `(given,
surname)` pairs (see [`correct_name`](@ref)): same surname logic (exact / compound-truncation-aware
/ q-gram typo-tolerant), same "align the shorter given-name list against the longer, mean score"
shape as `AC._align_given_tokens` -- but scored via [`_precision_token_score`](@ref), so an
initials-only given-name list can never contribute a confident match here (see that function's
docstring). `pairs` (the raw per-position `(token_a, token_b, score)` triples) is exposed for the
SAME reason `AC._name_match_score` exposes it: [`precision_contradiction`](@ref) needs it to catch
a hard per-token mismatch an aggregate score can launder away via a shared incidental token.
"""
function precision_match_score(corrected_a, corrected_b)
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
    surname_typo = (valid_a && valid_b) ? AC._qgram_jaccard(join(surname_a, " "), join(surname_b, " ")) : 0.0
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
            s = _precision_token_score(st, lt)
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
                   match_threshold=PRECISION_MATCH_THRESHOLD,
                   surname_threshold=PRECISION_SURNAME_THRESHOLD) -> Bool

Connect-or-not test for [`compute_precision_clusters`](@ref)'s union-find phase: both the given-name
alignment AND the surname score must clear their (high, precision-oriented) thresholds. On its own
this is NOT sufficient for correctness -- see [`precision_contradiction`](@ref)'s docstring for a
concrete false-positive this alone lets through regardless of how high the threshold is set.
"""
function precision_edge(corrected_a, corrected_b;
                         match_threshold::Float64=PRECISION_MATCH_THRESHOLD,
                         surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD)
    r = precision_match_score(corrected_a, corrected_b)
    r.surname >= surname_threshold && r.match >= match_threshold
end

"""
    precision_contradiction(names, corrected; surname_threshold=PRECISION_SURNAME_THRESHOLD)
        -> Union{Tuple{String,String}, Nothing}

Checks EVERY pair in a `precision_edge`-connected component for a hard contradiction: a low DIRECT
surname score between two members, or a per-position given-name mismatch (`AC._name_qgrams`-based
score below [`PRECISION_CONTRADICTION_FLOOR`](@ref)) between two full-word tokens. Mirrors
`AC._name_cluster_contradiction` exactly, adapted to pre-corrected tokens.

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
                                  surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD)
    for i in 1:length(names), j in (i+1):length(names)
        r = precision_match_score(corrected[names[i]], corrected[names[j]])
        r.surname >= surname_threshold || return (names[i], names[j])
        for (ta, tb, s) in r.pairs
            if length(ta) > 1 && length(tb) > 1 && s < PRECISION_CONTRADICTION_FLOOR
                return (names[i], names[j])
            end
        end
    end
    return nothing
end

"""
    precision_strict_compatible(corrected_a, corrected_b;
                                 surname_threshold=PRECISION_STRICT_SURNAME_THRESHOLD,
                                 match_threshold=PRECISION_STRICT_MATCH_THRESHOLD) -> Bool

Must-link test for [`precision_split`](@ref) -- same thresholds as
`AC._name_cluster_strict_compatible` (surname `>= 0.5`, match `>= 0.9`; validated there against a
mined ground truth, not re-derived here).
"""
function precision_strict_compatible(corrected_a, corrected_b;
                                      surname_threshold::Float64=PRECISION_STRICT_SURNAME_THRESHOLD,
                                      match_threshold::Float64=PRECISION_STRICT_MATCH_THRESHOLD)
    r = precision_match_score(corrected_a, corrected_b)
    r.surname >= surname_threshold && r.match >= match_threshold
end

"""
    precision_split(names, corrected) -> Vector{Vector{String}}

Greedy re-partition of a contradiction-flagged component, mirroring `AC._name_cluster_split`
exactly (same greedy, order-dependent must-link-to-every-existing-member behavior, same known
limitation -- see that function's docstring).
"""
function precision_split(names::Vector{String}, corrected)
    clusters = Vector{Vector{String}}()
    for nm in sort(names)
        placed = false
        for c in clusters
            if all(m -> precision_strict_compatible(corrected[nm], corrected[m]), c)
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
    compute_precision_clusters(raw_names, vocab; method=:qgram,
                               match_threshold=PRECISION_MATCH_THRESHOLD,
                               surname_threshold=PRECISION_SURNAME_THRESHOLD) -> Vector{Vector{String}}

Precision-first replacement for `AC.compute_name_clusters`: corrects every name once (see
[`correct_name`](@ref)), buckets by corrected surname ([`precision_cluster_keys`](@ref)), connects
pairs within a bucket via union-find using [`precision_edge`](@ref) (high thresholds, no bare-initial
shortcut), THEN checks every resulting component for a [`precision_contradiction`](@ref) and
[`precision_split`](@ref)s it if found -- this last step is required for correctness, not an extra
safety margin (see [`precision_contradiction`](@ref)'s docstring for the concrete false-positive it
catches that no connect threshold alone can). A name whose given-name list is entirely bare initials
never connects to anything here regardless of how well its surname matches -- it stays a singleton
group, to be picked up by a later, separately-designed imputation stage (not part of this module).

Garbage names (`AC._is_garbage_name`) are never bucketed -- they fall through to singleton groups
via the union-find default, same guard as `AC.compute_name_clusters`.
"""
function compute_precision_clusters(raw_names::Vector{String}, vocab::Vocabulary; method::Symbol=:qgram,
                                     match_threshold::Float64=PRECISION_MATCH_THRESHOLD,
                                     surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD)
    n = length(raw_names)
    n == 0 && return Vector{Vector{String}}()
    idx = Dict(nm => i for (i, nm) in enumerate(raw_names))
    corrected = Dict(nm => correct_name(vocab, nm; method) for nm in raw_names if !AC._is_garbage_name(nm))

    candidate_buckets = Dict{String,Vector{String}}()
    for nm in raw_names
        haskey(corrected, nm) || continue
        for k in precision_cluster_keys(corrected[nm])
            push!(get!(candidate_buckets, k, String[]), nm)
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
        for i in 1:length(bucket), j in (i+1):length(bucket)
            a, b = bucket[i], bucket[j]
            precision_edge(corrected[a], corrected[b]; match_threshold, surname_threshold) &&
                uf_union!(idx[a], idx[b])
        end
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
        cx = precision_contradiction(comp, corrected; surname_threshold)
        if cx === nothing
            push!(groups, comp)
        else
            append!(groups, precision_split(comp, corrected))
        end
    end
    return groups
end

end # module
