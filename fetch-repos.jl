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
    for e in findall("//oai:record", root(f), NS)
        identifier = findfirst(".//oai:identifier", e, NS) 
        identifier === nothing && continue
        datestamp = findfirst(".//oai:datestamp", e, NS)
        metadata = e # findfirst(".//oai:metadata", e, NS)
        identifier = nodecontent(identifier)
        datestamp = datestamp === nothing ? "" : nodecontent(datestamp)

        key = string("meta/", identifier, "/id")
        get(db, key, nothing) !== nothing && continue
        println(stderr, identifier)
        db[key] = identifier
        db[string("queue/", identifier)] = reponame
        db[string("meta/", identifier, "/datestamp")] = datestamp 

        empty!(D)
        for (i, el) in enumerate(findall(".//purl:*", metadata, NS))
            k = string("meta/", identifier, "/", el.name)
            D[k] = c = get(D, k, 0) + 1
            if c > 1
                db[string(k, ":", c)] = nodecontent(el)
            else
                db[k] = nodecontent(el)
            end
        end
    end 
    
    resumption = findfirst(".//oai:resumptionToken", root(f), NS)
    if resumption !== nothing
        resumption = nodecontent(resumption)
        fetch_repo(resumption_url(repourl, resumption), reponame, db; timeout)
    end
end

function fetch_repo(repourl, reponame, db; timeout)
    println(stderr, "FETCH: ", (reponame, repourl))
    buff = try
        buff = IOBuffer()
        download(repourl, buff; timeout)
        seekstart(buff)
        buff
    catch e
        println(stderr, "ERROR while downloading repository $reponame -- $repourl")
        println(stderr, e)
        rethrow() 
    end
    
    parse_xml_repo(buff, repourl, reponame, db; timeout)
end

include("repos.jl")

function main(repolist; envpath="repositorios/meta.lmdb", interval=Day(1), timeout=360.0)
    mkpath(envpath)
    db = LMDBDict{String,String}(envpath)
    db.env[:MapSize] = 2^32-1
    
    Threads.@threads for i in eachindex(repolist)
        # for i in eachindex(repolist)
        url, name = repolist[i]
        # name != "uanl" && continue
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

main(repolist)
