# Meta-disciplinas a partir de las palabras clave (2026-11-26; la CTI no se usa para aprender). Las palabras clave
# del vocabulario limpio (vocabulario_palabras_clave.py) se agrupan por su significado y cada grupo es una
# meta-disciplina; los documentos caen en los grupos más cercanos.
#
# 1. Vector de cada palabra: el promedio normalizado de los vectores de ficha de los documentos que la traen.
# 2. k-means esférico sobre las palabras, sembrado con `fft` (k-centros) de SimilaritySearch; en cada vuelta la
#    asignación es por coseno con `ExhaustiveSearch` y cada centro es el promedio normalizado de sus palabras,
#    pesadas por la raíz de su frecuencia (las frecuentes pesan más, sin aplastar a las demás).
#    Antes se quitan las palabras dispersas ("mexico", "maestria", "general"): las de al menos 30 documentos cuya
#    coherencia (la longitud del promedio de los vectores de sus documentos, antes de normalizar) está en el
#    15 % más bajo de esas.
# 3. Palabras de cada grupo: las frecuentes (≥ 20 documentos si hay) más cercanas al centro.
# 4. Qwen (la API del demo, data/web/generador.env; qwen3.8-flash) nombra cada grupo en español y en inglés, lo
#    describe en una oración y dice si es un tema de investigación o algo genérico, administrativo o de archivo,
#    a partir de sus palabras y de los títulos de los documentos más cercanos al centro (metadatos públicos).
#    Los grupos que no son temáticos se quitan.
# 5. Cada documento de texto (tenga o no palabras clave) va al grupo temático más cercano por su vector de
#    ficha, y también al segundo si su similitud está a menos de MARGEN de la primera.
#
# Escribe en data/index/dense/metadisciplinas-corrida/ (metadisciplinas.json, metadisciplinas_documentos.jsonl,
# metadisciplinas_grafo.json, metadisciplinas_centros.f32), nunca sobre la corrida oficial: ésa está en
# metadisciplinas/ (la del 2026-11-26) y su asignación la recalcula asigna_metadisciplinas.jl. Para fijar otra
# corrida como oficial se copian esos archivos a metadisciplinas/ (ver su README).
# Uso (desde la raíz): julia +1.13.3 --project=. -t auto experiments/rag_web/metadisciplinas.jl [K]
include(joinpath(@__DIR__, "cti_inferencia.jl"))
using .CTIInference: ficha_vectors
using ReposMx, JSON, LinearAlgebra, Statistics, Dates, Unicode, HTTP
using ReposMx.Storage: list_repo_names, load_corpus_records
using ReposMx.EngineIndex: doc_key_of
import SimilaritySearch as SS

const IDX, DATA = "data/index", "data/repos"
const DIR = ReposMx.Dense.dense_dir(IDX)
const OUT = mkpath(joinpath(DIR, "metadisciplinas-corrida"))
const K = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 120
const MARGEN = 0.01f0
const DISPERSAS = 0.15            # fracción de las palabras frecuentes, las menos coherentes, que se quitan
const MODELO = "qwen3.8-flash"
const MIN_DOCS = 200              # un grupo con menos documentos cercanos se funde en el más próximo
const VECINOS = 3                 # aristas del grafo por centro, además de las de documentos compartidos
const VUELTAS = 25

norma(k) = strip(replace(replace(lowercase(Unicode.normalize(String(k); stripmark=true)), r"[^\w\s]" => " "), r"\s+" => " "))

# las posiciones del centro más cercano de cada columna de Q (coseno, exacta)
function cercanos(C::Matrix{Float32}, Q::Matrix{Float32}, k::Int)
    E = SS.ExhaustiveSearch(SS.Dist.NormCosine(), SS.MatrixDatabase(C))
    SS.searchbatch(E, SS.GenericContext(), SS.MatrixDatabase(Q), k)
end

