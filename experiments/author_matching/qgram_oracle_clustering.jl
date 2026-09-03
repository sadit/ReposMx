#=
Candidate replacement for author-name-matching (see `src/AuthorConsolidation.jl`'s `name_keys` /
`compute_groups` / `_plausibly_same_person`). STATUS: validated, NOT integrated — this is a
standalone research script, not wired into `src/`. Nothing here has touched production code.

## What this is

A two-phase clustering design, replacing a single pairwise veto with:

1. **Clustering (recall-oriented)**: connect two raw names if a character-q-gram name-similarity
   score (`name_similarity_v4`) clears a GENEROUS bar (`CLUSTER_MATCH_THR`/`CLUSTER_SURNAME_THR` =
   0.5) — tolerant of typos/transliteration variants a strict exact-match veto would miss (e.g.
   "Fedorovish"/"Federovish", q-gram overlap only 0.38 on that one token). Candidate pairs are
   generated via `surname_keys` bucketing (an efficiency-only step — see its docstring — NOT a
   correctness decision, unlike the historically-failed attempt to bucket
   `compute_similarity_merges` by surname, documented in `AuthorConsolidation.jl`: that bucketing
   corrupted an ADAPTIVE, population-relative similarity signal; the q-gram score here is an
   ABSOLUTE, fixed threshold, unaffected by what else shares a bucket).
2. **Oracle (precision-oriented)**: a phase-1 cluster stays merged by DEFAULT — it's only split if
   `has_contradiction` finds a genuine counter-example inside it: two members whose given names, at
   some aligned position, are both fully spelled out (neither a bare initial) and score BELOW a low
   floor (`CONTRADICTION_FLOOR` = 0.2) — clearly different words, not a spelling variant. This is
   asymmetric on purpose: proving two names the SAME is hard; proving them DIFFERENT, when the
   evidence is this stark, is not. Splitting uses a stricter, order-dependent greedy partition
   (`oracle_partition`) — see Known limitations.

## How this was validated

Against the real 10-repo corpus (`REPOS` below), 19,543 raw names, and a mined ground truth (see
`mine_ground_truth.jl`, run separately): end-to-end (checking actual final-cluster co-membership,
not just the pairwise score) — FN ≈ 0.35% (10/2842 good pairs split apart), FP ≈ 0.18% (40/22785
bad pairs merged together) — better than every rule-based or blended-q-gram-score approach tried
before this design (best prior: FP 0.88%/FN 0.42%). Also passes 19/19 hand-picked regression cases
(the same real-rebuild-derived examples in `test/runtests.jl`'s `_plausibly_same_person` tests).
Concrete known-hard cases confirmed correct: "JOSE CAMARGO PEREZ"/"JUAN CONTRERAS PEREZ"/"JULIO
CANDELA PEREZ" (different people sharing 2 initials + surname — the `initials_key` collision bug
this design was originally aimed at) correctly separated; "MANUEL ALBERTO CHAVEZ GONZALEZ"/"MARIA
ANTONIETA CHAVEZ GONZALEZ" (identical double surname, different given name) correctly separated;
5 real typo/transliteration variants of one "Alexei ... Licea Navarro" correctly merged. Also fixes,
as a side effect, the pre-existing 117-member ORCID/URL garbage blob (`is_garbage` guard) already
documented in memory.

Run it: `julia --project=. experiments/author_matching/qgram_oracle_clustering.jl` from the repo
root, after a normal harvest/build-corpus for `REPOS`. The mined-ground-truth validation section
is skipped (with a message) if `mine_ground_truth.jl` hasn't been run locally yet — those files are
gitignored, regenerate them first for the full validation output.

## Known, accepted limitations (not chased further — see git history / session notes)

