using EzXML, Downloads, JSON, Glob



const NS = ["oai" => "http://www.openarchives.org/OAI/2.0/", 
            "dc" => "http://www.openarchives.org/OAI/2.0/oai_dc/",
            "purl" => "http://purl.org/dc/elements/1.1/"
           ]

function create_json_repo(filename;
        outname = replace(filename, r".xml" => "") * ".json"
    )
    println(stderr, "converting $filename to $outname")
    f = readxml(filename)
    D = []
    for e in findall("//oai:record", root(f), NS)
        #@info e
        identifier = findfirst(".//oai:identifier", e, NS) 
        datestamp = findfirst(".//oai:datestamp", e, NS)
        metadata = e # findfirst(".//oai:metadata", e, NS)
        identifier = identifier === nothing ? nothing : nodecontent(identifier)
        datestamp = datestamp === nothing ? nothing : nodecontent(datestamp)
        E = Dict{String, Any}("id" => identifier, "datestamp" => datestamp)
        push!(D, E)

        for el in findall(".//purl:*", metadata, NS)
            k = el.name
            v = get(E, k, nothing)

            if v === nothing
                E[k] = [nodecontent(el)]
            else
                push!(v, nodecontent(el))
            end

        end
    end

    open(outname, "w") do out
        for d in D
            println(out, json(d))
        end
    end
end


for filename in glob("repositorios/metadata-2024-05-29/*.xml")
    create_json_repo(filename)
end
