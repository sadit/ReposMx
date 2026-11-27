# La cara JSON: el contrato para cualquier cliente que no sea la interfaz web. Las páginas de paginas.jl llaman
# a las mismas funciones de acervo.jl, no a estas rutas. Ninguna respuesta lleva rutas de archivos de nuestra
# copia; el texto de las partes del texto completo sale sólo si el servicio se levantó con REPOSMX_MOSTRAR_TEXTO=1.

const MAX_CONSULTA = 1000       # caracteres
const MAX_K = 50

struct ErrorPeticion <: Exception
    msg::String
end

struct Peticion
    q::String
    modo::Symbol
    repo::String
    cti::Union{Nothing,Pair{String,String}}   # nivel => valor de la clasificación CTI
    meta::String            # clave de la meta-disciplina ("" = sin filtro)
    autor::String           # id consolidado del autor en cuya producción se busca ("" = en todo)
    k::Int
    por_documento::Int
    conv::String            # la conversación que se sigue ("" = una nueva)
end

pares(req::HTTP.Request) = URIs.queryparampairs(URI(req.target))

function entero(v::AbstractString, nombre, rango)
    n = tryparse(Int, strip(v))
    (n === nothing || !(n in rango)) && throw(ErrorPeticion("$nombre debe ser un entero entre $(first(rango)) y $(last(rango))"))
    n
end

"Lee y valida `q`, `modo`, `repo`, `autor`, `k`, `por_documento` y `conv`."
function peticion(req::HTTP.Request, s; k_def::Int=10)
    q, repo, autor, k, pd, conv = "", "", "", k_def, 2, ""
    cti, meta = nothing, ""
    modo = first(modos(s.acervo))
    for (llave, v) in pares(req)
        if llave == "q"
            q = String(strip(v))
        elseif llave == "modo"
            modo = Symbol(v)
            modo in modos(s.acervo) || throw(ErrorPeticion("modo debe ser uno de: " * join(modos(s.acervo), ", ")))
        elseif llave == "repo"
            repo = String(strip(v))
        elseif llave == "autor"
            autor = String(strip(v))
        elseif llave == "cti" && !isempty(strip(v))
            cti = cti_de(s, v)
        elseif llave == "meta" && !isempty(strip(v))
            meta = String(strip(v))
            haskey(s.acervo.meta_docs, meta) || throw(ErrorPeticion("meta-disciplina desconocida: $meta"))
        elseif llave == "k"
            k = entero(v, "k", 1:MAX_K)
        elseif llave == "por_documento"
            pd = entero(v, "por_documento", 0:MAX_K)
        elseif llave == "conv"
            conv = String(strip(v))
        end
    end
    isempty(q) && throw(ErrorPeticion("falta la consulta (q)"))
    length(q) > MAX_CONSULTA && throw(ErrorPeticion("la consulta pasa de $MAX_CONSULTA caracteres"))
    (isempty(repo) || repo in s.acervo.repos) || throw(ErrorPeticion("repositorio desconocido: $repo"))
    length(autor) > 200 && throw(ErrorPeticion("autor inválido"))
    Peticion(q, modo, repo, cti, meta, autor, k, pd, conv)
end

"`nivel:valor` (por ejemplo `disciplina:CIENCIA DE LOS ORDENADORES`) a `nivel => valor`, validado contra el acervo."
function cti_de(s, v::AbstractString)
    i = findfirst(':', v)
    i === nothing && throw(ErrorPeticion("cti debe ser nivel:valor (nivel: area, campo o disciplina)"))
    nivel, valor = String(strip(v[1:prevind(v, i)])), String(strip(v[nextind(v, i):end]))
    vals = Dict(s.acervo.cti)
    haskey(vals, nivel) || throw(ErrorPeticion("nivel CTI desconocido: $nivel (area, campo o disciplina)"))
    any(x -> x.name == valor, vals[nivel]) || throw(ErrorPeticion("no hay documentos con $nivel $valor"))
    nivel => valor
end

"El autor de la petición, o `nothing`; lanza `ErrorPeticion` si no se encuentra."
function autor_de(s, ref::AbstractString)
    isempty(ref) && return nothing
    a = autor(s.acervo, ref)
    a === nothing && throw(ErrorPeticion("no se encontró ese autor"))
    isempty(a.documentos) && throw(ErrorPeticion("ese autor no tiene documentos indexados"))
    a
end

"Corre la búsqueda con el cupo del servicio y deja un renglón en la bitácora, sin el texto de la consulta."
function responde(s, p::Peticion)
    t = @elapsed r = Base.acquire(s.cupo) do
        busca(s.acervo, p.q; modo=p.modo, repo=p.repo, cti=p.cti, meta=p.meta, autor=autor_de(s, p.autor), k=p.k, por_documento=p.por_documento)
    end
    bitacora("busca modo=", p.modo, isempty(p.autor) ? "" : " autor", " k=", p.k, " resultados=", length(r.resultados), " ms=", round(Int, 1000t))
    r
end

