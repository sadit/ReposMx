module AuthorConsolidation

using TextSearch
using SimilaritySearch: SearchGraph, SearchGraphContext, VectorDatabase, index!,
                        bichromatic_metricjoin, Dist
using TOML
using SHA
using ..Config: DEFAULT_AUTHOR_OVERRIDES_TOML

export build_and_persist, load_all, name_keys, compute_groups, compute_name_clusters,
       load_overrides, save_imputes, assign_raw_ids, assign_id, compute_similarity_merges

"""
    AUTHOR_NAME_CONFIG

Shared with `Indexing.jl`'s `authors_name` index — same tokenization must be used for clustering
(this module) and for indexing, or the two would disagree on what counts as the same token.
"""
const AUTHOR_NAME_CONFIG = TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])

const CONSOLIDATED_SUBDIR = "authors_consolidated"

"""
    _order_normalize(s) -> String

Same "Apellido, Nombre" -> "Nombre Apellido" swap as `DB.normalize_author_name` (duplicated, not
imported: `Corpus.jl`/this module load before `DB.jl` in `ReposMx.jl`'s include order, and this is
five lines of pure string logic with no reason to fight that order for).
"""
function _order_normalize(s::AbstractString)
    s = strip(s)
    if occursin(",", s)
        parts = split(s, ","; limit=2)
        if length(parts) == 2 && !isempty(strip(parts[1])) && !isempty(strip(parts[2]))
            s = strip(parts[2]) * " " * strip(parts[1])
        end
    end
    return s
end

"""
    name_keys(raw::AbstractString) -> (full_key, initials_key, initials_text)

Two matching keys for `raw`, both computed from the same order-normalized, tokenized
(`AUTHOR_NAME_CONFIG`: accents stripped, lowercased, punctuation removed) name:

- `full_key`: every token, in order, joined by `_` — matches only near-exact name variants.
- `initials_key` / `initials_text`: every token except the last reduced to its first letter, last
  token (assumed surname) kept whole — matches "Juan García" with "J. García". `initials_key` is
  underscore-joined (for hashing/comparison); `initials_text` is space-joined (for display and for
  the extra text appended to the indexed `authors_name` document).

Two raw names sharing either key are assumed to be the same person by [`compute_groups`](@ref).
"""
function name_keys(raw::AbstractString)
    toks = String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(raw))))
    isempty(toks) && return (full_key="", initials_key="", initials_text="")
    full_key = join(toks, "_")
    initials_toks = length(toks) == 1 ? toks : vcat([string(first(t)) for t in toks[1:end-1]], [toks[end]])
    return (full_key=full_key, initials_key=join(initials_toks, "_"), initials_text=join(initials_toks, " "))
end

"""
    load_overrides(path=DEFAULT_AUTHOR_OVERRIDES_TOML) -> (; merges, splits, imputes)

Reads the consolidation overrides file (TOML: `merge`/`split`, edited by hand, plus `impute`,
written by an automatic recall pass — see [`save_imputes`](@ref)). Missing file = no overrides
(not an error) so a fresh checkout with no `author_overrides.toml` still works. `impute` entries
are returned in `imputes`, same shape as `merges` (`compute_groups` treats both identically — see
its docstring for why they're two sections in the file despite being one mechanism).
"""
function load_overrides(path::AbstractString=DEFAULT_AUTHOR_OVERRIDES_TOML)
    merges = Vector{Vector{String}}()
    splits = Vector{Tuple{String,String}}()
    imputes = Vector{Vector{String}}()
    if isfile(path)
        d = TOML.parsefile(path)
        for g in get(d, "merge", [])
            length(g) >= 2 && push!(merges, String.(collect(g)))
        end
        for p in get(d, "split", [])
            length(p) == 2 && push!(splits, (String(p[1]), String(p[2])))
        end
        for g in get(d, "impute", [])
            length(g) >= 2 && push!(imputes, String.(collect(g)))
        end
    end
    return (; merges, splits, imputes)
end

"""
    save_imputes(imputes::Vector{<:AbstractVector{<:AbstractString}}, path=DEFAULT_AUTHOR_OVERRIDES_TOML)

Rewrites ONLY the `impute` section of the overrides file, read-modify-write: `merge`/`split` (and
anything else already in the file) are read back verbatim and preserved untouched, since those are
human-edited and this function must never silently clobber a hand-curated entry. Meant to be
called once per rebuild by the (not yet implemented — interface only, see this module's docs)
imputation pass, after [`compute_groups`](@ref) has run with the PREVIOUS `impute` contents, so
each run's imputation proposals fully replace the last run's rather than accumulating stale ones.
Creates the file (with empty `merge`/`split`) if it doesn't exist yet.
"""
function save_imputes(imputes::AbstractVector, path::AbstractString=DEFAULT_AUTHOR_OVERRIDES_TOML)
    d = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    d["merge"] = get(d, "merge", Vector{Vector{String}}())
    d["split"] = get(d, "split", Vector{Vector{String}}())
    d["impute"] = [String.(collect(g)) for g in imputes]
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, d)
    end
    return nothing
end

"""
    _SURNAME_PARTICLES

Spanish/Mexican surname connector words: a compound surname like "de la Cruz" or "del Razo" is
ONE unit, not independent tokens — used by [`_surname_unit_ending_at`](@ref) so those words
neither leak into a given-name list as if they were middle names, nor get compared as if they were
the surname's own identity. Confirmed on a real 10-repo corpus: 1,084 of 19,543 raw names (~5.5%)
contain one of these words — common enough that this is not an edge case.

`"y"` (the surname-JOINING conjunction, as in `"Milián y Ávila"`) is handled SEPARATELY (see
[`_surname_unit_ending_at`](@ref)), not included here -- unlike a `"de"/"la"`-led run (which
attaches to a genuinely SEPARATE surname that precedes it, e.g. paternal `"Torres"` in `"Torres de
la Cruz"`), `"X y Z"` is conventionally ONE complete, atomic compound surname on its own, with
nothing further absorbed alongside it WHEN IT OCCUPIES THE TRAILING (maternal) SLOT. Conflating
the two (treating `"y"` as just another particle in the SAME backward walk) was tried and found
wanting 2026-09-06/07: `"GUADALUPE MARIA MILIAN Y AVILA"` needs `"milian"` and `"avila"` joined as
ONE unit (nothing else absorbed), not `"milian"` treated as a separate paternal surname the way
`"torres"` genuinely is in the `"de la Cruz"` case.
"""
const _SURNAME_PARTICLES = Set(["de", "del", "la", "las", "los", "san", "santa"])

"""
    _surname_unit_ending_at(toks::Vector{String}, i::Int) -> (start::Int, unit::String, is_y::Bool)

Parses ONE surname unit -- a single word, or a traditionally-atomic compound -- ending at position
`i` in `toks`, scanning BACKWARD from `i`. Returns the index where the unit STARTS (`start <= i`),
the unit itself (hyphen-joined if it's a compound, so it is never split into independent pieces
later by vocabulary popularity counts or bucketing the way its literal words would be if left
separate), and whether it was a `"y"`-conjunction.

[`_split_given_surname`](@ref) calls this SAME function for BOTH the maternal (trailing) and
paternal surname slots, since either slot can independently be a plain word or a compound. **Found
live, fixed 2026-09-07: an earlier version (`_collapse_surname_compounds`) only ever looked for a
particle-led compound anchored at the very END of `toks`**, silently assuming a compound could
only ever be the MATERNAL surname -- `"Victor del Real Torres"` (paternal `"del Real"`, separate
plain maternal `"Torres"`) came out as `given=["victor","del"], surname=["real","torres"]` (`"del"`
stranded in `given`, `"real"` wrongly read as a bare paternal surname) since the particle `"del"`
sits two tokens before the end, not immediately before it. With the fix (trying this SAME
unit-parser at whichever position each slot starts), it correctly gives
`given=["victor"], surname=["del-real","torres"]`.

Two compound patterns (see [`_SURNAME_PARTICLES`](@ref) for why they're handled differently):

1. **`"y"`-conjunction** (`toks[i-1] == "y"`, e.g. `"Milián y Ávila"`): joins `toks[i-2]`, `"y"`,
   and `toks[i]` into ONE atomic unit, `is_y=true`.
2. **`_SURNAME_PARTICLES`-led run** (e.g. `"del Real"`, `"de la Cruz"`): walks backward through
   consecutive particles immediately before `toks[i]`, joining the whole run, `is_y=false`.

Neither pattern found: the unit is just `toks[i]` alone, `start=i`, `is_y=false`.
"""
function _surname_unit_ending_at(toks::Vector{String}, i::Int)
    if i >= 3 && toks[i-1] == "y"
        return i - 2, string(toks[i-2], "-y-", toks[i]), true
    end
    j = i
    while j > 1 && toks[j-1] in _SURNAME_PARTICLES
        j -= 1
    end
    j < i && return j, join(toks[j:i], "-"), false
    return i, toks[i], false
end

