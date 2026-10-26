# Captures the answers of the search layer to a fixed set of queries, and compares two captures.
#
#     julia --project=. -t auto test/golden/capture.jl capture test/golden/reference.json
#     julia --project=. -t auto test/golden/capture.jl compare test/golden/reference.json new.json
#
# The queries are drawn from the corpus with a fixed seed, so two runs over the same corpus ask
# the same questions. A capture records, for each query, the keys of the results in rank order
# and their scores. `compare` reports the queries whose keys differ and the largest difference
# of score between results with the same key.
#
# This is the reference for moving the search layer onto SimilaritySearchEngine
# (docs/plan-motor.md): phase 2 must reproduce it, and phase 3 measures its changes against it.

using ReposMx, JSON3, Random
using ReposMx.Storage: list_repo_names, load_corpus_records

const SEED = 20261024
const TOP = 10

function sample_queries(; data_dir=ReposMx.Config.DEFAULT_DATA_DIR)
    rng = Xoshiro(SEED)
    docs = Dict{String,Any}[]
    for r in sort(list_repo_names(; data_dir))
        append!(docs, load_corpus_records(r; data_dir))
    end
    isempty(docs) && error("no corpus records under $data_dir")
    pick() = docs[rand(rng, 1:length(docs))]
    words(s, n) = join(first(split(String(s)), n), " ")

    q = (; docs=NamedTuple[], authors=NamedTuple[], refs=NamedTuple[], similar_docs=NamedTuple[])
    while length(q.docs) < 80
        d = pick()
        kws = filter(k -> length(k) >= 3, String.(get(d, "keywords", String[])))
        isempty(kws) || push!(q.docs, (; q=rand(rng, kws)))
    end
    while length(q.docs) < 120
        t = words(get(pick(), "title", ""), 4)
        isempty(t) || push!(q.docs, (; q=t))
    end
    # Filtered and paged forms of some of the queries above.
    for i in 1:20
        d = pick()
        base = q.docs[i].q
        push!(q.docs, (; q=base, repo=String(d["repo"])))
        push!(q.docs, (; q=base, year_min=2010, year_max=2020))
        push!(q.docs, (; q=base, doc_type="tesis"))
        push!(q.docs, (; q=base, offset=TOP))
    end
    while length(q.authors) < 30
        cs = String.(get(pick(), "creators", String[]))
        isempty(cs) || push!(q.authors, (; q=first(cs)))
    end
    for i in 1:10
        push!(q.authors, (; q=q.authors[i].q, repo=String(pick()["repo"])))
    end
    while length(q.refs) < 30
        refs = get(pick(), "references", Any[])
        isempty(refs) && continue
        t = words(get(rand(rng, refs), "text", ""), 5)
        isempty(t) || push!(q.refs, (; q=t))
    end
    while length(q.similar_docs) < 15
        d = pick()
        get(d, "reference_count", 0) > 0 && push!(q.similar_docs, (; repo=String(d["repo"]), doc_id=String(d["id"])))
    end
    return q
end

opts(x) = (; (k => v for (k, v) in pairs(x) if k !== :q)...)

function capture(path)
    q = sample_queries()
    engine = ReposMx.Search.SearchEngine()
    out = Dict{String,Any}("seed" => SEED, "docs" => [], "authors" => [], "refs" => [],
                           "similar_authors" => [], "similar_docs" => [])
    try
        for x in q.docs
            r = ReposMx.Search.query_index(engine, x.q; top=TOP, opts(x)...)
            push!(out["docs"], Dict("query" => x, "has_more" => r["has_more"],
                                    "keys" => ["$(h["repo"]):$(h["id"])" for h in r["hits"]],
                                    "scores" => [h["score"] for h in r["hits"]]))
        end
        for x in q.authors
            r = ReposMx.Search.search_authors(engine, x.q; top=TOP, opts(x)...)
            push!(out["authors"], Dict("query" => x, "has_more" => r["has_more"],
                                       "keys" => [a["consolidated_id"] for a in r["authors"]],
                                       "scores" => [a["score"] for a in r["authors"]]))
        end
        # The similar-author queries start from the top author of each name query.
        for a in out["authors"][1:15]
            isempty(a["keys"]) && continue
            r = ReposMx.Search.find_similar_authors_by_profile(engine, first(a["keys"]); top=TOP)
            push!(out["similar_authors"], Dict("query" => first(a["keys"]),
                                               "keys" => [s["consolidated_id"] for s in r["similar_authors"]],
                                               "scores" => [s["score"] for s in r["similar_authors"]]))
        end
        for x in q.refs
            r = ReposMx.Search.search_references(engine, x.q; top=TOP)
            push!(out["refs"], Dict("query" => x, "has_more" => r["has_more"],
                                    "keys" => ["$(h["repo"]):$(h["doc_id"])" for h in r["references"]],
                                    "scores" => [h["score"] for h in r["references"]]))
        end
        for x in q.similar_docs
            r = ReposMx.Search.find_similar_documents_by_references(engine, x.repo, x.doc_id; top=TOP)
            push!(out["similar_docs"], Dict("query" => "$(x.repo):$(x.doc_id)",
                                            "keys" => ["$(h["repo"]):$(h["id"])" for h in r["similar_documents"]],
                                            "scores" => [h["score"] for h in r["similar_documents"]]))
        end
    finally
        close(engine)
    end
    open(io -> JSON3.pretty(io, out), path, "w")
    println("wrote ", path, ": ", join(("$k=$(length(out[k]))" for k in ("docs", "authors", "similar_authors", "refs", "similar_docs")), ", "))
end

function compare(path_a, path_b)
    a, b = JSON3.read(read(path_a)), JSON3.read(read(path_b))
    a[:seed] == b[:seed] || error("the two captures were drawn with different seeds")
    for section in (:docs, :authors, :similar_authors, :refs, :similar_docs)
        same, maxdiff = 0, 0.0
        for (x, y) in zip(a[section], b[section])
            if collect(x[:keys]) == collect(y[:keys])
                same += 1
                isempty(x[:scores]) || (maxdiff = max(maxdiff, maximum(abs.(x[:scores] .- y[:scores]))))
            else
                println("  $section: ", x[:query], " -> ", length(intersect(x[:keys], y[:keys])), "/",
                        length(x[:keys]), " keys in common")
            end
        end
        println("$section: $same/$(length(a[section])) with identical keys, largest score difference $maxdiff")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    cmd = get(ARGS, 1, "")
    cmd == "capture" && length(ARGS) == 2 ? capture(ARGS[2]) :
    cmd == "compare" && length(ARGS) == 3 ? compare(ARGS[2], ARGS[3]) :
    error("usage: capture.jl capture OUT.json | compare A.json B.json")
end
