# Experimento (2026-11-26): inferir la clasificación CTI (área, campo, disciplina) de los documentos que no la
# declaran, con los que sí como entrenamiento. Se descartó: la CTI se queda como metadato declarado, no como dato
# para aprender (decisión del usuario). Resultados, acierto de la primera etiqueta en el 10 % apartado:
#
#   | Nivel             | Vecinos (todos los etiquetados) | Prototipos consistentes | 50 % más limpio | 25 % |
#   |-------------------|------:|------:|------:|------:|
#   | Área (7)          | 0.772 | 0.759 | 0.733 | 0.708 |
#   | Campo (24)        | 0.701 | 0.685 | 0.647 | 0.610 |
#   | Disciplina (236)  | 0.503 | 0.471 | 0.403 | 0.322 |
#
# Consistentes con su vecindario: 77 % de las áreas, 69 % de los campos y 51 % de las disciplinas declaradas.
# Las funciones de vecinos (SimilaritySearch, exacta), entropía y prototipos se reutilizan para las palabras
# clave. Uso (desde la raíz): julia +1.13.3 --project=. -t auto -e 'include("experiments/rag_web/cti_inferencia.jl");
#   CTIInference.infer_cti(); CTIInference.infer_cti_prototypes()'

"""
    CTIInference

The CTI classification (área, campo, disciplina) of the documents that do not declare it, inferred from
those that do (decision of the user, 2026-11-26: enrich each group and subgroup now with a simple
classifier, and see later whether a better one is worth it).

Each document is represented by the vector of its record (the `ficha` unit of the dense export). A
document without a label at a level gets the labels of its `k` nearest labeled documents at that level,
each weighted by its cosine similarity, compared exactly. The levels are chosen top-down: the campo among
the campos of the área (declared, or else inferred), the disciplina among the disciplinas of the campo. A
declared label is never replaced. Part of the labeled documents of each level is held out to measure the
accuracy (the predicted label is one of the declared ones).

[`infer_cti`](@ref) writes `<dense_dir>/cti_inferida.jsonl` and `cti_inferida.json` (the summary).
They were added to the declared labels in partition followers of the dense project while this was tried.
"""
module CTIInference

using JSON, LinearAlgebra, Random, Dates
import SimilaritySearch
using ReposMx
using ReposMx.Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR, DEFAULT_CATALOGS_DIR
using ReposMx.Storage: list_repo_names, load_corpus_records
using ReposMx.Corpus: is_text_document
using ReposMx.Catalogs: _cti_dicts, _cti_area_of_campo
using ReposMx.EngineIndex: doc_key_of
using ReposMx.Dense: dense_dir, _shard, DIM

export infer_cti, infer_cti_prototypes, INFERRED_FILE

const INFERRED_FILE = "cti_inferida.jsonl"
const LEVELS = ("areas", "campos", "disciplinas")

"""
    cti_hierarchy(catalogs_dir) -> (area_of_campo, campo_of_disciplina)

By name: the área of each campo (campo catalog) and the campo of each disciplina (the prefix of its code).
"""
function cti_hierarchy(catalogs_dir::AbstractString=DEFAULT_CATALOGS_DIR)
    area, campo, disciplina, _ = _cti_dicts(catalogs_dir)
    area_of = Dict{String,String}()
    for (c, a) in _cti_area_of_campo(catalogs_dir)
        haskey(campo, c) && haskey(area, a) && (area_of[campo[c]] = area[a])
    end
    campo_of = Dict{String,String}()
    for (d, name) in disciplina
        haskey(campo, d[1:2]) && (campo_of[name] = campo[d[1:2]])
    end
    return area_of, campo_of
end

# The record vector (normalized) of every document in text of the export, and its key "<repo>:<id>".
function ficha_vectors(index_dir, data_dir)
    dir = dense_dir(index_dir)
    excluded = Set{String}()
    for repo in list_repo_names(; data_dir), doc in load_corpus_records(repo; data_dir)
        is_text_document(string(something(get(doc, "type", ""), ""))) ||
            push!(excluded, doc_key_of(repo, string(get(doc, "id", ""))))
    end
    vec_of = Dict{String,Tuple{Int,Int}}()
    shards = Matrix{Float16}[]
    for n in sort([f[1:end-6] for f in readdir(joinpath(dir, "textos")) if endswith(f, ".jsonl")])
        isfile(joinpath(dir, "vectores", n * ".f16")) || error("$n has no vectors yet")
        V, texts = _shard(dir, n)
        push!(shards, V)
        for (j, t) in enumerate(texts)
            vec_of[t["sha"]] = (length(shards), j)
        end
    end
    keys = String[]
    cols = Tuple{Int,Int}[]
    for l in eachline(joinpath(dir, "unidades.jsonl"))
        u = JSON.parse(l)
        u["k"] == 0 || continue
        key = doc_key_of(u["repo"], u["id"])
        key in excluded && continue
        push!(keys, key)
        push!(cols, vec_of[u["sha"]])
    end
    X = Matrix{Float32}(undef, DIM, length(keys))
    Threads.@threads for i in eachindex(cols)
        s, j = cols[i]
        v = view(X, :, i)
        v .= view(shards[s], :, j)
        v ./= norm(v)
    end
    return keys, X
