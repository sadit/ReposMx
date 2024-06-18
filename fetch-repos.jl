using Downloads, Printf, Dates, EzXML, JSON, Glob, LMDB
using Downloads: download


const NS = ["oai" => "http://www.openarchives.org/OAI/2.0/", 
            "dc" => "http://www.openarchives.org/OAI/2.0/oai_dc/",
            "purl" => "http://purl.org/dc/elements/1.1/"
           ]

function parse_xml_repo(input::IO, repourl, reponame, db; timeout)
    f = try
            readxml(input)
        catch
            print(stderr, "ERROR while reading xml $repourl")
            return
        end

    D = Dict{String,Int}()
    # println(f)
    for metadata in findall("//oai:record", root(f), NS)
        xmlentry = string(metadata)
        identifier = findfirst(".//oai:identifier", metadata, NS) 
        identifier === nothing && continue
        identifier = nodecontent(identifier)
        #datestamp = datestamp === nothing ? "" : nodecontent(datestamp)
        k_ = string("meta/", identifier)
        get(db, k_, nothing) !== nothing && continue
        db[k_] = xmlentry
        println(stderr, identifier)
        db[string("status/", reponame, "/", identifier)] = ""
    end 
    
    resumption = findfirst(".//oai:resumptionToken", root(f), NS)
    if resumption !== nothing
        resumption = nodecontent(resumption)
        fetch_repo(resumption_url(repourl, resumption), reponame, db; timeout)
    end
end

HEADERS = Dict("User-Agent" => "Mozilla/5.0 (compatible, MSIE 11, Windows NT 6.3; Trident/7.0; rv:11.0) like Gecko")
function fetch_repo(repourl, reponame, db; timeout)
    println(stderr, "FETCH: ", (reponame, repourl))
    output = IOBuffer()
    res = request(repourl; output, timeout, throw=false, headers=HEADERS)
    seekstart(output)
    
    if res isa RequestError || res.status >= 300
        println(stderr, "ERROR while downloading repository $reponame -- $repourl")
        println(stderr, res)
    else
        parse_xml_repo(output, repourl, reponame, db; timeout)
    end
end


function main(repolist; envpath="repositorios/xmeta.lmdb", interval=Day(1), timeout=360.0)
    mkpath(envpath)
    db = LMDBDict{String,String}(envpath)
    db.env[:MapSize] = 2^32-1
    
    Threads.@threads for i in eachindex(repolist)
        # for i in eachindex(repolist)
        name, url = repolist[i]
        #name != "umich" && continue
        k = "prev-harvest/$name"
        prev = get(db, k, nothing)
        if prev === nothing || DateTime(prev) + interval <= now()
            try
                fetch_repo(url, name, db; timeout)
            catch e
                println(stderr, "ERROR fetch_repo")
                println(stderr, e)
            else
                prev !== nothing && delete!(db, k)
                db[k] = string(now())
            end
        end
    end
end

repolist = open(JSON.parse, "repos.json")

main(repolist)
