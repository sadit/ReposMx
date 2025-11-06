using DataFrames, CSV, JLD2, Glob, Random

include("ollama-client.jl")

function load_repo(filename)
    [JSON3.read(line) for line in eachline(filename)]
end

function get_text(p, field)
    if field === :file
        t = p[field]
        if t === nothing
            "sin manuscrito"
        else
            arr = split(t, "\n\n")
            if length(arr) > 20
                arr = arr[[1, 2, 3, 4, 5, 6, 7, 8, end - 7, end - 6, end - 5, end - 4, end - 3, end - 2, end - 1, end]]
            else
                arr = arr[1]
            end
            join(arr, "\n\n")
        end
    else
        join(p[field], "\n\n")
    end
end

function convert_repo_file(filename, outname)
    repo = load_repo(filename)
    #repo = repo[1:200]
    keys = [p[:key] for p in repo]
    @info "loaded $(length(keys)) records from $filename"
    jldopen(outname * ".tmp", "w") do f
        f["keys"] = JSON3.write(keys)

        for field in [:title, :description] #, :file]
            @info outname => field
            text = [get_text(p, field) for p in repo]
            model, emb = embed(text)
            f["$field/model"] = model
            f["$field/emb"] = emb
        end
    end

    mv(outname * ".tmp", outname)
end

function main(; filelist=glob("Repositorios-Institucionales/data-repos-meta/*.json"))
    shuffle!(filelist)

    for filename in filelist
        outname = replace(filename, ".json" => "") * ".h5"
        if isfile(outname)
            @info "$outname already exists"
            continue
        end

        convert_repo_file(filename, outname)

        # break
    end

end

