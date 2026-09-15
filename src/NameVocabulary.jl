module NameVocabulary

using ..AuthorConsolidation: AuthorConsolidation
using SimilaritySearch: SimilaritySearch
const AC = AuthorConsolidation
const Dist = SimilaritySearch.Dist

export Vocabulary, build_name_vocabulary, popularity, in_vocab, correct_token

"""
    _DAMERAU

Single shared `Dist.Seqs.DamerauLevenshtein()` instance (its scratch-buffer pool is built once at
construction) -- restricted Damerau-Levenshtein (OSA): `Levenshtein` plus adjacent-character
transposition as a FOURTH edit operation at cost 1, instead of plain Levenshtein's 2 (a
substitution at each of the two swapped positions). Directly fixes a real, confirmed limitation
of the plain-Levenshtein scoring this module used earlier: `"rcuz"` (a transposition typo of
`"cruz"`) scored
edit-distance 1 to the WRONG `"cuz"` (a deletion) but distance 2 to the intended `"cruz"` under
plain Levenshtein, so plain Levenshtein confidently proposed the wrong correction. Under
`DamerauLevenshtein`, `"rcuz"` is distance 1 from BOTH `"cruz"` and `"cuz"` -- correctly recognizing
the transposition as equally cheap, though this reintroduces a tie that popularity (see
[`correct_token`](@ref)'s tie-break) is what actually resolves in `"cruz"`'s favor.
"""
const _DAMERAU = Dist.Seqs.DamerauLevenshtein()

"""
    _bk_search(bkt, ctx, query::AbstractString, radius::Int) -> Vector{Tuple{String,Int}}

Every vocabulary token within [`_DAMERAU`](@ref)-distance `radius` of `query` (`query` itself
excluded IF present in the tree), paired with its
exact distance -- returning the distance too avoids [`correct_token`](@ref) recomputing it.
`bkt === nothing` (an empty tree) returns no candidates, not an error.

Thin wrapper over `SimilaritySearch.BKT` (`Dist.Seqs.DamerauLevenshtein`-keyed, built once per
role in [`Vocabulary`](@ref)'s constructor with `checkmetric=false` -- see there for why) plus a
`SimilaritySearch.RadiusSorted(radius)` queue, adapting its `.ids`/`.dists` result to the
`(token, distance)` pairs [`correct_token`](@ref) expects, exactly like the hand-rolled BK-tree
this replaced (2026-09-06 -> 2026-09-07, once `SimilaritySearch` shipped a real `BKT` with
parallel construction, see [`Vocabulary`](@ref)'s docstring).
"""
function _bk_search(bkt, ctx, query::AbstractString, radius::Int)
    bkt === nothing && return Tuple{String,Int}[]
    res = SimilaritySearch.search(bkt, ctx, query, SimilaritySearch.RadiusSorted(Float32(radius)))
    results = Tuple{String,Int}[]
    for (id, d) in zip(res.ids, res.dists)
        cand = SimilaritySearch.database(bkt, id)
        cand == query && continue
        push!(results, (cand, round(Int, d)))
    end
    return results
end

"""
    Vocabulary

Given-name/surname token frequency table built by [`build_name_vocabulary`](@ref). `counts` maps
`(token, role)` (`role` is `:given` or `:surname`) to how many raw author names contributed that
token under that role — a token can appear under both roles (e.g. "Guadalupe" is a given name for
some people, part of a compound surname for others), and that's tracked as two independent counts,
not forced into one. Bare initials (`length(token) == 1`) never appear here at all (see
[`build_name_vocabulary`](@ref)).

`bktree` is a per-role `SimilaritySearch.BKT` ([`_DAMERAU`](@ref)-keyed, built once per role
below), which [`correct_token`](@ref) queries by exact edit-distance radius. `bktctx` is the shared
`SimilaritySearch.GenericContext` those trees were built with and are searched with -- `BKT` search
allocates no scratch of its own (per its own docstring), so reusing one context for every
concurrent search is safe.

**`BKT` is keyed by `:damerau` with `checkmetric=false`, NOT a hand-rolled tree anymore
(2026-09-07).** `BKT` prunes via the triangle inequality, which restricted Damerau-Levenshtein
(OSA) does not strictly satisfy (it is a `SemiMetric`, not a `Metric` -- see [`_DAMERAU`](@ref)'s
docstring) -- `checkmetric=false` overrides `BKT`'s own safety check for exactly this case.
`SimilaritySearch.BKT`'s own docstring documents this precise tradeoff and measured it directly:
on a 20k-word dictionary with 200 typo queries, keying by `:damerau` with `checkmetric=false` lost
NOTHING at all (recall `1.0`) at radius 1, 2, and 3, at 7.9%/39%/68% of an exhaustive scan -- this
module only ever searches at `max_distance=1`, comfortably inside that validated range. The
alternative the same docstring offers (key by plain `Levenshtein`, a true `Metric`, search at
radius `2*max_distance`, then filter exactly by `:damerau`) is NOT used here: it is the safer
choice in the abstract, but costs MORE than an exhaustive scan by `r=3` on that same benchmark, and
this module's own radius never needs to go that high.
"""
struct Vocabulary
    counts::Dict{Tuple{String,Symbol},Int}
    bktree::Dict{Symbol,Any}
    bktctx::SimilaritySearch.GenericContext