# Qwen: nombre, descripción y si el grupo es temático. Sin la API (data/web/generador.env) los grupos quedan
# sin nombre y todos se toman por temáticos.
function nombra!(grupos)
    env = joinpath("data", "web", "generador.env")
    isfile(env) || (println("sin $env: los grupos no se nombran"); return)
    cfg = Dict(String(a) => String(b) for (a, b) in (split(l, '='; limit=2) for l in eachline(env) if occursin('=', l) && !startswith(l, '#')))
    api, llave = rstrip(cfg["REPOSMX_GENERADOR_API"], '/'), cfg["REPOSMX_GENERADOR_LLAVE"]
    function pide(g)
        msg = "Estas son las palabras clave (en español o inglés) y algunos títulos de documentos de un grupo que se encontró " *
              "automáticamente en repositorios académicos mexicanos.\n\nPalabras: " * join(g["palabras"], "; ") *
              "\n\nTítulos:\n" * join(("- " * t for t in g["titulos"]), "\n") *
              "\n\nResponde sólo un objeto JSON con: \"nombre\" (el campo de estudio en español, de 2 a 5 palabras), " *
              "\"nombre_en\" (lo mismo en inglés), \"descripcion\" (una oración en español) y \"tematico\" (true si el grupo " *
              "corresponde a un campo o tema de investigación reconocible; false si es genérico, administrativo, de archivo o " *
              "una mezcla sin tema común)."
        cuerpo = JSON.json(Dict("model" => MODELO, "temperature" => 0, "max_tokens" => 300, "enable_thinking" => false,
                                "messages" => [Dict("role" => "system", "content" => "Eres un bibliotecario experto en clasificar la producción académica."),
                                               Dict("role" => "user", "content" => msg)]))
        for intento in 1:4
            try
                r = HTTP.post(api * "/chat/completions", ["Content-Type" => "application/json", "Authorization" => "Bearer " * llave], cuerpo;
                              request_timeout=120, status_exception=false)
                if r.status == 200
                    t = JSON.parse(String(r.body))["choices"][1]["message"]["content"]
                    m = match(r"\{.*\}"s, t)
                    m === nothing && error("sin JSON")
                    x = JSON.parse(m.match)
                    g["nombre"], g["nombre_en"], g["descripcion"] = string(x["nombre"]), string(get(x, "nombre_en", "")), string(get(x, "descripcion", ""))
                    g["tematico"] = get(x, "tematico", true) in (true, "true", "sí", "si")
                    return
                end
                r.status in (429, 503) || error("la API respondió $(r.status)")
            catch e
                intento == 4 && (@warn "no se nombró un grupo" g["id"] e; return)
            end
            sleep(3intento)
        end
    end
    t = @elapsed asyncmap(pide, grupos; ntasks=2)
    println("$(count(g -> haskey(g, "nombre"), grupos)) grupos nombrados por $MODELO en $(round(t; digits=1)) s")
end