"""
    _split_given_surname(toks::Vector{String}) -> (; given::Vector{String}, surname::Vector{String})

Splits `toks` into given-name and (possibly compound) surname token lists -- the successor to an
earlier `_surname_span(toks) -> UnitRange{Int}` (removed 2026-09-07, once a compound surname needed
to become a NEW joined string that isn't a slice of the original `toks` at all, so an index range
could no longer represent it). Parses from the tail using [`_surname_unit_ending_at`](@ref):

1. The MATERNAL (trailing) slot is whatever unit ends at the last token -- a plain word, or a
   compound if one is found there. If it's a `"y"`-conjunction, it's already atomic (see
   [`_SURNAME_PARTICLES`](@ref)): nothing more is absorbed, everything before it is `given`.
2. Otherwise, if at least one given-name token would still remain, try the SAME unit-parser again
   ending right before the maternal slot -- this is the PATERNAL slot, and it too may turn out to
   be a plain word or a compound (e.g. `"del Real"` in `"Victor del Real Torres"`). Only kept if it
   still leaves at least one token for `given`.

Examples: `["juan", "perez", "gomez"]` -> `surname=["perez","gomez"]` (given: `"juan"`).
`["victor", "manuel", "torres", "de", "la", "cruz"]` -> `surname=["torres","de-la-cruz"]` (given:
`"victor","manuel"`). `["victor", "del", "real", "torres"]` -> `surname=["del-real","torres"]`
(given: `"victor"`). `["juan", "tellez"]` -> `surname=["tellez"]` (only one token available at all,
nothing to absorb without emptying `given` entirely). `["guadalupe", "maria", "milian", "y",
"avila"]` -> `surname=["milian-y-avila"]` (given: `"guadalupe","maria"` -- NOT `"milian"` absorbed
as a separate paternal surname, since the "y"-compound is already atomic).

**Found live, fixed 2026-09-06: an earlier version never absorbed a separate paternal slot at
all** — a surname was multi-token ONLY when particle-led; an ordinary "Nombre ApellidoPaterno
ApellidoMaterno" record (no particle at all, the MORE common case) got just its last token
recognized as `surname`, with the paternal surname silently swept into `given` instead. Two
concrete, confirmed-live consequences:
- `"DANIEL M. GARCIA LOPEZ"` parsed as `given=["daniel","m"], surname=["lopez"]` -- the bare
  initial `"m"` then matched `"martinez"` via the given-alignment's bare-initial shortcut against
  `"DANIEL MARTINEZ LOPEZ"` (`given=["daniel","martinez"], surname=["lopez"]` under the OLD split),
  scoring a false PERFECT match (both surnames "lopez", `match=1.0`) between two different people
  who only coincidentally share a maternal surname.
- `"VICTOR MANUEL TORRES DE LA CRUZ"` parsed `surname=["de","la","cruz"]` only (paternal "torres"
  swept into `given`) -- coincidentally sharing that maternal-only surname with an unrelated
  `"Víctor Manuel Morales de la Cruz"` (`surname=["de","la","cruz"]` too) gave `surname_exact=1.0`
  for two different people whose real (paternal) surnames actually differ. With the fix, both
  records' surnames correctly include the paternal element (`"torres"`/`"morales"`), so
  `surname_a != surname_b` and the SURNAME check alone now rejects the pair. A related case,
  `"ALEJANDRA SANCHEZ GONZALEZ"`/`"Alejandro Sánchez González"`, also stops being a false match:
  the OLD split left `"sanchez"` in `given` on both sides, where its coincidental EXACT match
  pulled the given-alignment AVERAGE up to `0.944` (masking `"alejandra"`/`"alejandro"`'s `0.889`);
  with `"sanchez"` correctly recognized as (part of) the surname instead, each side's `given` list
  has just the ONE discriminating token, so the average IS that token's score (`0.889`, correctly
  below the connect threshold), with nothing left to average it against.
"""
function _split_given_surname(toks::Vector{String})
    n = length(toks)
    n == 0 && return (given=String[], surname=String[])
    n == 1 && return (given=String[], surname=toks)

    start2, unit2, is_y2 = _surname_unit_ending_at(toks, n)
    is_y2 && return (given=toks[1:start2-1], surname=[unit2])

    if start2 > 2
        start1, unit1, _ = _surname_unit_ending_at(toks, start2 - 1)
        start1 >= 2 && return (given=toks[1:start1-1], surname=[unit1, unit2])
    end
    return (given=toks[1:start2-1], surname=[unit2])
end

"""
    _surname_content(surname::Vector{String}) -> Vector{String}

Flattens a (possibly canonically hyphenated, see [`_split_given_surname`](@ref)) surname into its
real CONTENT words, for scoring purposes: splits every element on `"-"` and drops
[`_SURNAME_PARTICLES`](@ref) and the `"y"` conjunction, leaving only the words that actually carry
identity. `["torres", "de-la-cruz"]` -> `["torres", "cruz"]`; `["milian-y-avila"]` -> `["milian",
"avila"]`; a plain `["torres"]` (nothing hyphenated) passes through unchanged.

**Why scoring needs this separate from the canonical form `_split_given_surname` returns:** the
canonical form is what makes `"Milián y Ávila"` and `"de la Cruz"` stable, unambiguous IDENTITIES
(one bucket key, one vocabulary entry, one exact-match value) -- but real records are INCONSISTENT
about including the connector at all (`"Milián Ávila"`, dropping the `"y"`, is common shorthand for
the exact same surname). Comparing canonical forms directly would score `["milian-y-avila"]`
against `["milian","avila"]` as UNRELATED (different shapes, found live: this scored `0.0`, a
regression from even the pre-canonical-form behavior) purely because one happened to spell out the
connector and the other didn't. Flattening both to content-only words before comparing (paternal
vs paternal, maternal vs maternal, see [`_surname_typo_score`](@ref)) recovers the match `de la
Cruz`.
"""
function _surname_content(surname::Vector{String})
    words = String[]
    for s in surname
        for w in split(s, "-")
            (w in _SURNAME_PARTICLES || w == "y") && continue
            push!(words, w)
        end
    end
    return words
end

"""
    _collapse_self_annotations(toks::Vector{String}) -> Vector{String}

A bare initial immediately followed by its own expansion within the SAME raw name (e.g.
`"L. (Luis) Barron"` -> `[l, luis, barron]`) is one given-name concept written twice, not two
independent given names — collapse to the expansion so it doesn't inflate the given-token count
and force a real given name into competing for alignment against it (see
[`_align_given_tokens`](@ref)).
"""
function _collapse_self_annotations(toks::Vector{String})
    out = String[]
    i = 1
    while i <= length(toks)
        if i < length(toks) && length(toks[i]) == 1 && length(toks[i+1]) > 1 && toks[i][1] == first(toks[i+1])
            push!(out, toks[i+1])
            i += 2
        else
            push!(out, toks[i])
            i += 1
        end
    end
    return out
end

"""
    _qgram_name_tokens(raw::AbstractString) -> Vector{String}

Tokenizes `raw` the same way as [`name_keys`](@ref) (order-normalized, `AUTHOR_NAME_CONFIG`), then
[`_collapse_self_annotations`](@ref). Unlike [`_name_tokens`](@ref) (used by
[`_plausibly_same_person`](@ref)), this does NOT strip parenthetical content: for the q-gram
metric below, a citation-style parenthetical like `"(Alejandro)"` in `"Anaya, A. (Alejandro)"` is
real signal (`del_punc=true` already unwraps the parens on tokenizing, keeping `"alejandro"` as
its own token) — stripping it away was verified, while developing this metric, to tank the
similarity score for exactly this pair.

Memoized (see [`_TOKENS_CACHE`](@ref)): [`compute_name_clusters`](@ref) calls this on the SAME
raw name string thousands of times over (once per candidate pair it participates in within its
surname bucket), and re-tokenizing every time was, measured on the real full corpus's largest
bucket (`"hernandez"`, 12,615 names), most of the per-pair cost.
"""
function _qgram_name_tokens(raw::AbstractString)
    get!(_TOKENS_CACHE, raw) do
        _collapse_self_annotations(String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(raw)))))
    end
end

"""
    _TOKENS_CACHE

Memoization cache for [`_qgram_name_tokens`](@ref) — pure function of its input, so caching
indefinitely (never invalidated/cleared) is always correct, not just a "for now" shortcut. Grows
only while [`compute_name_clusters`](@ref) runs (a rebuild step, not a query-serving path), bounded
by the corpus's number of DISTINCT raw names — not a concern for a long-running server process.
NOT thread-safe: [`compute_name_clusters`](@ref)'s loops are sequential today; parallelizing them
would need a thread-safe cache (or one cache per thread) instead of this plain `Dict`.
"""
const _TOKENS_CACHE = Dict{String,Vector{String}}()

"""
    _name_qgrams(t::AbstractString; q::Int=4) -> Set{String}

Boundary-marked (`"^t\$"`) character `q`-grams of `t` — a token shorter than the padded window
becomes one literal element (covers bare initials at any `q`). Memoized (see
[`_QGRAMS_CACHE`](@ref)), same rationale and thread-safety caveat as [`_qgram_name_tokens`](@ref):
a token like `"hernandez"` or `"maria"` recurs across huge numbers of candidate pairs within one
surname bucket.
"""
function _name_qgrams(t::AbstractString; q::Int=4)
    get!(_QGRAMS_CACHE, (t, q)) do
        padded = collect("^" * t * "\$")
        length(padded) < q ? Set([String(padded)]) :
            Set(String(padded[i:i+q-1]) for i in 1:(length(padded)-q+1))
    end
end

"""
    _QGRAMS_CACHE

Memoization cache for [`_name_qgrams`](@ref) — see [`_TOKENS_CACHE`](@ref)'s docstring, same
rationale applies verbatim.
"""
const _QGRAMS_CACHE = Dict{Tuple{String,Int},Set{String}}()

