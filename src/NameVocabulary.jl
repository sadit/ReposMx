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
of this module's own `:levenshtein` method: `"rcuz"` (a transposition typo of `"cruz"`) scored
edit-distance 1 to the WRONG `"cuz"` (a deletion) but distance 2 to the intended `"cruz"` under
plain Levenshtein, so plain Levenshtein confidently proposed the wrong correction. Under
`DamerauLevenshtein`, `"rcuz"` is distance 1 from BOTH `"cruz"` and `"cuz"` -- correctly recognizing
the transposition as equally cheap, though this reintroduces a tie that popularity (see
[`correct_token`](@ref)'s tie-break) is what actually resolves in `"cruz"`'s favor.
"""
const _DAMERAU = Dist.Seqs.DamerauLevenshtein()

"""
    Vocabulary

Given-name/surname token frequency table built by [`build_name_vocabulary`](@ref). `counts` maps
`(token, role)` (`role` is `:given` or `:surname`) to how many raw author names contributed that
token under that role — a token can appear under both roles (e.g. "Guadalupe" is a given name for
some people, part of a compound surname for others), and that's tracked as two independent counts,
not forced into one. Bare initials (`length(token) == 1`) never appear here at all (see
[`build_name_vocabulary`](@ref)).

`qgram_index` is a per-role inverted index (q-gram -> tokens containing it) built once, used by
[`correct_token`](@ref) to avoid scanning the whole vocabulary for every correction.
"""
struct Vocabulary
    counts::Dict{Tuple{String,Symbol},Int}
    qgram_index::Dict{Symbol,Dict{String,Vector{String}}}
end

"""
    Vocabulary(counts::Dict{Tuple{String,Symbol},Int}) -> Vocabulary

Builds a `Vocabulary` directly from an already-computed `(token, role) -> count` table -- the
q-gram index is derived from `counts` alone, so this is all [`build_name_vocabulary`](@ref) does
beyond scanning raw names for `counts` in the first place. Meant for reloading a vocabulary saved
as a plain counts artifact (e.g. built once over a large corpus for threshold-tuning experiments)
without re-scanning any raw names.
"""
function Vocabulary(counts::Dict{Tuple{String,Symbol},Int})
    qgram_index = Dict{Symbol,Dict{String,Vector{String}}}(:given => Dict{String,Vector{String}}(),
                                                             :surname => Dict{String,Vector{String}}())
    for ((tok, role), _) in counts
        idx = qgram_index[role]
        for g in AC._name_qgrams(tok)
            push!(get!(idx, g, String[]), tok)
        end
    end
    return Vocabulary(counts, qgram_index)
end

"""
    _tokens_by_role(raw::AbstractString) -> (; given, surname)

Splits `raw` into given-name and surname tokens using the SAME logic already validated for name
clustering (`AC._qgram_name_tokens`/`AC._surname_span`) — not reinvented here. Surname particles
(`AC._SURNAME_PARTICLES`, e.g. "de"/"la"/"los") are dropped from the returned `surname` list: they
are part of the surname SPAN for matching purposes elsewhere, but are never real name content, so
they never get a vocabulary entry of their own.
"""
function _tokens_by_role(raw::AbstractString)
    toks = AC._qgram_name_tokens(raw)
    isempty(toks) && return (given=String[], surname=String[])
    span = AC._surname_span(toks)
    given = toks[1:first(span)-1]
    surname = [t for t in toks[span] if t ∉ AC._SURNAME_PARTICLES]
    return (; given, surname)
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
    _candidates(v::Vocabulary, token, role) -> Vector{String}

Every DISTINCT vocabulary token under `role` sharing at least one q-gram with `token` (via
`v.qgram_index`) -- the search space [`correct_token`](@ref) actually scores, instead of the whole
vocabulary. A genuine typo/transliteration variant always shares at least one q-gram with the
correct spelling for any real-world token length this problem sees (see `AC._name_qgrams`'s own
docstring for the same assumption elsewhere in this codebase).
"""
function _candidates(v::Vocabulary, token::AbstractString, role::Symbol)
    idx = v.qgram_index[role]
    seen = Set{String}()
    for g in AC._name_qgrams(token)
        for cand in get(idx, g, String[])
            push!(seen, cand)
        end
    end
    delete!(seen, token)
    return collect(seen)
end

"""
    _levenshtein(a, b) -> Int

Plain edit distance, iterative DP with two rolling rows (no external dependency -- this codebase
has no string-distance package, and the algorithm is a dozen lines).
"""
function _levenshtein(a::AbstractString, b::AbstractString)
    ac, bc = collect(a), collect(b)
    la, lb = length(ac), length(bc)
    la == 0 && return lb
    lb == 0 && return la
    prev = collect(0:lb)
    curr = similar(prev)
    for i in 1:la
        curr[1] = i
        for j in 1:lb
            cost = ac[i] == bc[j] ? 0 : 1
            curr[j+1] = min(prev[j+1] + 1, curr[j] + 1, prev[j] + cost)
        end
        prev, curr = curr, prev
    end
    return prev[end]
end

"""
    correct_token(v::Vocabulary, token, role; method=:damerau, min_popularity_ratio=2.0,
                  max_own_popularity=1, max_distance=1, min_qgram_sim=0.5)
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
- Only for a token that clears that bar: scores every q-gram-sharing candidate (`_candidates`) via
  `method`:
  - `:damerau` -- restricted Damerau-Levenshtein ([`_DAMERAU`](@ref), transposition as a 4th edit
    op at cost 1) distance `<= max_distance`, score = `1 - distance/max(length(token),length(cand))`.
  - `:levenshtein` -- plain edit distance <= `max_distance`, same score formula -- kept only for
    comparison against `:damerau`; see the tuning results below for why `:damerau` should be
    preferred over it whenever the choice is between the two.
  - `:qgram` -- `AC._qgram_jaccard(token, cand)`, kept only if `>= min_qgram_sim`.
- A candidate is only ACCEPTED if it is ALSO meaningfully more popular than `token` itself
  (`popularity(cand) >= min_popularity_ratio * max(popularity(token), 1)`) -- a second,
  independent bar on top of the own-popularity gate above.
- Among candidates that clear both bars, the HIGHEST-scoring one wins; a TIE is broken by
  popularity (higher wins) rather than by `_candidates`' arbitrary `Set` iteration order -- needed
  for `:damerau` specifically, since a transposition and e.g. a deletion can land at the exact same
  edit distance (see [`_DAMERAU`](@ref)'s docstring for the concrete `"cruz"`/`"cuz"` case).
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

**Still a known limitation, NOT fixed by `:damerau`: candidate generation itself is q-gram-based
for every method, so a transposition-heavy typo on a SHORT token can evade it entirely.** `"jsoe"`
(a transposition of `"jose"`) shares ZERO 4-grams with `"jose"` -- every 4-char window is corrupted
by the swap on a word this short -- so `"jose"` never even reaches ANY method's candidate set,
regardless of which one scores it. If this turns out to matter in practice, the fix belongs in
`_candidates` (widen candidate generation), not in swapping which metric scores the candidates it
already found.

**93-repo vocabulary tuning (`experiments/author_matching/tune_correction_thresholds.jl`) --
`:qgram` was NOT the safer default it looked like at 10-repo scale; that earlier framing was
wrong.** Two purpose-built evaluation sets (597 synthetic single-edit typos of the most popular
tokens per role; 1,000 real pairs of DIFFERENT, q-gram-similar, BOTH-independently-established --
popularity `>= 2` on both sides -- tokens per role, generated from `NameVocabulary`'s own candidate
index so this stays cheap at 73K-token scale) show, at `max_own_popularity=1`:

| method | recall | precision (0 real-name conflations wanted) |
|---|---|---|
| `:qgram` (the old default) | 12.1% (72/597) | 100% (1000/1000) |
| `:levenshtein`, `max_distance=2` | 73.0% (436/597) | 100% (1000/1000) |
| `:damerau`, `max_distance=1` (the new default) | **83.8% (500/597)** | **100% (1000/1000)** |

`max_distance=1` gives `:damerau` the SAME recall as `max_distance=2` (both 83.8%) -- expected,
since every synthetic test corruption is exactly one edit away and `DamerauLevenshtein` now costs
every one of its four edit types (substitution/insertion/deletion/transposition) at 1, so
`max_distance=1` already catches all of them; the more conservative value is the new default since
it costs nothing here.

`max_own_popularity=1` is confirmed load-bearing regardless of method: relaxing it to `2` collapses
`:damerau`/`:levenshtein`'s precision from 100% to ~30-49% in the same test (`:qgram` degrades far
less sharply, 100%->61-89% depending on `min_qgram_sim`, but starts from such low recall that it's
not a useful tradeoff regardless). The earlier "`:qgram` is safer" conclusion (drawn from a much
smaller, noisier 10-repo vocabulary) does not hold up at this scale -- `:qgram`'s low recall was
previously read as caution, but the larger vocabulary shows the POPULARITY gate is what actually
protects precision, not the choice of string metric; `:qgram` was just leaving most of the
available recall on the table for no corresponding safety benefit.

This is exactly why `:damerau` exists as a THIRD option rather than replacing `:levenshtein`'s
implementation in place: plain Levenshtein's specific failure mode (a transposition typo scores
distance-2, so a same-distance-1 WRONG neighbor -- e.g. `"rcuz"` -> `"cuz"` instead of the intended
`"cruz"` -- confidently wins) is a real, additional cost on top of `:levenshtein`'s already-better-
than-`:qgram` numbers (accounting for most of the recall gap between the two: 73.0% -> 83.8%), and
`Dist.Seqs.DamerauLevenshtein` (this package's own restricted/OSA implementation) removes exactly
that cost by costing the transposition at 1 instead of 2 -- at the price of then tying with e.g. a
deletion at the same distance, which is why the popularity tie-break above exists: it is what
actually resolves `"rcuz"` toward `"cruz"` over `"cuz"`, not the distance metric alone.

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
                        method::Symbol=:damerau,
                        min_popularity_ratio::Float64=2.0,
                        max_own_popularity::Int=1,
                        max_distance::Int=1,
                        min_qgram_sim::Float64=0.5)
    length(token) <= 1 && return (token, 1.0)

    own_pop = popularity(v, token, role)
    own_pop > max_own_popularity && return in_vocab(v, token, role) ? (token, 1.0) : (token, 0.0)

    best_tok, best_score, best_pop = token, 0.0, own_pop
    for cand in _candidates(v, token, role)
        score = if method == :levenshtein
            d = _levenshtein(token, cand)
            d > max_distance ? 0.0 : 1.0 - d / max(length(token), length(cand))
        elseif method == :damerau
            # token/cand passed directly as String -- SimilaritySearch >= 1.3.4's
            # AbstractString-specialized evaluate method handles Unicode internally.
            d = SimilaritySearch.evaluate(_DAMERAU, token, cand)
            d > max_distance ? 0.0 : 1.0 - d / max(length(token), length(cand))
        elseif method == :qgram
            s = AC._qgram_jaccard(token, cand)
            s < min_qgram_sim ? 0.0 : s
        else
            error("unknown correction method $method (expected :levenshtein, :damerau, or :qgram)")
        end
        score <= 0.0 && continue  # below the method's own floor -- never eligible, ties included
        cand_pop = popularity(v, cand, role)
        cand_pop >= min_popularity_ratio * max(own_pop, 1) || continue
        # accept if strictly better, OR tied with strictly better popularity -- otherwise a tie is
        # resolved by `_candidates`' arbitrary Set iteration order instead of by evidence.
        # Necessary specifically for `:damerau`: a transposition and e.g. a deletion can land at
        # the SAME edit distance (see `_DAMERAU`'s docstring for the concrete "cruz"/"cuz" case),
        # and popularity is what should decide between them.
        (score > best_score || (score == best_score && cand_pop > best_pop)) || continue
        best_tok, best_score, best_pop = cand, score, cand_pop
    end
    best_tok != token && return (best_tok, best_score)
    return in_vocab(v, token, role) ? (token, 1.0) : (token, 0.0)
end

end # module
