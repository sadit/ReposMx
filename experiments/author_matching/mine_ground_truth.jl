#=
Ground-truth miner for author-name-matching experiments (see `qgram_oracle_clustering.jl` in this
same directory). NOT wired into `src/` — this is a standalone research script, run manually against
a real (multi-repo) local rebuild to produce labeled pairs for validating a candidate name-matching
metric before it's ever considered for production.

Usage: `julia --project=. experiments/author_matching/mine_ground_truth.jl` from the repo root,
after a normal `reposmx build-corpus`/harvest for the repos listed in `REPOS` below. Writes
`mined_trivial_good.txt`, `mined_hard_good.txt`, `mined_bad_v2.txt` next to this file (`" ||| "`-
separated raw name pairs, one per line) — these are gitignored (regenerate, don't commit; they're
derived data tied to whatever repos happen to be harvested locally, same reasoning as `data/`).

Labeling method: "good" pairs are auto-labeled two ways — trivially via exact `full_key` match
(100% reliable), and "hard" cases via `strict_same_person` (an order-independent, abbreviation-
tolerant-only-for-the-first-token multiset coverage check, stricter than production's
`_plausibly_same_person`), with a post-hoc contradiction filter removing any short-form name
matched to two different paternal surnames (provable ambiguity, e.g. "Jorge Ruiz" matching both
"...Gonzalez Ruiz" and "...Solis Ruiz"). "Bad" pairs are mined from `_plausibly_same_person`-
bucketed-by-surname connected components, keeping only pairs NOT already connected via `full_key`/
`initials_key`, filtered through the same `strict_same_person` check (many pairs that first looked
"bad" by that construction turned out to be genuine matches the veto correctly allows — an early,
important correction found while building this).

Known residual label noise (do not "fix" further without new evidence): a handful of "good"/"bad"
labels are themselves wrong in ways that trace back to `_given_name_token_compatible`'s bare-initial
rule allowing a single-letter token to match ANY name sharing that first letter — e.g. "J. Jesus
Arriaga Rodriguez" got auto-labeled a match for "Jasmine Rodriguez" purely because "J." is
compatible-by-construction with anything starting with J. `qgram_oracle_clustering.jl`'s validation
run should be read with this in mind: a handful of its reported "FP"/"FN" are actually mining label
bugs, not candidate-metric failures — cross-check any surprising one by hand before trusting the
label over the metric.
=#

using ReposMx
using ReposMx.AuthorConsolidation: name_keys, _plausibly_same_person, _surname_of_name,
                                    _given_name_token_compatible, AUTHOR_NAME_CONFIG
using TextSearch

const AC = ReposMx.AuthorConsolidation
const REPOS = ["buap","ccg","centrogeo","ciad","ciatec","ciateq","cicese","cicy","cide","cidesi"]

raw_tokens(raw::AbstractString) = String.(collect(tokenize(AUTHOR_NAME_CONFIG, AC._order_normalize(raw))))

"""
    tokens_coverable(short, long) -> Bool

Every token in `short` must find a distinct partner in `long` (order-independent, one-to-one).
Abbreviation tolerance (single-letter initial matching a full word's first letter) is allowed ONLY
for `short[1]` -- the well-established convention already used by `_plausibly_same_person`. Every
OTHER token in `short` requires an EXACT match. Without this restriction, a token that's actually a
misclassified paternal surname (this whole preprocessing pipeline naively treats every
non-final token as "given", which is wrong for 3+-token "Nombre ApellidoPaterno ApellidoMaterno"
names) could spuriously abbreviation-match an unrelated middle initial in a completely different
person's name (found live: "Alonso Ortiz, J." <-> "José A. Rodríguez-Ortiz", where "alonso" wrongly
matched "a").
"""
function tokens_coverable(short::Vector{String}, long::Vector{String})
    used = falses(length(long))
    for (pos, st) in enumerate(short)
        found = false
        for (i, lt) in enumerate(long)
            used[i] && continue
            compatible = pos == 1 ? _given_name_token_compatible(st, lt) : (st == lt)
            if compatible
                used[i] = true
                found = true
                break
            end
        end
        found || return false
    end
    return true
end

