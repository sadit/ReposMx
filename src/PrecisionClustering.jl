module PrecisionClustering

using ..AuthorConsolidation: AuthorConsolidation
using ..NameVocabulary: Vocabulary, correct_token, _DAMERAU
using SimilaritySearch: SimilaritySearch, @BATCHES, @BEGIN, @BEGINBATCH, @LOOP, @nbatches, @batchid, getminbatch
const AC = AuthorConsolidation
const Dist = SimilaritySearch.Dist

export correct_name, precision_cluster_keys, precision_match_score, precision_edge,
       precision_contradiction, precision_strict_compatible, precision_split,
       compute_precision_clusters

const PRECISION_MATCH_THRESHOLD = 0.9
const PRECISION_SURNAME_THRESHOLD = 0.9
# Deliberately EQUAL to PRECISION_SURNAME_THRESHOLD/PRECISION_MATCH_THRESHOLD above, not borrowed
# from AC._name_cluster_strict_compatible's separately-validated 0.5/0.9 (a q-gram-scored pair,
# validated for PRODUCTION's recall-then-oracle design, where the oracle is deliberately more
# permissive than phase-1). Found live: a 0.5 surname bar here let precision_split RE-MERGE a pair
# precision_contradiction had just flagged (surname=0.625 under :damerau -- below the 0.9 connect
# bar that triggered the flag, but above a 0.5 re-merge bar) -- the exact same
# flag-then-silently-undo bug already fixed once for the per-position floor (see
# precision_strict_compatible's docstring), recurring here via a second, independent threshold gap.
# This module's whole design is precision-first; there is no reason its OWN reconnection test
# should be looser than its OWN connect test.
const PRECISION_STRICT_SURNAME_THRESHOLD = PRECISION_SURNAME_THRESHOLD
const PRECISION_STRICT_MATCH_THRESHOLD = PRECISION_MATCH_THRESHOLD
const PRECISION_CONTRADICTION_FLOOR = 0.2        # matches AC._NAME_CLUSTER_CONTRADICTION_FLOOR

"""
    correct_name(vocab, raw) -> (; given::Vector{String}, surname::Vector{String}, content::Vector{String})

Splits `raw` into given/surname tokens using the same `AC._split_given_surname` logic as production
clustering, then corrects each REAL content word against `vocab` (see `NameVocabulary.correct_token`).
`surname` keeps `AC._split_given_surname`'s CANONICAL form -- a traditionally-atomic compound
(particle-led like `"de-la-cruz"`, or `"y"`-joined like `"milian-y-avila"`) stays ONE hyphenated
element, with each of its REAL words corrected individually and the connectors (`AC._SURNAME_PARTICLES`,
`"y"`) passed through unchanged (they were never in the vocabulary to begin with, see
`NameVocabulary.build_name_vocabulary`), then rejoined with the same hyphens. Bare initials also
pass through unchanged (`correct_token` is a no-op on them by construction) -- this stage never
fabricates a full word out of an initial, it only fixes typos in words that are ALREADY full words.

`content` (2026-09-08) is `AC._surname_content(surname)` (the flattened, connector-free words),
computed ONCE here rather than by every caller that needs it. Found live via Julia's sampling
profiler on a real 50-repo corpus: [`precision_match_score`](@ref) was recomputing this from scratch
on EVERY pairwise comparison (not once per name), a real, significant chunk of a
`compute_precision_clusters` run that took ~74 minutes there -- `corrected` is already a per-name
cache (built once per name in [`compute_precision_clusters`](@ref)), so `content` belongs in it too.
"""
function correct_name(vocab::Vocabulary, raw::AbstractString)
    toks = AC._qgram_name_tokens(raw)
    isempty(toks) && return (given=String[], surname=String[], content=String[])
    gs = AC._split_given_surname(toks)
    given_toks, surname_toks = gs.given, gs.surname
    given = [first(correct_token(vocab, t, :given)) for t in given_toks]
    _correct_word(w) = (w in AC._SURNAME_PARTICLES || w == "y") ? w : first(correct_token(vocab, w, :surname))
    surname = [occursin('-', s) ? join(_correct_word.(split(s, "-")), "-") : _correct_word(s)
               for s in surname_toks]
    return (given=given, surname=surname, content=AC._surname_content(surname))
end