"""
    _qgram_jaccard(a::AbstractString, b::AbstractString) -> Float64

Jaccard similarity of `a` and `b`'s [`_name_qgrams`](@ref) — character-level, so misspellings and
transliteration variants (e.g. `"Fedorovish"`/`"Federovish"`) still overlap meaningfully even
without an exact match.
"""
function _qgram_jaccard(a::AbstractString, b::AbstractString)
    qa, qb = _name_qgrams(a), _name_qgrams(b)
    u = length(union(qa, qb))
    u == 0 ? 0.0 : length(intersect(qa, qb)) / u
end

"""
    _token_alignment_score(a::AbstractString, b::AbstractString) -> Float64

Pairwise (never pooled into a bag) compatibility of two given-name tokens: exact match (`1.0`), a
REAL (not synthetic) bare initial matching the other's first letter (`1.0`/`0.0`), or
[`_qgram_jaccard`](@ref) for typo/spelling-variant tolerance. No position restriction on the
bare-initial shortcut — safe here specifically because a length-1 token can only come from genuine
raw-data abbreviation, never from a synthesized initial (this design never enriches/synthesizes
initials from spelled-out names — an earlier, rejected bag-of-q-grams design did, and that's
exactly what let two different people sharing a coincidental first letter collide).

Memoized at the level of the FULL pairwise score (see [`_TOKEN_SCORE_CACHE`](@ref)), not just the
underlying q-gram sets: a token pair like `"maria"`/`"jose"` recurs across huge numbers of NAME
pairs within one surname bucket (every "Maria ..." name against every "Jose ..." name sharing that
surname), and caching only the q-gram sets still leaves the `union`/`intersect` work to redo on
every occurrence. Measured together with [`_qgram_name_tokens`](@ref)/[`_name_qgrams`](@ref)'s
caching, this cut real full-corpus benchmark time by ~5.75x on the largest real bucket (a 1,500-
name sample of `"hernandez"`: 46.4s -> 8.1s, identical edge count both times).
"""
function _token_alignment_score(a::AbstractString, b::AbstractString)
    a == b && return 1.0
    length(a) == 1 && !isempty(b) && return a[1] == first(b) ? 1.0 : 0.0
    length(b) == 1 && !isempty(a) && return b[1] == first(a) ? 1.0 : 0.0
    key = a <= b ? (a, b) : (b, a)  # _qgram_jaccard is symmetric; canonicalize to double the hit rate
    get!(() -> _qgram_jaccard(a, b), _TOKEN_SCORE_CACHE, key)
end

"""
    _TOKEN_SCORE_CACHE

Memoization cache for [`_token_alignment_score`](@ref)'s non-trivial (q-gram) branch — see
[`_TOKENS_CACHE`](@ref)'s docstring, same rationale and thread-safety caveat apply verbatim.
"""
const _TOKEN_SCORE_CACHE = Dict{Tuple{String,String},Float64}()

"""
    _align_given_tokens(short::Vector{String}, long::Vector{String}) -> Vector{Tuple{String,String,Float64}}

Bipartite greedy alignment of `short`'s tokens against `long`'s (one-to-one, tolerant of
dropped/reordered middle names): for each token in `short`, attribute the best-scoring REMAINING
candidate in `long` via [`_token_alignment_score`](@ref), even at score `0.0` — "no candidate beat
the initial floor" must never collapse into "no partner exists to compare against": a token that
matches nothing (score `0.0` against every remaining option) is itself the contradiction signal
[`_name_cluster_contradiction`](@ref) needs, not an absence of one.
"""
function _align_given_tokens(short::Vector{String}, long::Vector{String})
    used = falses(length(long))
    pairs = Tuple{String,String,Float64}[]
    for st in short
        best_j, best_s = 0, -1.0
        for (j, lt) in enumerate(long)
            used[j] && continue
            s = _token_alignment_score(st, lt)
            s > best_s && ((best_s, best_j) = (s, j))
        end
        if best_j > 0
            used[best_j] = true
            push!(pairs, (st, long[best_j], best_s))
        else
            push!(pairs, (st, "", 0.0))
        end
    end
    return pairs
end

"""
    _surname_typo_score(content_a::Vector{String}, content_b::Vector{String}) -> Float64

Typo/spelling-variant tolerance for a surname -- the fuzzy fallback `surname` falls back to when
the surname content isn't EXACTLY equal on both sides. Takes FLATTENED, connector-free content
(see [`_surname_content`](@ref) -- NOT the canonical, possibly-hyphenated form
[`_split_given_surname`](@ref) returns). Scores the PATERNAL word (`content[1]`) and the MATERNAL
remainder (`content[2:end]`, joined) SEPARATELY, then takes their MINIMUM -- NOT one score over
the whole phrase joined together.

**Found live, fixed 2026-09-07: joining the whole surname into one phrase before scoring lets a
long SHARED token mask a real difference in the other one.** Once the paternal-surname-absorption
fix made a genuine 2-token surname the norm, two DIFFERENT people who happen to share one of the
two tokens started scoring a deceptively high `_qgram_jaccard` over the joined phrase -- confirmed
live on the real 10-repo corpus: `"MIGUEL ANGEL RODRIGUEZ RODRIGUEZ"` (paternal `"rodriguez"`,
maternal `"rodriguez"`) against the unrelated `"MIGUEL ANGEL SANCHEZ RODRIGUEZ"` (paternal
`"sanchez"`, maternal `"rodriguez"`) shares the ENTIRE maternal word `"rodriguez"` (9 letters)
against only a 7-letter difference in the paternal token, so `_qgram_jaccard("rodriguez rodriguez",
"sanchez rodriguez")` scores well above this module's `0.5` phase-1 bar despite the two people's
real (paternal) surnames being completely different -- introduced 26 new false positives against a
mined ground truth that weren't there before the paternal-surname fix. Scoring paternal and
maternal separately and taking the MINIMUM means a mismatch in EITHER position drags the whole
score down regardless of how well the other one matches, exactly mirroring how
[`_name_cluster_contradiction`](@ref) already treats a per-position given-name mismatch as decisive
rather than something an aggregate average can launder away.

**Operates on FLATTENED content, not the canonical hyphenated form, for a second reason found live
2026-09-07:** comparing canonical forms directly breaks exactly the connector-omission variance
real records have -- `["milian-y-avila"]` (one atomic element) against `["milian","avila"]` (the
same surname, "y" just not written out) have different SHAPES, so a positional paternal/maternal
split over the canonical elements themselves scored this pair `0.0` (worse than before the
canonical form existed at all). Flattening both to `["milian","avila"]` first makes them
comparable regardless of which one spelled out the connector.

When one side has no maternal component at all (`length(content) == 1`) and the other does, the
comparison here is asymmetric (empty vs non-empty) and scores `0.0` for that half -- this is
`_surname_typo`'s territory, not `trunc`'s: a genuine ONE-paternal-word-only truncation is caught
separately by `trunc` (via matching `content[1]`s directly) before this function's result is even
consulted (`surname = max(surname_exact, trunc, surname_typo)`), so this function returning `0.0`
for that shape doesn't cost anything already covered elsewhere.
"""
function _surname_typo_score(content_a::Vector{String}, content_b::Vector{String})
    paternal_score = _qgram_jaccard(content_a[1], content_b[1])
    maternal_a, maternal_b = @view(content_a[2:end]), @view(content_b[2:end])
    maternal_score = if isempty(maternal_a) && isempty(maternal_b)
        1.0
    elseif isempty(maternal_a) || isempty(maternal_b)
        0.0
    else
        _qgram_jaccard(join(maternal_a, " "), join(maternal_b, " "))
    end
    return min(paternal_score, maternal_score)
end

"""
    _is_garbage_name(nm::AbstractString) -> Bool

True for a raw "name" that's actually a bare URL/ORCID literal or digit string — TextSearch's
tokenizer normalizes any URL to a literal `"url"` placeholder and any digit run to `"0"`, so
different garbage ORCID/URL "names" collapse to identical tokens (the root cause of a pre-existing
117-member `"_url"` blob previously produced by `full_key`/`initials_key`). Checked at the raw-
string level, before tokenizing, in [`_name_match_score`](@ref).
"""
_is_garbage_name(nm::AbstractString) = occursin(r"^https?://|orcid|^[\d\-]+$"i, nm)