end

"""
    Vocabulary(counts::Dict{Tuple{String,Symbol},Int}) -> Vocabulary

Builds a `Vocabulary` directly from an already-computed `(token, role) -> count` table -- the
BK-trees are derived from `counts` alone, so this is all [`build_name_vocabulary`](@ref) does
beyond scanning raw names for `counts` in the first place.
Meant for reloading a vocabulary saved as a plain counts artifact (e.g. built once over a large
corpus for threshold-tuning experiments) without re-scanning any raw names.

Each role's `BKT` is built via `SimilaritySearch.index!`, which parallelizes level-by-level
construction internally via `@BATCHES` (see that function's own docstring) -- multi-threaded
whenever this call itself runs with `Threads.nthreads() > 1`, with no extra effort needed here.
"""
function Vocabulary(counts::Dict{Tuple{String,Symbol},Int})
    tokens_by_role = Dict{Symbol,Vector{String}}(:given => String[], :surname => String[])
    for ((tok, role), _) in counts
        push!(tokens_by_role[role], tok)
    end
    ctx = SimilaritySearch.GenericContext(; reporters=[])
    bktree = Dict{Symbol,Any}()
    for (role, toks) in tokens_by_role
        db = SimilaritySearch.VectorDatabase(toks)
        bkt = SimilaritySearch.BKT(_DAMERAU, db; checkmetric=false)
        SimilaritySearch.index!(bkt, ctx)
        bktree[role] = bkt
    end
    return Vocabulary(counts, bktree, ctx)
end

"""
    _tokens_by_role(raw::AbstractString) -> (; given, surname)

Splits `raw` into given-name and surname tokens using the SAME logic already validated for name
clustering (`AC._qgram_name_tokens`/`AC._split_given_surname`) — not reinvented here. `surname` is
FLATTENED, connector-free content (`AC._surname_content`), NOT the canonical, possibly-hyphenated
compound form `AC._split_given_surname` itself returns: vocabulary popularity and correction
(`correct_token`) operate at the level of individual real words (`"cruz"`, `"milian"`, `"avila"`),
never on a whole compound like `"de-la-cruz"` as one unit -- particles/the "y" conjunction
(`AC._SURNAME_PARTICLES`) are dropped entirely, same as before: they are part of the surname for
matching purposes elsewhere, but are never real name content, so they never get a vocabulary entry
of their own.
"""
function _tokens_by_role(raw::AbstractString)
    toks = AC._qgram_name_tokens(raw)
    isempty(toks) && return (given=String[], surname=String[])
    (; given, surname) = AC._split_given_surname(toks)
    return (; given, surname=AC._surname_content(surname))
end

"""
    build_name_vocabulary(raw_names::Vector{String}) -> Vocabulary

Builds the (token, role) -> popularity table over `raw_names`, plus the q-gram candidate index
used by [`correct_token`](@ref). Garbage names (`AC._is_garbage_name`, bare URLs/ORCIDs/digit
runs) are skipped entirely. Compound names are already split into individual tokens by
[`_tokens_by_role`](@ref) -- each contributes its own popularity count independently. Bare
single-character tokens (real initials in the raw data) are discarded: they carry no name
information to correct against, and including them would let every "J." in the corpus inflate a
single-letter "token"'s popularity for no benefit.
"""
function build_name_vocabulary(raw_names::Vector{String})
    counts = Dict{Tuple{String,Symbol},Int}()
    for raw in raw_names
        AC._is_garbage_name(raw) && continue
        (; given, surname) = _tokens_by_role(raw)
        for t in given
            length(t) <= 1 && continue
            key = (t, :given)
            counts[key] = get(counts, key, 0) + 1
        end
        for t in surname
            length(t) <= 1 && continue
            key = (t, :surname)
            counts[key] = get(counts, key, 0) + 1
        end
    end
    return Vocabulary(counts)
