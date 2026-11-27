module Catalogs

using Downloads, JSON
using Downloads: request
using ..Config: DEFAULT_HEADERS, DEFAULT_CATALOGS_DIR

export fetch_cti_catalogs, resolve_cti_code, cti_levels, cti_paths

const CTI_API_BASE = "https://catalogs.repositorionacionalcti.mx/webresources"

# One entry per CTI hierarchy level: (catalog name on the API / local filename stem, the "clave"
# field that actually matches the digit-length-coded values seen in harvested `dc:subject` text
# -- NOT `id<Level>`, which is an unrelated internal sequential database id). Verified live against
# the real API: `cveArea` is always 1 digit, `cveCampo` 2, `cveDisciplina` 4, `cveSubdisciplina` 6,
# no leading zeros, no code maps to two different `descripcion` values (duplicate rows exist per
# catalog but always agree on the description, so last-write-wins while building the Dict is safe).
const CTI_LEVELS = (
    (name="areacono", clave_key="cveArea"),
    (name="campocono", clave_key="cveCampo"),
    (name="disciplinacono", clave_key="cveDisciplina"),
    (name="subdisciplinacono", clave_key="cveSubdisciplina"),
)

"""
    fetch_cti_catalogs(; catalogs_dir=DEFAULT_CATALOGS_DIR, timeout=60.0)

Downloads the CTI Área/Campo/Disciplina/Subdisciplina del Conocimiento catalogs from the
Repositorio Nacional's public catalog API (`$CTI_API_BASE`) and saves each response verbatim as
`<catalogs_dir>/cti_<name>.json`. Meant to be run once (manually, or via `reposmx fetch-catalogs`)
-- these catalogs rarely change, unlike the per-repo harvested data. [`resolve_cti_code`](@ref)
reads these files back to decode the bare `cti/<code>` values seen in harvested `dc:subject` text
(see `Corpus.parse_keywords`).
"""
function fetch_cti_catalogs(; catalogs_dir::AbstractString=DEFAULT_CATALOGS_DIR, timeout::Float64=60.0)
    mkpath(catalogs_dir)
    for level in CTI_LEVELS
        url = "$CTI_API_BASE/$(level.name)"
        output = IOBuffer()
        res = request(url; output, timeout, throw=false, headers=DEFAULT_HEADERS)
        seekstart(output)

        if res isa Downloads.RequestError
            println(stderr, "[catalogs] Network error fetching $(level.name): code=$(res.code) $(res.message)")
            continue
        elseif res isa Downloads.Response && res.status >= 400
            println(stderr, "[catalogs] HTTP error $(res.status) fetching $(level.name)")
            continue
        end

        body = String(take!(output))
        dest = joinpath(catalogs_dir, "cti_$(level.name).json")
        write(dest, body)
        n = try
            length(JSON.parse(body))
        catch
            "?"
        end
        println("[catalogs] $(level.name): $n registros -> $dest")
    end
    return nothing
end

"""
    _cti_dicts(catalogs_dir) -> NTuple{4, Dict{String,String}}

Loads and memoizes (keyed by `catalogs_dir`, so tests can point at a synthetic directory without
touching the real one) the 4 CTI level dicts: código (`cve<Nivel>`) -> `descripcion`.
"""
const _CTI_DICTS_CACHE = Dict{String, NTuple{4, Dict{String,String}}}()

function _cti_dicts(catalogs_dir::AbstractString)
    get!(_CTI_DICTS_CACHE, catalogs_dir) do
        paths = [joinpath(catalogs_dir, "cti_$(level.name).json") for level in CTI_LEVELS]
        if !any(isfile, paths)
            println(stderr, "[catalogs] Catálogos CTI no encontrados en '$catalogs_dir' -- " *
                             "corre 'reposmx fetch-catalogs' primero. Los códigos cti/<N> en " *
                             "dc:subject se omitirán hasta entonces.")
        end
        Tuple(
            begin
                d = Dict{String,String}()
                if isfile(path)
                    for entry in JSON.parsefile(path)
                        code = get(entry, level.clave_key, nothing)
                        desc = get(entry, "descripcion", nothing)
                        (code === nothing || desc === nothing) && continue
                        d[String(code)] = String(desc)
                    end
                end
                d
            end
            for (level, path) in zip(CTI_LEVELS, paths)
        )
    end
end