"""
    _name_match_score(name_a, name_b) -> (; match, mismatch_frac, surname, pairs)

Character-q-gram-based name-similarity metric backing [`compute_name_clusters`](@ref) — the
name-based clustering signal, replacing `full_key`/`initials_key` exact matching. This does NOT
replace [`_plausibly_same_person`](@ref), which keeps doing its own, different job: vetoing
*content*-similarity candidates in [`compute_similarity_merges`](@ref).

`surname`: exact match, truncation-aware (a full "Nombre ApellidoPaterno ApellidoMaterno" record's
PATERNAL surname -- the first FLATTENED content word, see [`_surname_content`](@ref) -- against
another record's single, truncated surname, i.e. one side dropped its maternal surname entirely),
or q-gram typo-tolerant score, for the (possibly compound) surname. `match`: mean per-token
alignment score ([`_align_given_tokens`](@ref)) of the SHORTER given-name list — generous to
truncation, since extra tokens on the longer side never enter the denominator. `mismatch_frac`:
fraction of the shorter given-name list's tokens whose best partner scored below `0.3` — a
separate, explicit penalty axis instead of folding "found nothing" into the same ratio as "found
something so-so". `pairs`: the raw per-position `(token_a, token_b, score)` triples, used by
[`_name_cluster_contradiction`](@ref) to catch a hard mismatch an aggregate score can launder away
via a shared incidental token (e.g. two different people who happen to share a middle name).

Guards against garbage input (see [`_is_garbage_name`](@ref)) and against a degenerate
single-character surname head (e.g. a digit run normalized to a literal `"0"`) ever counting as a
match — the same failure mode [`_plausibly_same_person`](@ref) guards against.
"""
function _name_match_score(name_a::AbstractString, name_b::AbstractString)
    (_is_garbage_name(name_a) || _is_garbage_name(name_b)) &&
        return (match=0.0, mismatch_frac=1.0, surname=0.0, pairs=Tuple{String,String,Float64}[])
    toks_a, toks_b = _qgram_name_tokens(name_a), _qgram_name_tokens(name_b)
    (isempty(toks_a) || isempty(toks_b)) &&
        return (match=0.0, mismatch_frac=1.0, surname=0.0, pairs=Tuple{String,String,Float64}[])
    split_a, split_b = _split_given_surname(toks_a), _split_given_surname(toks_b)
    given_a, given_b = split_a.given, split_b.given
    content_a, content_b = _surname_content(split_a.surname), _surname_content(split_b.surname)
    valid_a = length(toks_a[end]) >= 2  # garbage guard: a degenerate single-char surname head
    valid_b = length(toks_b[end]) >= 2  # (e.g. a digit-run normalized to "0") must never count as a match
    surname_exact = (valid_a && valid_b && content_a == content_b) ? 1.0 : 0.0
    # a SHORT surname (length 1 -- no maternal recorded at all, not a specific different one) is a
    # truncation of a longer one iff its word matches EITHER end of the longer side's compound
    # content -- the paternal position (content[1], the common case: maternal was dropped) OR the
    # maternal/tail position (content[end]). The second arm matters because paternal-surname
    # absorption cannot always tell a real paternal surname from an ordinary compound GIVEN name
    # from token position alone (e.g. "Allyson Lucinda Benton" -- "Lucinda" absorbed as if it were
    # a paternal surname candidate, alongside the real surname "Benton"); checking both ends
    # recovers the truncation match via whichever end happens to hold the name that's actually
    # shared, without having to resolve that ambiguity. Two fully-specified surnames of length >= 2
    # each never hit this: a shared word at either end with a genuinely different rest is two
    # different people, not a truncation, and is left to surname_typo's fuzzy score instead.
    trunc = (valid_a && valid_b && (length(content_a) == 1 || length(content_b) == 1) &&
             (content_a[1] == content_b[1] || content_a[end] == content_b[end])) ? 1.0 : 0.0
    surname_typo = (valid_a && valid_b) ? _surname_typo_score(content_a, content_b) : 0.0
    surname = max(surname_exact, trunc, surname_typo)
    if isempty(given_a) && isempty(given_b)
        return (match=1.0, mismatch_frac=0.0, surname=surname, pairs=Tuple{String,String,Float64}[])
    elseif isempty(given_a) || isempty(given_b)
        return (match=0.0, mismatch_frac=1.0, surname=surname, pairs=Tuple{String,String,Float64}[])
    end
    shorter, longer = length(given_a) <= length(given_b) ? (given_a, given_b) : (given_b, given_a)
    pairs = _align_given_tokens(shorter, longer)
    scores = [p[3] for p in pairs]
    return (match=sum(scores) / length(scores), mismatch_frac=count(<(0.3), scores) / length(scores),
            surname=surname, pairs=pairs)
end

"""
    _name_cluster_keys(raw::AbstractString) -> Vector{String}

Candidate-generation buckets for [`compute_name_clusters`](@ref) (efficiency only, not a
correctness decision — the actual connect-or-not decision is [`_name_match_score`](@ref), an
absolute fixed-threshold score unaffected by what else shares a bucket; see
[`compute_name_clusters`](@ref)'s docstring for why that distinction matters). Built from
[`_surname_content`](@ref) (FLATTENED, connector-free content -- not the canonical, possibly
hyphenated form [`_split_given_surname`](@ref) returns): two keys, (1) the last content word —
always correct for a record's own surname (keeps an ordinary "First Middle Last" person, e.g.
`"Allyson Lucinda Benton"`, correctly bucketed under `"benton"` regardless of whether `"Lucinda"`
got absorbed as a paternal-surname candidate or not); and (2) the first content word (when there
are 2+) — needed so a full "Nombre ApellidoPaterno ApellidoMaterno" record and its truncated
single-surname form still share a bucket even when the maternal side is itself a compound
(`"Torres De La Cruz"` — bucketing only by the last content word `"cruz"` would never match a
truncated `"Torres"` record). Using flattened content rather than the canonical form here is
deliberate: it also buckets a plain `"Cruz"` together with a compound `"De La Cruz"` even when
those particle words are missing/typo'd on one side, at the cost of a candidate pair
[`_name_match_score`](@ref) may still reject -- exactly the kind of over-inclusive-but-cheap net
this function already exists for.
"""
function _name_cluster_keys(raw::AbstractString)
    toks = _qgram_name_tokens(raw)
    isempty(toks) && return String[]
    (; surname) = _split_given_surname(toks)
    content = _surname_content(surname)
    isempty(content) && return String[]
    keys = [content[end]]
    length(content) >= 2 && push!(keys, content[1])
    return unique(keys)
end

const _NAME_CLUSTER_MATCH_THRESHOLD = 0.5
const _NAME_CLUSTER_SURNAME_THRESHOLD = 0.5

"""
    _name_cluster_edge(a, b) -> Bool

Phase 1 (clustering, RECALL-oriented) test for [`compute_name_clusters`](@ref): connect `a`/`b` if
[`_name_match_score`](@ref) clears a GENEROUS bar — tolerant of typos/transliteration variants a
strict veto would miss (e.g. `"Fedorovish"`/`"Federovish"`, q-gram overlap only 0.38 on that one
token, well under any "confident" bar, but not zero either).
"""
function _name_cluster_edge(a::AbstractString, b::AbstractString)
    r = _name_match_score(a, b)
    r.surname >= _NAME_CLUSTER_SURNAME_THRESHOLD && r.match >= _NAME_CLUSTER_MATCH_THRESHOLD
end

const _NAME_CLUSTER_CONTRADICTION_FLOOR = 0.2

"""
    _name_cluster_contradiction(names) -> Union{Tuple{String,String},Nothing}

Phase 2 (oracle, PRECISION-oriented) for [`compute_name_clusters`](@ref): a phase-1 cluster stays
merged by DEFAULT — this only reports a split-worthy counter-example when it finds one, checking
EVERY pair in `names` (not just phase-1 edges) for either of two kinds of hard evidence:

1. A low DIRECT [`_name_match_score`](@ref) surname score between the two specific members —
   surname incompatibility between two names IS the contradiction, not a precondition to skip
   before looking for one (an earlier version treated it as the latter, which missed real
   contradictions introduced by phase-1 mechanisms that don't independently gate on surname the
   way [`_name_cluster_edge`](@ref) does, and also under-protects the current exact-loop phase 1
   against transitive chaining through a truncation bridge: A-B and B-C each individually
   plausible via a different truncation relationship, but A and C incompatible with each other).
2. Two given-name tokens, at some aligned position, both fully spelled out (neither a bare
   initial) and scoring below `_NAME_CLUSTER_CONTRADICTION_FLOOR` — clearly different words, not a
   spelling variant. Checked per POSITION rather than via the aggregate `match` score — a shared
   incidental token (e.g. a common middle name) must never launder away a hard mismatch elsewhere
   in the alignment (found live: `"MANUEL ALBERTO CHAVEZ GONZALEZ"` vs `"MARIA ANTONIETA CHAVEZ
   GONZALEZ"` share the literal token `"chavez"` in given-name position, which pulled the AVERAGE
   match score to 0.333 — above a 0.2 floor — even though `"manuel"`/`"maria"` at the
   discriminating position score near zero).

This asymmetry is deliberate: proving two names the SAME is hard (this module's whole reason to
exist); proving them DIFFERENT, when the evidence is this stark, is not.
"""
function _name_cluster_contradiction(names::Vector{String})
    for i in 1:length(names), j in (i+1):length(names)
        r = _name_match_score(names[i], names[j])
        # A low DIRECT surname score between two members of the SAME cluster is itself a hard
        # contradiction, not a reason to skip this pair — found live while validating an
        # alternative phase-1 mechanism whose connection criterion doesn't independently gate on
        # surname the way _name_cluster_edge does: two people sharing only a coincidental
        # paternal-surname-candidate token ("moreno") but with genuinely different real surnames
        # ("Galván" vs "Rivas") ended up in the same component with no direct edge requiring
        # surname compatibility between THEM specifically. This also hardens the CURRENT
        # exact-loop phase 1 against transitive chaining through a truncation bridge (A-B and B-C
        # each individually plausible via a different truncation relationship, but A and C
        # incompatible with each other) — the same class of bug `initials_key`'s bare-initial
        # bridging caused originally, just one hop further away, so worth checking regardless of
        # how phase 1 connected this component.
        r.surname >= _NAME_CLUSTER_SURNAME_THRESHOLD || return (names[i], names[j])
        for (ta, tb, s) in r.pairs
            if length(ta) > 1 && length(tb) > 1 && s < _NAME_CLUSTER_CONTRADICTION_FLOOR
                return (names[i], names[j])
            end
        end
    end
    return nothing
