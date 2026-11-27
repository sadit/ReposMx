# Mide sobre una muestra del texto completo cómo salen las partes que se codifican (Units, docs/plan-rag-web.md):
# en qué fracción se hallan los encabezados (los que valen: seguidos de prosa), cuántas partes salen por
# documento y cuántos caracteres. Uso: julia --project=. -t 16 experiments/rag_web/mide_secciones.jl [n]
using ReposMx, JSON, Random
const U = ReposMx.Units

function main(nmuestra)
    Random.seed!(1)
    files = String[]
    for r in readdir("data/repos")
        p = joinpath("data/repos", r, "corpus.jsonl")
        isfile(p) || continue
        for l in eachline(p)
            d = JSON.parse(l)
            get(d, "has_fulltext", false) == true && push!(files, d["fulltext_file"])
        end
    end
    muestra = shuffle(files)[1:min(nmuestra, end)]
    found = Vector{Set{Symbol}}(undef, length(muestra))
    nparts = zeros(Int, length(muestra)); nchars = zeros(Int, length(muestra))
    Threads.@threads for i in eachindex(muestra)
        t = read(muestra[i], String)
        lines = U.normalize_text(t)
        found[i] = Set(s for (j, l) in enumerate(lines) for s in (U.heading(l),) if s !== nothing && U._prose_follows(lines, j))
        p = U.fulltext_units(t)
        nparts[i] = length(p); nchars[i] = sum(length(last(x)) for x in p; init=0)
    end
    println("documentos con texto: $(length(files)); muestra: $(length(muestra))")
    for (s, _) in U.SECTIONS
        println(rpad(s, 14), lpad(round(100 * count(f -> s in f, found) / length(found); digits=1), 6), " %")
    end
    println("partes por documento: media $(round(sum(nparts) / length(nparts); digits=2)), sin partes $(count(==(0), nparts))")
    println("caracteres por documento: media $(round(Int, sum(nchars) / length(nchars)))")
    println("estimado para $(length(files)) documentos: $(round(Int, sum(nparts) / length(nparts) * length(files))) partes, ",
            "$(round(sum(nchars) / length(nchars) * length(files) / 1e6; digits=1)) millones de caracteres")
end

main(parse(Int, get(ARGS, 1, "3000")))