end

"""
    popularity(v::Vocabulary, token, role) -> Int

How many raw names contributed `token` under `role` (`:given`/`:surname`); `0` if never seen —
including for a bare initial, which [`build_name_vocabulary`](@ref) never records.
"""
popularity(v::Vocabulary, token::AbstractString, role::Symbol) = get(v.counts, (token, role), 0)

"""
    in_vocab(v::Vocabulary, token, role) -> Bool

Whether `token` has at least one recorded occurrence under `role`.
"""
in_vocab(v::Vocabulary, token::AbstractString, role::Symbol) = haskey(v.counts, (token, role))

"""
    _accept_by_distance(best_tok, best_dist, best_pop, cand, d, cand_pop, min_popularity_ratio, own_pop)
        -> (best_tok, best_dist, best_pop)

Acceptance/tie-break decision for [`correct_token`](@ref)'s candidate loop, factored out as a
plain value-in-value-out function (not a closure over the caller's locals) so the hot loop pays
nothing for capturing/boxing a mutable outer variable. Ranks candidates by RAW edit distance
(smaller wins), not by a length-normalized score. **Deliberately not a `1 - d/maxlen` score**:
that normalization makes the SAME raw distance mean something different
depending on token length (distance 1 on a 6-letter token scores far lower than distance 1 on a
12-letter one), and conflates a genuinely CLOSER candidate at a larger distance-to-length ratio
with a genuinely FARTHER one -- found live to matter once `max_distance > 1` lets candidates at
different distances compete for the same slot; under the ranking here, distance strictly decides
first, with popularity breaking a tie only between candidates at the IDENTICAL distance (needed
because a transposition and e.g. a deletion can land at the SAME edit distance, see
[`_DAMERAU`](@ref)'s docstring for the concrete `"cruz"`/`"cuz"` case).
"""
function _accept_by_distance(best_tok, best_dist, best_pop, cand, d, cand_pop, min_popularity_ratio, own_pop)
    cand_pop >= min_popularity_ratio * max(own_pop, 1) || return (best_tok, best_dist, best_pop)
    (d < best_dist || (d == best_dist && cand_pop > best_pop)) || return (best_tok, best_dist, best_pop)
    return (cand, d, cand_pop)
end

