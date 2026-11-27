"""
Demo web de búsqueda de ReposMx (docs/plan-rag-web.md, fase 2): un solo proceso de Julia con el índice de
ReposMx embebido, las consultas codificadas por Ollama, la respuesta redactada por un modelo (la API de Qwen del
RAG ambiental) y Oxygen para las dos caras. Es AmbientalWeb (~/Projects/Legistlan/RAG-Medio-Ambiente/sistema/web)
con otro acervo:

- `acervo.jl`: abre el índice y busca en documentos, autores y referencias; no sabe de HTTP.
- `generador.jl`: la respuesta redactada con los fragmentos encontrados.
- `conversacion.jl`: las conversaciones (pasos de pregunta, búsqueda y respuesta).
- `api.jl`: cara JSON (`/api/...`).
- `paginas.jl`: cara HTML (htmx, Alpine.js, Tailwind).

Se levanta con `web/sirve.sh`. Sólo escucha en 127.0.0.1; hacia afuera lo publica el portero. Nunca sirve los
archivos de nuestra copia: cita las fuentes con sus metadatos y la liga a su registro.
"""
module ReposMxWeb

using ReposMx, SimilaritySearchEngine, JSON, HTTP, URIs, SHA, Dates, Unicode
import Oxygen

include("acervo.jl")
include("generador.jl")
include("conversacion.jl")

struct Servicio
    acervo::Acervo
    gen::Union{Nothing,Generador}      # `nothing`: sólo búsqueda
    convs::Conversaciones
    prefijo::String                    # "" o "/reposmx": bajo qué ruta vive el demo
    cupo::Base.Semaphore               # búsquedas a la vez
    mostrar_texto::Bool                # mostrar el texto de las partes del texto completo (no: decisión del usuario)
    versiones::Dict{String,String}     # archivo estático -> huella corta, para que el navegador lo guarde sin caducar
    arranque::DateTime
end
const SERVICIO = Ref{Servicio}()

include("api.jl")
include("paginas.jl")

function rutas(estaticos::AbstractString)
    Oxygen.get(cuida(api_buscar), "/api/buscar")
    Oxygen.get(cuida(api_responder), "/api/responder")
    Oxygen.get(cuida(api_conversacion), "/api/conversacion")
    Oxygen.get(cuida(api_autores), "/api/autores")
    Oxygen.get(cuida(api_referencias), "/api/referencias")
    Oxygen.get(cuida(api_colecciones), "/api/colecciones")
    Oxygen.get(cuida(api_metadisciplinas), "/api/metadisciplinas")
    Oxygen.get(cuida(pagina_mapa, fallo_html), "/mapa")
    Oxygen.get(cuida(api_salud), "/api/salud")
    Oxygen.get(cuida(pagina_inicio, fallo_html), "/")
    Oxygen.get(cuida(pagina_buscar, fallo_html), "/buscar")
    Oxygen.get(cuida(pagina_autores, fallo_html), "/autores")
    Oxygen.get(cuida(pagina_referencias, fallo_html), "/referencias")
    Oxygen.stream(flujo_redaccion, "/redaccion")
    Oxygen.staticfiles(estaticos, "estaticos"; headers=["Cache-Control" => "public, max-age=31536000, immutable"])
end

