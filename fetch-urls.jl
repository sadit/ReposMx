using JSON, Downloads, URIs, Glob

function get_url_manuscript(data::IO, urlbase)
    for f in eachline(data)
        m = match(r"""href="([^"]*)"?[\\s>]"""imx, f)
        if m !== nothing
            url = first(m.captures)
            if endswith(url, "pdf")
                if !startswith(url, "http")
                    @info "====="
                    @info urlbase
                    @info url
                    url = join((urlbase, url), "/")
                end

                return url
            end
        end
    end
end

function main(repolist; timeout=1.1)
    Threads.@threads for i in eachindex(repolist)
        filename = repolist[i]
        filenameurls = filename * "+urls"
        isfile(filenameurls) && continue
        @info filename
        repopath = replace(basename(filename), ".json" => "")
        repopath = joinpath("repositorios", repopath)
        D = []
        for (lineno, line) in enumerate(eachline(filename))
            p = JSON.parse(line)
            push!(D, p)
            id = get(p, "identifier", nothing)
            if id === nothing
                @info "WARN: $filename identifier was not found -- line $lineno"
            else
                url = last(id)
                data = try
                    output = IOBuffer()
                    Downloads.download(url, output; timeout)
                    seekstart(output)
                catch e
                    @info "ERROR while downloading $url -- line $lineno"
                    @info p
                    continue
                end

                #if startswith(url, "http")
                urlbase = replace(url, r"(\w)/\w.+" => s"\1")
                urlpaper = get_url_manuscript(data, urlbase)
                path = let path = join((repopath, parse(URI, url).path), "/")
                    mkpath(path)
                    joinpath(path, "file.pdf")
                end

                if urlpaper !== nothing
                    p["url"] = [urlpaper]
                    p["file"] = [path]
                    if !isfile(path)
                        @info "urls $urlpaper -> $path"
                        try
                            Downloads.download(urlpaper, path)
                        catch e
                            @info "ERROR while downloading manuscript url=$urlpaper path=$path" e
                        end
                    end
                end
            end 
        end
        
        open(filenameurls, "w") do f
            for p in D
                println(f, json(p))
            end
        end
    end
end

main(glob("repositorios/metadata-2024-05-29/*.json") |> reverse)