"""
    precision_cluster_keys(corrected) -> Vector{String}

Candidate-bucket keys for [`compute_precision_clusters`](@ref), mirroring `AC._name_cluster_keys`'s
two-key scheme (last content word + first content word, for compound-surname truncation -- see that
function's docstring for why FLATTENED content, not the canonical hyphenated form, is used here)
but sourced from an ALREADY-CORRECTED, ALREADY-FLATTENED `corrected.content` (see
[`correct_name`](@ref)) instead of re-tokenizing OR re-flattening.
"""
function precision_cluster_keys(corrected)
    content = corrected.content
    isempty(content) && return String[]
    keys = [content[end]]
    length(content) >= 2 && push!(keys, content[1])
    return unique(keys)
end

"""
    _precision_token_score(a, b; dl=_DAMERAU, cache=nothing) -> Float64

String-similarity for THIS stage -- used both for a single given-name token pair AND (via
[`precision_match_score`](@ref)) for a whole joined surname phrase.

Restricted Damerau-Levenshtein (`dl`, defaulting to [`_DAMERAU`](@ref) imported from
`NameVocabulary` -- but see [`compute_precision_clusters`](@ref)'s `@BATCHES` loop for why a caller
might pass its OWN instance instead), normalized the same way `NameVocabulary.correct_token` does:
`1 - distance/max(length(a), length(b))`. Needs SimilaritySearch >= 1.3.4 for its
`AbstractString`-accepting `evaluate` method (`a`/`b` passed straight through, no `Vector{Char}`
conversion -- see that version's changelog). This module originally scored by q-gram Jaccard
(`AC._qgram_jaccard`); it was dropped after the retuning documented in
`NameVocabulary.correct_token` -- edit distance won on recall at equal precision, and the two
scores are NOT on a comparable scale, so every threshold here is tuned for THIS one.

**Bare-initial shortcut (2026-09-08): a CLOSED FORM, not an approximation.** A length-1 token `a`
against a longer `b` has a PROVABLY EXACT Damerau-Levenshtein distance of `length(b) - 1` when their
first letters agree (insert `b`'s remaining suffix -- no cheaper edit sequence exists), giving
`score = 1 - (length(b)-1)/length(b) = 1/length(b)` -- computed directly, no `evaluate` call needed.
When the first letters disagree, the true distance is even larger (never a better score), so this
returns `0.0` -- a safe underestimate, never an overestimate, and never on a path a downstream
threshold check is sensitive to (both `>= 0.9` connect and `< 0.2` contradiction land on the same
side of `0.0` as they would of the true, still-low value). **Deliberately still NOT a "1.0 = full
match" shortcut** (unlike `AC._token_alignment_score`'s production version): [`compute_precision_clusters`](@ref)'s
whole design depends on an initial-only given-name list never reaching its `match >= 0.9` connect
bar -- that stays true here (`1/length(b) < 0.9` for any realistic name length), this is purely a
cheap way to skip an `evaluate` call for a case whose answer was always going to be low.

**`cache` (2026-09-08): memoizes by DISTINCT WORD PAIR, not by name pair.** A real corpus bucket
(thousands of raw names sharing a surname) draws its given-name/surname tokens from a MUCH smaller
distinct vocabulary (a few hundred spellings at most) -- recomputing `evaluate(dl, a, b)` freshly
for every name-PAIR that happens to share the same two words is exactly the repeated work found
live to dominate a real 93-repo run (compute_precision_clusters took ~7.7 hours there). When `cache`
is provided (see [`compute_precision_clusters`](@ref)'s `@BATCHES` loop, one fresh `Dict` per batch,
same reasoning as its own per-batch `dl`), the FIRST time a specific unordered pair of words is
scored, the result is computed and stored; every later request for that SAME pair (from a different
name-pair entirely) is a dictionary lookup, not a fresh edit-distance computation. This is an EXACT
cache (the stored value is the same `evaluate` result, just computed once), not an approximation --
unlike a BK-tree-radius neighbor lookup (considered and rejected here 2026-09-08: a pair just
outside a small search radius is not safely "far" for the LOW `contradiction_floor=0.2` check, only
for the high `0.9` connect bar, so an approximate "not found = far" answer would risk manufacturing
contradictions that don't exist).
"""
function _precision_token_score(a::AbstractString, b::AbstractString;
                                 dl=_DAMERAU, cache::Union{Nothing,AbstractDict}=nothing)
    a == b && return 1.0
    la, lb = length(a), length(b)
    if la == 1 || lb == 1
        shorter, longer = la <= lb ? (a, b) : (b, a)
        return (!isempty(longer) && shorter[1] == first(longer)) ? 1.0 / length(longer) : 0.0
    end
    cache === nothing && return 1.0 - SimilaritySearch.evaluate(dl, a, b) / max(la, lb)
    key = a < b ? (a, b) : (b, a)
    return get!(cache, key) do
        1.0 - SimilaritySearch.evaluate(dl, a, b) / max(la, lb)
    end
