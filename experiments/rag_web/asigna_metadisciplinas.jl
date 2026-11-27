# Asigna las meta-disciplinas oficiales (metadisciplinas/, la corrida del 2026-11-26) a los documentos de texto: cada
# uno va al centro más cercano a su ficha y, si el segundo está a menos de `margen` de similitud, también a ése. Es la
# misma regla de experiments/rag_web/metadisciplinas.jl, sobre los centros guardados; sirve para documentos nuevos o
# para otra codificación. Escribe data/index/dense/metadisciplinas_documentos.jsonl (lo lee Dense.build_dense_project).
# Con --compara, sólo cuenta en cuántos documentos coincide con el archivo que ya existe.
# Uso (desde la raíz): julia +1.13.3 --project=. -t auto experiments/rag_web/asigna_metadisciplinas.jl [--compara]
include(joinpath(@__DIR__, "cti_inferencia.jl"))
using .CTIInference: ficha_vectors
using ReposMx, JSON
import SimilaritySearch as SS

const RAIZ = dirname(dirname(@__DIR__))
const OFICIAL = joinpath(RAIZ, "metadisciplinas")
const DIR = ReposMx.Dense.dense_dir(joinpath(RAIZ, "data", "index"))
const SALIDA = joinpath(DIR, "metadisciplinas_documentos.jsonl")

function main(compara::Bool)
    of = JSON.parsefile(joinpath(OFICIAL, "oficial.json"))
    orden = String.(of["orden_centros"]); margen = Float32(of["margen"])
    C = reshape(reinterpret(Float32, read(joinpath(OFICIAL, "centros.f32"))), ReposMx.Dense.DIM, length(orden)) |> Matrix
    keys, X = ficha_vectors(joinpath(RAIZ, "data", "index"), joinpath(RAIZ, "data", "repos"))
    E = SS.ExhaustiveSearch(SS.Dist.NormCosine(), SS.MatrixDatabase(C))
    ids, d = SS.searchbatch(E, SS.GenericContext(), SS.MatrixDatabase(X), 2)
    asig = Dict{String,Vector{String}}()
    filas = String[]
    for i in eachindex(keys)
        ms = [orden[ids[1, i]]]
        (1 - d[2, i]) >= (1 - d[1, i]) - margen && push!(ms, orden[ids[2, i]])
        asig[keys[i]] = ms
        push!(filas, JSON.json(Dict("documento" => keys[i], "metadisciplinas" => ms, "similitud" => round(1 - d[1, i]; digits=3))))
    end
    if compara
        iguales = total = 0
        for l in eachline(SALIDA)
            r = JSON.parse(l); total += 1
            Set(String.(r["metadisciplinas"])) == Set(get(asig, r["documento"], String[])) && (iguales += 1)
        end
        println("coinciden $iguales de $total documentos ($(round(100iguales / total; digits=3)) %); recalculados: $(length(keys))")
    else
        open(io -> foreach(f -> println(io, f), filas), SALIDA, "w")
        println("$(length(keys)) documentos asignados en $SALIDA")
    end
end

main("--compara" in ARGS)
