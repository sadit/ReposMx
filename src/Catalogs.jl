module Catalogs

using Downloads, JSON
using Downloads: request
using ..Config: DEFAULT_HEADERS, DEFAULT_CATALOGS_DIR

export fetch_cti_catalogs, resolve_cti_code

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

end # module Catalogs
