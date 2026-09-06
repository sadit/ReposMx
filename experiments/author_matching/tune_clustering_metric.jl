#=
Threshold-tuning experiment for `PrecisionClustering`'s CLUSTERING-level string-similarity metric
(`_precision_token_score`/`precision_match_score`'s `method` kwarg) -- NOT the vocabulary
correction metric (`NameVocabulary.correct_token`'s own `method`, already tuned separately in
`tune_correction_thresholds.jl`). Run against the real 10-repo corpus (same subset used throughout
this codebase's author-matching validation, see `mine_ground_truth.jl`) -- NOT wired into `src/`, a
standalone research script, same status as the other experiment files in this directory.

## Why this is a SEPARATE tuning pass from correction

`NameVocabulary.correct_token` only touches a token when it is essentially a singleton spelling
(`max_own_popularity=1`) -- two ESTABLISHED spelling variants (both popular) are deliberately left
untouched by correction, on purpose, to avoid flattening distinct real names into each other. If
`PrecisionClustering`'s own clustering step didn't ALSO tolerate some spelling variation on
already-corrected tokens, those established variants (or any typo correction declined to touch)
would never connect. Until 2026-09-06 that tolerance was `AC._qgram_jaccard` (Jaccard similarity of
character q-grams); this experiment measures whether switching it to the SAME
`SimilaritySearch.Dist.Seqs.DamerauLevenshtein` metric `correct_token` already uses (normalized as
`1 - distance/max(length(a),length(b))`, exactly matching that function's own scoring formula) is a
net win, and if so, what `match_threshold`/`surname_threshold` values it needs -- q-gram Jaccard and
edit-distance-normalized scores are NOT on the same scale for the same input (a single substitution
in a 10-character word costs one full q-gram-window's worth of overlap loss under Jaccard, versus a
flat `1/10` under the edit-distance formula), so the OLD 0.9/0.9 thresholds cannot be assumed to
transfer -- they need their own measurement, exactly like every other threshold decision in this
codebase's author-matching work.

## What's measured

For each (`method`, `match_threshold`, `surname_threshold`) combination: `n groups`, group-level
agreement/disagreement against production's `AC.compute_name_clusters` (same-canonicalized-set
diff, NOT just count), and same-cluster rate against the mined ground truth
(`mined_trivial_good.txt`/`mined_hard_good.txt`/`mined_bad_v2.txt`, produced by `mine_ground_truth.jl`
-- run that first if these files don't exist yet).

## Usage

`julia --project=. experiments/author_matching/tune_clustering_metric.jl` from the repo root, after
a normal 10-repo corpus build (`buap`/`ccg`/`centrogeo`/`ciad`/`ciatec`/`ciateq`/`cicese`/`cicy`/
`cide`/`cidesi`, same subset as `mine_ground_truth.jl`) and after running `mine_ground_truth.jl` at
least once to produce the ground-truth files this script reads.
=#

using ReposMx
const AC = ReposMx.AuthorConsolidation
const NV = ReposMx.NameVocabulary
const PC = ReposMx.PrecisionClustering

const REPOS10 = ["buap", "ccg", "centrogeo", "ciad", "ciatec", "ciateq", "cicese", "cicy", "cide", "cidesi"]
const GT_DIR = @__DIR__

function load_pairs(path)
    pairs = Tuple{String,String}[]
    for line in eachline(path)
        parts = split(line, " ||| ")
        length(parts) == 2 || continue
        push!(pairs, (String(parts[1]), String(parts[2])))
    end
    return pairs
end

function group_index(groups)
    idx = Dict{String,Int}()
    for (gi, g) in enumerate(groups), nm in g
        idx[nm] = gi
    end
    return idx
end

function same_cluster_rate(idx, pairs)
    n = 0
    hits = 0
    for (a, b) in pairs
        (haskey(idx, a) && haskey(idx, b)) || continue
        n += 1
        idx[a] == idx[b] && (hits += 1)
    end
    return n == 0 ? (0.0, 0, 0) : (hits / n, hits, n)
end

canon(groups) = Set(Tuple(sort(g)) for g in groups)

function main()
    all_docs, _, _, _ = ReposMx.Indexing._collect_documents(; repos=REPOS10)
    authors_data = ReposMx.Corpus.build_authors_index_data(all_docs)
    raw_names = sort(unique([a["name"] for a in authors_data]))
    println("n raw names = ", length(raw_names))

    print("PRODUCTION (compute_name_clusters): ")
    @time groups_prod = AC.compute_name_clusters(raw_names)
    println("  n groups = ", length(groups_prod))
    c_prod = canon(groups_prod)

    vocab = NV.build_name_vocabulary(raw_names)

    good_files = ["mined_trivial_good.txt", "mined_hard_good.txt", "mined_bad_v2.txt"]
    if !all(f -> isfile(joinpath(GT_DIR, f)), good_files)
        println("\n(missing mined ground truth files -- run mine_ground_truth.jl first; ",
                "continuing with group-count/diff-vs-production only)")
    end
    trivial_good = isfile(joinpath(GT_DIR, "mined_trivial_good.txt")) ? load_pairs(joinpath(GT_DIR, "mined_trivial_good.txt")) : Tuple{String,String}[]
    hard_good = isfile(joinpath(GT_DIR, "mined_hard_good.txt")) ? load_pairs(joinpath(GT_DIR, "mined_hard_good.txt")) : Tuple{String,String}[]
    bad = isfile(joinpath(GT_DIR, "mined_bad_v2.txt")) ? load_pairs(joinpath(GT_DIR, "mined_bad_v2.txt")) : Tuple{String,String}[]

    # (method, match_threshold, surname_threshold) combos to sweep -- :qgram at its established
    # 0.9/0.9 is the baseline to beat, not a combo needing its own sweep here (already validated
    # over this whole session).
    combos = [
        (:qgram, 0.9, 0.9),
        (:damerau, 0.9, 0.9),
        (:damerau, 0.85, 0.9),
        (:damerau, 0.8, 0.9),
        (:damerau, 0.75, 0.9),
        (:damerau, 0.7, 0.9),
        (:damerau, 0.8, 0.8),
        (:damerau, 0.75, 0.8),
    ]

    println("\n", rpad("method", 10), rpad("match_thr", 10), rpad("surn_thr", 10), rpad("n_groups", 10),
            rpad("only_prod", 10), rpad("only_this", 10), rpad("total_diff", 11),
            rpad("trivial", 9), rpad("hard", 9), "bad")
    for (method, mt, st) in combos
        t0 = time()
        groups = PC.compute_precision_clusters(raw_names, vocab; method=method, match_threshold=mt, surname_threshold=st)
        elapsed = time() - t0
        idx = group_index(groups)
        c = canon(groups)
        only_prod = length(setdiff(c_prod, c))
        only_this = length(setdiff(c, c_prod))
        rt, _, _ = same_cluster_rate(idx, trivial_good)
        rh, _, _ = same_cluster_rate(idx, hard_good)
        rb, _, _ = same_cluster_rate(idx, bad)
        println(rpad(string(method), 10), rpad(string(mt), 10), rpad(string(st), 10), rpad(string(length(groups)), 10),
                rpad(string(only_prod), 10), rpad(string(only_this), 10), rpad(string(only_prod + only_this), 11),
                rpad(string(round(rt, digits=4)), 9), rpad(string(round(rh, digits=4)), 9), round(rb, digits=4),
                "   (", round(elapsed, digits=1), "s)")
    end

    # --- contradiction_floor sweep, :damerau only, connect thresholds fixed at the validated 0.9/0.9 ---
    # Found live: PRECISION_CONTRADICTION_FLOOR=0.2 (right for :qgram) lets real false positives
    # through under :damerau -- "torres"/"morales" scores 0.571, "hernandez"/"adrian" scores 0.333,
    # both comfortably above 0.2 despite being unambiguously different people. Sweeping higher floor
    # values to see how much of that this catches, and at what recall cost (a floor set too high
    # starts rejecting genuine typos too -- "fedorovish"/"federovish", a transposition, scores 0.9,
    # almost identical to "alejandra"/"alejandro"'s 0.889 despite one being a typo and the other a
    # different, gendered name -- these two may not be separable by this floor alone).
    println("\n--- contradiction_floor sweep (:damerau, match_threshold=surname_threshold=0.9) ---")
    println(rpad("floor", 8), rpad("n_groups", 10), rpad("only_prod", 10), rpad("only_this", 10),
            rpad("total_diff", 11), rpad("trivial", 9), rpad("hard", 9), "bad")
    for floor in (0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9)
        groups = PC.compute_precision_clusters(raw_names, vocab; method=:damerau, contradiction_floor=floor)
        idx = group_index(groups)
        c = canon(groups)
        only_prod = length(setdiff(c_prod, c))
        only_this = length(setdiff(c, c_prod))
        rt, _, _ = same_cluster_rate(idx, trivial_good)
        rh, _, _ = same_cluster_rate(idx, hard_good)
        rb, _, _ = same_cluster_rate(idx, bad)
        println(rpad(string(floor), 8), rpad(string(length(groups)), 10),
                rpad(string(only_prod), 10), rpad(string(only_this), 10), rpad(string(only_prod + only_this), 11),
                rpad(string(round(rt, digits=4)), 9), rpad(string(round(rh, digits=4)), 9), round(rb, digits=4))
    end

    println("\nTUNE_CLUSTERING_METRIC_DONE")
end

main()
