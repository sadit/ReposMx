using JSON, Downloads, URIs, Glob, LMDB, Random

getlast(d::AbstractString) = d
getlast(d::AbstractVector) = last(d)

function get_url(identifier, reponame; timeout::Float64, valid_extensions)
    # @info id, identifier, reponame
    if reponame == "uanl"
        if match(r".(txt|pdf|doc|docx|ppt|pptx|xlsx|xls|odt|zip|gz|tar)$"imx, identifier) === nothing
            return nothing
        else
            return identifier
        end
    end

    url = identifier
    println(stderr, "LOOKING for paper's link in $url")
    output = IOBuffer()
    res = Downloads.request(url; output, timeout, throw=false)
    seekstart(output)
    if res isa Response && 200 <= res.status < 300
        urlbase = replace(url, r"(\w)/\w.+" => s"\1")
        return get_url_manuscript(output, urlbase; timeout, valid_extensions)
    end

    #if startswith(url, "http")
    println(stderr, "ERROR while downloading url=$url -- reponame=$reponame -- get_url")
    return nothing
end

function get_url_manuscript(data::IO, urlbase; timeout::Float64, valid_extensions)
    # @info data
    for line in eachline(data)
        #m = match(r"""href="([^"']*)?(txt|pdf|doc|docx|ppt|pptx|xlsx|xls|odt|zip|gz|tar)\?[^"']*["'][\s>]"""imx, line)
        m = match(r"""href="([^"'\?]+)"""imx, line)
        #println(line)
        #println(m)

        m === nothing && continue
        url = String(m.captures[1]) # regex can return SubString and Curl could fail
        _, ext = splitext(url)
        lowercase(ext) in valid_extensions || continue
        match(r"aviso.+privacidad"i, url) !== nothing && continue
        #@info url, ext

        if !startswith(url, "http")
            println(stderr, "===== $urlbase -- $url")
            url = join((urlbase, url), "/")
        end

        return url 
    end

    nothing
end

function main(repolist; timeout=60.0*6, env="repositorios/meta.lmdb", repofiles="repositorios/files")
    db = LMDBDict{String,String}(env)
    db.env[:MapSize] = 2^32-1
    valid_extensions = Set(split(".txt .pdf .doc .docx .ppt .pptx .xlsx .xls .odt .zip .gz .tar", ' '))
    K = keys(db; prefix="queue/")
    shuffle!(K)
    @info "FOUND $(length(K)) unprocessed entries"
    iolock = Threads.SpinLock()
    iolock0 = Threads.SpinLock()

    Threads.@threads for i in eachindex(K)
        k1 = K[i]
        # occursin("ciesas", k1) || continue
        reponame = get(db, k1, nothing)
        repopath = joinpath(repofiles, reponame)
        lock(iolock) do
            mkpath(repopath)
        end
        k = string("meta/", replace(k1, r"^queue/" => ""))
        identifier_key = keys(db; prefix=string(k, "/identifier"))
        if length(identifier_key) == 0
            println(stderr, "WARN key $k/identifier is missing")
            continue
        end
        id = get(db, string(k, "/id"), nothing)
        identifier = nothing
        for ik in identifier_key
            x = db[ik]
            if startswith(x, "http")
                identifier = x
            end
        end
        identifier === nothing && continue
        urlpaper = get_url(identifier, reponame; timeout, valid_extensions) 
        urlpaper === nothing && continue
        # @info :URL_PAPER => urlpaper 
        path = let path = parse(URI, urlpaper).path
            path = replace(path, "/" => "__") |> lowercase
            length(path) > 128 && (path = string(hash(path), path[end-32:end]))
            joinpath(repopath, path)
        end
        isfile(path) && continue
    
        println(stderr, "DOWNLOAD $urlpaper -> $path")
        output = IOBuffer()
        res = Downloads.request(urlpaper; timeout, output, throw=false)
        db[string(k, "/url")] = json(res)
        if res isa RequestError || !(200 <= res.status < 300)
            println(stderr, "ERROR while downloading manuscript url=$urlpaper path=$path\n", res)
            continue
        end
        
        lock(iolock0) do
            open(path, "w") do f
                write(f, take!(output))
            end
        end
        db[string(k, "/file")] = path
        delete!(db, k1)
    end
end

include("repos.jl")
main(repolist)