- `oracle_partition` is a GREEDY, ORDER-DEPENDENT partition (processes names in sorted order,
  joins the first compatible existing sub-cluster) — a real correlation-clustering / cluster-
  editing solution is NP-hard in general; this greedy heuristic can rarely miss an obviously-
  correct merge depending on processing order (found live: "Víctor Aguilar-Hernández"/"Víctor Hugo
  Aguilar Hernández", a clean match in isolation, occasionally lands in a different sub-cluster
  when several other "Hernández" records are also being partitioned in the same pass). This is a
  RECALL cost (a missed merge, recoverable by a later pass or manual review), judged lower-priority
  than fixing precision bugs.
- The "drop the paternal surname entirely, keep only the maternal" truncation direction is
  unhandled (asymmetric with the handled direction: `Juan Tellez Avila` -> `Juan Tellez` truncates
  correctly, keeping the paternal surname, which is the documented convention; but e.g. `Edgar
  Eugenio Ramírez de la Cruz` -> `Edgar Cruz`, dropping the paternal surname and keeping only the
  compound maternal surname's head word, does not match). Flagged as plausible-but-unconfirmed
  early in this design's development and never chased — real-world frequency/importance unknown.
- Compound-surname particle list (`SURNAME_PARTICLES`) is Spanish/Mexican-specific and not
  exhaustively validated — e.g. "y" as a surname-joining conjunction ("Milián y Ávila") is
  deliberately NOT included (untested; may need its own validation pass before adding).
=#

using ReposMx
using ReposMx.AuthorConsolidation: name_keys, AUTHOR_NAME_CONFIG
using TextSearch

const AC = ReposMx.AuthorConsolidation
const Q = 4
const REPOS = ["buap","ccg","centrogeo","ciad","ciatec","ciateq","cicese","cicy","cide","cidesi"]

raw_tokens_(raw::AbstractString) = String.(collect(tokenize(AUTHOR_NAME_CONFIG, AC._order_normalize(raw))))

"""
    collapse_self_annotations(toks) -> Vector{String}

A bare initial immediately followed by its own expansion within the SAME raw name (e.g.
`"L. (Luis) Barron"` -> `[l, luis, barron]`) is one given-name concept written twice, not two
independent given names -- collapse to the expansion so it doesn't inflate the given-token count
and force a real given name into competing for alignment against it.
"""
function collapse_self_annotations(toks::Vector{String})
    out = String[]; i = 1
    while i <= length(toks)
        if i < length(toks) && length(toks[i]) == 1 && length(toks[i+1]) > 1 && toks[i][1] == first(toks[i+1])
            push!(out, toks[i+1]); i += 2
        else
            push!(out, toks[i]); i += 1
        end
    end
    return out
end
raw_tokens(raw::AbstractString) = collapse_self_annotations(raw_tokens_(raw))

# Spanish/Mexican surname connector words: a compound surname like "de la Cruz" or "del Razo" is
# ONE unit, not independent tokens -- previously "la"/"de" leaked into the given-name list as if
# they were middle names (diluting/corrupting the alignment), and pre-clustering keyed on the
# literal last token ("cruz") never matched a truncated form's paternal surname ("torres" in
# "Victor Manuel Torres De La Cruz" / "Victor Torres"). Real corpus check: 1084/19543 raw names
# (~5.5%) contain one of these words -- common enough that this is not an edge case.
const SURNAME_PARTICLES = Set(["de", "del", "la", "las", "los", "san", "santa"])

"""
    surname_span(toks) -> UnitRange

Index range of `toks` covering the (possibly compound) surname: starts at `length(toks)` and
walks backward absorbing `SURNAME_PARTICLES` tokens, stopping at the first non-particle token
encountered (which is itself included, as the surname's head word) -- e.g. [..,"torres","de",
"la","cruz"] -> the span is "de","la","cruz" (3 tokens); ["juan","tellez"] -> the span is just
"tellez" (no particles to absorb).
"""
function surname_span(toks::Vector{String})
    i = length(toks)
    while i > 1 && toks[i-1] in SURNAME_PARTICLES
        i -= 1
    end
    return i:length(toks)
end

function qgrams(t::AbstractString; q::Int=Q)
    padded = collect("^" * t * "\$")
    length(padded) < q && return Set([String(padded)])
    return Set(String(padded[i:i+q-1]) for i in 1:(length(padded)-q+1))
end
function qgram_jaccard_tok(a::AbstractString, b::AbstractString)
    qa, qb = qgrams(a), qgrams(b)
    u = length(union(qa, qb)); u == 0 ? 0.0 : length(intersect(qa, qb)) / u
end

"""
    token_pair_score(a, b) -> Float64

Pairwise (never pooled into a bag) compatibility of two given-name tokens: exact match (1.0), a
REAL (not synthetic) bare initial matching the other's first letter (1.0/0.0), or character-q-gram
Jaccard for typo/spelling-variant tolerance. No position restriction on the bare-initial shortcut —
safe here specifically because this design never enriches/synthesizes initials from spelled-out
names (unlike an earlier, rejected bag-of-q-grams approach), so a length-1 token can only come from
genuine raw-data abbreviation.
"""
function token_pair_score(a::AbstractString, b::AbstractString)
    a == b && return 1.0
    length(a) == 1 && !isempty(b) && return a[1] == first(b) ? 1.0 : 0.0
    length(b) == 1 && !isempty(a) && return b[1] == first(a) ? 1.0 : 0.0
    qgram_jaccard_tok(a, b)
end

"""
    align_pairs(short, long) -> Vector{Tuple{String,String,Float64}}

Bipartite greedy alignment of `short`'s tokens against `long`'s (one-to-one, tolerant of
dropped/reordered middle names): for each token in `short`, attribute the best-scoring REMAINING
candidate in `long`, even at score 0.0 -- "no candidate beat the initial floor" must never
collapse into "no partner exists to compare against": a token that matches nothing (score 0.0
against every remaining option) is itself the contradiction signal `has_contradiction` needs, not
an absence of one.
"""
function align_pairs(short::Vector{String}, long::Vector{String})
    used = falses(length(long)); pairs = Tuple{String,String,Float64}[]
    for st in short
        best_j, best_s = 0, -1.0
        for (j, lt) in enumerate(long)
            used[j] && continue
            s = token_pair_score(st, lt)
            if s > best_s; best_s, best_j = s, j; end
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

# TextSearch's tokenizer normalizes any URL to a literal "url" placeholder and any digit run to
# "0" -- different garbage ORCID/URL "names" collapse to identical tokens as a result (the
# pre-existing 117-member "_url" blob already documented in memory from full_key/initials_key).
# Guard at the raw-string level, same pattern already validated in this session's ground-truth
# mining (see `mine_ground_truth.jl`).
is_garbage(nm::AbstractString) = occursin(r"^https?://|orcid|^[\d\-]+$"i, nm)

"""
    name_similarity_v4(name_a, name_b) -> (; match, mismatch_frac, surname, pairs)

The core candidate metric. `surname`: exact/truncation-aware (single-vs-compound-surname
mixing)/typo-tolerant score for the (possibly compound) surname. `match`: mean per-token alignment
score of the SHORTER given-name list (generous to truncation -- extra tokens on the longer side
never enter the denominator). `mismatch_frac`: fraction of the shorter given-name list's tokens
whose best partner scored below 0.3 -- a SEPARATE, explicit penalty axis instead of folding "found
nothing" into the same ratio as "found something so-so". `pairs`: the raw per-position
`(token_a, token_b, score)` triples, used by `has_contradiction` to catch a hard mismatch that an
AGGREGATE score can launder away via a shared incidental token (see its docstring).
"""
function name_similarity_v4(name_a::AbstractString, name_b::AbstractString)
    (is_garbage(name_a) || is_garbage(name_b)) && return (match=0.0, mismatch_frac=1.0, surname=0.0, pairs=Tuple{String,String,Float64}[])
    toks_a, toks_b = raw_tokens(name_a), raw_tokens(name_b)
    (isempty(toks_a) || isempty(toks_b)) && return (match=0.0, mismatch_frac=1.0, surname=0.0, pairs=Tuple{String,String,Float64}[])
    span_a, span_b = surname_span(toks_a), surname_span(toks_b)
    surname_a, surname_b = toks_a[span_a], toks_b[span_b]  # possibly-compound surname, as a token vector
    given_a, given_b = toks_a[1:first(span_a)-1], toks_b[1:first(span_b)-1]
    valid_a = length(toks_a[end]) >= 2  # garbage guard: a degenerate single-char surname head
    valid_b = length(toks_b[end]) >= 2  # (e.g. a digit-run normalized to "0") must never count as a match
    surname_exact = (valid_a && valid_b && surname_a == surname_b) ? 1.0 : 0.0
    trunc = 0.0
    length(given_a) == 1 && length(surname_a) == 1 && length(given_b) >= 1 && valid_a && surname_a[1] == given_b[end] && (trunc = 1.0)
    length(given_b) == 1 && length(surname_b) == 1 && length(given_a) >= 1 && valid_b && surname_b[1] == given_a[end] && (trunc = 1.0)
    surname_typo = (valid_a && valid_b) ? qgram_jaccard_tok(join(surname_a, " "), join(surname_b, " ")) : 0.0
    surname = max(surname_exact, trunc, surname_typo)
    if isempty(given_a) && isempty(given_b)
        return (match=1.0, mismatch_frac=0.0, surname=surname, pairs=Tuple{String,String,Float64}[])
    elseif isempty(given_a) || isempty(given_b)
        return (match=0.0, mismatch_frac=1.0, surname=surname, pairs=Tuple{String,String,Float64}[])
    end
    shorter, longer = length(given_a) <= length(given_b) ? (given_a, given_b) : (given_b, given_a)
    pairs = align_pairs(shorter, longer)
    scores = [p[3] for p in pairs]
    return (match=sum(scores) / length(scores), mismatch_frac=count(<(0.3), scores) / length(scores), surname=surname, pairs=pairs)
end

"""
    surname_keys(raw) -> Vector{String}

Candidate generation only (efficiency, not a correctness decision): bucket by TWO keys -- (1) the
literal last token, always correct for a record's own surname whether or not there's any
paternal/maternal ambiguity at all (this is what keeps an ordinary "First Middle Last" person,
e.g. "Allyson Lucinda Benton", correctly bucketed under "benton" -- an EARLIER version of this
function dropped this safety net and bucketed such names under "lucinda" instead, mistaking an
ordinary middle given name for a paternal-surname candidate: a real regression, found live via the
mined ground truth, worse than the narrow compound-surname gain it was trying to make); and (2)
the paternal-surname CANDIDATE (`given_and_paternal[end]`, when there are 2+ tokens before the
surname span) -- needed so a full "Nombre ApellidoPaterno ApellidoMaterno" record and its truncated
single-surname form still share a bucket even when the maternal side is itself a compound ("Torres
De La Cruz" -- bucketing only by the literal last token "cruz" would never match a truncated
"Torres" record; see `surname_span`).
"""
function surname_keys(raw::AbstractString)
    toks = raw_tokens(raw)
    isempty(toks) && return String[]
    span = surname_span(toks)
    given_and_paternal = toks[1:first(span)-1]
    keys = [toks[end]]
    length(given_and_paternal) >= 2 && push!(keys, given_and_paternal[end])
    return unique(keys)
end

# Phase 1 (clustering, RECALL-oriented): connect a-b if the q-gram name metric clears a GENEROUS
# bar -- tolerant of typos/transliteration variants (e.g. "Fedorovish"/"Federovish", raw q-gram
# overlap only 0.38 on that one token, well under any "confident" bar, but not zero either).
const CLUSTER_MATCH_THR = 0.5
const CLUSTER_SURNAME_THR = 0.5

function phase1_edge(a::AbstractString, b::AbstractString)
    r = name_similarity_v4(a, b)
    r.surname >= CLUSTER_SURNAME_THR && r.match >= CLUSTER_MATCH_THR
end

# Phase 2 (oracle, PRECISION-oriented): default is "stay merged" -- a phase-1 component is only
# split if the oracle finds a genuine counter-example inside it (see has_contradiction).
const CONTRADICTION_FLOOR = 0.2

"""
    has_contradiction(names) -> Union{Tuple{String,String},Nothing}

A contradiction is a PER-POSITION fact, not an aggregate one: a shared incidental token (e.g. a
common middle name) must never launder away a hard mismatch elsewhere in the alignment (found
live: "MANUEL ALBERTO CHAVEZ GONZALEZ" vs "MARIA ANTONIETA CHAVEZ GONZALEZ" share the literal
token "chavez" in given-name position, which pulled the AVERAGE match score to 0.333 -- above a
0.2 floor -- even though "manuel"/"maria" at the discriminating position score near zero).
"""
function has_contradiction(names::Vector{String})
    for i in 1:length(names), j in (i+1):length(names)
        r = name_similarity_v4(names[i], names[j])
        r.surname >= CLUSTER_SURNAME_THR || continue
        for (ta, tb, s) in r.pairs
            if length(ta) > 1 && length(tb) > 1 && s < CONTRADICTION_FLOOR
                return (names[i], names[j])
            end
        end
    end
    return nothing
end

function strict_compatible(a::AbstractString, b::AbstractString; s=0.5, m=0.9)
    r = name_similarity_v4(a, b)
    r.surname >= s && r.match >= m
end

"""
    oracle_partition(names) -> Vector{Vector{String}}

Greedy re-partition of a contradiction-flagged component using a STRICT pairwise compatibility
check (thresholds validated against the mined ground truth: FP=0.14%, FN=0.14% on 25K+ pairs) as a
must-link test -- a name joins an EXISTING sub-cluster only if compatible with EVERY member
already in it, which is what actually prevents transitive chaining through a bridge name. NOTE:
order-dependent (see module docstring's "Known limitations") -- not a general correlation-
clustering solver.
"""
function oracle_partition(names::Vector{String})
    clusters = Vector{Vector{String}}()
    for nm in sort(names)
        placed = false
        for c in clusters
            if all(m -> strict_compatible(nm, m), c)
                push!(c, nm); placed = true; break
            end
        end
        placed || push!(clusters, [nm])
    end
    return clusters
end

function connected_components(names::Vector{String}, edge_fn)
    n = length(names)
    idx = Dict(names[i] => i for i in 1:n)
    adj = [Int[] for _ in 1:n]
    for i in 1:n, j in (i+1):n
        edge_fn(names[i], names[j]) && (push!(adj[i], j); push!(adj[j], i))
    end
    visited = falses(n)
    comps = Vector{Vector{String}}()
    for i in 1:n
        visited[i] && continue
        comp = Int[]; queue = [i]; visited[i] = true
        while !isempty(queue)
            cur = popfirst!(queue); push!(comp, cur)
            for m in adj[cur]
                if !visited[m]; visited[m] = true; push!(queue, m); end
            end
        end
        push!(comps, [names[k] for k in comp])
    end
    return comps
end

# ============================================================
# Run the pipeline on a real local rebuild
# ============================================================
all_docs, _, _, _ = ReposMx.Indexing._collect_documents(; repos=REPOS)
authors_data = ReposMx.Corpus.build_authors_index_data(all_docs)
raw_names = sort(unique([a["name"] for a in authors_data]))
n = length(raw_names)
println("n raw names = ", n)

candidate_buckets = Dict{String,Vector{String}}()
for nm in raw_names
    for k in surname_keys(nm)
        push!(get!(candidate_buckets, k, String[]), nm)
    end
end
println("n candidate buckets = ", length(candidate_buckets), "  largest = ", maximum(length.(values(candidate_buckets))))

# Global union-find over ALL raw_names, fed by every bucket's candidate pairs -- a name landing in
# two buckets (surname + paternal-surname-candidate, for 3+-token names) must not depend on which
# bucket happens to be visited first (per-bucket processing with an ad-hoc "already claimed" skip
# silently dropped valid components depending on iteration order -- found live: identical names
# "CECILIA HERNANDEZ ZEPEDA" / "Cecilia Hernandez-Zepeda" ended up in different final groups purely
# because of bucket visitation order, before this was switched to a proper global union-find).
idx = Dict(nm => i for (i, nm) in enumerate(raw_names))
parent = collect(1:length(raw_names))
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

for (_, bucket_names) in candidate_buckets
    bucket_names = unique(bucket_names)
    length(bucket_names) < 2 && continue
    for i in 1:length(bucket_names), j in (i+1):length(bucket_names)
        a, b = bucket_names[i], bucket_names[j]
        phase1_edge(a, b) && uf_union!(idx[a], idx[b])
    end
end

by_root = Dict{Int,Vector{String}}()
for nm in raw_names
    push!(get!(by_root, uf_find(idx[nm]), String[]), nm)
end

final_groups = Vector{Vector{String}}()
for (_, comp) in by_root
    if length(comp) == 1
        push!(final_groups, comp)
        continue
    end
    cx = has_contradiction(comp)
    if cx === nothing
        push!(final_groups, comp)
    else
        append!(final_groups, oracle_partition(comp))
    end
end

println("\nn final groups = ", length(final_groups))
sizes = sort(length.(final_groups); rev=true)
println("largest 15 group sizes: ", sizes[1:min(end,15)])
println("n groups with size >= 4: ", count(>=(4), sizes))

function find_group_containing(groups, name)
    for g in groups
        name in g && return g
    end
    return nothing
end
println("\n--- Perez counter-example (initials_key collision bug this design targets) ---")
for probe in ["JOSE CAMARGO PEREZ", "JUAN CONTRERAS PEREZ", "JULIO CANDELA PEREZ", "JOSE FRANCISCO CRUZ PEREZ"]
    g = find_group_containing(final_groups, probe)
    println("group of \"$probe\": ", g === nothing ? "NOT FOUND" : g)
end
println("\n--- Chavez Gonzalez counter-example (identical double surname, different given name) ---")
for probe in ["MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ"]
    g = find_group_containing(final_groups, probe)
    println("group of \"$probe\": ", g === nothing ? "NOT FOUND" : g)
end
println("\n--- Alexei typo-tolerance (5 real spelling variants of one person) ---")
for probe in ["ALEXEI FEDOROVISH LICEA NAVARRO", "Alexei Federovish Licea Navarro", "Alexei Fedorovish Licea Navarro", "Alexei Fedórovish Licea Navarro"]
    g = find_group_containing(final_groups, probe)
    println("group of \"$probe\": ", g === nothing ? "NOT FOUND" : g)
end

# ============================================================
# Validation against mined ground truth (optional -- run mine_ground_truth.jl first)
# ============================================================
function load_pairs(path)
    pairs = Tuple{String,String}[]
    for line in eachline(path)
        parts = split(line, " ||| ")
        length(parts) == 2 && push!(pairs, (String(parts[1]), String(parts[2])))
    end
    return pairs
end

gt_files = ["mined_trivial_good.txt", "mined_hard_good.txt", "mined_bad_v2.txt"]
if all(f -> isfile(joinpath(@__DIR__, f)), gt_files)
    println("\n=== end-to-end validation against mined ground truth (cluster co-membership) ===")
    group_id = Dict{String,Int}()
    for (gi, g) in enumerate(final_groups)
        for nm in g
            group_id[nm] = gi
        end
    end
    good_pairs = vcat(
        load_pairs(joinpath(@__DIR__, "mined_trivial_good.txt")),
        load_pairs(joinpath(@__DIR__, "mined_hard_good.txt")),
    )
    bad_pairs = load_pairs(joinpath(@__DIR__, "mined_bad_v2.txt"))

    function same_cluster(a, b)
        haskey(group_id, a) && haskey(group_id, b) || return missing
        group_id[a] == group_id[b]
    end

    good_found = filter(x -> !ismissing(x[3]), [(a,b,same_cluster(a,b)) for (a,b) in good_pairs])
    bad_found = filter(x -> !ismissing(x[3]), [(a,b,same_cluster(a,b)) for (a,b) in bad_pairs])
    println("good pairs with both names present: ", length(good_found), " / ", length(good_pairs))
    println("bad pairs with both names present: ", length(bad_found), " / ", length(bad_pairs))

    fn = count(x -> x[3] == false, good_found)
    fp = count(x -> x[3] == true, bad_found)
    println("FN (good pair, different cluster) = ", fn, " / ", length(good_found), " (", round(100*fn/length(good_found),digits=3), "%)")
    println("FP (bad pair, same cluster) = ", fp, " / ", length(bad_found), " (", round(100*fp/length(bad_found),digits=3), "%)")
    println("(a handful of these are mining label bugs, not real metric failures -- see mine_ground_truth.jl's docstring)")
else
    println("\n(skipping mined-ground-truth validation -- run mine_ground_truth.jl first to generate ", join(gt_files, ", "), ")")
end

# ============================================================
# Hand-picked regression suite (mirrors test/runtests.jl's _plausibly_same_person cases)
# ============================================================
println("\n=== hand-picked regression set (m=0.9, mm=0.34, s=0.5) ===")
function plausibly_same_v4(a, b; s=0.5, m=0.9, mm=0.34)
    r = name_similarity_v4(a, b)
    r.surname >= s && r.match >= m && r.mismatch_frac <= mm
end
cases_false = [
    ("A. Alberto R. Fernandes", "PATRICIA FERNANDES"), ("ADDY LETICIA ZARZA GARCIA", "Jesús Ortega García"),
    ("Carlos Corona-García", "Salomon Vasquez-Garcia"), ("Méndez Cabrera, Socorro", "Valdez Cabrera, Celia"),
    ("Paul Dupree", "ray dupree"), ("JHON LEANDRO PEREZ", "JULIO CESAR PEREZ PEREZ"),
    ("JULIAN RAMIREZ GONZALEZ", "Javier Rendón González"), ("RIGOBERTO ORTEGA PEREZ", "RODOLFO ORTIZ PEREZ"),
    ("MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ"), ("MIGUEL ANGEL LARA TREJO", "Mario Trejo"),
    ("0000-0001-7887-7580", "0000-0002-8080-8186"), ("Juan Perez Gomez", "Juan Gomez Hernandez"),
]
cases_true = [
    ("Juan Antonio Garcia Lopez", "J. A. Garcia-Lopez"), ("JEWEL NICOLE ANNA TODD", "Jewel Todd"),
    ("Alejandro Anaya", "Anaya, A. (Alejandro)"), ("Barrón, L. (Luis)", "Luis Felipe Barrón"),
    ("Juan Tellez Avila", "Juan Tellez"), ("Juan Tellez-Avila", "Juan Tellez"), ("J. Tellez Avila", "Juan Tellez"),
]
nfail = 0
for (a, b) in cases_false
    r = name_similarity_v4(a, b); ok = !plausibly_same_v4(a, b)
    ok || (global nfail += 1)
    println(ok ? "OK  " : "FAIL", " (expect false) match=", round(r.match,digits=3), " mismatch=", round(r.mismatch_frac,digits=3), " surname=", round(r.surname,digits=3), "  \"$a\" <-> \"$b\"")
end
for (a, b) in cases_true
    r = name_similarity_v4(a, b); ok = plausibly_same_v4(a, b)
    ok || (global nfail += 1)
    println(ok ? "OK  " : "FAIL", " (expect true)  match=", round(r.match,digits=3), " mismatch=", round(r.mismatch_frac,digits=3), " surname=", round(r.surname,digits=3), "  \"$a\" <-> \"$b\"")
end
println("\nTOTAL FAILURES (hand-picked): ", nfail)
println("DONE")