end

"""
    _surname_typo_score(content_a, content_b; dl=_DAMERAU) -> Float64

Mirrors `AC._surname_typo_score` exactly (see that function's docstring for the full rationale,
the concrete "MIGUEL ANGEL RODRIGUEZ RODRIGUEZ"/"MIGUEL ANGEL SANCHEZ RODRIGUEZ" false-positive it
fixes, and why it takes FLATTENED content -- `AC._surname_content` -- rather than the canonical,
possibly-hyphenated form [`correct_name`](@ref) returns): scores the PATERNAL word and the MATERNAL
remainder SEPARATELY via [`_precision_token_score`](@ref), then takes their MINIMUM, instead of one
score over the whole surname joined into a single phrase -- a long shared word (typically the
maternal one) must never mask a real difference in the other.

**Never `join`s a single-element maternal remainder (2026-09-08).** Found live via Julia's sampling
profiler on a real 50-repo corpus: `join(::Vector, " ")` on a ONE-element vector allocates a fresh
`IOBuffer`/`sprint` call for zero benefit (the joined string is just that one element) -- and a
single-word maternal remainder (the ordinary "Nombre ApellidoPaterno ApellidoMaterno" case) is the
overwhelmingly common shape, so this was a real, significant cost in exactly the hot loop that
matters most. `join` is now only ever called when there are genuinely 2+ words on EITHER side.
"""
function _surname_typo_score(content_a::Vector{String}, content_b::Vector{String};
                              dl=_DAMERAU,
                              cache::Union{Nothing,AbstractDict}=nothing)
    paternal_score = _precision_token_score(content_a[1], content_b[1]; dl, cache)
    maternal_a, maternal_b = @view(content_a[2:end]), @view(content_b[2:end])
    maternal_score = if isempty(maternal_a) && isempty(maternal_b)
        1.0
    elseif isempty(maternal_a) || isempty(maternal_b)
        0.0
    elseif length(maternal_a) == 1 && length(maternal_b) == 1
        _precision_token_score(maternal_a[1], maternal_b[1]; dl, cache)
    else
        _precision_token_score(join(maternal_a, " "), join(maternal_b, " "); dl, cache)
    end
    return min(paternal_score, maternal_score)
end

"""
    precision_match_score(corrected_a, corrected_b; dl=_DAMERAU,
                          cache=nothing, surname_shortcut=nothing) -> (; match, surname, pairs)

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

**`surname_shortcut` (2026-09-08): skip the given-name alignment entirely once surname has already
failed.** Every caller in this module (`precision_edge`, `precision_contradiction`,
`precision_strict_compatible`) checks `surname >= surname_threshold` FIRST and never looks at
`match`/`pairs` at all when that fails -- so computing the given-name bipartite alignment in that
case was, like the surname-typo skip above, pure wasted work. `nothing` (the default) always
computes it, preserving old behavior for any caller that genuinely needs `pairs` unconditionally;
each real caller passes its OWN threshold.

`cache` is forwarded to every [`_precision_token_score`](@ref) call (surname AND given-name) -- see
that function's docstring for what it memoizes and why.
"""
function precision_match_score(corrected_a, corrected_b; dl=_DAMERAU,
                                cache::Union{Nothing,AbstractDict}=nothing,
                                surname_shortcut::Union{Nothing,Float64}=nothing)
    given_a, given_b = corrected_a.given, corrected_b.given
    content_a, content_b = corrected_a.content, corrected_b.content
    valid_a = !isempty(content_a) && length(content_a[end]) >= 2
    valid_b = !isempty(content_b) && length(content_b[end]) >= 2
    surname_exact = (valid_a && valid_b && content_a == content_b) ? 1.0 : 0.0
    # a SHORT surname (length 1) is a truncation of a longer one iff its word matches EITHER end
    # of the longer side's compound content -- mirrors AC._name_match_score exactly, see that
    # function's docstring for why both ends matter, not just the paternal position.
    trunc = (valid_a && valid_b && (length(content_a) == 1 || length(content_b) == 1) &&
             (content_a[1] == content_b[1] || content_a[end] == content_b[end])) ? 1.0 : 0.0
    surname_typo = (surname_exact < 1.0 && valid_a && valid_b) ?
        _surname_typo_score(content_a, content_b; dl, cache) : 0.0
    surname = max(surname_exact, trunc, surname_typo)

    if surname_shortcut !== nothing && surname < surname_shortcut
        return (match=0.0, surname=surname, pairs=Tuple{String,String,Float64}[])
    end

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
            s = _precision_token_score(st, lt; dl, cache)
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
                   dl=_DAMERAU,
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
                         dl=_DAMERAU,
                         cache::Union{Nothing,AbstractDict}=nothing,
                         match_threshold::Float64=PRECISION_MATCH_THRESHOLD,
                         surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD)
    r = precision_match_score(corrected_a, corrected_b; dl, cache, surname_shortcut=surname_threshold)
    r.surname >= surname_threshold && r.match >= match_threshold