end

"""
    _name_cluster_strict_compatible(a, b) -> Bool

Stricter pairwise test used only by [`_name_cluster_split`](@ref), once a cluster has already been
flagged by [`_name_cluster_contradiction`](@ref) — thresholds validated against a mined ground
truth (2,842 good / 22,785 bad pairs, real 10-repo corpus): FP≈0.14%, FN≈0.14%.
"""
function _name_cluster_strict_compatible(a::AbstractString, b::AbstractString)
    r = _name_match_score(a, b)
    r.surname >= 0.5 && r.match >= 0.9
end

"""
    _name_cluster_split(names::Vector{String}) -> Vector{Vector{String}}

Greedy re-partition of a contradiction-flagged component using
[`_name_cluster_strict_compatible`](@ref) as a must-link test — a name joins an EXISTING
sub-cluster only if compatible with EVERY member already in it (not just one), which is what
actually prevents transitive chaining through a bridge name (the exact failure mode that broke an
earlier, rejected attempt at bucketing [`compute_similarity_merges`](@ref) by surname — see that
function's docstring). This is a GREEDY, ORDER-DEPENDENT heuristic (processes `names` in sorted
order, joins the first compatible existing sub-cluster) — not a general correlation-clustering
solver; it can rarely miss an obviously-correct merge depending on processing order. Judged a lower
priority to fix than a precision bug: a missed merge is recoverable (a later rebuild, or a manual
`author_overrides.toml` entry); a false merge is not.

A second, related source of missed merges (not just processing order): a component only reaches
this function at all once [`_name_cluster_contradiction`](@ref) has flagged it, and reconnection
here then requires [`_name_cluster_strict_compatible`](@ref)'s stricter `match >= 0.9` — well above
[`_name_cluster_edge`](@ref)'s generous `match >= 0.5` that connected the pair in the first place.
A genuine typo/transliteration variant can clear the generous phase-1 bar but not the strict
reconnection one: found live, `"VCTOR H. BALTAZAR-HERNANDEZ"` / `"VICTOR HUGO BALTAZAR HERNANDEZ"`
score `match=0.762` (well above 0.5, comfortably connected at phase 1) but below 0.9, so once
their (huge, 3,815-member, real 10-repo corpus) shared component got flagged for a split by some
OTHER unrelated contradiction inside it, these two ended up in separate final singletons despite
being an obvious match. Confirmed the split itself is otherwise healthy in this case (the same
3,815-member component correctly decomposed into 3,150 final groups, largest size 8 — no residual
giant blobs) — this is a narrow, specific recall cost of the two-tier threshold design, not a sign
the splitter is failing at its main job.
"""
function _name_cluster_split(names::Vector{String})
    clusters = Vector{Vector{String}}()
    for nm in sort(names)
        placed = false
        for c in clusters
            if all(m -> _name_cluster_strict_compatible(nm, m), c)
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
    compute_name_clusters(raw_names::Vector{String}) -> Vector{Vector{String}}

Groups `raw_names` by a two-phase, name-only (no profile content — see
[`compute_similarity_merges`](@ref) for the separate content-based signal) matching design,
replacing `full_key`/`initials_key` exact-match clustering as [`compute_groups`](@ref)'s name-based
signal: [`_name_cluster_edge`](@ref) (generous, recall-oriented, via q-gram similarity) proposes
connections within cheap candidate buckets ([`_name_cluster_keys`](@ref)); every resulting
component then goes through [`_name_cluster_contradiction`](@ref)/[`_name_cluster_split`](@ref)
(precision-oriented) — a component stays merged UNLESS the oracle finds a genuine counter-example
inside it.

Built to replace `full_key`/`initials_key`, which silently merged different people sharing two
initials plus a surname (e.g. `"JOSE CAMARGO PEREZ"`/`"JUAN CONTRERAS PEREZ"`/`"JULIO CANDELA
PEREZ"` all reduced to the same `initials_key`). Validated end-to-end on a real 10-repo corpus
(19,543 names) against a mined ground truth: this design correctly separates that exact case, plus
the harder `"MANUEL ALBERTO CHAVEZ GONZALEZ"`/`"MARIA ANTONIETA CHAVEZ GONZALEZ"` case (identical
double surname, different given name), while still merging real typo/transliteration variants
(`"Fedorovish"`/`"Federovish"`) pure exact-key matching would have missed too. End-to-end error
rate: FN≈0.35% (2,842 known-good pairs), FP≈0.18% (22,785 known-bad pairs) — both far lower than a
standalone (non-content-gated) `_plausibly_same_person` achieves at the same job (an earlier,
rejected replacement attempt grew max group size from ~10 to 76).

`_name_cluster_keys` bucketing is an efficiency step only — the earlier surname-bucketing failure
documented in [`compute_similarity_merges`](@ref)'s docstring does NOT apply here: that failure
came from bucketing an ADAPTIVE, population-relative similarity signal (`bichromatic_metricjoin`'s
per-point quantile threshold), which shifts meaning depending on what population it's given;
[`_name_match_score`](@ref) is an ABSOLUTE fixed threshold, unaffected by what else shares a
candidate bucket.

Known, accepted limitations (not chased further without new evidence):
- [`_name_cluster_split`](@ref)'s greedy partition is order-dependent — a rare recall cost, not a
  precision one.