end

# The declared labels of each document of `keys` at each level: level => key => labels.
function declared_labels(keys, data_dir)
    want = Set(keys)
    out = Dict(l => Dict{String,Vector{String}}() for l in LEVELS)
    for repo in list_repo_names(; data_dir), doc in load_corpus_records(repo; data_dir)
        key = doc_key_of(repo, string(get(doc, "id", "")))
        key in want || continue
        for l in LEVELS
            v = get(doc, l, nothing)
            v isa AbstractVector && !isempty(v) && (out[l][key] = String[string(x) for x in v])
        end
    end
    return out
end

"""
    knn_scores(Xtr, ytr, Q, k) -> Vector{Dict{Int,Float32}}

For each column of `Q`, the labels of its `k` nearest columns of `Xtr`, each label scored with the sum of the
cosine similarities of the neighbors that carry it. `ytr[j]` holds the label numbers of column `j`. The
neighbors come from SimilaritySearch: an `ExhaustiveSearch` with `Dist.NormCosine` (the vectors are
normalized), so they are the exact ones; a graph would be compared against this one first (global notes).
"""
function knn_scores(Xtr::Matrix{Float32}, ytr::Vector{Vector{Int}}, Q::AbstractMatrix{Float32}, k::Int)
    k = min(k, size(Xtr, 2))
    E = SimilaritySearch.ExhaustiveSearch(SimilaritySearch.Dist.NormCosine(), SimilaritySearch.MatrixDatabase(Xtr))
    ids, dists = SimilaritySearch.searchbatch(E, SimilaritySearch.GenericContext(), SimilaritySearch.MatrixDatabase(Matrix{Float32}(Q)), k)
    out = Vector{Dict{Int,Float32}}(undef, size(Q, 2))
    Threads.@threads for c in 1:size(Q, 2)
        d = Dict{Int,Float32}()
        for r in 1:k
            j = ids[r, c]
            j == 0 && continue
            sim = max(1.0f0 - dists[r, c], 0.0f0)
            for y in ytr[j]
                d[y] = get(d, y, 0.0f0) + sim
            end
        end
        out[c] = d
    end
    return out
end

# The best label of `scores` among those that `allowed` accepts (all when none is accepted), with its share of
# the total score; `nothing` when there are no scores.
function choose(scores::Dict{Int,Float32}, names::Vector{String}, allowed)
    isempty(scores) && return nothing
    total = sum(values(scores))
    best, bs = 0, -1.0f0
    for (y, s) in scores
        allowed(names[y]) && s > bs && ((best, bs) = (y, s))
    end
    best == 0 && for (y, s) in scores
        s > bs && ((best, bs) = (y, s))
    end
    return names[best] => Float64(bs / total)
end

