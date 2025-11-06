using Downloads, Printf, Dates, EzXML, JSON, Glob, LMDB, ProgressMeter
using Downloads: download, Curl


Downloads.EASY_HOOK[] = (easy, info) -> begin
    Curl.set_ssl_verify(easy, false)
end

#=const NS = ["oai" => "http://www.openarchives.org/OAI/2.0/", 
            "dc" => "http://www.openarchives.org/OAI/2.0/oai_dc/",
            "schemaLocation" => "http://www.openarchives.org/OAI/2.0/oai_dc/ http://www.openarchives.org/OAI/2.0/oai_dc.xsd",
            "purl" => "http://purl.org/dc/elements/1.1/"
           ]=#

function opendb(; envpath="repositorios/xmeta.lmdb")
    mkpath(envpath)
    db = LMDBDict{String,String}(envpath)
    db.env[:MapSize] = 2^32-1
    db
end

function filecontent(file)
    file = let arr = splitpath(splitext(file) |> first)
        arr[2] = "text"
        arr[end] = arr[end] * ".txt"
        joinpath(arr)
    end

    if isfile()
        read(file, String)
    else
        @warn "text file $file was not found"
        nothing
    end

end

function dump_json(; envpath="repositorios/xmeta.lmdb",
        db=opendb(; envpath), savecontent=true, outdir = "data-repos-meta"
    )
    K = filter(k -> !endswith(k, "/file"), keys(db; prefix="meta"))
    S = Dict(((_, repo, key) = split(k, '/'; limit=3); key => repo)
                    for k in keys(db; prefix="status"))
    
   
    i = 0
    DATA = Dict()
    @showprogress dt=1 desc="registers" for key in K
        xmldata = get(db, key, nothing)
        xmldata === nothing && continue

        #xmldata = replace(xmldata, r"""(xmlns|xsi):[^\s>]+:"[^"]+"([\s>])""" => s"\2") 
        xmldata = replace(xmldata, r"""\s?(xmlns|xsi):.*?>""" => s">") 
        xmldata = replace(xmldata, r"<(/?)(\w+):(\w+)(/?[>\s])" => s"<\1\3\4") 
        # println(stderr, xmldata)
        doc = parsexml(xmldata)
        file = get(db, key * "/file", nothing)
        file = if file === nothing || length(file) == 0 || !savecontent
            nothing
        else
            filecontent(file)
        end
        repo = S[split(key, '/'; limit=2) |> last]
    
        # @info key => file
        D = Dict{String,Any}("key" => key, "file" => file, "repo" => repo)
        if haskey(DATA, repo)
            push!(DATA[repo], D)
        else
            DATA[repo] = [D]
        end
        queries = ["identifier", "title", "creator", "contributor", "date", "description", "subject", "language", "rights", "publisher", "type"]
        for key_ in queries
            D[key_] = d = []
            for n in findall("//" * key_, root(doc)) # NS)
                c = nodecontent(n)
                push!(d, c)
            end
            D[key_] = join(d, "\n\n")
        end
        #=rand() < 0.01 && begin
            println(stderr, "========================")
            println(stderr, key)
            println(stderr, xmldata)
            println(stderr, D)
            break
        end=#
    end
    
    mkpath(outdir)
    for (i, (repo, D)) in enumerate(DATA)
        filename = "$outdir/$repo.json"
        open(filename, "w") do f
            println(stderr, "saving $filename ($i of $(length(DATA)))")
            for d in D
                println(f, json(d))
            end
        end
    end
end