- The "drop the paternal surname entirely, keep only the maternal" truncation direction is
  unhandled (asymmetric with the handled direction — `"Juan Tellez Avila"` -> `"Juan Tellez"`
  truncates correctly, keeping the paternal surname per convention, but e.g. `"Edgar Eugenio
  Ramírez de la Cruz"` -> `"Edgar Cruz"`, dropping the paternal surname and keeping only the
  compound maternal surname's head word, does not match).
- [`_SURNAME_PARTICLES`](@ref) is not exhaustively validated (see its docstring).
- Not fast: on the real 10-repo development corpus (19,543 raw names), a full
  `reposmx consolidate-authors` run (this clustering plus everything else that command does —
  content-similarity join, RocksDB persistence, BM25 rebuilds) took ~10 minutes. Full-corpus
  (~95-repo) runtime has not been measured; a very large candidate bucket (a common surname across
  the whole corpus) could make the O(bucket²) phase-1 pass slower still. Revisit if it actually
  turns out to be a problem, same policy as [`compute_similarity_merges`](@ref)'s own bucketing
  note — correctness came first here too.
"""
function compute_name_clusters(raw_names::Vector{String})
    n = length(raw_names)
    n == 0 && return Vector{Vector{String}}()
    idx = Dict(nm => i for (i, nm) in enumerate(raw_names))

    candidate_buckets = Dict{String,Vector{String}}()
    for nm in raw_names
        for k in _name_cluster_keys(nm)
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

    _log(msg) = (println(msg); flush(stdout))

    n_buckets = length(candidate_buckets)
    _log("  compute_name_clusters: $n_buckets buckets, largest=$(isempty(candidate_buckets) ? 0 : maximum(length, values(candidate_buckets)))")
    t_phase1 = time()
    for (bi, (_, bucket)) in enumerate(candidate_buckets)
        bucket = unique(bucket)
        length(bucket) < 2 && continue
        for i in 1:length(bucket), j in (i+1):length(bucket)
            a, b = bucket[i], bucket[j]
            _name_cluster_edge(a, b) && uf_union!(idx[a], idx[b])
        end
        if bi % 2000 == 0
            _log("  compute_name_clusters: phase1 bucket $bi/$n_buckets, elapsed=$(round(time()-t_phase1,digits=1))s")
        end
    end
    _log("  compute_name_clusters: phase1 done, elapsed=$(round(time()-t_phase1,digits=1))s")

    by_root = Dict{Int,Vector{String}}()
    for nm in raw_names
        push!(get!(by_root, uf_find(idx[nm]), String[]), nm)
    end
    comp_sizes = sort(length.(values(by_root)); rev=true)
    _log("  compute_name_clusters: $(length(by_root)) components, largest sizes=$(comp_sizes[1:min(10,end)])")

    groups = Vector{Vector{String}}()
    t_oracle = time()
    for (ci, (_, comp)) in enumerate(by_root)
        if length(comp) == 1
            push!(groups, comp)
            continue
        end
        big = length(comp) > 50
        big && _log("  compute_name_clusters: oracle on component #$ci, size=$(length(comp))...")
        t_comp = time()
        cx = _name_cluster_contradiction(comp)
        if cx === nothing
            push!(groups, comp)
        else
            append!(groups, _name_cluster_split(comp))
        end
        big && _log("  compute_name_clusters: component #$ci done, elapsed=$(round(time()-t_comp,digits=1))s")
    end
    _log("  compute_name_clusters: oracle phase done, elapsed=$(round(time()-t_oracle,digits=1))s")
    return groups
end

"""
    compute_groups(raw_names::Vector{String}, overrides) -> Vector{Vector{String}}

Connected components of the graph whose nodes are `raw_names` and whose edges are: same name
cluster (see [`compute_name_clusters`](@ref) — replaces the earlier `full_key`/`initials_key`
exact-match signal), or an explicit `merge`/`impute` pair — minus any explicit `split` pair.
Overrides are applied AFTER clustering, unconditionally (never re-checked by the oracle): a human
`merge` forces an edge the algorithm couldn't find on its own, and a human `split` removes one it
shouldn't have made — neither should be second-guessed by [`_name_cluster_contradiction`](@ref).
`impute` is mechanically IDENTICAL to `merge` (a forced edge, same as-is treatment) — the only
difference is who writes that section of the overrides file: a person edits `merge`/`split` by
hand, a separate (not-yet-implemented) recall-oriented pass computes and rewrites `impute` on its
own each run (see [`load_overrides`](@ref)/the module docstring's persistence-format note). Plain
BFS over an adjacency `Dict`, no graph library needed.
"""
function compute_groups(raw_names::Vector{String}, overrides)
    adj = Dict{String,Vector{String}}(n => String[] for n in raw_names)

    connect!(a, b) = begin
        a == b && return
        push!(adj[a], b)
        push!(adj[b], a)
    end

    for group in compute_name_clusters(raw_names)
        for i in 1:length(group), j in (i+1):length(group)
            connect!(group[i], group[j])
        end
    end
    for g in Iterators.flatten((overrides.merges, overrides.imputes))
        present = filter(n -> haskey(adj, n), g)
        for i in 1:length(present), j in (i+1):length(present)
            connect!(present[i], present[j])
        end
    end

    excluded = Set{Tuple{String,String}}()
    for (a, b) in overrides.splits
        push!(excluded, (a, b))
        push!(excluded, (b, a))
    end
    if !isempty(excluded)
        for n in keys(adj)
            adj[n] = filter(m -> !((n, m) in excluded), adj[n])
        end
    end

    visited = Set{String}()
    groups = Vector{Vector{String}}()
    for n in raw_names
        n in visited && continue
        comp = String[]
        queue = [n]
        push!(visited, n)
        while !isempty(queue)
            cur = popfirst!(queue)
            push!(comp, cur)
            for m in adj[cur]
                if !(m in visited)
                    push!(visited, m)
                    push!(queue, m)
                end
            end
        end
        push!(groups, comp)
    end
    return groups
end

"""
    _surname_of_name(raw::AbstractString) -> String

Last tokenized word of `raw` (order-normalized, same `AUTHOR_NAME_CONFIG` tokenization as
[`name_keys`](@ref)) — the "apellido" convention already implicit in `initials_key`, factored
out here since both [`_bucket_for`](@ref) (one name) and [`compute_similarity_merges`](@ref)
(pairs of names) need it.
"""
function _surname_of_name(raw::AbstractString)
    toks = String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(raw))))
    isempty(toks) ? "" : toks[end]
end

"""
    _strip_parenthetical(s::AbstractString) -> String

Removes any "(...)" span. A citation-style raw name like `"Anaya, A. (Alejandro)"` redundantly
spells out the abbreviated given name in parentheses — left in, `"(Alejandro)"` tokenizes into
its own given-name token, making a genuine match (`"Alejandro Anaya"`) look like it has a
different number of given-name components than the abbreviated form. Stripped before tokenizing
in [`_name_tokens`](@ref) so both forms reduce to the same given-name token.
"""
_strip_parenthetical(s::AbstractString) = replace(s, r"\([^)]*\)" => "")

"""
    _name_tokens(raw::AbstractString) -> (given::Vector{String}, surname::String)

`raw`, order-normalized and parenthetical-stripped, tokenized (same `AUTHOR_NAME_CONFIG` as
[`name_keys`](@ref)) and split into given-name tokens (all but the last) and surname (the last
one, matching [`_surname_of_name`](@ref)/`initials_key`'s "apellido" convention).
"""
function _name_tokens(raw::AbstractString)
    toks = String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(_strip_parenthetical(raw)))))
    isempty(toks) && return (String[], "")
    return (toks[1:end-1], toks[end])
end

"""
    _given_name_token_compatible(a, b) -> Bool

Two given-name tokens are compatible if they're equal, or if one is a single-character initial
matching the other's first letter (e.g. `"j"` / `"juan"`) — but NOT merely sharing a first
letter (`"juan"` vs `"julio"` is `false`): that distinction is exactly what separates a real name
abbreviation from two different people who happen to start with the same letter.
"""
function _given_name_token_compatible(a::AbstractString, b::AbstractString)
    a == b && return true
    (length(a) == 1 && !isempty(b) && a[1] == first(b)) && return true
    (length(b) == 1 && !isempty(a) && b[1] == first(a)) && return true
    return false
end

"""
    _surnames_plausibly_match(given_a, surname_a, given_b, surname_b) -> Bool

Surname half of [`_plausibly_same_person`](@ref)'s gate. This corpus mixes two real, common
conventions for the *same* researcher's name across different raw records: the full Mexican form
("Nombre[s] ApellidoPaterno ApellidoMaterno" — tokenized here as `given` ending with the paternal
surname, `surname` holding the maternal one) and a single-surname form the same person is often
recorded under internationally ("Nombre Apellido" — `given` is just the given name(s), `surname`
holds the one reported surname). A hyphenated combined surname like `"Tellez-Avila"` tokenizes
into the same two tokens as `"Tellez Avila"` (the tokenizer treats `-` as a separator, verified
elsewhere in this module), so it's already the full-form case, not a third one to handle here.

Mixing full and single-surname records for the same person can never share an exact last-token
surname (`"avila" != "tellez"`), so on top of requiring an exact match, this also accepts a
single-surname name (`length(given) == 1`) whose one surname equals the *other* name's paternal
surname (`given[end]`, when that other name has 2+ given-position tokens) — the surname a Mexican
researcher keeps when publishing under the single-surname convention is, by convention, the
paternal one, never the maternal. Both sides of every comparison still require `length >= 2` (see
[`_plausibly_same_person`](@ref)'s docstring on why: garbage data degenerating to single-character
tokens must never count as a match).
"""
function _surnames_plausibly_match(given_a::Vector{String}, surname_a::AbstractString,
                                    given_b::Vector{String}, surname_b::AbstractString)
    length(surname_a) >= 2 && length(surname_b) >= 2 && surname_a == surname_b && return true
    length(given_a) == 1 && length(given_b) >= 2 && length(surname_a) >= 2 && surname_a == given_b[end] && return true
    length(given_b) == 1 && length(given_a) >= 2 && length(surname_b) >= 2 && surname_b == given_a[end] && return true
    return false
end

"""
    _plausibly_same_person(name_a, name_b) -> Bool

Name-based gate for [`compute_similarity_merges`](@ref): requires the surname to plausibly match
(exact last-token match, or a full-vs-single-surname truncation — see
[`_surnames_plausibly_match`](@ref)), and the **first given-name token** to be equal or an
initial-abbreviation of the other's (see [`_given_name_token_compatible`](@ref)) —  deliberately
does not require every given-name token to match, since middle names are routinely dropped or
added between how the same person's name appears in different raw records (e.g. `"Jewel Todd"`
vs `"JEWEL NICOLE ANNA TODD"`).

Two weaker gates were tried and rejected empirically, on a real 10-repo rebuild, before landing
on this one:
- **surname alone**: let through pairs like `("A. Alberto R. Fernandes", "PATRICIA FERNANDES")`
  and `("ADDY LETICIA ZARZA GARCIA", "Jesús Ortega García")` — different people sharing only a
  common (often maternal, in the "Nombre ApellidoPaterno ApellidoMaterno" convention the
  last-token rule picks up) surname.
- **surname + bare first-letter-of-first-token**: still let through clusters of clearly
  different people sharing a common surname (Pérez, González, Hernández...) and a coincidental
  first initial — e.g. `("JHON LEANDRO PEREZ", "JULIO CESAR PEREZ PEREZ")` and
  `("RIGOBERTO ORTEGA PEREZ", "RODOLFO ORTIZ PEREZ")` all pass a bare "same starting letter"
  check, but none of those given names is actually an abbreviation of the other.

This version rejects every one of those while still passing genuine variants like
`("Juan Antonio Garcia Lopez", "J. A. Garcia-Lopez")`, citation-style forms like
`("Alejandro Anaya", "Anaya, A. (Alejandro)")`, and — via
[`_surnames_plausibly_match`](@ref) — a Mexican double-surname record next to that same person's
single-surname (paternal-only) record, e.g. `("Juan Tellez Avila", "Juan Tellez")`, without also
accepting two different people who each have one of the two surnames but in swapped
paternal/maternal roles, e.g. `("Juan Perez Gomez", "Juan Gomez Hernandez")` (still rejected: both
are full two-surname forms, so only the exact-match rule applies, and `"gomez" != "hernandez"`).
"""
function _plausibly_same_person(name_a::AbstractString, name_b::AbstractString)
    given_a, surname_a = _name_tokens(name_a)
    given_b, surname_b = _name_tokens(name_b)
    (!isempty(given_a) && !isempty(given_b)) || return false
    _surnames_plausibly_match(given_a, surname_a, given_b, surname_b) || return false
    _given_name_token_compatible(given_a[1], given_b[1])
end

function _bucket_for(raw_names_in_group::Vector{String})
    s = _surname_of_name(sort(raw_names_in_group)[1])
    isempty(s) ? "misc" : s
end

"""
    _short_hash(n_digits, parts) -> String

Deterministic `n_digits`-digit numeric string from the first 32 bits of `sha256(join(parts, sep))`
— `parts` sorted/deduped by the caller so the result depends only on the *set* of inputs. Not
cryptographic; just a small, stable fingerprint (this project already depends on `SHA`, no new dep).
"""
function _short_hash(n_digits::Int, parts::Vector{String})
    h = bytes2hex(sha256(join(parts, "\x1f")))  # \x1f: unit separator, won't appear in real names
    v = parse(UInt32, h[1:8]; base=16)
    lpad(string(v % 10^n_digits), n_digits, '0')
end

"""
    assign_id(names, institutions, used_ids, disambig_digits) -> (id::String, collided::Bool)

Short, readable id: `<apellido>_<hash de 4 dígitos>` de `names` (el o los nombres crudos que
representa) + `institutions`. `<apellido>` viene de [`_bucket_for`](@ref) sobre `names` — mismo
criterio que ya usa la organización en disco. Con ~300K perfiles, un espacio de 4 dígitos por sí
solo colisiona seguido dentro de un mismo apellido común (paradoja del cumpleaños) — por eso, si la
base ya está en `used_ids`, se le agrega un sufijo `_<n dígitos>` probando 0, 1, 2... hasta hallar
uno libre. Muta `used_ids` (agrega el id devuelto). El resultado es reproducible entre corridas
solo si quien llama procesa siempre en el mismo orden — ver [`assign_raw_ids`](@ref) y
[`build_and_persist`](@ref).
"""
function assign_id(names::Vector{String}, institutions::Vector{String}, used_ids::Set{String}, disambig_digits::Int)
    base = "$(_bucket_for(names))_$(_short_hash(4, vcat(sort(unique(names)), sort(unique(institutions)))))"
    if base ∉ used_ids
        push!(used_ids, base)
        return base, false
    end
    for suf in 0:(10^disambig_digits - 1)
        cand = "$(base)_$(lpad(suf, disambig_digits, '0'))"
        if cand ∉ used_ids
            push!(used_ids, cand)
            return cand, true
        end
    end
    error("Espacio de desambiguación agotado para '$base' ($disambig_digits dígitos) — subir disambig_digits")
end

"""
    assign_raw_ids(authors_data) -> (ids::Dict{String,String}, n_collisions::Int)

One id per raw profile (2 disambiguation digits — raw profiles vastly outnumber consolidated
ones, but each id only has to be unique among raw profiles sharing the same surname+hash4, which
in practice is a small pool). Processes `authors_data` sorted by name so the assignment is the
same across rebuilds regardless of corpus scan order.
"""
function assign_raw_ids(authors_data::Vector{<:AbstractDict})
    used = Set{String}()
    ids = Dict{String,String}()
    n_collisions = 0
    for a in sort(authors_data; by=x -> x["name"])
        id, collided = assign_id([a["name"]], collect(get(a, "institutions", String[])), used, 2)
        ids[a["name"]] = id
        collided && (n_collisions += 1)
    end
    return ids, n_collisions
end

"""
    PrevLeaderInfo

One previous group's identity, keyed by its LEADER's raw name (see [`previous_leader_info`](@ref)):
`id` (that group's `consolidated_id`, which — under the leader model — always equals the leader's
own raw id), `size` (how many raw names it had) and `doc_count` (its total document count), both
needed only as [`rollup`](@ref)'s merge tie-break, not for anything else.
"""
const PrevLeaderInfo = @NamedTuple{id::String, size::Int, doc_count::Int}

"""
    previous_leader_info(previous_profiles::Vector{<:AbstractDict}) -> Dict{String,PrevLeaderInfo}

Reconstructs "who was the leader of which group last time" from [`load_all`](@ref)'s output, keyed
by leader raw name — the input [`rollup`](@ref) needs to decide id continuity across rebuilds. A
profile written before this field existed (no `"leader_raw_name"` key) is silently skipped: its
raw names simply look "brand new" to [`rollup`](@ref) next time, which is the correct, safe
degradation (a fresh id gets assigned exactly as it would for any other new group) rather than an
error.
"""
function previous_leader_info(previous_profiles::Vector{<:AbstractDict})
    info = Dict{String,PrevLeaderInfo}()
    for p in previous_profiles
        leader = get(p, "leader_raw_name", nothing)
        leader === nothing && continue
        info[leader] = (id=p["consolidated_id"], size=length(p["raw_names"]), doc_count=p["doc_count"])
    end
    return info
end

"""
    resolve_leader(raw_names_in_group, entries, prev_leaders) -> (leader_name::String, consolidated_id::String)

The core of the stable-id model: a group's `consolidated_id` IS its leader's own raw id, so
choosing an id and choosing a leader are the same decision. `prev_leaders` is this run's
[`previous_leader_info`](@ref) table; `entries` are `by_name[n]` for each `n` in
`raw_names_in_group`, used only to read `doc_count`.

- **No previous leader is a member of this group** (brand new group, or every previous leader that
  touched it ended up somewhere else): the member with the highest `doc_count` becomes the leader
  — same criterion `rollup` already used to pick the display name before this existed.
- **Exactly one previous leader is a member**: that SAME leader/id carries over unchanged — covers
  an ordinary continuation (group grew or shrank without splitting) AND the split case (the piece
  that still contains the old leader keeps the id; every other piece has zero previous leaders
  among its members, so it falls into the "brand new" case above with its own fresh leader/id).
- **Two or more previous leaders are members** (a real merge): the LARGEST previous group wins (by
  raw-member count, then total `doc_count`, then lexicographically smallest id, for a fully
  deterministic tie-break) — its leader/id carries over; the other merged-in previous leader(s)
  simply stop being anyone's leader.
"""
function resolve_leader(raw_names_in_group::Vector{String}, entries::Vector, prev_leaders::AbstractDict)
    present = [nm for nm in raw_names_in_group if haskey(prev_leaders, nm)]
    if isempty(present)
        by_name_entry = Dict(zip(raw_names_in_group, entries))
        leader = raw_names_in_group[argmax([by_name_entry[nm]["doc_count"] for nm in raw_names_in_group])]
        return leader, nothing
    elseif length(present) == 1
        return present[1], prev_leaders[present[1]].id
    else
        chosen = first(sort(present; by=nm -> (-prev_leaders[nm].size, -prev_leaders[nm].doc_count, prev_leaders[nm].id)))
        return chosen, prev_leaders[chosen].id
    end
end

"""
    rollup(raw_names_in_group, by_name, raw_id_of, prev_leaders) -> Dict{String,Any}

Combines the raw author profiles (`by_name[raw]` for each `raw` in the group, as produced by
`Corpus.build_authors_index_data`) into one consolidated profile — sums, unions, and a STABLE id.
`consolidated_id` is always the group's LEADER's own raw id (from `raw_id_of`) — see
[`resolve_leader`](@ref) for how the leader is chosen/carried over using `prev_leaders`
([`previous_leader_info`](@ref)). Since every raw name has a globally unique raw id
([`assign_raw_ids`](@ref)) and belongs to exactly one final group, two different groups can never
end up choosing the same leader — no hash, no disambiguation digits, no `used_ids` bookkeeping
needed for this id anymore.
"""
function rollup(raw_names_in_group::Vector{String}, by_name::AbstractDict, raw_id_of::AbstractDict, prev_leaders::AbstractDict)
    entries = [by_name[n] for n in raw_names_in_group]
    sorted_raw = sort(raw_names_in_group)
    institutions = sort(unique(vcat([collect(get(e, "institutions", String[])) for e in entries]...)))

    leader_name, carried_id = resolve_leader(raw_names_in_group, entries, prev_leaders)
    consolidated_id = carried_id === nothing ? raw_id_of[leader_name] : carried_id

    canonical_entry = entries[argmax([e["doc_count"] for e in entries])]
    canonical = canonical_entry["name"]
    k = name_keys(canonical)

    cap(v, n) = first(v, min(n, length(v)))

    profile = Dict{String,Any}(
        "consolidated_id" => consolidated_id,
        "leader_raw_name" => leader_name,
        "name" => canonical,
        "name_initials_form" => k.initials_text,
        "role" => get(canonical_entry, "role", "Autor"),
        "raw_names" => sorted_raw,
        "doc_count" => sum(e["doc_count"] for e in entries),
        "doc_ids" => unique(vcat([collect(get(e, "doc_ids", String[])) for e in entries]...)),
        "institutions" => institutions,
        "keywords" => cap(unique(vcat([collect(get(e, "keywords", String[])) for e in entries]...)), 40),
        "repos" => sort(unique(vcat([collect(get(e, "repos", String[])) for e in entries]...))),
        "coauthors" => cap(unique(vcat([collect(get(e, "coauthors", String[])) for e in entries]...)), 15),
        "topic_texts" => cap(unique(vcat([collect(get(e, "topic_texts", String[])) for e in entries]...)), 10),
        "cited_references" => cap(unique(vcat([collect(get(e, "cited_references", String[])) for e in entries]...)), 30),
    )
    return profile
end

"""
    compute_similarity_merges(authors_data; k::Int=16) -> Vector{Tuple{String,String}}

Finds pairs of raw profiles whose *content* (keywords, topics, cited references, institutions —
never the name) is similar enough to plausibly be the same person, complementing
[`compute_groups`](@ref)'s name-key matching: that catches near-identical name spellings, this
catches the opposite case — a genuinely different-looking name (typo, alternate transliteration,
married name) whose *work* is unmistakably the same person's.

Built with `TextSearch.VectorModel` (classical TFIDF, sparse) over a `SimilaritySearch.SearchGraph`
and `bichromatic_metricjoin` (self-join with an adaptive per-point threshold — no cosine cutoff to
tune by hand). Every candidate pair from the join is vetoed unless [`_plausibly_same_person`](@ref)
(surname AND given-name initial) holds between the two raw names — a real risk of pure content
similarity is two *different* people who coauthor constantly (near-identical topic/keyword
profiles) or who simply share a common surname; the gate rejects both cases while still letting
the join find same-name variants that the exact name-key match missed.

**Tried and reverted: partitioning by surname before joining.** The obvious way to cut the cost of
this at full-corpus scale (~100K+ raw profiles) is to bucket `authors_data` by
[`_surname_of_name`](@ref) and join each bucket independently — since
[`_plausibly_same_person`](@ref) requires an exact surname match anyway, a global join's
cross-surname candidates are guaranteed to be vetoed, so bucketing looks like pure waste avoided.
**Verified empirically on a real 10-repo rebuild that this silently breaks the join's precision**:
merges jumped from 4 (correct) to 5,575, with consolidated groups like "garcia" swallowing 47
raw names spanning obviously unrelated people (`"JESSICA ARBALLO GARCIA"`, `"JOEL ANTUNEZ GARCIA"`,
`"JOSE ALBERTO ALVARADO GARCIA"`, ...). Root cause: `bichromatic_metricjoin`'s adaptive per-point
threshold is a *quantile of the dataset it's given* — computed against the whole diverse corpus, it
is strict (most profiles are simply unlike most other profiles); computed within one surname's
bucket alone, that population is far more homogeneous (same language, overlapping general academic
vocabulary, often overlapping institutions), so many merely-similar pairs looked "unusually close"
*relative to their bucket*. That let far more pairs reach the veto, and the veto's own known-weak
spot — a bare single-letter initial (e.g. `"J."`) is compatible with *any* given name starting with
that letter — turned into a bridge: connected-component grouping in
[`compute_groups`](@ref) chained dozens of different "Jaime"/"Javier"/"Jessica"/"Joel"/"Jose*"
people together through such a bridge node. None of this showed up in the un-bucketed design
because the (properly calibrated) join rarely proposed a candidate needing the veto's help in the
first place. A real fix would need a similarity floor calibrated from the *whole* corpus, not
per-bucket — worth doing if full-corpus runtime turns out to actually require it, but not without
its own dedicated validation pass; until then this stays a single join over `authors_data` as a
whole, correctness over speed.

Returns `(name_a, name_b)` pairs meant to be folded into `overrides.merges` before calling
`compute_groups` (see [`build_and_persist`](@ref)) — this function knows nothing about the
override/graph machinery, it just proposes additional edges from a different signal.

`authors_data` is sorted by name internally before building the index — verified empirically
that without this, the exact same underlying profiles in a different order (which happens
across separate rebuilds: `Corpus.build_authors_index_data` collects them via a `Dict`, whose
iteration order depends on Julia's per-process randomized string hashing) can make
`bichromatic_metricjoin` propose a different candidate set, since a `SearchGraph`'s structure is
sensitive to insertion order. Sorting first makes the result reproducible across rebuilds, same
as [`assign_raw_ids`](@ref)/[`build_and_persist`](@ref) already do for id assignment.
"""
function compute_similarity_merges(authors_data::Vector{<:AbstractDict}; k::Int=16)
    authors_data = sort(authors_data; by=a -> a["name"])
    n = length(authors_data)
    n < 3 && return Tuple{String,String}[]

    profile_text(a) = join(vcat(
        collect(get(a, "keywords", String[])),
        collect(get(a, "topic_texts", String[])),
        collect(get(a, "cited_references", String[])),
        collect(get(a, "institutions", String[])),
    ), " \n ")

    texts = [profile_text(a) for a in authors_data]
    voc = Vocabulary(AUTHOR_NAME_CONFIG, texts)
    vocsize(voc) == 0 && return Tuple{String,String}[]  # every profile had empty content text
    model = VectorModel(IdfWeighting(), TfWeighting(), voc)
    vecs = vectorize_corpus(model, texts; verbose=false)
    db = VectorDatabase(vecs)

    G = SearchGraph(Dist.NormCosine(), db)
    ctx = SearchGraphContext()
    index!(G, ctx)

    joined = bichromatic_metricjoin(G, ctx, db; k=min(k, n - 1), samedata=true)

    merges = Tuple{String,String}[]
    for (ia, ib, _dist) in joined
        ia == ib && continue
        na, nb = authors_data[ia]["name"], authors_data[ib]["name"]
        _plausibly_same_person(na, nb) || continue
        push!(merges, (na, nb))
    end
    return merges
end

"""
    build_and_persist(authors_data, index_dir, raw_id_of; overrides_path=DEFAULT_AUTHOR_OVERRIDES_TOML) -> Int

Clusters `authors_data` (raw profiles, as returned by `Corpus.build_authors_index_data`) into
consolidated profiles and writes one `.toml` file per group under
`<index_dir>/authors_consolidated/<apellido_bucket>/<consolidated_id>.toml` — see this module's
docs for why TOML, and why the bucket directory is purely organizational (2 levels: the
consolidated-authors directory itself, then the bucket). `raw_id_of` (from
[`assign_raw_ids`](@ref)) supplies the raw id [`rollup`](@ref) uses whenever a group's leader turns
out to need a fresh one.

STATEFUL, not a clean-slate computation: reads back the PREVIOUS run's profiles
([`load_all`](@ref)) BEFORE wiping the directory, to know which raw name was each existing group's
leader ([`previous_leader_info`](@ref)) — this is what lets [`rollup`](@ref)/[`resolve_leader`](@ref)
keep a group's `consolidated_id` stable across rebuilds (same leader survives unchanged; a split's
non-leader piece and a genuinely new group both get a fresh id; a merge keeps the larger previous
group's id) instead of the id silently changing whenever group membership shifts even slightly.
Still wipes and rewrites every `.toml` file each call — only the id/leader CHOICE is carried over,
not the files themselves.

Does NOT call [`compute_similarity_merges`](@ref) — full-corpus scale (317K raw profiles) made
its `SearchGraph` construction / `bichromatic_metricjoin` step impractically slow (a real rebuild
attempt on the full ~93-repo corpus stalled for hours with no forward progress and no error, after
successfully processing the 10-repo development subset in minutes). Content-similarity-based
matching is being redesigned (tracked in
[issue #2](https://github.com/sadit/ReposMx/issues/2)) as evidence FOR the [`compute_name_clusters`](@ref)
oracle to justify *splitting* a cluster (a precision tool), not as a source of *merge* candidates
(the job it does today) — clustering stays recall-oriented and name-only per that plan.
`compute_similarity_merges`/`_plausibly_same_person` are left in place, tested, and still callable
directly; they're just not wired into this function until that redesign lands.
"""
function build_and_persist(authors_data::Vector{<:AbstractDict}, index_dir::AbstractString, raw_id_of::AbstractDict;
                            overrides_path::AbstractString=DEFAULT_AUTHOR_OVERRIDES_TOML)
    by_name = Dict{String,Any}(a["name"] => a for a in authors_data)
    raw_names = collect(keys(by_name))
    overrides = load_overrides(overrides_path)

    prev_leaders = previous_leader_info(load_all(index_dir))

    groups = compute_groups(raw_names, overrides)

    base_dir = joinpath(index_dir, CONSOLIDATED_SUBDIR)
    isdir(base_dir) && rm(base_dir; recursive=true, force=true)
    mkpath(base_dir)

    seen_ids = Set{String}()
    n_new = 0
    for g in sort(groups; by=grp -> sort(grp)[1])
        profile = rollup(g, by_name, raw_id_of, prev_leaders)
        cid = profile["consolidated_id"]
        @assert cid ∉ seen_ids "duplicate consolidated_id $cid across two different groups — should be impossible under the leader model"
        push!(seen_ids, cid)
        haskey(prev_leaders, profile["leader_raw_name"]) || (n_new += 1)
        dir = joinpath(base_dir, _bucket_for(g))
        mkpath(dir)
        open(joinpath(dir, "$(cid).toml"), "w") do io
            TOML.print(io, profile)
        end
    end
    println("  consolidated groups with a freshly assigned leader/id: $n_new / $(length(groups))")
    return length(groups)
end

"""
    load_all(index_dir::AbstractString) -> Vector{Dict{String,Any}}

Reads back every consolidated profile written by [`build_and_persist`](@ref). Walks the whole
`authors_consolidated` subtree (`walkdir`, not a fixed-depth glob) so a future change to the
bucketing scheme in `_bucket_for` can't silently drop profiles from the index.
"""
function load_all(index_dir::AbstractString)
    base_dir = joinpath(index_dir, CONSOLIDATED_SUBDIR)
    isdir(base_dir) || return Dict{String,Any}[]
    profiles = Dict{String,Any}[]
    for (root, _, files) in walkdir(base_dir)
        for f in files
            endswith(f, ".toml") || continue
            push!(profiles, TOML.parsefile(joinpath(root, f)))
        end
    end
    return profiles
end

end # module AuthorConsolidation