"""
    first_token_ungrounded_initial(toks) -> Bool

True when `toks[1]` is a bare single-letter initial with no expansion confirming it WITHIN THIS
SAME name (i.e. not the "K. (Kaniska) Dam" self-annotated pattern, where the initial and its own
spelled-out form are adjacent tokens in one raw name -- there the initial is grounded by its own
record, not a guess). An ungrounded bare initial is inherently unverifiable when matched against a
*different* profile's full given name (could stand for many different names).
"""
function first_token_ungrounded_initial(toks::Vector{String})
    isempty(toks) && return false
    length(toks[1]) != 1 && return false
    length(toks) < 2 && return true
    return first(toks[2]) != toks[1][1]
end

"""
    ambiguous_bare_initial(given_a, given_b) -> Bool

True when EITHER side's first given-name token is an ungrounded bare initial (see
`first_token_ungrounded_initial`) -- that's the token the abbreviation-matching rule leans on to
satisfy coverage, from either direction, so either side being ungrounded makes the whole
comparison unverifiable. Such a pair is excluded from the ground truth instead of guessed.
"""
function ambiguous_bare_initial(given_a::Vector{String}, given_b::Vector{String})
    first_token_ungrounded_initial(given_a) || first_token_ungrounded_initial(given_b)
end

"""
    strict_same_person(a, b) -> Union{Bool,Nothing}

A more thorough version of `_plausibly_same_person` used ONLY for labeling ground truth (not a
candidate for the production veto without its own validation cycle): same exact final surname,
AND the full given-name token list of the shorter name is entirely coverable by the longer name's
given-name tokens (see `tokens_coverable`) -- not just the first token, unlike
`_plausibly_same_person`. Catches "same content, reordered/abbreviated/middle-name-dropped" as
genuinely the same person, and rejects "shares first given name + surname but has an outright
conflicting extra token" (e.g. "Jose Camargo Perez" vs "Jose Francisco Cruz Perez" -- "camargo"
matches nothing in {francisco,cruz}). Returns `nothing` (not `true`/`false`) when the comparison
is a bare-initial-only case (see `ambiguous_bare_initial`) -- too unverifiable to label either way.
"""
function strict_same_person(a::AbstractString, b::AbstractString)
    toks_a, toks_b = raw_tokens(a), raw_tokens(b)
    (isempty(toks_a) || isempty(toks_b)) && return false
    given_a, surname_a = toks_a[1:end-1], toks_a[end]
    given_b, surname_b = toks_b[1:end-1], toks_b[end]
    (surname_a == surname_b && length(surname_a) >= 2) || return false
    (isempty(given_a) || isempty(given_b)) && return false
    ambiguous_bare_initial(given_a, given_b) && return nothing
    shorter, longer = length(given_a) <= length(given_b) ? (given_a, given_b) : (given_b, given_a)
    return tokens_coverable(shorter, longer)
end

is_garbage(nm) = occursin(r"^https?://|orcid|^[\d\-]+$"i, nm)

all_docs, _, _, _ = ReposMx.Indexing._collect_documents(; repos=REPOS)
authors_data = ReposMx.Corpus.build_authors_index_data(all_docs)
raw_names = filter(!is_garbage, sort(unique([a["name"] for a in authors_data])))
n = length(raw_names)
println("n raw names (post garbage filter) = ", n)

# ---- trivial good: full_key exact matches (unchanged from before) ----
by_full = Dict{String,Vector{String}}()
by_init = Dict{String,Vector{String}}()
for nm in raw_names
    k = name_keys(nm)
    isempty(k.full_key) || push!(get!(by_full, k.full_key, String[]), nm)
    isempty(k.initials_key) || push!(get!(by_init, k.initials_key, String[]), nm)
end
trivial_good = Tuple{String,String}[]
for (_, grp) in by_full
    length(grp) < 2 && continue
    for i in 1:length(grp), j in (i+1):length(grp)
        push!(trivial_good, (grp[i], grp[j]))
    end
end
println("trivial good pairs (full_key exact): ", length(trivial_good))

# ---- the _plausibly_same_person-bucketed-by-surname components (same construction as before) ----
by_surname = Dict{String,Vector{String}}()
for nm in raw_names
    s = _surname_of_name(nm)
    isempty(s) || push!(get!(by_surname, s, String[]), nm)