"""
El paso siguiente de una conversación: sigue la de `p.conv` o empieza una; busca la pregunta (sola: las
anteriores no entran en la búsqueda) y añade el paso. Devuelve la conversación y el número del paso.
"""
function paso_nuevo!(s, p::Peticion)
    cs = s.convs
    c = nothing
    if !isempty(p.conv)
        c = viva(cs, p.conv)
        c === nothing && throw(SinConversacion())
        length(c.pasos) >= cs.max_pasos && throw(LimiteDePasos(cs.max_pasos))        # antes de buscar
    end
    r = responde(s, p)
    c === nothing && (c = nueva!(cs))
    c, agrega!(cs, c, Paso(r))
end

bitacora(xs...) = (println(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), " ", xs...); flush(stdout))

"Un renglón en la bitácora por redacción, sin el texto de la consulta ni el de la respuesta."
function anota(r::Redaccion, segundos, paso::Int=1)
    bitacora("redacta paso=", paso, " leidos=", r.leidos, r.de_memoria ? " de memoria" :
             string(" tokens=", get(r.tokens, "prompt", 0), "+", get(r.tokens, "respuesta", 0), " cache=", get(r.tokens, "cache", 0),
                    " espera=", round(Int, r.ms["espera"]), " lee=", round(Int, r.ms["lee"]), " escribe=", round(Int, r.ms["escribe"])),
             " ms=", round(Int, 1000 * segundos))
end

redondea(x::Nothing) = nothing
redondea(x::Real) = round(Float64(x); digits=4)

como_dict(s, r::Resultado) = Dict{String,Any}(
    "repo" => r.repo, "parte" => r.doc_id, "documento" => r.documento, "seccion" => r.seccion,
    "puntaje" => redondea(r.puntaje), "similitud" => redondea(r.similitud), "bm25" => redondea(r.bm25),
    "titulo" => r.titulo, "cita" => r.cita, "liga" => r.liga, "resumen" => r.resumen,
    "texto" => (publico(r) || s.mostrar_texto) ? r.texto : nothing)

como_dict(s, a::Autor) = Dict{String,Any}("id" => a.id, "nombre" => a.nombre, "documentos" => length(a.documentos))
como_dict(s, ::Nothing) = nothing

cti_dict(c) = c === nothing ? nothing : Dict("nivel" => first(c), "valor" => last(c), "fuente" => "declarada por el repositorio (catálogos CTI de SECIHTI)")

meta_dict(s, m) = isempty(m) ? nothing : Dict("clave" => m, "nombre" => nombre_meta(s.acervo, m))

como_dict(s, r::Respuesta) = Dict{String,Any}(
    "consulta" => r.consulta, "modo" => String(r.modo), "repo" => r.repo, "cti" => cti_dict(r.cti), "metadisciplina" => meta_dict(s, r.meta), "autor" => como_dict(s, r.autor),
    "ms" => Dict(k => round(v; digits=1) for (k, v) in r.ms), "resultados" => [como_dict(s, x) for x in r.resultados])

como_dict(s, r::Redaccion) = Dict{String,Any}(
    "texto" => r.texto, "fragmentos_leidos" => r.leidos, "citados" => r.citados, "de_memoria" => r.de_memoria, "sugerencias" => r.sugerencias,
    "ms" => Dict(k => round(v; digits=1) for (k, v) in r.ms), "tokens" => r.tokens)

como_dict(s, p::Paso) = Dict{String,Any}(
    "consulta" => p.consulta, "modo" => String(p.modo), "repo" => p.repo, "cti" => cti_dict(p.cti), "metadisciplina" => meta_dict(s, p.meta), "autor" => como_dict(s, p.autor),
    "ms" => Dict(k => round(v; digits=1) for (k, v) in p.ms), "resultados" => [como_dict(s, x) for x in p.resultados],
    "respuesta" => como_dict(s, p.respuesta))

fallo(msg, status) = Oxygen.json(Dict("error" => msg); status)

"Envuelve una ruta: los errores de la petición son 400, los del codificador 503 y lo demás 500 sin detalle."
function cuida(f, en_error=fallo)
    function (req::HTTP.Request)
        try
            f(req)
        catch e
            e isa ErrorPeticion && return en_error(e.msg, 400)
            e isa ErrorCodificador && return en_error("El codificador de consultas no está disponible; la búsqueda por palabras (BM25) sigue funcionando.", 503)
            e isa LimiteDePasos && return en_error("Esta conversación llegó al límite de $(e.max) preguntas; empieza una nueva.", 409)
            e isa SinConversacion && return en_error("Esa conversación ya no está en la memoria del servidor; empieza una nueva.", 404)
            e isa GeneradorOcupado && return en_error("Demo con recursos limitados: hay demasiadas respuestas en fila; intenta en un par de minutos. La búsqueda sigue funcionando.", 503)
            e isa ErrorGenerador && return en_error("El modelo que redacta no está disponible; la búsqueda sigue funcionando.", 503)
            @error "error en una ruta" ruta = first(split(req.target, '?')) exception = (e, catch_backtrace())
            en_error("Error interno.", 500)
        end
    end
end

api_buscar(req::HTTP.Request) = (s = SERVICIO[]; Oxygen.json(como_dict(s, responde(s, peticion(req, s)))))

