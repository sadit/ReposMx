# El generador: un modelo lee los primeros fragmentos de la búsqueda y redacta la respuesta con citas, en flujo.
# Es el de AmbientalWeb (~/Projects/Legistlan/RAG-Medio-Ambiente/sistema/web/src/generador.jl) con otras
# instrucciones y otra forma de dar los fragmentos; ahí están las razones de cada detalle (la marca de las
# preguntas para seguir, los fragmentos entre marcas `<fragmento id="N">`, la numeración de corrido en la
# conversación, la pregunta antes y después de los fragmentos). Habla con una API compatible con OpenAI
# (`/chat/completions`), la de Qwen del RAG ambiental (decisión del usuario, 2026-11-26), o con Ollama.
#
# La respuesta es texto corrido: se muestra, no se analiza ni se toma como dato. Las fuentes con su liga son la
# referencia. El modelo lee partes del texto completo de nuestra copia, que la página no muestra: se le pide que
# resuma con sus palabras y no copie pasajes.
const SISTEMA = "Eres un asistente que ayuda a encontrar y entender la producción académica de instituciones mexicanas " *
                "(tesis, artículos, libros, reportes) en una conversación. Respondes en español la pregunta actual del " *
                "usuario usando los fragmentos que se te dan con ella; las preguntas y respuestas anteriores son el contexto " *
                "de la conversación. Cada fragmento es parte de un documento: su ficha (título, autores, resumen y palabras " *
                "clave) o una parte de su texto (del inicio o del final), y tiene un identificador (id). Cada afirmación lleva " *
                "al final, entre corchetes, el id del fragmento del que la tomaste, por ejemplo [7]; cita un fragmento sólo si " *
                "su texto dice eso mismo y no pongas ids de más. Cuando sirva, di qué documento lo dice (autores y año). No " *
                "uses conocimiento que no esté en los fragmentos o en la conversación ni inventes autores, títulos, años, " *
                "datos o resultados. Resume con tus palabras: no copies pasajes de los fragmentos. Si los fragmentos no " *
                "bastan para responder, dilo con claridad y explica qué sí tratan. Sé breve: uno o dos párrafos, sin encabezados."

struct ErrorGenerador <: Exception
    msg::String
    status::Int                    # el de HTTP si la API contestó con error; 0 si no
end
ErrorGenerador(msg) = ErrorGenerador(msg, 0)
Base.showerror(io::IO, e::ErrorGenerador) = print(io, "generador: ", e.msg)
struct GeneradorOcupado <: Exception end       # ya hay demasiadas respuestas en fila
struct ClienteAusente <: Exception end         # quien pidió la respuesta cerró la conexión

struct Redaccion
    texto::String
    leidos::Int                    # cuántos fragmentos leyó el modelo (los primeros de la lista)
    citados::Vector{String}        # los números de fragmento citados en el texto; informativo
    ms::Dict{String,Float64}       # espera (turno), lee (el prompt), escribe
    tokens::Dict{String,Int}       # prompt, respuesta, cache (los del prompt que el servicio tomó de su caché)
    de_memoria::Bool
    sugerencias::Vector{String}    # preguntas que el modelo propuso para seguir; puede no haber
end
Redaccion(texto, leidos, citados, ms, tokens, de_memoria) = Redaccion(texto, leidos, citados, ms, tokens, de_memoria, String[])

struct Generador
    api::Symbol                    # :ollama u :openai
    url::String                    # Ollama: http://127.0.0.1:11434; OpenAI: la base, que suele terminar en /v1
    modelo::String                 # como lo llama esa API
    nombre::String                 # como se le llama en la página
    llave::String                  # de la API; "" si no pide
    extra::Dict{String,Any}        # :openai: campos de más para el cuerpo de la petición, propios de cada servicio
    fragmentos::Int                # cuántos lee el modelo
    max_caracteres::Int            # de cada fragmento
    max_tokens::Int                # de la respuesta
    num_ctx::Int                   # sólo Ollama: el contexto que se le pide
    a_la_vez::Int                  # redacciones simultáneas (1 con Ollama en CPU: el modelo ocupa todos los núcleos)
    ocupados::Threads.Atomic{Int}  # redactando
    fila::Threads.Atomic{Int}      # redactando o en espera
    max_fila::Int
    max_silencio::Float64          # segundos sin que la API mande nada antes de darla por caída
    cache::Dict{String,Redaccion}  # llave -> respuesta terminada
    candado::ReentrantLock
    max_cache::Int
    sugerencias::Int               # cuántas preguntas para seguir se le piden después de cada respuesta; 0 = ninguna