"""
    infer_cti(; index_dir, data_dir, catalogs_dir, k=15, holdout=0.1, seed=1) -> Dict

Infers the área, campo and disciplina of the documents in text that do not declare them (see the module)
and writes `<dense_dir>/cti_inferida.jsonl`, one line per document with something inferred:
`{"documento", "area", "campo", "disciplina"}`, each `{"valor", "confianza"}` or absent (declared, or no
neighbor with a label). `confianza` is the share of the score of the chosen label among the labels of the
neighbors. The summary (accuracy on the held-out documents of each level, counts) goes to
`cti_inferida.json` and is returned.
"""
function infer_cti(; index_dir=DEFAULT_INDEX_DIR, data_dir=DEFAULT_DATA_DIR, catalogs_dir=DEFAULT_CATALOGS_DIR,
                   k::Int=15, holdout::Float64=0.1, seed::Int=1)
    t0 = time()
    keys, X = ficha_vectors(index_dir, data_dir)
    declared = declared_labels(keys, data_dir)
    area_of, campo_of = cti_hierarchy(catalogs_dir)
    parent = Dict("areas" => nothing, "campos" => area_of, "disciplinas" => campo_of)
    println("CTI inference: $(length(keys)) documents in text; declared: ",
            join(("$(length(declared[l])) $l" for l in LEVELS), ", "))
    rng = MersenneTwister(seed)
    result = Dict(key => Dict{String,Any}() for key in keys)          # key => level => valor => confianza
    summary = Dict{String,Any}("fecha" => string(now()), "documentos" => length(keys), "k" => k, "holdout" => holdout)
    chosen = Dict(l => Dict{String,String}() for l in LEVELS)        # the label of each document at each level: declared or inferred
    for l in LEVELS
        lab = declared[l]
        names = sort!(unique!(reduce(vcat, collect(values(lab)); init=String[])))
        num = Dict(n => i for (i, n) in enumerate(names))
        train = [i for (i, key) in enumerate(keys) if haskey(lab, key)]
        shuffle!(rng, train)
        nh = round(Int, holdout * length(train))
        test, fit = train[1:nh], train[nh+1:end]
        y(i) = [num[n] for n in lab[keys[i]]]
        # accuracy on the held-out documents, trained without them, without the hierarchy
        sc = knn_scores(X[:, fit], [y(i) for i in fit], view(X, :, test), k)
        top1 = count(j -> (c = choose(sc[j], names, _ -> true); c !== nothing && first(c) in lab[keys[test[j]]]), eachindex(test))
        top3 = count(eachindex(test)) do j
            r = sort!(collect(sc[j]); by=last, rev=true)
            any(p -> names[first(p)] in lab[keys[test[j]]], first(r, 3))
        end
        # the documents without a label at this level, against every labeled one
        todo = [i for (i, key) in enumerate(keys) if !haskey(lab, key)]
        sc = knn_scores(X[:, train], [y(i) for i in train], view(X, :, todo), k)
        p = parent[l]
        confs = Float64[]
        for (j, i) in enumerate(todo)
            key = keys[i]
            up = p === nothing ? nothing : get(chosen[l == "campos" ? "areas" : "campos"], key, nothing)
            c = choose(sc[j], names, n -> up === nothing || get(p, n, nothing) == up)
            c === nothing && continue
            result[key][l] = Dict("valor" => first(c), "confianza" => round(last(c); digits=3))
            chosen[l][key] = first(c)
            push!(confs, last(c))
        end
        for i in train                    # the declared label (the first, for the hierarchy of the next level)
            chosen[l][keys[i]] = first(lab[keys[i]])
        end
        q(x) = isempty(confs) ? 0.0 : round(quantile_(confs, x); digits=3)
        summary[l] = Dict{String,Any}("etiquetas" => length(names), "declarados" => length(train), "inferidos" => length(confs),
                                      "prueba" => nh, "acierto_1" => round(top1 / max(nh, 1); digits=3),
                                      "acierto_3" => round(top3 / max(nh, 1); digits=3),
                                      "confianza_cuartiles" => [q(0.25), q(0.5), q(0.75)])
        println("  $l: $(length(names)) etiquetas, $(length(train)) declarados, $(length(confs)) inferidos; acierto en ",
                "$nh apartados: $(summary[l]["acierto_1"]) (entre los 3 primeros: $(summary[l]["acierto_3"]))")
    end
    dir = dense_dir(index_dir)
    open(joinpath(dir, INFERRED_FILE * ".tmp"), "w") do io
        for key in keys
            r = result[key]
            isempty(r) && continue
            d = Dict{String,Any}("documento" => key)
            for (l, v) in r
                d[l == "areas" ? "area" : l == "campos" ? "campo" : "disciplina"] = v
            end
            println(io, JSON.json(d))
        end
    end
    mv(joinpath(dir, INFERRED_FILE * ".tmp"), joinpath(dir, INFERRED_FILE); force=true)
    summary["segundos"] = round(time() - t0; digits=1)
    write(joinpath(dir, "cti_inferida.json"), JSON.json(summary, 2))
    return summary
end

# ---------------------------------------------------------------------------------------------------------
# Prototypes (idea of the user, 2026-11-26): the labels are noisy, so only the labeled documents whose
# neighborhood agrees with them are kept as prototypes, and every document is classified by its nearest
# prototypes.

