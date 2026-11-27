# Palabras clave predichas con prototipos (idea del usuario, 2026-11-26), para sacar después meta-disciplinas.
# Las palabras clave del vocabulario limpio (vocabulario_palabras_clave.py) son el objetivo: el 49 % de los
# documentos de texto trae alguna, contra el 29 % que trae área CTI, que no se usa para aprender.
#
# 1. Grafo de 15 vecinos exactos (SimilaritySearch) entre los documentos con palabras del vocabulario, sin el
#    10 % apartado para medir.
# 2. Prototipos: los documentos cuyo vecindario tiene entropía baja respecto a las palabras clave y cuya palabra
#    dominante es una de las suyas (cti_inferencia.jl, neighborhood_entropy). Se prueban varias fracciones.
# 3. Cada documento recibe las palabras de sus 15 prototipos más cercanos, cada una con la suma de las
#    similitudes de los que la traen, por su IDF (para que "mexico" o "licenciatura" no ganen siempre).
# 4. Medición en los apartados: precisión@5 (de las 5 propuestas, cuántas son suyas) y recuperación@5 (de las
#    suyas, cuántas están entre las 5).
#
# Escribe data/index/dense/palabras_clave_predichas.jsonl ({"documento", "palabras": [{"valor", "puntaje"}]}),
# para los documentos sin palabras del vocabulario, con la mejor fracción, y palabras_clave_predichas.json.
# Uso (desde la raíz): julia +1.13.3 --project=. -t auto experiments/rag_web/palabras_clave_prototipos.jl
include(joinpath(@__DIR__, "cti_inferencia.jl"))
using .CTIInference: ficha_vectors, knn_scores, allknn_exact, neighborhood_entropy
using ReposMx, JSON, Random, Dates, Unicode
using ReposMx.Storage: list_repo_names, load_corpus_records
using ReposMx.EngineIndex: doc_key_of

const IDX, DATA, K, TOP = "data/index", "data/repos", 15, 5
const DIR = ReposMx.Dense.dense_dir(IDX)

# la misma forma normal que vocabulario_palabras_clave.py (minúsculas, sin acentos ni puntuación); los acentos
# rotos con "?" se descartan aquí (allá se reparan: son pocos)
norma(k) = strip(replace(replace(lowercase(Unicode.normalize(String(k); stripmark=true)), r"[^\w\s]" => " "), r"\s+" => " "))

function main()
    t0 = time()
    voc = Set(String.(JSON.parsefile(joinpath(DIR, "vocabulario_palabras_clave.json"))))
    keys, X = ficha_vectors(IDX, DATA)
    pos = Dict(k => i for (i, k) in enumerate(keys))
    names = sort!(collect(voc)); num = Dict(n => i for (i, n) in enumerate(names))
    lab = Dict{Int,Vector{Int}}()
    for repo in list_repo_names(; data_dir=DATA), doc in load_corpus_records(repo; data_dir=DATA)
        i = get(pos, doc_key_of(repo, string(get(doc, "id", ""))), 0)
        i == 0 && continue
        ks = unique([num[n] for n in (norma(k) for k in get(doc, "keywords", String[]) if !occursin('?', k)) if haskey(num, n)])
        isempty(ks) || (lab[i] = ks)
    end
    N = length(lab)
    df = zeros(Int, length(names)); for ks in values(lab), y in ks; df[y] += 1; end
    idf = log.(N ./ max.(df, 1))
    println("documentos de texto: $(length(keys)); con palabras del vocabulario: $N; vocabulario: $(length(names))")
    train = collect(Base.keys(lab)); shuffle!(MersenneTwister(1), train)
    nh = round(Int, 0.1N); test, fit = train[1:nh], train[nh+1:end]
    yfit = [lab[i] for i in fit]
    tg = @elapsed ids, dists = allknn_exact(X[:, fit], K + 1)
    H, _, ok = neighborhood_entropy(ids, dists, yfit)
    println("grafo de $(length(fit)) documentos en $(round(tg; digits=1)) s; consistentes (su palabra dominante es suya): ",
            "$(count(ok)) ($(round(100count(ok) / length(fit); digits=1)) %)")
    top(sc) = first(sort!([(y, s * idf[y]) for (y, s) in sc]; by=last, rev=true), TOP)
    function mide(P)
        sc = knn_scores(X[:, fit[P]], yfit[P], X[:, test], K)
        p = r = 0.0
        for (j, i) in enumerate(test)
            pred = first.(top(sc[j])); gold = lab[i]
            hit = length(intersect(pred, gold))
            p += hit / TOP; r += hit / length(gold)
        end
        (round(p / nh; digits=3), round(r / nh; digits=3))
    end
    hs = sort(H[ok])
    variantes = Any[]
    todos = collect(eachindex(fit))
    push!(variantes, ("todos", todos, mide(todos)))
    for q in (1.0, 0.5, 0.25)
        τ = hs[clamp(round(Int, q * length(hs)), 1, length(hs))]
        P = [j for j in eachindex(fit) if ok[j] && H[j] <= τ]
        push!(variantes, (q, P, mide(P)))
    end
    for (q, P, (p, r)) in variantes
        println("  conservar $q: $(length(P)) prototipos, $(length(unique(reduce(vcat, yfit[P])))) palabras con prototipo; ",
                "precisión@$TOP $p, recuperación@$TOP $r")
    end
    q, P, _ = variantes[argmax([v[3][2] for v in variantes])]           # la de mejor recuperación
    todo = [i for i in eachindex(keys) if !haskey(lab, i)]
    sc = knn_scores(X[:, fit[P]], yfit[P], X[:, todo], K)
    open(joinpath(DIR, "palabras_clave_predichas.jsonl"), "w") do io
        for (j, i) in enumerate(todo)
            t = top(sc[j]); isempty(t) && continue
            println(io, JSON.json(Dict("documento" => keys[i], "palabras" => [Dict("valor" => names[y], "puntaje" => round(s; digits=3)) for (y, s) in t])))
        end
    end
    write(joinpath(DIR, "palabras_clave_predichas.json"), JSON.json(Dict(
        "fecha" => string(now()), "documentos" => length(keys), "con_palabras" => N, "vocabulario" => length(names), "k" => K,
        "consistentes" => count(ok), "elegida" => string(q), "predichos" => length(todo), "segundos" => round(time() - t0; digits=1),
        "variantes" => [Dict("conservar" => string(v[1]), "prototipos" => length(v[2]), "precision" => v[3][1], "recuperacion" => v[3][2]) for v in variantes]), 2))
    println("elegida: conservar $q; $(length(todo)) documentos sin palabras clave reciben $TOP; $(round(time() - t0; digits=1)) s")
end

main()