function main()
    t0 = time()
    names = String.(JSON.parsefile(joinpath(DIR, "vocabulario_palabras_clave.json")))
    num = Dict(n => i for (i, n) in enumerate(names))
    keys, X = ficha_vectors(IDX, DATA)
    pos = Dict(k => i for (i, k) in enumerate(keys))
    titulo = fill("", length(keys))
    V = zeros(Float32, size(X, 1), length(names)); df = zeros(Int, length(names))
    for repo in list_repo_names(; data_dir=DATA), doc in load_corpus_records(repo; data_dir=DATA)
        i = get(pos, doc_key_of(repo, string(get(doc, "id", ""))), 0)
        i == 0 && continue
        titulo[i] = string(something(get(doc, "title", ""), ""))
        for y in unique([num[n] for n in (norma(k) for k in get(doc, "keywords", String[]) if !occursin('?', k)) if haskey(num, n)])
            V[:, y] .+= view(X, :, i); df[y] += 1
        end
    end
    vivas = findall(>(0), df)
    names, V, df = names[vivas], V[:, vivas], df[vivas]
    R = [norm(view(V, :, j)) / df[j] for j in eachindex(df)]          # coherencia: 1 si todos sus documentos coinciden
    frec = findall(>=(30), df)
    umbral = sort(R[frec])[max(1, round(Int, DISPERSAS * length(frec)))]
    fuera = [j for j in frec if R[j] <= umbral]
    println("palabras dispersas quitadas: $(length(fuera)) (coherencia ≤ $(round(umbral; digits=3)) entre $(length(frec)) con ≥ 30 documentos); ",
            "las más frecuentes: ", join(names[sort(fuera; by=j -> -df[j])][1:min(40, end)], ", "))
    quedan = setdiff(eachindex(df), fuera)
    names, V, df = names[quedan], V[:, quedan], df[quedan]
    foreach(normalize!, eachcol(V))
    w = sqrt.(Float32.(df))
    println("palabras: $(length(names)); documentos de texto: $(length(keys)); K = $K")
    # semillas: k-centros (farthest first traversal)
    sel = SS.fft(SS.Dist.NormCosine(), SS.MatrixDatabase(V), K; verbose=false)
    C = V[:, sel.centers]
    asig = zeros(Int, length(names))
    for v in 1:VUELTAS
        ids, _ = cercanos(C, V, 1)
        nueva = Int.(vec(ids))
        cambios = count(nueva .!= asig); asig = nueva
        C .= 0
        for (j, c) in enumerate(asig); C[:, c] .+= w[j] .* view(V, :, j); end
        for c in 1:K
            norm(view(C, :, c)) > 0 ? normalize!(view(C, :, c)) : (C[:, c] .= V[:, rand(1:length(names))])   # un centro vacío se vuelve a sembrar
        end
        (cambios == 0 || v == VUELTAS) && (println("k-means: $v vueltas, $cambios cambios en la última"); break)
    end
    # palabras de cada grupo y los títulos de los documentos más cercanos a su centro
    ids1, d1 = cercanos(C, X, 1)
    grupos = Dict{String,Any}[]
    for c in 1:K
        m = findall(==(c), asig)
        isempty(m) && continue
        sim = [dot(view(V, :, j), view(C, :, c)) for j in m]
        frec = filter(j -> df[m[j]] >= 20, eachindex(m)); orden = sort(isempty(frec) ? collect(eachindex(m)) : frec; by=j -> -sim[j])
        top = [names[m[j]] for j in first(orden, 25)]
        docs = findall(==(c), vec(ids1))
        ej = [titulo[i] for i in docs[sortperm(d1[1, docs])][1:min(5, end)] if !isempty(titulo[i])]
        push!(grupos, Dict("id" => c, "palabras" => top, "n_palabras" => length(m), "documentos_con_palabras" => sum(df[m]),
                           "titulos" => ej, "cercanos" => length(docs)))
    end
    nombra!(grupos)
    chicos = [g for g in grupos if g["cercanos"] < MIN_DOCS]
    println("grupos con menos de $MIN_DOCS documentos, que se funden en el más próximo: ",
            join((string(get(g, "nombre", "?"), " (", g["cercanos"], ")") for g in chicos), "; "))
    tematicos = Set(g["id"] for g in grupos if get(g, "tematico", true) === true && g["cercanos"] >= MIN_DOCS)
    println("grupos temáticos según $MODELO: $(length(tematicos)) de $(length(grupos)); quitados: ",
            join((get(g, "nombre", join(first(g["palabras"], 3), " · ")) for g in grupos if !(g["id"] in tematicos)), "; "))
    # documentos: el grupo temático más cercano y, si está casi igual de cerca, el segundo
    cols = sort!(collect(tematicos))
    ids, d = cercanos(C[:, cols], X, 2)
    cuenta = zeros(Int, K); dobles = 0
    open(joinpath(OUT, "metadisciplinas_documentos.jsonl"), "w") do io
        for i in eachindex(keys)
            ms = [cols[ids[1, i]]]
            if (1 - d[2, i]) >= (1 - d[1, i]) - MARGEN
                push!(ms, cols[ids[2, i]]); dobles += 1
            end
            foreach(c -> cuenta[c] += 1, ms)
            println(io, JSON.json(Dict("documento" => keys[i], "metadisciplinas" => ms, "similitud" => round(1 - d[1, i]; digits=3))))
        end
    end
    filter!(g -> g["id"] in tematicos, grupos)
    # el grafo: documentos compartidos por cada par de grupos (los que caen en dos) y los VECINOS más cercanos por centro
    comparten = Dict{Tuple{Int,Int},Int}()
    for l in eachline(joinpath(OUT, "metadisciplinas_documentos.jsonl"))
        ms = JSON.parse(l)["metadisciplinas"]
        length(ms) == 2 && (p = (min(ms...), max(ms...)); comparten[p] = get(comparten, p, 0) + 1)
    end
    Cg = C[:, cols]; S = Cg' * Cg
    aristas = Set{Tuple{Int,Int}}()
    for (a, ca) in enumerate(cols)
        for b in partialsortperm(view(S, :, a), 2:VECINOS+1; rev=true)
            push!(aristas, (min(ca, cols[b]), max(ca, cols[b])))
        end
    end
    # y los VECINOS pares con mayor proporción de documentos compartidos (al menos 10), para que el grafo se pueda ver
    for (a, ca) in enumerate(cols)
        pares = [(p, c) for (p, c) in comparten if ca in p && c >= 10]
        sort!(pares; by=x -> -last(x) / (count(==(first(first(x))), asig) + count(==(last(first(x))), asig) + 1))
        foreach(x -> push!(aristas, first(x)), first(pares, VECINOS))
    end
    pos_c = Dict(c => i for (i, c) in enumerate(cols))
    # identificadores estables: M001... por número de documentos
    for g in grupos; g["documentos"] = cuenta[g["id"]]; end
    sort!(grupos; by=g -> -g["documentos"])
    clave = Dict(g["id"] => string("M", lpad(i, 3, '0')) for (i, g) in enumerate(grupos))
    for g in grupos; g["clave"] = clave[g["id"]]; delete!(g, "cercanos"); end
    # los documentos, con las claves estables
    lineas = [JSON.parse(l) for l in eachline(joinpath(OUT, "metadisciplinas_documentos.jsonl"))]
    open(joinpath(OUT, "metadisciplinas_documentos.jsonl"), "w") do io
        for x in lineas
            x["metadisciplinas"] = [clave[c] for c in x["metadisciplinas"]]
            println(io, JSON.json(x))
        end
    end
    write(joinpath(OUT, "metadisciplinas_centros.f32"), Cg)                   # DIM x n, en el orden de `orden_centros`
    n = Dict(g["id"] => g["documentos"] for g in grupos)
    enlaces = [Dict("source" => clave[a], "target" => clave[b], "similitud" => round(S[pos_c[a], pos_c[b]]; digits=3),
                    "comparten" => get(comparten, (a, b), 0),
                    "jaccard" => round(get(comparten, (a, b), 0) / max(1, n[a] + n[b] - get(comparten, (a, b), 0)); digits=4))
               for (a, b) in aristas]
    write(joinpath(OUT, "metadisciplinas_grafo.json"), JSON.json(Dict(
        "nodos" => [Dict("id" => g["clave"], "nombre" => get(g, "nombre", ""), "nombre_en" => get(g, "nombre_en", ""),
                         "descripcion" => get(g, "descripcion", ""), "documentos" => g["documentos"], "palabras" => first(g["palabras"], 12))
                    for g in grupos],
        "enlaces" => enlaces), 2))
    println("grafo: $(length(grupos)) nodos, $(length(enlaces)) aristas ($(length(comparten)) pares con documentos compartidos)")
    write(joinpath(OUT, "metadisciplinas.json"), JSON.json(Dict("fecha" => string(now()), "k" => K, "margen" => MARGEN,
        "modelo" => MODELO, "documentos" => length(keys), "con_dos" => dobles, "grupos" => grupos,
        "orden_centros" => [clave[c] for c in cols]), 2))
    tam = sort([g["documentos"] for g in grupos])
    println("grupos: $(length(grupos)); documentos por grupo: mínimo $(first(tam)), mediana $(tam[cld(end, 2)]), máximo $(last(tam)); ",
            "con dos grupos: $dobles ($(round(100dobles / length(keys); digits=1)) %); $(round(time() - t0; digits=1)) s")
    for g in grupos
        println(g["clave"], lpad(g["documentos"], 7), "  ", rpad(get(g, "nombre", "?"), 42), " ", join(first(g["palabras"], 6), " · "))
    end
end

main()