"""
    neighborhood_entropy(ids, dists, ytr, nlabels) -> (entropy, top, consistent)

For each column `j` of a self k-nearest-neighbor graph (`ids`/`dists` from `allknn`, the column itself
included and skipped), the distribution of the labels of its neighbors, each neighbor weighted by its cosine
similarity and splitting it among its labels: its entropy (nats), its top label, and whether that top label
is one of the labels of `j`.
"""
function neighborhood_entropy(ids::AbstractMatrix, dists::AbstractMatrix, ytr::Vector{Vector{Int}})
    n = size(ids, 2)
    H = fill(Inf, n); top = zeros(Int, n); ok = falses(n)
    Threads.@threads for j in 1:n
        d = Dict{Int,Float64}()
        for r in axes(ids, 1)
            i = ids[r, j]
            (i == 0 || i == j) && continue
            w = max(1.0 - dists[r, j], 0.0) / length(ytr[i])
            for y in ytr[i]
                d[y] = get(d, y, 0.0) + w
            end
        end
        isempty(d) && continue
        t = sum(values(d))
        H[j] = -sum(v / t * log(v / t) for v in values(d) if v > 0)
        top[j] = argmax(d)
        ok[j] = top[j] in ytr[j]
    end
    return H, top, ok
end

"""
    choose_many(scores, names, allowed; rel=0.5) -> Vector{Pair{String,Float64}}

The labels of `scores` that `allowed` accepts (all of them when it accepts none): the best one, and the
others whose score is at least `rel` times the best one, each with its share of the total score. A document
can declare several labels at a level (one in 92 to 97 % of the labeled ones).
"""
function choose_many(scores::Dict{Int,Float32}, names::Vector{String}, allowed; rel::Float64=0.5)
    isempty(scores) && return Pair{String,Float64}[]
    total = sum(values(scores))
    cand = [(y, s) for (y, s) in scores if allowed(names[y])]
    isempty(cand) && (cand = collect(scores))
    sort!(cand; by=last, rev=true)
    top = last(first(cand))
    return [names[y] => Float64(s / total) for (y, s) in cand if s >= rel * top]
end

f1(pred, gold) = (isempty(pred) || isempty(gold)) ? 0.0 :
    (tp = length(intersect(pred, gold)); tp == 0 ? 0.0 : 2tp / (length(pred) + length(gold)))

allknn_exact(X::Matrix{Float32}, k::Int) = SimilaritySearch.allknn(
    SimilaritySearch.ExhaustiveSearch(SimilaritySearch.Dist.NormCosine(), SimilaritySearch.MatrixDatabase(X)),
    SimilaritySearch.GenericContext(), k; progress=nothing)