"""
    correct_token(v::Vocabulary, token, role; min_popularity_ratio=2.0,
                  max_own_popularity=1, max_distance=1)
        -> (corrected::String, confidence::Float64)

Corrects `token` (assumed to already be in the given/surname ROLE it will be compared under)
against `v`'s vocabulary for that same role -- never crosses given<->surname.

- A bare initial (`length(token) <= 1`, never in the vocabulary by construction): returned as-is,
  `confidence=1.0`, no candidate search at all -- nothing correctable.
- **`token`'s OWN popularity must be at or below `max_own_popularity` (default 1 -- essentially a
  singleton spelling) before ANY candidate search happens at all.** This is a necessary
  precondition, not just a tie-break: a token that already occurs more than once in the corpus is
  treated as an established, real spelling and is NEVER touched, no matter how popular some
  q-gram-similar alternative is. See below for why this gate exists.
- Only for a token that clears that bar: candidates come from [`_bk_search`](@ref)'s exact
  edit-distance-radius query (`max_distance`, [`_DAMERAU`](@ref): transposition as a 4th edit op at
  cost 1), which also hands back the exact distance so it's never recomputed. Ranked by RAW distance
  ([`_accept_by_distance`](@ref) -- smaller wins, NOT a length-normalized score, see that function's
  docstring for why), and `confidence = 1/(1+distance)` -- distance-native, meaning the same thing
  regardless of `token`'s length, unlike a `1 - distance/length` proportion would. **A confidence
  here is NOT comparable to a q-gram Jaccard score on the same [0,1] scale -- a `0.9` under Jaccard
  and a `0.9` under `1/(1+distance)` mean different things; never carry a threshold tuned against
  one over to the other** (found live: exactly what made `PrecisionClustering`'s
  `contradiction_floor`, tuned when this module still scored by q-gram Jaccard, fail to transfer).
- A candidate is only ACCEPTED if it is ALSO meaningfully more popular than `token` itself
  (`popularity(cand) >= min_popularity_ratio * max(popularity(token), 1)`) -- a second,
  independent bar on top of the own-popularity gate above.
- Among candidates that clear both bars, the SMALLEST raw distance wins; a TIE (same distance) is
  broken by popularity (higher wins) rather than by candidate-iteration order -- needed because a
  transposition and e.g. a deletion can land at the exact same edit distance (see
  [`_DAMERAU`](@ref)'s docstring for the concrete `"cruz"`/`"cuz"` case).
- If no candidate clears both bars, `token` is returned unchanged -- `confidence=1.0` if it was
  already an exact vocabulary hit (nothing needed correcting), `confidence=0.0` otherwise (correction
  was attempted and failed to find anything plausible -- distinct from the `1.0` case, useful for
  diagnostics).

**Two real bugs, found live via the 10-repo corpus, both fixed before this shipped.**

1. An earlier version short-circuited on ANY exact vocabulary hit, before ever searching for a
   more popular candidate. That's silently a no-op whenever the vocabulary is built from the SAME
   corpus being corrected (the common case, e.g. `PrecisionClustering`'s use) -- every token,
   including a one-off misspelling, is trivially "in vocabulary" against itself, since building the
   vocabulary recorded it too. Confirmed: correction changed ZERO of 19,412 non-garbage raw names
   on the real 10-repo corpus under that logic.
2. Removing that short-circuit on its own (without the `max_own_popularity` gate) turned out to be
   its own bug: with only `min_popularity_ratio=2.0` guarding acceptance, correction started
   flattening genuinely DIFFERENT, both-real Spanish names into whichever one happened to be more
   common in the corpus -- Spanish names have a small phonetic space, so pairs like
   `"fernandez"`/`"hernandez"`, `"adalberto"`/`"alberto"`, `"arcos"`/`"marcos"` are one q-gram edit
   apart while BOTH sides are legitimate, common names. Confirmed live and clearly wrong:
   `"A. . (Alejandra) Ríos C."` (the record's OWN parenthetical explicitly says "Alejandra",
   feminine) got "corrected" to `"alejandro"` (masculine) purely because that spelling is more
   popular corpus-wide and one edit away -- a 2x popularity ratio is nowhere near enough evidence to
   overrule that. `max_own_popularity` fixes this: a token appearing MORE than once in the corpus
   already has independent corroborating evidence it's a real, intentional spelling, not a slip --
   only a spelling that's (by default) essentially unique gets subjected to the popularity-ratio
   check at all.

**Candidate generation comes from a BK-tree ([`_bk_search`](@ref)), NOT from a q-gram inverted
index -- this fixed a real limitation the earlier q-gram design had.** `"jsoe"` (a transposition of
`"jose"`) shares ZERO 4-grams with `"jose"` -- every 4-char window is corrupted by the swap on a
word this short -- so under q-gram candidate generation, `"jose"` never even reached the scoring
step, regardless of which metric would have scored it. The BK-tree searches by ACTUAL edit-distance
radius (`max_distance`), so a transposition-heavy short-token typo like this is found directly:
confirmed live, `correct_token(vocab, "jsoe", :given)` returns `"jose"` (assuming it's the more
popular spelling) where the q-gram design returned `"jsoe"` unchanged.

**93-repo vocabulary tuning (`experiments/author_matching/tune_correction_thresholds.jl`) -- why
q-gram Jaccard, this module's original scoring, was dropped: it was NOT the safer choice it looked
like at 10-repo scale.** Two purpose-built evaluation sets (597 synthetic single-edit typos of the most popular
tokens per role; 1,000 real pairs of DIFFERENT, q-gram-similar, BOTH-independently-established --
popularity `>= 2` on both sides -- tokens per role, generated from `NameVocabulary`'s own candidate
index so this stays cheap at 73K-token scale) show, at `max_own_popularity=1`:

| method | recall | precision (0 real-name conflations wanted) |
|---|---|---|
| q-gram Jaccard (the original scoring) | 12.1% (72/597) | 100% (1000/1000) |
| plain Levenshtein, `max_distance=2` | 73.0% (436/597) | 100% (1000/1000) |
| Damerau-Levenshtein, `max_distance=1` (what shipped) | **83.8% (500/597)** | **100% (1000/1000)** |

`max_distance=1` gives Damerau-Levenshtein the SAME recall as `max_distance=2` (both 83.8%) -- expected,
since every synthetic test corruption is exactly one edit away and `DamerauLevenshtein` now costs
every one of its four edit types (substitution/insertion/deletion/transposition) at 1, so
`max_distance=1` already catches all of them; the more conservative value is the new default since
it costs nothing here.

`max_own_popularity=1` is confirmed load-bearing regardless of metric: relaxing it to `2` collapses
edit-distance precision from 100% to ~30-49% in the same test (q-gram Jaccard degrades far less
sharply, 100%->61-89% depending on the similarity floor, but starts from such low recall that it's
not a useful tradeoff regardless). The earlier "q-gram is safer" conclusion (drawn from a much
smaller, noisier 10-repo vocabulary) does not hold up at this scale -- its low recall was
previously read as caution, but the larger vocabulary shows the POPULARITY gate is what actually
protects precision, not the choice of string metric; q-gram was just leaving most of the available
recall on the table for no corresponding safety benefit.

Damerau-Levenshtein rather than plain Levenshtein, specifically: plain Levenshtein's failure mode
(a transposition typo scores distance-2, so a same-distance-1 WRONG neighbor -- e.g. `"rcuz"` ->
`"cuz"` instead of the intended `"cruz"` -- confidently wins) accounts for most of the recall gap
between the two (73.0% -> 83.8%). `Dist.Seqs.DamerauLevenshtein` (this package's own restricted/OSA
implementation) removes that cost by costing the transposition at 1 instead of 2 -- at the price of
then tying with e.g. a deletion at the same distance, which is why the popularity tie-break above
exists: it is what actually resolves `"rcuz"` toward `"cruz"` over `"cuz"`, not the distance metric
alone.

**`Dist.Seqs.DamerauLevenshtein.evaluate` accepts `String`/`SubString` directly as of
SimilaritySearch 1.3.4** (`evaluate(::DamerauLevenshtein, a::AbstractString, b::AbstractString)`,
added specifically to remove this exact caller-side conversion step) -- Unicode included, via
Julia's string-iteration protocol internally rather than integer-indexing. Earlier versions
(1.3.2/1.3.3, when `DamerauLevenshtein` was first added) only had the generic array method
(`evaluate(dl, a, b)` indexing `a[i]`/`b[i]`), which throws `StringIndexError` on multi-byte UTF-8
content (confirmed live: this vocabulary has real Cyrillic/CJK names) since a `String` is indexed
by UTF-8 codeunit, not by character. This module used to work around that itself by converting
both sides to `Vector{Char}` (once per call for `token`, once per token at `Vocabulary`-build time
for every candidate) -- no longer needed now that the caller can just pass `token`/`cand` as-is.
"""
function correct_token(v::Vocabulary, token::AbstractString, role::Symbol;
                        min_popularity_ratio::Float64=2.0,
                        max_own_popularity::Int=1,
                        max_distance::Int=1)
    length(token) <= 1 && return (token, 1.0)

    own_pop = popularity(v, token, role)
    own_pop > max_own_popularity && return in_vocab(v, token, role) ? (token, 1.0) : (token, 0.0)

    best_tok, best_dist, best_pop = token, max_distance + 1, own_pop
    for (cand, d) in _bk_search(v.bktree[role], v.bktctx, token, max_distance)
        best_tok, best_dist, best_pop = _accept_by_distance(best_tok, best_dist, best_pop, cand, d,
                                                               popularity(v, cand, role), min_popularity_ratio, own_pop)
    end
    # confidence is distance-native (NOT length-normalized): 1/(1+distance), so it depends only
    # on how many edits away the match was, the same meaning regardless of token length -- never
    # 0.0 for a found correction (that value is reserved for "nothing plausible found").
    best_tok != token && return (best_tok, 1.0 / (1.0 + best_dist))

    return in_vocab(v, token, role) ? (token, 1.0) : (token, 0.0)
end

end # module
