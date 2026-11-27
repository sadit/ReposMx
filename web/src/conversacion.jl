# Conversaciones: una serie de pasos, cada uno una pregunta con su búsqueda y su respuesta redactada. Las
# preguntas y respuestas anteriores acompañan a la pregunta actual cuando el modelo redacta (generador.jl); cada
# pregunta se busca sola. Hay un límite de pasos por conversación. Es la parte de AmbientalWeb sin las sesiones
# guardadas (fase 5 de docs/plan-rag-web.md): viven en la memoria del proceso y se pierden al reiniciarlo.

mutable struct Paso
    consulta::String
    modo::Symbol
    repo::String
    cti::Union{Nothing,Pair{String,String}}
    meta::String
    autor::Union{Nothing,Autor}
    resultados::Vector{Resultado}
    ms::Dict{String,Float64}                   # de la búsqueda
    respuesta::Union{Nothing,Redaccion}        # `nothing`: sin redactar (en curso, cancelada o sin generador)
end
Paso(r::Respuesta) = Paso(r.consulta, r.modo, r.repo, r.cti, r.meta, r.autor, r.resultados, r.ms, nothing)

mutable struct Conversacion
    id::String
    pasos::Vector{Paso}
    tocada::Float64
end

struct LimiteDePasos <: Exception
    max::Int
end
struct SinConversacion <: Exception end        # esa conversación ya no está en la memoria

struct Conversaciones
    vivas::Dict{String,Conversacion}
    candado::ReentrantLock
    max_pasos::Int
    max_vivas::Int
end
Conversaciones(; max_pasos::Int=6, max_vivas::Int=500) = Conversaciones(Dict{String,Conversacion}(), ReentrantLock(), max_pasos, max_vivas)

# El identificador es lo único que hace falta para leer una conversación: 128 bits del sistema.
identificador() = bytes2hex(open(io -> read(io, 16), "/dev/urandom"))

function nueva!(cs::Conversaciones)
    c = Conversacion(identificador(), Paso[], time())
    lock(cs.candado) do
        if length(cs.vivas) >= cs.max_vivas                 # se van las que llevan más tiempo sin tocarse
            viejas = sort!(collect(values(cs.vivas)); by=x -> x.tocada)
            for x in first(viejas, max(1, length(viejas) ÷ 4))
                delete!(cs.vivas, x.id)
            end
        end
        cs.vivas[c.id] = c
    end
    c
end

function viva(cs::Conversaciones, id::AbstractString)
    occursin(r"^[0-9a-f]{32}$", id) || return nothing
    lock(cs.candado) do
        c = get(cs.vivas, id, nothing)
        c === nothing || (c.tocada = time())
        c
    end
end

"Añade un paso y devuelve su número; lanza `LimiteDePasos` si la conversación ya llegó al límite."
function agrega!(cs::Conversaciones, c::Conversacion, p::Paso)
    lock(cs.candado) do
        length(c.pasos) >= cs.max_pasos && throw(LimiteDePasos(cs.max_pasos))
        push!(c.pasos, p)
        c.tocada = time()
        length(c.pasos)
    end
end

fija!(cs::Conversaciones, p::Paso, r::Redaccion) = lock(() -> (p.respuesta = r; nothing), cs.candado)

"Cuántos fragmentos se mostraron antes del paso `n`: los de ese paso se numeran a partir del siguiente."
antes(c::Conversacion, n::Int) = sum(length(p.resultados) for p in first(c.pasos, n - 1); init=0)

"Las preguntas anteriores al paso `n` que ya tienen respuesta, con ella: lo que acompaña a la pregunta actual."
historia(cs::Conversaciones, c::Conversacion, n::Int) = lock(cs.candado) do
    Tuple{String,String}[(p.consulta, p.respuesta.texto) for p in first(c.pasos, n - 1) if p.respuesta !== nothing]
end