"""
    infer_cti_prototypes(; index_dir, data_dir, catalogs_dir, k=15, keep=(0.25, 0.5, 0.75, 1.0), holdout=0.1, seed=1) -> Dict

[`infer_cti`](@ref) with prototypes. At each level, the self `k`-nearest-neighbor graph of the labeled
documents (without the held-out ones) gives each one the entropy of the labels of its neighbors
([`neighborhood_entropy`](@ref)). The prototypes are the documents whose own label is the top label of their
neighborhood and whose entropy is among the lowest `keep` fraction of those. Each fraction of `keep` is
measured on the held-out documents (classified by their `k` nearest prototypes); the best one by accuracy
classifies the documents without a label, top-down as in `infer_cti`. Writes
`<dense_dir>/cti_inferida_prototipos.jsonl` (same format as `cti_inferida.jsonl`) and
`cti_inferida_prototipos.json` (the summary).
"""
function infer_cti_prototypes(; index_dir=DEFAULT_INDEX_DIR, data_dir=DEFAULT_DATA_DIR, catalogs_dir=DEFAULT_CATALOGS_DIR,
                              k::Int=15, keep=(0.25, 0.5, 0.75, 1.0), holdout::Float64=0.1, seed::Int=1)
    t0 = time()
    keys, X = ficha_vectors(index_dir, data_dir)
    declared = declared_labels(keys, data_dir)
    area_of, campo_of = cti_hierarchy(catalogs_dir)
    parent = Dict("areas" => nothing, "campos" => area_of, "disciplinas" => campo_of)
    rng = MersenneTwister(seed)
    result = Dict(key => Dict{String,Any}() for key in keys)
    chosen = Dict(l => Dict{String,Vector{String}}() for l in LEVELS)
    summary = Dict{String,Any}("fecha" => string(now()), "documentos" => length(keys), "k" => k, "holdout" => holdout)
    println("CTI inference with prototypes: $(length(keys)) documents in text")
    for l in LEVELS
        lab = declared[l]
        names = sort!(unique!(reduce(vcat, collect(values(lab)); init=String[])))
        num = Dict(n => i for (i, n) in enumerate(names))
        train = [i for (i, key) in enumerate(keys) if haskey(lab, key)]
        shuffle!(rng, train)
        nh = round(Int, holdout * length(train))
        test, fit = train[1:nh], train[nh+1:end]
        y(i) = [num[n] for n in lab[keys[i]]]
        yfit = [y(i) for i in fit]
        tg = @elapsed ids, dists = allknn_exact(X[:, fit], k + 1)
        H, _, ok = neighborhood_entropy(ids, dists, yfit)
        hs = sort(H[ok])
        acc(sc) = (count(j -> (c = choose(sc[j], names, _ -> true); c !== nothing && first(c) in lab[keys[test[j]]]), eachindex(test)) / max(nh, 1),
                   count(j -> any(p -> names[first(p)] in lab[keys[test[j]]], first(sort!(collect(sc[j]); by=last, rev=true), 3)), eachindex(test)) / max(nh, 1),
                   sum(j -> f1(first.(choose_many(sc[j], names, _ -> true)), lab[keys[test[j]]]), eachindex(test); init=0.0) / max(nh, 1))
        Xtest = X[:, test]
        variants = Dict{String,Any}[]
        base = acc(knn_scores(X[:, fit], yfit, Xtest, k))
        push!(variants, Dict("conservar" => "todos los etiquetados", "prototipos" => length(fit), "etiquetas_con_prototipo" => length(unique(reduce(vcat, yfit))),
                             "acierto_1" => round(base[1]; digits=3), "acierto_3" => round(base[2]; digits=3), "f1_varias" => round(base[3]; digits=3)))
        best, bestacc, bestproto = nothing, -1.0, Int[]
        for q in keep
            τ = isempty(hs) ? Inf : hs[clamp(round(Int, q * length(hs)), 1, length(hs))]
            proto = [j for j in eachindex(fit) if ok[j] && H[j] <= τ]
            isempty(proto) && continue
            a = acc(knn_scores(X[:, fit[proto]], yfit[proto], Xtest, k))
            push!(variants, Dict("conservar" => q, "entropia_max" => round(τ; digits=3), "prototipos" => length(proto),
                                 "etiquetas_con_prototipo" => length(unique(reduce(vcat, yfit[proto]))),
                                 "acierto_1" => round(a[1]; digits=3), "acierto_3" => round(a[2]; digits=3), "f1_varias" => round(a[3]; digits=3)))
            a[1] > bestacc && ((best, bestacc, bestproto) = (q, a[1], proto))
        end
        println("  $l: grafo de $(length(fit)) etiquetados en $(round(tg; digits=1)) s; consistentes con su vecindario: ",
                "$(count(ok)) ($(round(100 * count(ok) / length(fit); digits=1)) %)")
        for v in variants
            println("    conservar $(v["conservar"]): $(v["prototipos"]) prototipos, $(v["etiquetas_con_prototipo"]) de $(length(names)) etiquetas; ",
                    "acierto $(v["acierto_1"]) (3 primeros: $(v["acierto_3"]); F1 con varias: $(v["f1_varias"]))")
        end
        # the documents without a label at this level, by their nearest prototypes (the best fraction)
        P = fit[bestproto]
        todo = [i for (i, key) in enumerate(keys) if !haskey(lab, key)]
        sc = knn_scores(X[:, P], [y(i) for i in P], X[:, todo], k)
        p = parent[l]
        confs = Float64[]
        for (j, i) in enumerate(todo)
            key = keys[i]
            up = p === nothing ? String[] : get(chosen[l == "campos" ? "areas" : "campos"], key, String[])
            cs = choose_many(sc[j], names, n -> isempty(up) || get(p, n, nothing) in up)
            isempty(cs) && continue
            result[key][l] = [Dict("valor" => v, "confianza" => round(c; digits=3)) for (v, c) in cs]
            chosen[l][key] = first.(cs)
            push!(confs, last(first(cs)))
        end
        for i in train
            chosen[l][keys[i]] = lab[keys[i]]
        end
        summary[l] = Dict{String,Any}("etiquetas" => length(names), "declarados" => length(train), "prueba" => nh,
                                      "consistentes" => count(ok), "variantes" => variants, "elegida" => best,
                                      "inferidos" => length(confs))
    end
    dir = dense_dir(index_dir)
    f = joinpath(dir, "cti_inferida_prototipos.jsonl")
    open(f * ".tmp", "w") do io
        for key in keys
            r = result[key]
            isempty(r) && continue
            d = Dict{String,Any}("documento" => key)
            for (l, v) in r
                d[l == "areas" ? "area" : l == "campos" ? "campo" : "disciplina"] = v
            end
            println(io, JSON.json(d))
        end
    end
    mv(f * ".tmp", f; force=true)
    summary["segundos"] = round(time() - t0; digits=1)
    write(joinpath(dir, "cti_inferida_prototipos.json"), JSON.json(summary, 2))
    return summary
end

quantile_(v, p) = (s = sort(v); s[clamp(round(Int, p * length(s)), 1, length(s))])

end # module CTIInference
