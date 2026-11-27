# Las dos cuentas (notas globales): el índice denso (8 bits, rotación QR) contra la búsqueda exacta en Float32
# sobre los mismos vectores, con consultas reales codificadas por Ollama. Recuperación de los 10 primeros
# (partes, sin límite por documento) y tiempo por consulta.
# Uso: julia +1.13.3 --project=. experiments/rag_web/denso_vs_exacta.jl
using ReposMx, JSON, LinearAlgebra, Statistics
const D = ReposMx.Dense
idx, data = "data/index", "data/repos"
dir = D.dense_dir(idx)
excluded, _ = D._corpus_facts(data)
vec_of = Dict{String,Tuple{Int,Int}}(); shards = Matrix{Float16}[]
for n in sort([f[1:end-6] for f in readdir(joinpath(dir, "textos")) if endswith(f, ".jsonl")])
    V, texts = D._shard(dir, n); push!(shards, V)
    for (j, t) in enumerate(texts); vec_of[t["sha"]] = (length(shards), j); end
end
ids = String[]; cols = Vector{Float32}[]
for l in eachline(joinpath(dir, "unidades.jsonl"))
    u = JSON.parse(l)
    ReposMx.EngineIndex.doc_key_of(u["repo"], u["id"]) in excluded && continue
    s, j = vec_of[u["sha"]]; v = Float32.(view(shards[s], :, j)); push!(ids, u["doc_id"]); push!(cols, v ./ norm(v))
end
X = reduce(hcat, cols); cols = nothing
println("partes: ", length(ids))
consultas = ["redes neuronales para clasificar imágenes", "calidad del agua en acuíferos", "violencia de género en universidades",
    "resistencia a antibióticos en bacterias", "migración de jornaleros agrícolas", "síntesis de nanopartículas de plata",
    "historia de la revolución mexicana en Michoacán", "diabetes tipo 2 en adultos mayores", "energía solar fotovoltaica en viviendas",
    "lenguas indígenas y educación", "control de plagas en maíz", "sismos en la ciudad de México", "aprendizaje profundo para texto en español",
    "turismo y desarrollo local", "biodiversidad de anfibios", "política fiscal y crecimiento económico", "fibra óptica y sensores",
    "obesidad infantil y alimentación", "derecho a la consulta de pueblos indígenas", "corrosión de aceros", "pesquerías en el golfo de California",
    "salud mental de estudiantes", "remediación de suelos contaminados con metales", "teoría de grafos", "literatura mexicana del siglo XIX",
    "cambio climático y agricultura", "dengue y mosquitos Aedes", "microfinanzas y pobreza", "robótica móvil", "arquitectura vernácula"]
enc = D.QueryEncoder(); d = D.open_dense(idx)
rec = Float64[]; t_idx = Float64[]; t_ex = Float64[]
D.search_dense(d, D.encode_query(enc, consultas[1]), 10; per_document=0)
for c in consultas
    q = D.encode_query(enc, c)
    push!(t_idx, @elapsed r = D.search_dense(d, q, 10; per_document=0))
    push!(t_ex, @elapsed ex = ids[partialsortperm(X' * q, 1:10; rev=true)])
    push!(rec, length(intersect(Set(x.doc_id for x in r), Set(ex))) / 10)
end
D.close_dense(d)
println("recuperación@10 del índice contra la exacta: media ", round(mean(rec); digits=3), ", mínima ", minimum(rec))
println("ms por consulta: índice ", round(1000median(t_idx); digits=1), ", exacta (Float32, un hilo de BLAS) ", round(1000median(t_ex); digits=1))