end

"""
    precision_contradiction(names, corrected;
                            surname_threshold=PRECISION_SURNAME_THRESHOLD,
                            contradiction_floor=PRECISION_CONTRADICTION_FLOOR)
        -> Union{Tuple{String,String}, Nothing}

Checks EVERY pair in a `precision_edge`-connected component for a hard contradiction: a low DIRECT
surname score between two members, or a per-position given-name mismatch
([`_precision_token_score`](@ref) below `contradiction_floor`) between two full-word tokens.
Mirrors `AC._name_cluster_contradiction` exactly, adapted to pre-corrected tokens.

**`contradiction_floor`'s right value depends on the SCORING FUNCTION, not on some universal
notion of "different" -- found live while switching this module from q-gram Jaccard to edit
distance, against the real 10-repo corpus.** The original
`PRECISION_CONTRADICTION_FLOOR=0.2` assumed two genuinely DIFFERENT same-length words always score
near `0.0` -- true often enough for q-gram Jaccard, but NOT for
[`_precision_token_score`](@ref)'s `1 - distance/max(length)` formula: `"torres"`/`"morales"` (distance 4 of 7) scores `0.571`,
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
                                  dl=_DAMERAU,
                                  cache::Union{Nothing,AbstractDict}=nothing,
                                  surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD,
                                  contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR)
    for i in 1:length(names), j in (i+1):length(names)
        r = precision_match_score(corrected[names[i]], corrected[names[j]]; dl, cache,
                                   surname_shortcut=surname_threshold)
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
                                      dl=_DAMERAU,
                                      cache::Union{Nothing,AbstractDict}=nothing,
                                      surname_threshold::Float64=PRECISION_STRICT_SURNAME_THRESHOLD,
                                      match_threshold::Float64=PRECISION_STRICT_MATCH_THRESHOLD,
                                      contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR)
    r = precision_match_score(corrected_a, corrected_b; dl, cache, surname_shortcut=surname_threshold)
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
function precision_split(names::Vector{String}, corrected;
                          contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR)
    clusters = Vector{Vector{String}}()
    for nm in sort(names)
        placed = false
        for c in clusters
            if all(m -> precision_strict_compatible(corrected[nm], corrected[m]; contradiction_floor), c)
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
    _bucket_signature_groups(bucket, corrected, idx) -> (free_edges, comparable_reps)

Splits a candidate bucket into what can be resolved FOR FREE and what actually needs a comparison
(the "clustering más fino" step, 2026-09-08). Members of `bucket` sharing the EXACT same corrected
`(given, surname)` signature are, by construction, already a perfect match under
[`precision_edge`](@ref) (`a == b` scores `1.0`) -- grouping by signature and
star-connecting each group (first member to every other) gets those edges for free, no
[`precision_edge`](@ref) call at all, instead of every such pair being independently rediscovered by
an O(bucket²) scan. `comparable_reps` returns ONE representative name per DISTINCT signature that
is still worth comparing against other signatures -- excluding a signature only when its ENTIRE
given-name list is bare initials ("solo siglas"), since [`_precision_token_score`](@ref)'s closed
form proves THAT case can never reach this module's `0.9` connect bar regardless of what it's
compared against (see that function's docstring) -- comparing it against anything here is pure
wasted work; recovering it is entirely [`Imputation.impute_candidates`](@ref)'s job instead. A MIX
of a full word plus an initial (e.g. `"Daniel M. Garcia Lopez"`) is NOT excluded -- the full word
can still carry a genuine match even though the initial alone never could (found live 2026-09-08:
excluding on `any` bare initial instead of `all` wrongly dropped mined hard_good recall from
126/133 to 121/133 -- fixed before this shipped).

Measured on the real 93-repo corpus (2026-09-08): large surname buckets are only ~55-59% distinct
signatures (most same-surname people genuinely have different given names, not duplicate captures
of the same person) -- so this alone is a modest, real constant-factor win (~3x fewer comparisons),
not a complexity-class change; combined with also excluding solo-siglas signatures from the
comparison entirely, the SET actually compared shrinks further still.

**Not a new precision risk**: two genuinely DIFFERENT real people who happen to share the exact same
corrected full name were ALREADY silently merged by the unoptimized O(bucket²) loop too (`a == b`
already scored `1.0` there) -- this changes how that same outcome is COMPUTED (a dict grouping
instead of rediscovering it via `n` separate calls to `precision_edge`), not what it decides.
"""
function _bucket_signature_groups(bucket::Vector{String}, corrected, idx::AbstractDict)
    groups = Dict{Tuple{Vector{String},Vector{String}},Vector{String}}()
    for nm in bucket
        c = corrected[nm]
        push!(get!(groups, (c.given, c.surname), String[]), nm)
    end
    free_edges = Tuple{Int,Int}[]
    reps = String[]
    for (sig, members) in groups
        leader = members[1]
        for m in @view members[2:end]
            push!(free_edges, (idx[leader], idx[m]))
        end
        # excluded from comparison only when EVERY given-name token is a bare initial ("solo
        # siglas") -- a MIX of a full word plus an initial (e.g. "Daniel M. Garcia Lopez") still
        # needs comparing: the full word can carry a genuine match even though the initial alone
        # never could. Found live 2026-09-08: using `any` here instead of `all` wrongly excluded
        # exactly that mixed case, dropping mined hard_good recall from 126/133 to 121/133.
        (!isempty(sig[1]) && all(t -> length(t) == 1, sig[1])) || push!(reps, leader)
    end
    return free_edges, reps
