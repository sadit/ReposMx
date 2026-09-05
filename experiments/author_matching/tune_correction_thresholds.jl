#=
Threshold-tuning experiment for `NameVocabulary.correct_token`, run against the 93-repo vocabulary
artifact (`vocab_93repos.txt`, built by `build_vocabulary_93repos.jl` in this same directory) --
NOT wired into `src/`, a standalone research script, same status as `mine_ground_truth.jl`.

## Why this needs its own ground truth (not the existing mined_*.txt files)

`mined_trivial_good.txt`/`mined_hard_good.txt`/`mined_bad_v2.txt` (mined by `mine_ground_truth.jl`)
label whole-NAME pairs as same-person or not -- the right ground truth for validating
`PrecisionClustering`/`Imputation`, but too coarse for tuning `correct_token`'s thresholds
specifically: a name pair can differ for many reasons besides one misspelled token, so a token-level
correction decision doesn't have a clean win/loss signal in that data. Two purpose-built evaluation
sets instead:

- **Recall set** (does correction catch a real typo?): synthetic single-edit corruptions of the
  TOP 300 most popular tokens per role (substitution/deletion/insertion/transposition, one edit
  each, seeded for reproducibility) -- a corruption that happens to collide with a DIFFERENT real
  vocabulary entry is dropped (ambiguous, not a clean test). `correct_token` should recover the
  original popular token from its corrupted form.
- **Precision set** (does correction avoid conflating two DIFFERENT real names?): pairs of
  q-gram-similar tokens (via `NameVocabulary`'s own candidate index, so this stays cheap at
  73K-token scale -- an all-pairs comparison would be O(vocab^2)) where BOTH sides already have
  popularity > 1, i.e. both are independently established real spellings, not a rare/typo
  candidate for either. `correct_token`, when run on the LESS popular side, must NOT "correct" it
  toward the more popular one -- exactly the `"Fernandez"->"Hernandez"`/`"Alejandra"->"alejandro"`
  failure mode found live earlier this session, characterized precisely enough now to build a
  proper test set around it instead of spot-checking examples by hand.

## Usage

`julia --project=. experiments/author_matching/tune_correction_thresholds.jl` from the repo root,
after `build_vocabulary_93repos.jl` has produced `vocab_93repos.txt`. No corpus re-collection
needed -- loads the saved vocabulary artifact directly.
=#

using ReposMx
using Random
const AC = ReposMx.AuthorConsolidation
const NV = ReposMx.NameVocabulary

const ARTIFACT_PATH = joinpath(@__DIR__, "vocab_93repos.txt")

function load_vocabulary_artifact(path::AbstractString)
    counts = Dict{Tuple{String,Symbol},Int}()
    for line in eachline(path)
        parts = split(line, "\t")
        length(parts) == 3 || continue
        counts[(parts[2], Symbol(parts[1]))] = parse(Int, parts[3])
    end
    return NV.Vocabulary(counts)
end

"""
    _corrupt(rng, token) -> String

One random single-character edit (substitution/deletion/insertion/transposition, each equally
likely) -- deliberately the simplest realistic typo model, not a full OCR/keyboard-adjacency
simulation (this experiment cares about relative threshold behavior, not modeling every real typo
source).
"""
function _corrupt(rng::AbstractRNG, token::AbstractString)
    chars = collect(token)
    n = length(chars)
    op = rand(rng, 1:4)
    letters = 'a':'z'
    if op == 1 && n >= 1  # substitution
        i = rand(rng, 1:n)
        newc = rand(rng, letters)
        chars[i] = newc == chars[i] ? rand(rng, letters) : newc
    elseif op == 2 && n >= 2  # deletion
        deleteat!(chars, rand(rng, 1:n))
    elseif op == 3  # insertion
        i = rand(rng, 1:n+1)
        insert!(chars, i, rand(rng, letters))
    elseif op == 4 && n >= 2  # transposition
        i = rand(rng, 1:n-1)
        chars[i], chars[i+1] = chars[i+1], chars[i]
    else
        return _corrupt(rng, token)  # op not applicable at this length, retry
    end
    return String(chars)
end

"""
    build_recall_set(vocab, role; top_n=300, seed=1) -> Vector{Tuple{Symbol,String,String}}

`(role, original, corrupted)` triples for the `top_n` most popular tokens under `role` -- a
corruption colliding with a DIFFERENT existing vocabulary entry is dropped (retried with a new
corruption, up to a few attempts) since that would be an ambiguous test case, not a clean one.
`role` is carried alongside each pair (not just implied by which list it came from) so pairs from
different roles can be freely combined without losing which role each must be evaluated under.
"""
function build_recall_set(vocab::NV.Vocabulary, role::Symbol; top_n::Int=300, seed::Int=1)
    entries = [(t, c) for ((t, r), c) in vocab.counts if r == role]
    sort!(entries; by=last, rev=true)
    top = first(entries, min(top_n, length(entries)))
    rng = MersenneTwister(seed)
    triples = Tuple{Symbol,String,String}[]
    for (tok, _) in top
        corrupted = tok
        for _attempt in 1:5
            corrupted = _corrupt(rng, tok)
            other_hit = corrupted != tok && NV.in_vocab(vocab, corrupted, role)
            other_hit || break
        end
        corrupted == tok && continue
        NV.in_vocab(vocab, corrupted, role) && continue  # still collided after retries, skip
        push!(triples, (role, tok, corrupted))
    end
    return triples
end

