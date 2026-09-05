#=
Builds a `NameVocabulary.Vocabulary` over the FULL 93-repo corpus and saves it as a plain-text
artifact -- NOT wired into `src/`, a standalone research script, same status as
`mine_ground_truth.jl` in this same directory.

## Why 93 repos, not the 10-repo development subset

`NameVocabulary.correct_token`'s thresholds (`max_own_popularity`, `min_popularity_ratio`,
`min_qgram_sim`, `max_distance`) need real popularity statistics to tune against, and a 10-repo
vocabulary is too small a sample for that: on 19,543 raw names, MANY genuinely real (not
misspelled) given/surnames only ever appear once purely because the corpus is small, not because
they're actually rare in the Mexican-institutional-repository population this whole pipeline is
built for. Tuning thresholds against a vocabulary that conflates "rare in this small sample" with
"rare in general" risks the exact failure already found live this session: `correct_token`
flattening genuinely distinct, real names into a more-common one merely because the smaller sample
happened not to see the rare one more than once (see `NameVocabulary.jl`'s own docstring for the
concrete `"alejandre"`->`"alejandro"`, `"riveron"`->`"rivero"` examples that motivated the
`max_own_popularity` gate in the first place). The full 93-repo corpus (~452K raw names, per this
session's earlier bucket-size diagnostics) gives real names far more chances to appear more than
once, so `max_own_popularity`'s "occurs at most once" signal should be a much more reliable typo
indicator there than on the 10-repo subset.

## Artifact format

Plain UTF-8 text, one `(token, role, count)` triple per line, tab-separated:

```
given	juan	1234
surname	hernandez	5678
```

Deliberately NOT a serialized Julia object (`Serialization.serialize`): plain text is
grep-able/diff-able, portable across Julia versions, and trivial to reload (see
`load_vocabulary_artifact` below) -- the `qgram_index` half of a `Vocabulary` is cheap to rebuild
from `counts` alone (`NameVocabulary.Vocabulary(counts)`, added specifically to support this), so
there is nothing else worth persisting. Written to `vocab_93repos.txt` next to this file --
gitignored (regenerate, don't commit; same reasoning as `mined_*.txt` -- this is derived data tied
to whatever repos happen to be harvested locally, not source).

## Usage

`julia --project=. experiments/author_matching/build_vocabulary_93repos.jl` from the repo root,
after a normal harvest/build-corpus for all repos under `data/repos/`. Takes a while (collects
structured documents from all 93 repos, matching this session's other full-corpus scripts) --
run it once, then reuse the saved artifact via `load_vocabulary_artifact` in threshold-tuning
experiments instead of re-collecting the whole corpus each time.
=#

using ReposMx
const AC = ReposMx.AuthorConsolidation
const NV = ReposMx.NameVocabulary

const ARTIFACT_PATH = joinpath(@__DIR__, "vocab_93repos.txt")

"""
    all_93_repo_names(data_dir) -> Vector{String}

Every real harvested repo directory name under `data_dir` (`data/repos` at the project root),
EXCLUDING the two non-repo entries that live alongside them on disk (`"profiles"`, `"rocksdb"` --
confirmed by direct listing this session: `data/repos` has 95 entries, 93 of which are real repos).
Deliberately not read from a cached `/tmp` file (as earlier ad hoc scripts this session did) --
this script should reproduce its own repo list from source so it stays runnable in a fresh
environment.
"""
function all_93_repo_names(data_dir::AbstractString)
    non_repo_dirs = Set(["profiles", "rocksdb"])
    return sort([d for d in readdir(data_dir) if isdir(joinpath(data_dir, d)) && d ∉ non_repo_dirs])
end

"""
    save_vocabulary_artifact(v::NV.Vocabulary, path) -> Nothing

Writes `v.counts` to `path` in the tab-separated format documented above.
"""
function save_vocabulary_artifact(v::NV.Vocabulary, path::AbstractString)
    open(path, "w") do io
        for ((tok, role), cnt) in sort(collect(v.counts); by=first)
            println(io, role, "\t", tok, "\t", cnt)
        end
    end
    return nothing
end

"""
    load_vocabulary_artifact(path) -> NV.Vocabulary

Reloads a vocabulary saved by [`save_vocabulary_artifact`](@ref) -- reuse this from a
threshold-tuning script instead of re-collecting the 93-repo corpus each time.
"""
function load_vocabulary_artifact(path::AbstractString)
    counts = Dict{Tuple{String,Symbol},Int}()
    for line in eachline(path)
        parts = split(line, "\t")
        length(parts) == 3 || continue
        counts[(parts[2], Symbol(parts[1]))] = parse(Int, parts[3])
    end
    return NV.Vocabulary(counts)
end

function main()
    data_dir = joinpath(dirname(dirname(@__DIR__)), "data", "repos")
    repos93 = all_93_repo_names(data_dir)
    println("n repos = ", length(repos93))

    print("collecting documents: ")
    @time all_docs, _, _, _ = ReposMx.Indexing._collect_documents(; repos=repos93)
    authors_data = ReposMx.Corpus.build_authors_index_data(all_docs)
    raw_names = sort(unique([a["name"] for a in authors_data]))
    println("n raw names = ", length(raw_names))

    print("building vocabulary: "); @time vocab = NV.build_name_vocabulary(raw_names)
    n_given = count(k -> k[2] == :given, keys(vocab.counts))
    n_surname = count(k -> k[2] == :surname, keys(vocab.counts))
    println("distinct (token,role) entries = ", length(vocab.counts), "  (given=$n_given, surname=$n_surname)")

    # popularity distribution -- directly relevant to calibrating max_own_popularity/
    # min_popularity_ratio: how many distinct tokens would even be ELIGIBLE for correction
    # (popularity <= 1, the current default gate) vs. clearly-established (popularity > 1)?
    pops = collect(values(vocab.counts))
    n_pop1 = count(==(1), pops)
    n_pop_le5 = count(<=(5), pops)
    println("tokens with popularity == 1: $n_pop1 / $(length(pops)) (", round(100n_pop1/length(pops), digits=1), "%)")
    println("tokens with popularity <= 5: $n_pop_le5 / $(length(pops)) (", round(100n_pop_le5/length(pops), digits=1), "%)")
    println("max popularity (most common single token): ", maximum(pops))

    save_vocabulary_artifact(vocab, ARTIFACT_PATH)
    println("\nwrote artifact to ", ARTIFACT_PATH)

    # round-trip sanity check before trusting the artifact for future runs
    reloaded = load_vocabulary_artifact(ARTIFACT_PATH)
    @assert reloaded.counts == vocab.counts "round-trip mismatch -- artifact save/load is not lossless"
    println("round-trip check: OK (reloaded counts identical to the in-memory vocabulary)")
end

main()
println("\nBUILD_VOCABULARY_93REPOS_DONE")