"""
Un paso de conversación completo: la búsqueda y la respuesta redactada (`respuesta`). Sin `conv` empieza una
conversación; la respuesta trae `conv` y `paso` para seguirla. Espera a que termine. La página no usa esta ruta
sino el flujo de `/redaccion`.
"""
function api_responder(req::HTTP.Request)
    s = SERVICIO[]
    s.gen === nothing && return fallo("este servidor se levantó sin generador: sólo /api/buscar", 503)
    c, n = paso_nuevo!(s, peticion(req, s))
    p = c.pasos[n]
    d = como_dict(s, p)
    d["conv"], d["paso"], d["pasos_max"] = c.id, n, s.convs.max_pasos
    d["primer_fragmento"] = antes(c, n) + 1
    if !isempty(p.resultados)
        t = @elapsed red = redacta(s.gen, p.consulta, p.resultados; base=antes(c, n), historia=historia(s.convs, c, n),
                                   proponer=n < s.convs.max_pasos)
        fija!(s.convs, p, red)
        anota(red, t, n)
        d["respuesta"] = como_dict(s, red)
    end
    Oxygen.json(d)
end

function api_conversacion(req::HTTP.Request)
    s = SERVICIO[]
    c = viva(s.convs, get(Dict(pares(req)), "id", ""))
    c === nothing && throw(SinConversacion())
    Oxygen.json(Dict{String,Any}("pasos_max" => s.convs.max_pasos, "pasos" => [como_dict(s, p) for p in c.pasos]))
end

function consulta_lista(req, s)
    d = Dict(pares(req))
    q = String(strip(get(d, "q", "")))
    isempty(q) && throw(ErrorPeticion("falta la consulta (q)"))
    length(q) > MAX_CONSULTA && throw(ErrorPeticion("la consulta pasa de $MAX_CONSULTA caracteres"))
    repo = String(strip(get(d, "repo", "")))
    (isempty(repo) || repo in s.acervo.repos) || throw(ErrorPeticion("repositorio desconocido: $repo"))
    q, repo, entero(get(d, "k", "20"), "k", 1:MAX_K)
end

function api_autores(req::HTTP.Request)
    s = SERVICIO[]
    q, repo, k = consulta_lista(req, s)
    autores, ms = Base.acquire(() -> busca_autores(s.acervo, q; repo, k), s.cupo)
    Oxygen.json(Dict("consulta" => q, "repo" => repo, "ms" => round(ms; digits=1), "autores" => [Dict(
        "id" => a["consolidated_id"], "nombre" => a["name"], "documentos" => a["doc_count"], "repos" => a["repos"],
        "palabras_clave" => first(a["keywords"], 12), "coautores" => first(a["coauthors"], 12), "bm25" => redondea(a["score"])) for a in autores]))
end

function api_referencias(req::HTTP.Request)
    s = SERVICIO[]
    q, repo, k = consulta_lista(req, s)
    docs, ms = Base.acquire(() -> busca_referencias(s.acervo, q; repo, k), s.cupo)
    Oxygen.json(Dict("consulta" => q, "repo" => repo, "ms" => round(ms; digits=1), "documentos" => [Dict(
        "documento" => d.documento, "titulo" => d.titulo, "cita" => d.cita, "liga" => d.liga, "referencias" => d.total,
        "coinciden" => d.coinciden, "bm25" => redondea(d.bm25)) for d in docs]))
end

api_colecciones(req::HTTP.Request) = (s = SERVICIO[]; Oxygen.json(Dict(
    "colecciones" => ["documentos", "autores", "referencias"],
    "modos_documentos" => String.(collect(modos(s.acervo))),
    "repos" => s.acervo.repos,
    "cti" => Dict(n => [Dict("valor" => x.name, "documentos" => x.items) for x in v] for (n, v) in s.acervo.cti),
    "generador" => s.gen === nothing ? nothing : s.gen.nombre, "pasos_max" => s.convs.max_pasos)))

"El grafo de las meta-disciplinas (nodos con nombre, descripción, palabras y documentos; aristas por cercanía y documentos compartidos)."
function api_metadisciplinas(req::HTTP.Request)
    g = SERVICIO[].acervo.grafo
    g === nothing && return fallo("este servidor no tiene meta-disciplinas", 404)
    Oxygen.json(g)
end

function api_salud(req::HTTP.Request)
    s = SERVICIO[]
    Oxygen.json(Dict("estado" => "arriba", "desde" => string(s.arranque), "julia" => string(VERSION),
                     "denso" => tiene_denso(s.acervo), "partes" => s.acervo.unidades, "documentos_densos" => s.acervo.documentos,
                     "generador" => s.gen === nothing ? nothing :
                                    Dict("modelo" => s.gen.modelo, "fragmentos" => s.gen.fragmentos, "a_la_vez" => s.gen.a_la_vez,
                                         "en_fila" => s.gen.fila[], "sugerencias" => s.gen.sugerencias),
                     "conversaciones" => Dict("vivas" => lock(() -> length(s.convs.vivas), s.convs.candado), "pasos_max" => s.convs.max_pasos)))
end