end

"""
    compute_precision_clusters(raw_names, vocab;
                               match_threshold=PRECISION_MATCH_THRESHOLD,
                               surname_threshold=PRECISION_SURNAME_THRESHOLD,
                               contradiction_floor=PRECISION_CONTRADICTION_FLOOR) -> Vector{Vector{String}}

Precision-first replacement for `AC.compute_name_clusters`: corrects every name once
([`correct_name`](@ref)), buckets by corrected surname ([`precision_cluster_keys`](@ref)),
connects pairs within a bucket via union-find using [`precision_edge`](@ref) (high thresholds, no
bare-initial shortcut -- see [`_precision_token_score`](@ref)),
THEN checks every resulting component for a [`precision_contradiction`](@ref) and
[`precision_split`](@ref)s it if found -- this last step is required for correctness, not an extra
safety margin (see [`precision_contradiction`](@ref)'s docstring for the concrete false-positive it
catches that no connect threshold alone can). A name whose given-name list is entirely bare initials
never connects to anything here regardless of how well its surname matches -- it stays a singleton
group, to be picked up by a later, separately-designed imputation stage (not part of this module).

Correction and clustering are two deliberately separate stages: the first fixes a TYPO against the
vocabulary before anything else happens (gated on the token's own popularity, see
`NameVocabulary.correct_token`); the second scores two ALREADY-corrected strings that still differ
(no popularity gate -- every established spelling variant correction deliberately leaves untouched
still needs SOME tolerance here, or it would never connect to anything).

Garbage names (`AC._is_garbage_name`) are never bucketed -- they fall through to singleton groups
via the union-find default, same guard as `AC.compute_name_clusters`.

**The within-bucket connect phase runs in parallel via `SimilaritySearch.@BATCHES`, with a HYBRID
strategy by bucket size** (this project's parallelization idiom, since it already depends on that
package for it -- see `@BATCHES`'s own docstring for the full mechanics). Real corpora have a
Pareto-skewed bucket-size distribution (a handful of common-surname buckets in the thousands,
everything else small) -- lumping a giant bucket into the same `@LOOP` as thousands of tiny ones
would let it dominate whichever single batch happens to draw it, since `@BATCHES` only parallelizes
ACROSS loop iterations, never within one iteration's own body. So buckets below
`large_bucket_threshold` and buckets at or above it are handled by two DIFFERENT `@BATCHES` calls:

- **Small buckets**: one `@LOOP` over ALL of them, batched and run concurrently exactly as
  before -- many independent, individually-cheap units, each bucket's own O(size²) comparisons
  done by a plain sequential nested loop inside its batch (no further parallelism needed per unit).
- **Large buckets**: processed ONE AT A TIME (never two giant buckets competing for threads
  simultaneously), but each one's OWN O(size²) inner loop is itself what gets split across
  batches/threads (`@LOOP for i in 1:size-1`, each `i` owning row `j in (i+1):size` -- still no two
  batches ever touch the same `(i,j)` pair, so this needs no more synchronization than the small-
  bucket case).

Both cases mint their OWN `Dist.Seqs.DamerauLevenshtein()` instance AND their OWN word-pair `cache`
(a plain `Dict{Tuple{String,String},Float64}`, see [`_precision_token_score`](@ref)) per batch in
`@BEGINBATCH` (rather than sharing [`_DAMERAU`](@ref)/one cache across threads) and append
`(idx_a, idx_b)` pairs to a `@batchid()`-indexed edge list -- `@batchid()` rather than
`Threads.threadid()` specifically because it is stable and disjoint under EVERY scheduler
(`Threads.threadid()` can alias/migrate under the non-`:static` ones). The union-find itself stays
sequential, applied AFTER every batch of both kinds joins: `parent` is plain, unsynchronized mutable
state, so mutating it from multiple concurrent batches would race -- collecting edges in parallel
and unioning them in one single-threaded pass afterward sidesteps that entirely.

**Parallelizing the O(bucket²) loop only changes the CONSTANT factor, not its order -- found live,
2026-09-07/08, on a real full-93-repo rebuild: `compute_precision_clusters` took ~7.7 HOURS** (32
threads) despite the hybrid split above, because real common-Mexican-surname buckets there reach
12,615-17,789 members, several of them at once. Three real, measured optimizations landed on top of
the hybrid split as a result (all in [`precision_match_score`](@ref)/[`_precision_token_score`](@ref),
not here):

1. `precision_match_score` now takes a `surname_shortcut` threshold and skips the given-name
   bipartite alignment ENTIRELY once surname has already failed it -- every caller in this module
   checks surname first and never looks at `match`/`pairs` when it fails, so that alignment was pure
   wasted work in exactly that (common, most same-bucket pairs have UNRELATED given names) case.
2. `_precision_token_score`'s bare-initial case is now a closed-form O(1) formula, not an
   `evaluate` call -- see its own docstring for the exact distance proof.
3. `_precision_token_score` accepts a per-batch `cache`, memoized by DISTINCT WORD PAIR rather than
   by name pair -- a real corpus bucket draws its given/surname tokens from a MUCH smaller distinct
   vocabulary than its member count, so this collapses what would otherwise be repeated identical
   `evaluate` calls across thousands of name-pairs sharing the same two words.

Point 3 in particular was chosen over a BK-tree-radius-based neighbor lookup (considered first):
that alternative would be an APPROXIMATION (treating "not found within a small search radius" as
"far enough to not matter"), and was found to be unsafe specifically for the LOW
`contradiction_floor=0.2` check -- a pair just outside radius 1 is not safely below `0.2` for
realistic word lengths, only safely below the HIGH `0.9` connect bar. The cache above is exact (the
stored value is the identical `evaluate` result, just computed once), so it carries no such risk.

**A fourth, structural change (2026-09-08) on top of the three above: [`_bucket_signature_groups`](@ref)
splits each bucket into what's free and what's actually worth comparing** ("clustering más fino" --
see that function's own docstring for the full mechanics and why it's not a new precision risk).
Every bucket, BEFORE any batching, gets partitioned into (a) exact-signature groups, star-connected
for free with no [`precision_edge`](@ref) call at all, and (b) one representative per DISTINCT,
non-bare-initial-only signature -- ONLY those representatives feed the `small_buckets`/
`large_buckets` split and the batched comparison below, never the raw bucket membership. Measured
on the real 93-repo corpus: large buckets are only ~55-59% distinct signatures, so this alone is a
real (if modest, ~3x) reduction in how many comparisons are even attempted, on top of points 1-3.

Re-measurement on the 93-repo scale that motivated all of this is still pending as of this writing;
first validated on the 20-repo corpus (see this module's test suite and the session's own validation
scripts) against the same mined ground truth used throughout this project, same discipline as every
other change here. `precision_contradiction`/`precision_split` afterward stay sequential and
uncached -- not yet shown to be the bottleneck, but not re-measured at 93-repo scale either.
"""
function compute_precision_clusters(raw_names::Vector{String}, vocab::Vocabulary;
                                     match_threshold::Float64=PRECISION_MATCH_THRESHOLD,
                                     surname_threshold::Float64=PRECISION_SURNAME_THRESHOLD,
                                     contradiction_floor::Float64=PRECISION_CONTRADICTION_FLOOR,
                                     large_bucket_threshold::Int=200)
    n = length(raw_names)
    n == 0 && return Vector{Vector{String}}()
    idx = Dict(nm => i for (i, nm) in enumerate(raw_names))
    corrected = Dict(nm => correct_name(vocab, nm) for nm in raw_names if !AC._is_garbage_name(nm))

    candidate_buckets = Dict{String,Vector{String}}()
    for nm in raw_names
        haskey(corrected, nm) || continue
        for k in precision_cluster_keys(corrected[nm])
            push!(get!(candidate_buckets, k, String[]), nm)
        end
    end
    all_buckets = [unique(b) for b in values(candidate_buckets)]
    filter!(b -> length(b) >= 2, all_buckets)

    edges = Tuple{Int,Int}[]
    comparable_buckets = Vector{String}[]
    for bucket in all_buckets
        free_edges, reps = _bucket_signature_groups(bucket, corrected, idx)
        append!(edges, free_edges)
        length(reps) >= 2 && push!(comparable_buckets, reps)
    end
    small_buckets = filter(b -> length(b) < large_bucket_threshold, comparable_buckets)
    large_buckets = filter(b -> length(b) >= large_bucket_threshold, comparable_buckets)

    if !isempty(small_buckets)
        minbatch = getminbatch(length(small_buckets))
        per_batch_edges = Vector{Vector{Tuple{Int,Int}}}()
        @BATCHES minbatch begin
            @BEGIN
                per_batch_edges = [Tuple{Int,Int}[] for _ in 1:@nbatches()]
            @BEGINBATCH
                dl = Dist.Seqs.DamerauLevenshtein()
                cache = Dict{Tuple{String,String},Float64}()
                bedges = per_batch_edges[@batchid()]
            @LOOP for bi in eachindex(small_buckets)
                bucket = small_buckets[bi]
                for i in 1:length(bucket), j in (i+1):length(bucket)
                    a, b = bucket[i], bucket[j]
                    precision_edge(corrected[a], corrected[b]; dl, cache, match_threshold, surname_threshold) &&
                        push!(bedges, (idx[a], idx[b]))
                end
            end
        end
        for bedges in per_batch_edges
            append!(edges, bedges)
        end
    end

    for bucket in large_buckets
        sz = length(bucket)
        minbatch = getminbatch(sz - 1)
        per_batch_edges = Vector{Vector{Tuple{Int,Int}}}()
        @BATCHES minbatch begin
            @BEGIN
                per_batch_edges = [Tuple{Int,Int}[] for _ in 1:@nbatches()]
            @BEGINBATCH
                dl = Dist.Seqs.DamerauLevenshtein()
                cache = Dict{Tuple{String,String},Float64}()
                bedges = per_batch_edges[@batchid()]
            @LOOP for i in 1:(sz-1)
                a = bucket[i]
                for j in (i+1):sz
                    b = bucket[j]
                    precision_edge(corrected[a], corrected[b]; dl, cache, match_threshold, surname_threshold) &&
                        push!(bedges, (idx[a], idx[b]))
                end
            end
        end
        for bedges in per_batch_edges
            append!(edges, bedges)
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
    for (a, b) in edges
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
        cx = precision_contradiction(comp, corrected; surname_threshold, contradiction_floor)
        if cx === nothing
            push!(groups, comp)
        else
            append!(groups, precision_split(comp, corrected; contradiction_floor))
        end
    end
    return groups
end

end # module
