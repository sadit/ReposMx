using JLD2, Glob, Random

include("ollama-client.jl")

function load_repo(filename)
    [JSON3.read(line) for line in eachline(filename)]
end

function convert_repo_file(filename, outname, fieldlist)
    repo = load_repo(filename)
    #repo = repo[1:200]
    keys = [p[:key] for p in repo]
    @info "loaded $(length(keys)) records from $filename"
    jldopen(outname * ".tmp", "w") do f
        f["keys"] = JSON3.write(keys)
        text = [join([p[field] for field in fieldlist], "\n\n") for p in repo]
        model, emb = embed(Float16, text)
        f["$field/model"] = model
        f["$field/emb"] = emb
    end

    mv(outname * ".tmp", outname)
end

function main(; filelist=glob("data-repos-meta/*.json"), fieldlist=[:title, :description], filesuffix="-title+description.h5")
    shuffle!(filelist)

    n = length(filelist)
    for (i, filename) in enumerate(filelist)
        outname = replace(filename, ".json" => "") * filesuffix
        @info "processing $i/$n $outname"
        if isfile(outname)
            @info "$outname already exists"
            continue
        end

        convert_repo_file(filename, outname, fieldlist)
    end

end