end

function Generador(url, modelo; api::Symbol=:ollama, nombre=modelo, llave="", extra=Dict{String,Any}(), fragmentos=6, max_caracteres=1800, max_tokens=500,
                   num_ctx=8192, a_la_vez=1, max_fila=8, max_silencio=300, max_cache=1000, sugerencias=3)
    api in (:ollama, :openai) || throw(ArgumentError("api debe ser :ollama u :openai"))
    Generador(api, String(rstrip(url, '/')), modelo, nombre, llave, Dict{String,Any}(extra), fragmentos, max_caracteres, max_tokens, num_ctx, a_la_vez,
              Threads.Atomic{Int}(0), Threads.Atomic{Int}(0), max_fila, max_silencio, Dict{String,Redaccion}(), ReentrantLock(), max_cache,
              max(0, sugerencias))
end

"El modelo corre en esta máquina (Ollama) y no en un servicio de fuera."
es_local(g::Generador) = g.api === :ollama

const REINTENTOS = (3, 8, 15)        # segundos de espera antes de cada reintento cuando la API está saturada

# Un lugar para redactar, sin esperar: `true` si lo tomó.
function toma!(g::Generador)
    while true
        n = g.ocupados[]
        n >= g.a_la_vez && return false
        Threads.atomic_cas!(g.ocupados, n, n + 1) == n && return true
    end
end
suelta!(g::Generador) = (Threads.atomic_sub!(g.ocupados, 1); nothing)

"La misma pregunta, en el mismo punto de la misma conversación y con los mismos fragmentos, da la misma respuesta: es la llave de la memoria."
llave(g::Generador, consulta::AbstractString, leidos, base::Int, historia) = bytes2hex(sha1(join(
    [g.modelo, string(g.max_caracteres), string(g.max_tokens), string(base), (q * "\x01" * a for (q, a) in historia)...,
     String(consulta), (r.doc_id for r in leidos)...], "\0")))

# ---------------------------------------------------------------------------------------------------------
# Preguntas para seguir (como en AmbientalWeb): en la misma respuesta, el modelo pone una marca al
# terminar de responder y debajo unas preguntas que se pueden hacer a continuación. Tienen que salir de lo que
# los fragmentos dicen con claridad, para que al hacerlas haya de dónde responder, y entenderse solas, porque
# cada pregunta se busca por separado. Lo que va desde la marca no es parte de la respuesta: no se le manda al
# visitante como texto ni acompaña a las preguntas siguientes; de ahí se sacan las preguntas (`preguntas_de`),
# que la página ofrece como botones.
const MARCA = "<preguntas>"
const MARCA_RE = r"<preguntas\b[^>\n]*>?"i
const MAX_SUGERENCIA = 200         # caracteres de una pregunta propuesta

pide_sugerencias(n::Int) =
    "\nAl terminar la respuesta escribe en un renglón aparte la marca $MARCA, debajo $n preguntas que el usuario podría " *
    "hacer a continuación, una por renglón, y cierra con </preguntas>. Cada pregunta: (1) se responde con lo que dicen " *
    "claramente estos fragmentos, no con conocimiento de fuera ni con algo que sólo mencionan de paso; (2) está " *
    "relacionada con la pregunta actual y pide algo que tu respuesta no dijo ya, de preferencia lo que ayuda a entender " *
    "el tema (qué se ha estudiado, con qué métodos, qué se encontró, dónde) y no un dato suelto; " *
    "(3) se entiende sola, porque se buscará " *
    "por separado: nombra completo aquello de que trata (el tema, el método, el lugar o la población), sin referencias " *
    "como «este estudio», «dicho método», «eso» ni «el trabajo anterior». Las preguntas van sin numerar y sin ids de fragmento."