end
adj = Dict{String,Vector{String}}(nm => String[] for nm in raw_names)
for (_, grp) in by_surname
    for i in 1:length(grp), j in (i+1):length(grp)
        if _plausibly_same_person(grp[i], grp[j])
            push!(adj[grp[i]], grp[j])
            push!(adj[grp[j]], grp[i])
        end
    end
end
function components(adj, names)
    visited = Set{String}()
    comps = Vector{Vector{String}}()
    for nm in names
        nm in visited && continue
        comp = String[]; queue = [nm]; push!(visited, nm)
        while !isempty(queue)
            cur = popfirst!(queue); push!(comp, cur)
            for m in adj[cur]
                if !(m in visited)
                    push!(visited, m); push!(queue, m)
                end
            end
        end
        push!(comps, comp)
    end
    return comps
end
comps = components(adj, raw_names)

# ---- split every pair in size>=4 components into hard_good (strict_same_person) vs bad (not) ----
hard_good = Tuple{String,String}[]
bad = Tuple{String,String}[]
excluded_ambiguous = Ref(0)
for c in comps
    length(c) < 4 && continue
    for i in 1:length(c), j in (i+1):length(c)
        a, b = c[i], c[j]
        ka, kb = name_keys(a), name_keys(b)
        (ka.full_key == kb.full_key) && continue  # already in trivial_good, skip
        verdict = strict_same_person(a, b)
        if verdict === nothing
            excluded_ambiguous[] += 1
        elseif verdict
            push!(hard_good, (a, b))
        else
            push!(bad, (a, b))
        end
    end
end
println("hard good pairs (strict_same_person, not full_key): ", length(hard_good))
println("bad pairs (survive strict_same_person=false): ", length(bad))
println("excluded as ambiguous (bare-initial-only): ", excluded_ambiguous[])

# ---- post-filter: detect direct contradictions -- a "short form" (given=[first name], no
# middle/paternal-surname content) that gets matched to two DIFFERENT longer names with
# different apparent paternal surnames is demonstrably ambiguous (proof by contradiction: both
# can't be the same person as the short form AND be different people from each other), not
# just theoretically risky. Found live: "Jorge Ruiz" paired with both "...GONZALEZ RUIZ" and
# "...SOLIS RUIZ". Remove every pair involving such a short form from hard_good.
paternal_by_short = Dict{String,Set{String}}()
for (a, b) in hard_good
    ta, tb = raw_tokens(a), raw_tokens(b)
    shorter_toks, longer_toks = length(ta) <= length(tb) ? (ta, tb) : (tb, ta)
    length(shorter_toks) == 2 && length(longer_toks) >= 3 || continue  # "Nombre Apellido" vs fuller form
    short_key = shorter_toks[1] * "_" * shorter_toks[end]
    paternal = longer_toks[end-1]
    push!(get!(paternal_by_short, short_key, Set{String}()), paternal)
end
contradictory_shorts = Set(k for (k, v) in paternal_by_short if length(v) > 1)
println("short forms with contradictory paternal surnames (excluded): ", length(contradictory_shorts))

hard_good_clean = Tuple{String,String}[]
removed_contradictory = 0
for (a, b) in hard_good
    ta, tb = raw_tokens(a), raw_tokens(b)
    shorter_toks = length(ta) <= length(tb) ? ta : tb
    short_key = length(shorter_toks) == 2 ? shorter_toks[1] * "_" * shorter_toks[end] : ""
    if short_key in contradictory_shorts
        global removed_contradictory += 1
    else
        push!(hard_good_clean, (a, b))
    end
end
println("hard_good pairs removed for contradiction: ", removed_contradictory)
println("hard_good final: ", length(hard_good_clean))
hard_good = hard_good_clean

open(joinpath(@__DIR__, "mined_trivial_good.txt"), "w") do io
    for (a,b) in trivial_good; println(io, a, " ||| ", b); end
end
open(joinpath(@__DIR__, "mined_hard_good.txt"), "w") do io
    for (a,b) in hard_good; println(io, a, " ||| ", b); end
end
open(joinpath(@__DIR__, "mined_bad_v2.txt"), "w") do io
    for (a,b) in bad; println(io, a, " ||| ", b); end
end
println("DONE")
