using JSON, Downloads, URIs, Glob, LMDB, Random, EzXML, SHA

const NS = ["oai" => "http://www.openarchives.org/OAI/2.0/", 
            "dc" => "http://www.openarchives.org/OAI/2.0/oai_dc/",
            "purl" => "http://purl.org/dc/elements/1.1/"
           ]

getlast(d::AbstractString) = d
getlast(d::AbstractVector) = last(d)

HEADERS = Dict("User-Agent" => "Mozilla/5.0 (compatible, MSIE 11, Windows NT 6.3; Trident/7.0; rv:11.0) like Gecko")

function parse_url_ext(line, valid_extensions)
    m = match(r"""href="([^"'\?]+)"""imx, line)
    m === nothing && return (nothing, nothing)
    url = String(m.captures[1]) # regex can return SubString and Curl could fail
    _, ext = splitext(url)
    lowercase(ext) in valid_extensions || return (nothing, nothing)
    match(r"aviso.+privacidad"i, url) !== nothing && return (nothing, nothing)
    match(r"licencia.{3,10}$"i, url) !== nothing && return (nothing, nothing)
    match(r"licencia.*uso"i, url) !== nothing && return (nothing, nothing)
    url, ext
end


function get_url(identifier, reponame, db, key; timeout::Float64, valid_extensions)
    # @info id, identifier, reponame
    if reponame == "uanl"
        _, ext = splitext(identifier)
        lowercase(ext) in valid_extensions || return nothing
        return identifier
    end

    url = identifier
    println(stderr, "LOOKING for paper's link in $url")
    output = IOBuffer()
    res = request(url; output, timeout, throw=false, headers=HEADERS)
    seekstart(output)
    if res isa Response && 200 <= res.status < 300
        urlbase = replace(url, r"(\w)/\w.+" => s"\1")
        return get_url_manuscript(output, urlbase; timeout, valid_extensions)
    end
    #if startswith(url, "http")
    println(stderr, "ERROR while downloading url=$url -- reponame=$reponame -- get_url")
    println(stderr, res)
    db[key] = json(res)
    return nothing
end

function get_url_manuscript(data::IO, urlbase; timeout::Float64, valid_extensions)
    # @info data
    for line in eachline(data)
        #m = match(r"""href="([^"']*)?(txt|pdf|doc|docx|ppt|pptx|xlsx|xls|odt|zip|gz|tar)\?[^"']*["'][\s>]"""imx, line)
        url, ext = parse_url_ext(line, valid_extensions)
        url === nothing && continue
        #@info url, ext

        if !startswith(url, "http")
            println(stderr, "===== $urlbase -- $url")
            url = join((urlbase, url), "/")
        end

        return url
    end

    nothing
end

function must_download(db, status_key, xml_key)
    status = get(db, status_key, "")
    length(status) == 0 && return true 
    status = if status[1] != '{'
        status = Dict("status" => 200, "url" => status)
        db[status_key] = json(status)
        status
    else
        JSON.parse(status)
    end

    s = get(status, "status", 0)
    if s == 0
        # possible some error while downloading
        return true
    elseif 200 <= s < 300
        # OK downloded
        isfile(get(db, string(xml_key, "/file"), "")) || return true
        return false
    elseif 400 <= s < 500 # some error in the client request
        if !(s ∈ (410, 404))
            print(stderr, "status $status_key has an status code of $s; ignoring but it should be inspected")
            @info :STATUS => status
            return false
        end

        return true
    else # z >= 500 # server error; retrying
        return true
    end
end

function main(repolist;
        timeout=60.0*6,
        env="repositorios/xmeta.lmdb",
        repofiles="repositorios/files", 
        valid_extensions = Set(split(".txt .pdf .doc .docx .ppt .pptx .xlsx .xls .odt .zip .gz .tar", ' '))
    )
    db = LMDBDict{String,String}(env)
    db.env[:MapSize] = 2^32-1
    K = keys(db; prefix="status/")
    shuffle!(K)
    @info "FOUND $(length(K)) entries"
    iolock = Threads.SpinLock()
    iolock0 = Threads.SpinLock()

    Threads.@threads for i in eachindex(K)
        status_key = K[i]
        match(r"(udlap|umich)", status_key) === nothing && continue
        #=occursin("tecnm", status_key) || continue
        occursin("unam-educacion", status_key) || continue
        occursin("colef", status_key) || continue
        occursin("uady", status_key) || continue
        occursin("uam-cuaji", status_key) || continue
        =#
        # occursin("ciesas", k1) || continue
        _, reponame, id = split(status_key, '/'; limit=3)
        repopath = joinpath(repofiles, reponame)
        lock(iolock) do
            mkpath(repopath)
        end
       

        xml_key = string("meta/", id)
        @info xml_key
        must_download(db, status_key, xml_key) || continue
        xml = db[xml_key]
        L = parsexml(xml)
        identifier = nothing
        for n in findall("//purl:identifier", root(L), NS)
            c = nodecontent(n)
            if startswith(c, "http")
                identifier = c
            end
        end
        identifier === nothing && continue
        urlpaper = get_url(identifier, reponame, db, status_key; timeout, valid_extensions)
        urlpaper === nothing && continue
        # @info :URL_PAPER => urlpaper
        path = let path = bytes2hex(sha256(xml))
            _, ext = splitext(parse(URI, urlpaper).path)
            joinpath(repopath, path * ext)
        end
        isfile(path) && continue

        println(stderr, "DOWNLOAD $urlpaper -> $path")
        output = IOBuffer()
        res = request(urlpaper; timeout, output, throw=false, headers=HEADERS)
        db[status_key] = json(res)
        if res isa RequestError || !(200 <= res.status < 300)
            println(stderr, "ERROR while downloading manuscript url=$urlpaper path=$path\n", res)
            continue
        end

        lock(iolock0) do
            open(path, "w") do f
                write(f, take!(output))
            end
        end
        db[string(xml_key, "/file")] = path
    end
end

include("repos.jl")
main(repolist)