"Lo que escribió el modelo, partido en la marca: (la respuesta, lo que sigue a la marca). Sin marca todo es respuesta."
function parte(texto::AbstractString)
    m = match(MARCA_RE, texto)
    m === nothing ? (String(strip(texto)), "") : (String(strip(texto[1:prevind(texto, m.offset)])), String(texto[m.offset+ncodeunits(m.match):end]))
end

"""
    preguntas_de(cola, ya, cuantas) -> Vector{String}

Las preguntas que haya en lo que el modelo escribió después de la marca, leído con manga ancha (acuerdo 14: su
salida puede venir fuera de formato): cada renglón que termina en signo de interrogación, sin marcas, viñeta,
número ni citas. No entran las que repiten una de `ya` (las preguntas hechas en la conversación) ni las
repetidas entre sí. Si no hay ninguna la lista sale vacía y no se propone nada: nada depende de que el modelo
obedezca.
"""
function preguntas_de(cola::AbstractString, ya, cuantas::Int)
    igual(x) = lowercase(strip(replace(x, r"[^\p{L}\p{N}]+" => " ")))
    vistas = Set(igual(x) for x in ya)
    ps = String[]
    for l in split(cola, '\n')
        length(ps) >= cuantas && break
        q = replace(l, r"</?[a-zA-Z][^>\n]*>" => "", r"\[[^\[\]]{1,60}\]" => "")       # marcas y citas [7]
        q = replace(strip(q), r"^(?:[-*•–—]+|\d{1,2}\s*[.):-])\s*" => "")              # viñeta o número
        q = strip(q, ['"', '«', '»', '“', '”', '*', '_', ' '])
        i = findfirst('¿', q)
        i === nothing || (q = q[i:end])                                               # «Pregunta 1: ¿...?»
        q = String(strip(replace(replace(q, r"\s+" => " "), r" ([?,;:.])" => s"\1")))      # sin el hueco que dejó una cita antes del signo
        (endswith(q, "?") && 15 <= length(q) <= MAX_SUGERENCIA) || continue
        igual(q) in vistas && continue
        push!(vistas, igual(q))
        push!(ps, q)
    end
    ps
end

# El flujo hacia el visitante: pasa el texto de la respuesta y se detiene en la marca. Un pedazo puede traer la
# marca partida, así que se retiene la cola que todavía puede ser su principio (y los espacios que la preceden).
mutable struct Corte
    retenido::String
    cortado::Bool
end
Corte() = Corte("", false)

function pasa!(c::Corte, pedazo::AbstractString, al_llegar)
    c.cortado && return nothing
    t = c.retenido * pedazo
    m = match(MARCA_RE, t)
    if m !== nothing && (endswith(m.match, ">") || m.offset + ncodeunits(m.match) <= ncodeunits(t))      # la marca completa
        c.cortado, c.retenido = true, ""
        antes = rstrip(t[1:prevind(t, m.offset)])
        isempty(antes) || al_llegar(String(antes))
        return nothing
    end
    cola = match(r"\s*(?:<[a-zA-Z]{0,9})?$", t)                        # espacios y, quizá, el principio de la marca
    desde = cola.offset
    i = findnext('<', t, desde)
    i === nothing || startswith(MARCA, lowercase(t[i:end])) || (desde = ncodeunits(t) + 1)      # ese «<» no es la marca
    c.retenido = String(t[desde:end])
    desde > 1 && al_llegar(String(t[1:prevind(t, desde)]))
    nothing
end

function mensajes(g::Generador, consulta::AbstractString, leidos; base::Int=0, historia=(), proponer::Bool=false)
    frag = join(("<fragmento id=\"$(base + n)\">\ndocumento: $(r.titulo)\nautores y fuente: $(r.cita)\n" *
                 "parte: $(get(NOMBRE_SECCION, r.seccion, r.seccion))\ntexto: $(first(r.texto, g.max_caracteres))\n</fragmento>"
                 for (n, r) in enumerate(leidos)), "\n\n")
    ids = join((string(base + n) for n in eachindex(leidos)), ", ")
    msgs = [Dict("role" => "system", "content" => SISTEMA)]
    for (q, a) in historia
        push!(msgs, Dict("role" => "user", "content" => q), Dict("role" => "assistant", "content" => a))
    end
    # La pregunta va antes y después de los fragmentos. Con la pregunta sólo al final, en una conversación el
    # modelo llegó a contestar la pregunta anterior con los fragmentos de la actual (PROCESO.md, 2026-11-25).
    push!(msgs, Dict("role" => "user", "content" =>
        "Pregunta actual: $consulta\n\nFragmentos para responderla, cada uno con su id:\n\n$frag\n\nResponde la pregunta actual: $consulta\n" *
        "Después de cada afirmación pon entre corchetes el id del fragmento que la dice (ids de esta pregunta: $ids)." *
        (proponer && g.sugerencias > 0 ? pide_sugerencias(g.sugerencias) : "")))
