using Downloads, Printf, Dates, JSON, Glob, ProgressMeter, DataFrames, HDF5, Random
using Downloads: download, Curl


Downloads.EASY_HOOK[] = (easy, info) -> begin
    Curl.set_ssl_verify(easy, false)
end

using Downloads, JSON

function encode(messages::AbstractVector; url="http://localhost:8000/many/multi")
    headers = Dict("Content-Type" => "application/json")
    output = IOBuffer()
    input = IOBuffer(json(messages))
    r = request(url; method="POST", headers, input, output)

    # check r
    seekstart(output)
    h = readline(output)
    m, n = let (_, m, n) = split(h)
        parse(Int, m), parse(Int, n)
    end

    M = Matrix{Float32}(undef, n, m) # the service returns row major order matrices
    #@show m, n
    for j in 1:m
        for i in 1:n-1
            v = parse(Float32, readuntil(output, ' '))
            M[i, j] = v
        end
        v = parse(Float32, readuntil(output, '\n'))
        M[n, j] = v
    end
    M
end

function create_embedding(file; keys, must_expand=Set(["description"]))
    K = String[]
    E = Matrix[]
    @info "loading dataset $file"
    L = collect(eachline(open(file)))
    @info "loaded $(length(L)) registers"
    @showprogress dt=1 desc="encoding $file" for i in eachindex(L)  # please avoid adapt multithread for since the remove server will be the bottle neck
        r = JSON.parse(L[i])
        id = r["key"]
        messages = []
        for k in keys
            if k in must_expand
                for m in r[k]
                    push!(K, string(id, '/', k))
                    push!(messages, m)
                end
            else
                m = join(r[k], '\n')

                if length(m) > 0
                    push!(K, string(id, '/', k))
                    push!(messages, m)
                end
            end
        end

        if length(messages) > 0
            emb = encode(messages)
            push!(E, emb)
        end
    end

    K, hcat(E...)
end

function main(files; keys=["description", "title", "subject"], suffix=".emb.h5")
    n = length(files)
    for (i, filename) in enumerate(files)
        outname = replace(filename, ".json" => "") * suffix
        isfile(outname) && continue
        @info "processing $filename => $outname ($i of $n)"
        keylist, emb = create_embedding(filename; keys)
        if length(keylist) == 0
            @warn "$filename has no registers to encode"
            continue
        end

        h5open(outname, "w") do f
            f["keys"] = json(keylist)
            f["emb"] = emb
        end
    end
end