"""
    build_precision_set(vocab, role; min_popularity=2, max_pairs=500) -> Vector{Tuple{Symbol,String,String}}

`(role, more_popular, less_popular)` triples for DIFFERENT, q-gram-similar tokens under `role`,
both with popularity `>= min_popularity` -- both sides independently established, so
`correct_token` run on the less popular one must return it UNCHANGED. Uses `NameVocabulary`'s own
candidate index (`_candidates`) for cheap generation instead of an O(vocab^2) all-pairs scan.
"""
function build_precision_set(vocab::NV.Vocabulary, role::Symbol; min_popularity::Int=2, max_pairs::Int=500)
    established = [(t, c) for ((t, r), c) in vocab.counts if r == role && c >= min_popularity]
    seen = Set{Tuple{String,String}}()
    triples = Tuple{Symbol,String,String}[]
    for (tok, pop) in established
        for cand in NV._candidates(vocab, tok, role)
            cand == tok && continue
            cand_pop = NV.popularity(vocab, cand, role)
            cand_pop < min_popularity && continue
            a, b = pop >= cand_pop ? (tok, cand) : (cand, tok)
            (a, b) in seen && continue
            push!(seen, (a, b))
            push!(triples, (role, a, b))
            length(triples) >= max_pairs && return triples
        end
    end
    return triples
end

function evaluate(vocab, recall_set, precision_set; kwargs...)
    recall_hits = count(((role, orig, corrupted),) -> first(NV.correct_token(vocab, corrupted, role; kwargs...)) == orig,
                         recall_set)
    precision_hits = count(((role, popular, rare),) -> first(NV.correct_token(vocab, rare, role; kwargs...)) == rare,
                            precision_set)
    recall = length(recall_set) == 0 ? NaN : recall_hits / length(recall_set)
    precision_ok_rate = length(precision_set) == 0 ? NaN : precision_hits / length(precision_set)
    return (; recall, precision_ok_rate, recall_hits, precision_hits)
end

function main()
    vocab = load_vocabulary_artifact(ARTIFACT_PATH)
    println("vocabulary: ", length(vocab.counts), " (token,role) entries")

    recall_set = vcat(build_recall_set(vocab, :given), build_recall_set(vocab, :surname))
    precision_set = vcat(build_precision_set(vocab, :given), build_precision_set(vocab, :surname))
    println("recall set (synthetic typos of popular tokens): ", length(recall_set))
    println("precision set (real q-gram-similar established pairs): ", length(precision_set))

    println("\n--- method=:qgram, sweeping min_qgram_sim and max_own_popularity (min_popularity_ratio=2.0 fixed) ---")
    for max_own_pop in (1, 2, 3), min_qgram_sim in (0.4, 0.5, 0.6, 0.7)
        r = evaluate(vocab, recall_set, precision_set; method=:qgram, max_own_popularity=max_own_pop, min_qgram_sim=min_qgram_sim)
        println("  max_own_popularity=$max_own_pop  min_qgram_sim=$min_qgram_sim  ",
                "recall=", round(r.recall, digits=3), " (", r.recall_hits, "/", length(recall_set), ")  ",
                "precision_ok_rate=", round(r.precision_ok_rate, digits=3), " (", r.precision_hits, "/", length(precision_set), ")")
    end

    println("\n--- method=:qgram, sweeping min_popularity_ratio (max_own_popularity=1, min_qgram_sim=0.5 fixed) ---")
    for ratio in (2.0, 3.0, 5.0, 10.0, 20.0)
        r = evaluate(vocab, recall_set, precision_set; method=:qgram, max_own_popularity=1, min_qgram_sim=0.5, min_popularity_ratio=ratio)
        println("  min_popularity_ratio=$ratio  ",
                "recall=", round(r.recall, digits=3), " (", r.recall_hits, "/", length(recall_set), ")  ",
                "precision_ok_rate=", round(r.precision_ok_rate, digits=3), " (", r.precision_hits, "/", length(precision_set), ")")
    end

    println("\n--- method=:levenshtein, sweeping max_distance and max_own_popularity ---")
    for max_own_pop in (1, 2), max_distance in (1, 2)
        r = evaluate(vocab, recall_set, precision_set; method=:levenshtein, max_own_popularity=max_own_pop, max_distance=max_distance)
        println("  max_own_popularity=$max_own_pop  max_distance=$max_distance  ",
                "recall=", round(r.recall, digits=3), " (", r.recall_hits, "/", length(recall_set), ")  ",
                "precision_ok_rate=", round(r.precision_ok_rate, digits=3), " (", r.precision_hits, "/", length(precision_set), ")")
    end

    println("\n--- method=:damerau, sweeping max_distance and max_own_popularity ---")
    for max_own_pop in (1, 2), max_distance in (1, 2)
        r = evaluate(vocab, recall_set, precision_set; method=:damerau, max_own_popularity=max_own_pop, max_distance=max_distance)
        println("  max_own_popularity=$max_own_pop  max_distance=$max_distance  ",
                "recall=", round(r.recall, digits=3), " (", r.recall_hits, "/", length(recall_set), ")  ",
                "precision_ok_rate=", round(r.precision_ok_rate, digits=3), " (", r.precision_hits, "/", length(precision_set), ")")
    end

    println("\n--- current default (method=:qgram, max_own_popularity=1, min_popularity_ratio=2.0, min_qgram_sim=0.5) ---")
    r = evaluate(vocab, recall_set, precision_set)
    println("  recall=", round(r.recall, digits=3), " (", r.recall_hits, "/", length(recall_set), ")  ",
            "precision_ok_rate=", round(r.precision_ok_rate, digits=3), " (", r.precision_hits, "/", length(precision_set), ")")
end

main()
println("\nTUNE_CORRECTION_THRESHOLDS_DONE")