"""
    main()

Configuración por variables de ambiente: `REPOSMX_PUERTO` (8790), `REPOSMX_PREFIJO` (`/reposmx`; vacío para
servir en la raíz), `REPOSMX_RAIZ` (la raíz del repositorio), `REPOSMX_DATOS` (`data/repos`), `REPOSMX_INDICE`
(`data/index`), `REPOSMX_A_LA_VEZ` (búsquedas simultáneas, 16), `OLLAMA_URL` (`http://127.0.0.1:11434`),
`OLLAMA_MODELO` (`qwen3-embedding:0.6b-fp16`), `REPOSMX_FRAGMENTOS` (cuántos lee el generador, 6),
`REPOSMX_PASOS` (preguntas por conversación, 6), `REPOSMX_FILA` (respuestas redactándose o en espera, 8),
`REPOSMX_SUGERENCIAS` (preguntas para seguir, 3) y `REPOSMX_MOSTRAR_TEXTO` (`1` para mostrar el texto de las
partes del texto completo; por omisión sólo se muestra el de la ficha).

El generador: `REPOSMX_GENERADOR_API` (la base de una API compatible con OpenAI), `REPOSMX_GENERADOR` (el
modelo; `0` o vacío para servir sólo la búsqueda), `REPOSMX_GENERADOR_LLAVE`, `REPOSMX_GENERADOR_NOMBRE` (cómo
se le llama en la página), `REPOSMX_GENERADOR_EXTRA` (un objeto JSON con campos de más; por omisión
`{"enable_thinking": false}`) y `REPOSMX_REDACTAN` (respuestas a la vez, 1). `sirve.sh` las toma de
`data/web/generador.env`, fuera de git.

No se comprueban los vectores al arrancar (decisión del usuario, 2026-11-26): el codificador se compara una vez
con Colab antes de codificar (colab/codifica_cli.sh) y la calidad se mide en la evaluación (fase 3).
"""
function main()
    raiz = get(ENV, "REPOSMX_RAIZ", dirname(dirname(@__DIR__)))
    puerto = parse(Int, get(ENV, "REPOSMX_PUERTO", "8790"))
    prefijo = String(rstrip(get(ENV, "REPOSMX_PREFIJO", "/reposmx"), '/'))
    (isempty(prefijo) || startswith(prefijo, "/")) || error("REPOSMX_PREFIJO debe empezar con /")
    estaticos = joinpath(raiz, "web", "estaticos")
    println("ReposMxWeb en Julia ", VERSION, " con ", Threads.nthreads(), " hilos")

    pasos = parse(Int, get(ENV, "REPOSMX_PASOS", "6"))
    pasos >= 1 || error("REPOSMX_PASOS debe ser al menos 1")
    convs = Conversaciones(; max_pasos=pasos)

    gen = nothing
    api_gen = String(rstrip(strip(get(ENV, "REPOSMX_GENERADOR_API", "")), '/'))
    modelo_gen = strip(get(ENV, "REPOSMX_GENERADOR", ""))
    if !isempty(api_gen) && !(modelo_gen in ("", "0"))
        extra = strip(get(ENV, "REPOSMX_GENERADOR_EXTRA", "{\"enable_thinking\": false}"))
        extra = Dict{String,Any}(String(k) => v for (k, v) in JSON.parse(extra))
        gen = Generador(api_gen, modelo_gen; api=:openai, nombre=get(ENV, "REPOSMX_GENERADOR_NOMBRE", modelo_gen),
                        llave=strip(get(ENV, "REPOSMX_GENERADOR_LLAVE", "")), extra,
                        fragmentos=parse(Int, get(ENV, "REPOSMX_FRAGMENTOS", "6")), max_fila=parse(Int, get(ENV, "REPOSMX_FILA", "8")),
                        sugerencias=parse(Int, get(ENV, "REPOSMX_SUGERENCIAS", "3")),
                        a_la_vez=parse(Int, get(ENV, "REPOSMX_REDACTAN", "1")), max_silencio=120)
        try
            t = @elapsed prueba_generador(gen)
            println("generador: ", gen.modelo, " en ", gen.url, ", lee ", gen.fragmentos, " fragmentos, ", gen.a_la_vez,
                    " a la vez (", round(t; digits=1), " s la primera respuesta)")
        catch e
            e isa ErrorGenerador || rethrow()
            @warn "sin generador: se sirve sólo la búsqueda" motivo = e.msg
            gen = nothing
        end
    else
        println("sin generador (falta REPOSMX_GENERADOR_API o REPOSMX_GENERADOR): sólo búsqueda")
    end

    println("abriendo el acervo:")
    cod = Dense.QueryEncoder(get(ENV, "OLLAMA_URL", "http://127.0.0.1:11434"), get(ENV, "OLLAMA_MODELO", "qwen3-embedding:0.6b-fp16"))
    t = @elapsed acervo = abre(; data_dir=get(ENV, "REPOSMX_DATOS", joinpath(raiz, "data", "repos")),
                                index_dir=get(ENV, "REPOSMX_INDICE", joinpath(raiz, "data", "index")), cod,
                                metas_dir=joinpath(raiz, "metadisciplinas"))
    println("acervo abierto en ", round(t; digits=1), " s")

    versiones = Dict(f => bytes2hex(sha1(read(joinpath(estaticos, f))))[1:10] for f in readdir(estaticos) if isfile(joinpath(estaticos, f)))
    SERVICIO[] = Servicio(acervo, gen, convs, prefijo, Base.Semaphore(parse(Int, get(ENV, "REPOSMX_A_LA_VEZ", "16"))),
                          get(ENV, "REPOSMX_MOSTRAR_TEXTO", "0") == "1", versiones, now())
    rutas(estaticos)
    # En cuanto escucha, una petición a cada ruta: la compilación se paga aquí y no en la primera visita. No es
    # una comprobación: si Ollama no está, la búsqueda densa falla aquí en silencio y se avisa en la consulta.
    Threads.@spawn begin
        base = "http://127.0.0.1:$puerto$prefijo"
        pide(ruta; h=Pair{String,String}[]) = HTTP.get(base * ruta, h; connect_timeout=1, request_timeout=120, status_exception=false).status
        for _ in 1:300
            try
                pide("/api/salud") == 200 && break
            catch
            end
            sleep(0.1)
        end
        t = @elapsed begin
            pide("/"); pide("/api/colecciones"); pide("/mapa"); pide("/api/metadisciplinas")
            pide("/autores?q=garcia"); pide("/api/autores?q=garcia&k=3")
            pide("/referencias?q=redes+neuronales"); pide("/api/referencias?q=redes+neuronales&k=3")
            for m in modos(acervo)
                pide("/api/buscar?q=agua&k=3&modo=$m")
                pide("/buscar?q=agua&k=3&modo=$m"; h=["HX-Request" => "true"])
            end
            lock(() -> empty!(convs.vivas), convs.candado)                       # las del calentamiento no cuentan
        end
        println("rutas calentadas en ", round(t; digits=1), " s\nlisto: ", base, "/")
        flush(stdout)
    end
    # Sin bitácora de accesos (llevaría el texto de las consultas), sin /docs ni /metrics, sin trazas al cliente.
    Oxygen.serve(; host="127.0.0.1", port=puerto, prefix=isempty(prefijo) ? nothing : prefijo, parallel=true,
                 docs=false, metrics=false, show_errors=false, show_banner=false, access_log=nothing)
end

end