"""
    resolve_cti_code(code::AbstractString; catalogs_dir=DEFAULT_CATALOGS_DIR) -> Union{String,Nothing}

Resolves a bare CTI classification code (as seen in `info:eu-repo/classification/cti/<code>`) to
its human-readable name, picking the catalog level by the code's digit length (1=área, 2=campo,
4=disciplina, 6=subdisciplina). Returns `nothing` if the length doesn't match a known level, the
catalogs haven't been fetched yet (see [`fetch_cti_catalogs`](@ref)), or the code isn't found —
never falls back to the raw code, since a bare number is not a usable keyword.
"""
function resolve_cti_code(code::AbstractString; catalogs_dir::AbstractString=DEFAULT_CATALOGS_DIR)
    area, campo, disciplina, subdisciplina = _cti_dicts(catalogs_dir)
    level = length(code) == 1 ? area :
            length(code) == 2 ? campo :
            length(code) == 4 ? disciplina :
            length(code) == 6 ? subdisciplina :
            nothing
    level === nothing && return nothing
    return get(level, code, nothing)
end

# The área of each campo, read from the campo catalog. The other parents come from the code itself, which is
# hierarchical (campo = 2 digits, disciplina = 4, subdisciplina = 6, each extending the one above): the
# subdisciplina catalog lists some codes twice under different disciplinas (120317 under 1203 and 3304), so
# its nesting is not used.
const _CTI_AREA_OF_CAMPO = Dict{String, Dict{String,String}}()

function _cti_area_of_campo(catalogs_dir::AbstractString)
    get!(_CTI_AREA_OF_CAMPO, catalogs_dir) do
        out = Dict{String,String}()
        f = joinpath(catalogs_dir, "cti_campocono.json")
        isfile(f) || return out
        for e in JSON.parsefile(f)
            a = get(e, "idArea", nothing)
            a isa AbstractDict && (out[string(get(e, "cveCampo", ""))] = string(get(a, "cveArea", "")))
        end
        out
    end
end

"""
    cti_levels(codes; catalogs_dir=DEFAULT_CATALOGS_DIR) -> (areas, campos, disciplinas)

The names of the CTI área, campo and disciplina that a set of codes (`cti/<code>` in `dc:subject`) names.
A code gives its own level and the levels above it: the campo and the disciplina by its prefix, the área by
the campo catalog. Every declared code counts, also one off the path of a deeper one: many documents mix
disciplines, so the tree is not imposed on what the repositories declare (decision of the user, 2026-11-26).
Unknown codes are skipped. Each list is sorted and without repetitions.
"""
function cti_levels(codes; catalogs_dir::AbstractString=DEFAULT_CATALOGS_DIR)
    area, campo, disciplina, _ = _cti_dicts(catalogs_dir)
    area_of = _cti_area_of_campo(catalogs_dir)
    as, cs, ds = Set{String}(), Set{String}(), Set{String}()
    for code in codes
        x = String(strip(code))
        all(isdigit, x) || continue
        n = length(x)
        n == 1 && haskey(area, x) && push!(as, area[x])
        n in (2, 4, 6) || continue
        c = x[1:2]
        haskey(campo, c) || continue
        push!(cs, campo[c])
        a = get(area_of, c, "")
        haskey(area, a) && push!(as, area[a])
        n >= 4 && haskey(disciplina, x[1:4]) && push!(ds, disciplina[x[1:4]])
    end
    return sort!(collect(as)), sort!(collect(cs)), sort!(collect(ds))
end

"""
    cti_paths(catalogs_dir=DEFAULT_CATALOGS_DIR) -> Dict{String,Vector{Tuple{String,String}}}

For each disciplina name, the (área, campo) names of the path to it in the tree, to choose a disciplina going
through its área and campo. A name that the catalog uses in more than one campo has more than one path.
"""
function cti_paths(catalogs_dir::AbstractString=DEFAULT_CATALOGS_DIR)
    area, campo, disciplina, _ = _cti_dicts(catalogs_dir)
    area_of = _cti_area_of_campo(catalogs_dir)
    out = Dict{String,Vector{Tuple{String,String}}}()
    for (d, name) in disciplina
        c = d[1:2]
        haskey(campo, c) || continue
        p = (get(area, get(area_of, c, ""), ""), campo[c])
        v = get!(Vector{Tuple{String,String}}, out, name)
        p in v || push!(v, p)
    end
    return out
end

end # module Catalogs