end

"Los números de fragmento citados en el texto, entre corchetes, que pueden existir: del 1 a `hasta`."
function citados(texto::AbstractString, hasta::Int)
    cs = String[]
    for m in eachmatch(r"\[([^\[\]]{1,60})\]", texto), d in eachmatch(r"(?<![\d.])\d{1,3}(?![\d.])", m.captures[1])
        1 <= parse(Int, d.match) <= hasta && push!(cs, String(d.match))
    end
    unique!(cs)
end

# Lo que cambia de una API a la otra: a dónde se pide y con qué, y cómo se lee cada renglón del flujo.
function peticion_chat(g::Generador, msgs, max_tokens::Int)
    if g.api === :ollama
        (g.url * "/api/chat", ["Content-Type" => "application/json"],
         Dict("model" => g.modelo, "stream" => true, "messages" => msgs,
              "options" => Dict("temperature" => 0, "num_ctx" => g.num_ctx, "num_predict" => max_tokens)))
    else
        cab = ["Content-Type" => "application/json", "Accept" => "text/event-stream"]
        isempty(g.llave) || push!(cab, "Authorization" => "Bearer " * g.llave)
        cuerpo = Dict{String,Any}("model" => g.modelo, "stream" => true, "messages" => msgs, "temperature" => 0, "max_tokens" => max_tokens,
                                  "stream_options" => Dict("include_usage" => true))       # pide las cuentas de tokens al final del flujo
        (g.url * "/chat/completions", cab, merge!(cuerpo, g.extra))
    end
end

mensaje_de_error(e) = e isa AbstractDict ? string(get(e, "message", e)) : string(e)

# Un renglón del flujo: devuelve el pedazo de texto que trae ("" si ninguno) y anota en `uso` las cuentas y el fin.
function renglon!(g::Generador, l::AbstractString, uso::Dict{String,Float64})
    if g.api === :ollama                                    # un JSON por renglón
        isempty(l) && return ""
        ev = JSON.parse(l)
        haskey(ev, "error") && throw(ErrorGenerador(mensaje_de_error(ev["error"])))
        if get(ev, "done", false) === true
            uso["fin"] = 1
            uso["prompt"], uso["respuesta"] = get(ev, "prompt_eval_count", 0), get(ev, "eval_count", 0)
            uso["lee"], uso["escribe"] = get(ev, "prompt_eval_duration", 0) / 1e6, get(ev, "eval_duration", 0) / 1e6
        end
        m = get(ev, "message", nothing)
        d = m === nothing ? nothing : get(m, "content", nothing)
        return d isa AbstractString ? String(d) : ""
    end
    startswith(l, "data:") || return ""                    # eventos «data: {...}»; lo demás son comentarios o renglones vacíos
    dato = strip(l[6:end])
    dato == "[DONE]" && (uso["fin"] = 1; return "")
    ev = JSON.parse(dato)
    haskey(ev, "error") && throw(ErrorGenerador(mensaje_de_error(ev["error"])))
    u = get(ev, "usage", nothing)
    if u isa AbstractDict
        uso["prompt"], uso["respuesta"] = something(get(u, "prompt_tokens", 0), 0), something(get(u, "completion_tokens", 0), 0)
        det = get(u, "prompt_tokens_details", nothing)          # cuántos tokens del prompt salieron del caché del servicio
        det isa AbstractDict && (uso["cache"] = something(get(det, "cached_tokens", 0), 0))
    end
    cs = get(ev, "choices", nothing)
    (cs isa AbstractVector && !isempty(cs)) || return ""
    get(cs[1], "finish_reason", nothing) === nothing || (uso["fin"] = 1)
    delta = get(cs[1], "delta", nothing)
    d = delta === nothing ? nothing : get(delta, "content", nothing)      # el razonamiento, si el modelo lo manda aparte, no se usa
    d isa AbstractString ? String(d) : ""
