module OAI

using Downloads, EzXML, JSON, URIs, Dates
using Downloads: request, Curl
using ..Config: DEFAULT_HEADERS, DEFAULT_OAI_NS, DEFAULT_DATA_DIR, get_repositories, get_repository_url
using ..Storage: get_repo_dir, get_repo_info, save_repo_info

export harvest_repository, harvest_all

Downloads.EASY_HOOK[] = (easy, info) -> begin
    Curl.set_ssl_verify(easy, false)
end

"""
    resumption_url(base_url, token)

Builds the next OAI-PMH resumption URL according to the OAI-PMH 2.0 specification.
"""
function resumption_url(base_url::AbstractString, token::AbstractString)
    base = replace(base_url, r"\?.*" => "")
    return "$base?verb=ListRecords&resumptionToken=$(URIs.escapeuri(token))"
end

"""
    harvest_repository(reponame, endpoint; data_dir=DEFAULT_DATA_DIR, from_date=nothing, timeout=180.0, max_pages=10000)

Harvests records from an OAI-PMH endpoint and writes to `data_dir/<reponame>/metadata.jsonl`.
Supports incremental harvesting if `from_date` is provided.
"""
function harvest_repository(
    reponame::AbstractString,
    endpoint::AbstractString;
    data_dir=DEFAULT_DATA_DIR,
    from_date::Union{String, Nothing}=nothing,
    timeout::Float64=180.0,
    max_pages::Int=10000
)
    rdir = get_repo_dir(reponame; data_dir)
    mkpath(rdir)
    meta_path = joinpath(rdir, "metadata.jsonl")
    
    # Load existing IDs to avoid duplicates
    existing_ids = Set{String}()
    if isfile(meta_path)
        for line in eachline(meta_path)
            isempty(strip(line)) && continue
            try
                d = JSON.parse(line)
                haskey(d, "id") && push!(existing_ids, d["id"])
            catch
            end
        end
    end
    
    # Build initial URL
    curr_url = endpoint
    if from_date !== nothing && !occursin("from=", curr_url)
        # Format date as YYYY-MM-DD
        fdate = first(from_date, min(10, length(from_date)))
        sep = occursin("?", curr_url) ? "&" : "?"
        curr_url = "$curr_url$(sep)from=$fdate"
    end
    
    page = 1
    new_records = 0
    total_processed = 0
    
    # Open file for appending
    open(meta_path, "a") do f
        while curr_url !== nothing && page <= max_pages
            println(stderr, "[$reponame] page $page: $curr_url")
            output = IOBuffer()
            res = request(curr_url; output, timeout, throw=false, headers=DEFAULT_HEADERS)
            seekstart(output)
            
            if res isa Downloads.RequestError
                println(stderr, "[$reponame] Network error on page $page: code=$(res.code) $(res.message)")
                break
            elseif res isa Downloads.Response && res.status >= 400
                println(stderr, "[$reponame] HTTP error $(res.status) on page $page")
                break
            end
            
            xml_data = String(take!(output))
            isempty(strip(xml_data)) && break
            
            doc = try
                parsexml(xml_data)
            catch e
                println(stderr, "[$reponame] XML parse error on page $page: $e")
                break
            end
            
            oai_error = findfirst("//oai:error", root(doc), DEFAULT_OAI_NS)
            if oai_error !== nothing
                code = haskey(oai_error, "code") ? oai_error["code"] : ""
                msg = nodecontent(oai_error)
                println(stderr, "[$reponame] OAI response note: code='$code' msg='$msg'")
                break
            end
            
            records = findall("//oai:record", root(doc), DEFAULT_OAI_NS)
            for metadata in records
                identifier = findfirst(".//oai:identifier", metadata, DEFAULT_OAI_NS)
                identifier === nothing && continue
                id_str = nodecontent(identifier)
                total_processed += 1
                
                if !(id_str in existing_ids)
                    push!(existing_ids, id_str)
                    xmlentry = string(metadata)
                    r = Dict(
                        "id" => id_str,
                        "xml" => xmlentry,
                        "file" => nothing,
                        "status" => ""
                    )
                    println(f, JSON.json(r))
                    new_records += 1
                end
            end
            
            resumption = findfirst(".//oai:resumptionToken", root(doc), DEFAULT_OAI_NS)
            if resumption !== nothing
                token = strip(nodecontent(resumption))
                if isempty(token)
                    curr_url = nothing
                else
                    curr_url = resumption_url(endpoint, token)
                    page += 1
                end
            else
                curr_url = nothing
            end
        end
    end
    
    # Update info.json
    info = get_repo_info(reponame; data_dir)
    info["repo"] = String(reponame)
    info["total_records"] = length(existing_ids)
    info["last_harvest"] = string(now())
    save_repo_info(reponame, info; data_dir)
    
    println(stderr, "[$reponame] Harvest complete: $total_processed seen, $new_records newly added. Total records: $(length(existing_ids))")
    return (total_processed, new_records)
end

"""
    harvest_all(; data_dir=DEFAULT_DATA_DIR, repos=nothing, incremental=true, timeout=180.0)

Harvests all configured repositories (or a selected subset).
"""
function harvest_all(;
    data_dir=DEFAULT_DATA_DIR,
    repos::Union{Vector{String}, Nothing}=nothing,
    incremental::Bool=true,
    timeout::Float64=180.0
)
    all_repos = get_repositories()
    target_repos = if repos === nothing || isempty(repos)
        collect(all_repos)
    else
        filter(p -> p.first in repos, collect(all_repos))
    end

    println("Starting harvesting for $(length(target_repos)) repositories with $(Threads.nthreads()) threads...")
    
    Threads.@threads for i in eachindex(target_repos)
        name, url = target_repos[i]
        info = get_repo_info(name; data_dir)
        from_date = incremental ? get(info, "last_harvest", nothing) : nothing
        
        try
            harvest_repository(name, url; data_dir, from_date, timeout)
        catch e
            println(stderr, "[$name] Error during harvest: $e")
        end
    end
    
    println("All harvesting tasks completed.")
end

end # module OAI
