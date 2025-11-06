using JSON3, HTTP, HDF5, ProgressMeter

struct OllamaEmbedResponse{FT}
    model::String
    embeddings::Vector{Vector{FT}}
    total_duration
    load_duration
    prompt_eval_count
end

struct OllamaEmbeddingResponse{FT}
    embedding::Vector{FT}
end

const MODEL = "huggingface.co/AndreasX/jina-embeddings-v2-base-es-Q4_K_M-GGUF:latest"
#const MODEL = "jina/jina-embeddings-v2-base-es"
const CONTENT_TYPE = ["Content-Type" => "application/json"]
const PORT = 11434
const HOST = "127.0.0.1"
const URL_EMBED = "http://$HOST:$PORT/api/embed"
const URL_EMBEDDINGS = "http://$HOST:$PORT/api/embeddings"
const URL_TOKENIZE = "http://$HOST:$PORT/api/tokenize"

function embed(::Type{FT}, messages::AbstractVector; url=URL_EMBED, model=MODEL, content_type=CONTENT_TYPE, block::Int=64) where {FT<:AbstractFloat}
    X = []
    @showprogress dt = 2 desc = "computing embeddings with $model" for M in Iterators.partition(messages, block)
        data = JSON3.write(Dict("model" => model, "input" => M))
        res = HTTP.post(url, content_type, data)
        D = String(res.body)
        try
            x = JSON3.read(D, OllamaEmbedResponse{FT})
            push!(X, x.embeddings)
        catch e
            @show D
            rethrow(e)
        end
    end

    M = Matrix{FT}(undef, length(X[1][1]), length(messages))
    for (i, v) in enumerate(Iterators.flatten(X))
        M[:, i] .= v
    end

    model, M
end

function embed(::Type{FT}, message::AbstractString; url=URL_EMBEDDINGS, model=MODEL, content_type=CONTENT_TYPE) where {FT<:AbstractFloat}
    data = JSON3.write(Dict("model" => model, "prompt" => message))
    res = HTTP.post(url, content_type, data)
    D = String(res.body)
    model, JSON3.read(D, OllamaEmbeddingResponse{FT}).embedding
end

function tokenize(message::AbstractString; url=URL_TOKENIZE, model=MODEL, content_type=CONTENT_TYPE)
    data = JSON3.write(Dict("model" => model, "prompt" => message))
    res = HTTP.post(url, content_type, data)
    D = String(res.body)
    model, JSON3.read(D, Dict)
end