end

# Pide el chat en flujo. Una tarea lee los renglones y pasa los pedazos de texto por un canal; un reloj mete
# latidos al mismo canal para que quien consume pueda notar que su cliente se fue aunque el modelo todavía no
# escriba (leer el prompt tarda), y que la API dejó de responder. Si quien consume falla, se interrumpe la
# lectura: al cerrarse la conexión el servicio deja de generar (comprobado con Ollama el 2026-11-24).
# Devuelve el texto y las cuentas: tokens (prompt, respuesta) y milisegundos (lee, escribe).
function chat(g::Generador, msgs, al_llegar, latido; max_tokens::Int=g.max_tokens)
    url, cab, cuerpo = peticion_chat(g, msgs, max_tokens)
    cuerpo = JSON.json(cuerpo)
    quien = es_local(g) ? "Ollama" : "la API del generador"
    canal = Channel{Any}(256)
    uso = Dict{String,Float64}()                           # lo escribe el lector; se lee cuando ya cerró el canal
    lector = Threads.@spawn begin
        try
            HTTP.open("POST", url, cab; retry=false, connect_timeout=15, status_exception=false) do io
                write(io, cuerpo)
                r = HTTP.startread(io)
                if r.status != 200
                    msg = String(read(io))
                    try
                        msg = mensaje_de_error(get(JSON.parse(msg), "error", msg))
                    catch
                    end
                    throw(ErrorGenerador("$quien respondió $(r.status): $(first(msg, 300))", r.status))
                end
                while !eof(io)
                    d = renglon!(g, readline(io), uso)
                    isempty(d) || put!(canal, d)
                end
            end
        catch e
            if !(e isa InterruptException)
                err = e isa ErrorGenerador ? e : ErrorGenerador("$quien no responde en $(g.url) ($(typeof(e)))")
                try
                    put!(canal, err)
                catch
                end
            end
        finally
            close(canal)
        end
    end
    reloj = Timer(2; interval=2) do _
        try
            put!(canal, :latido)
        catch
        end
    end
    texto = IOBuffer()
    t0 = time()
    primero, ultimo = 0.0, t0
    try
        for ev in canal
            if ev === :latido
                time() - ultimo > g.max_silencio && throw(ErrorGenerador("$quien lleva $(round(Int, g.max_silencio)) s sin mandar nada"))
                latido()
            elseif ev isa Exception
                throw(ev)
            else
                ultimo = time()
                primero == 0 && (primero = ultimo)
                print(texto, ev)
                al_llegar(ev)
            end
        end
    catch
        close(canal)                                   # si está entre dos pedazos, el lector sale solo al escribir
        if timedwait(() -> istaskdone(lector), 0.5) !== :ok
            try
                schedule(lector, InterruptException(); error=true)      # está esperando al servicio: se interrumpe
            catch
            end
        end
        rethrow()
    finally
        close(reloj)
    end
    get(uso, "fin", 0) == 1 || throw(ErrorGenerador("$quien cortó la respuesta"))
    # Ollama dice cuánto tardó en leer y en escribir; de las demás se mide desde aquí (hasta el primer pedazo y después)
    primero == 0 && (primero = time())
    haskey(uso, "lee") || (uso["lee"] = 1000 * (primero - t0); uso["escribe"] = 1000 * (time() - primero))
    String(take!(texto)), uso
end

"""
    redacta(g, consulta, resultados; base, historia, proponer, al_llegar, al_estado) -> Redaccion

Redacta la respuesta con los primeros `g.fragmentos` de `resultados`. En una conversación, `base` es cuántos fragmentos se mostraron en las preguntas anteriores (los de ésta
se numeran desde `base + 1`) e `historia` las preguntas anteriores con su respuesta (`[(pregunta, respuesta), ...]`).
Con `proponer` se le piden además preguntas para seguir (`sugerencias` de la `Redaccion`; ver `preguntas_de`).
Si la API contesta que está saturada (429 o 503) se espera y se vuelve a pedir, hasta tres veces, avisando con
`al_estado(:saturado, intento)`. `al_llegar(pedazo)` recibe el texto conforme sale; `al_estado(:espera, otras)` se llama cada
segundo mientras espera su turno, `al_estado(:leyendo, 0)` al empezar y `al_estado(:latido, 0)` cada dos
segundos mientras tanto. Si una de esas funciones lanza una excepción (el cliente se fue), se suelta el turno
y se cancela la generación. Lanza `GeneradorOcupado` si la fila está llena y `ErrorGenerador` si la API falla.
"""
function redacta(g::Generador, consulta::AbstractString, resultados::Vector{Resultado};
                 base::Int=0, historia=Tuple{String,String}[], proponer::Bool=true, al_llegar=_ -> nothing, al_estado=(_, _) -> nothing)
    leidos = first(resultados, g.fragmentos)
    proponer = proponer && g.sugerencias > 0
    ll = llave(g, consulta, leidos, base, historia) * (proponer ? "+p" : "")       # con preguntas el prompt es otro
    de_memoria() = lock(g.candado) do
        x = get(g.cache, ll, nothing)
        x === nothing ? nothing : Redaccion(x.texto, x.leidos, x.citados, x.ms, x.tokens, true, proponer ? x.sugerencias : String[])
    end
    r = de_memoria()
    r !== nothing && (al_llegar(r.texto); return r)
    if Threads.atomic_add!(g.fila, 1) >= g.max_fila
        Threads.atomic_sub!(g.fila, 1)
        throw(GeneradorOcupado())
    end
    t0 = time()
    try
        while !toma!(g)
            al_estado(:espera, g.fila[] - 1)
            sleep(1)
        end
        try
            r = de_memoria()                           # otra petición igual la redactó mientras tanto
            r !== nothing && (al_llegar(r.texto); return r)
            espera = 1000 * (time() - t0)
            al_estado(:leyendo, 0)
            msgs = mensajes(g, consulta, leidos; base, historia, proponer)
            texto, uso = "", Dict{String,Float64}()
            corte = Corte()
            for intento in 0:length(REINTENTOS)
                try
                    texto, uso = chat(g, msgs, x -> pasa!(corte, x, al_llegar), () -> al_estado(:latido, 0);
                                      max_tokens=g.max_tokens + (proponer ? 60 * g.sugerencias + 40 : 0))
                    break
                catch e
                    (e isa ErrorGenerador && e.status in (429, 503) && intento < length(REINTENTOS)) || rethrow()
                    fin = time() + REINTENTOS[intento+1]         # saturada: todavía no escribió nada, se puede volver a pedir
                    while time() < fin
                        al_estado(:saturado, intento + 1)
                        sleep(1)
                    end
                    al_estado(:leyendo, 0)
                end
            end
            # lo retenido que al final no fue la marca también es respuesta (sin los espacios del final)
            corte.cortado || isempty(strip(corte.retenido)) || al_llegar(String(rstrip(corte.retenido)))
            texto, cola = parte(texto)
            sugerencias = proponer ? preguntas_de(cola, [String(consulta); String[q for (q, _) in historia]], g.sugerencias) : String[]
            r = Redaccion(texto, length(leidos), citados(texto, base + length(leidos)),
                          Dict("espera" => espera, "lee" => uso["lee"], "escribe" => uso["escribe"]),
                          Dict("prompt" => round(Int, get(uso, "prompt", 0)), "respuesta" => round(Int, get(uso, "respuesta", 0)),
                               "cache" => round(Int, get(uso, "cache", 0))), false, sugerencias)
            lock(g.candado) do
                length(g.cache) >= g.max_cache && empty!(g.cache)
                g.cache[ll] = r
            end
            return r
        finally
            suelta!(g)
        end
    finally
        Threads.atomic_sub!(g.fila, 1)
    end
end

"Una generación mínima: falla aquí si la API no responde, no acepta la llave o no tiene el modelo (con Ollama, además lo carga)."
function prueba_generador(g::Generador)
    texto, _ = chat(g, [Dict("role" => "user", "content" => "Responde sólo: listo")], _ -> nothing, () -> nothing; max_tokens=8)
    texto
end
