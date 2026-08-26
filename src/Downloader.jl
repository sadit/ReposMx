module Downloader

using Downloads, EzXML, JSON, URIs, SHA, Dates
using Downloads: request, Curl
using ..Config: DEFAULT_HEADERS, DEFAULT_OAI_NS, DEFAULT_DATA_DIR
using ..Storage: get_repo_dir, load_metadata_records, save_metadata_records

export download_repository_files, download_all_files

const VALID_EXTENSIONS = Set([".pdf", ".doc", ".docx", ".ppt", ".pptx", ".txt", ".odt", ".epub"])

function parse_manuscript_url(line::AbstractString, valid_exts::Set{String})
    m = match(r"""href="([^"'\?]+)"""imx, line)
    m === nothing && return (nothing, nothing)
    url = String(m.captures[1])
    _, ext = splitext(url)
    lowercase(ext) in valid_exts || return (nothing, nothing)
    occursin(r"aviso.+privacidad"i, url) && return (nothing, nothing)
    occursin(r"licencia"i, url) && return (nothing, nothing)
    return (url, lowercase(ext))
end

function extract_document_url(landing_url::AbstractString; timeout::Float64=30.0, valid_exts=VALID_EXTENSIONS)
    output = IOBuffer()
    res = request(landing_url; output, timeout, throw=false, headers=DEFAULT_HEADERS)
    seekstart(output)
    
    if !(res isa Downloads.Response && 200 <= res.status < 300)
        return nothing
    end
    
    urlbase = replace(landing_url, r"(\w)/[^\/]+$" => s"\1")
    for line in eachline(output)
        url, ext = parse_manuscript_url(line, valid_exts)
        url === nothing && continue
        
        if !startswith(url, "http")
            url = joinpath(urlbase, lstrip(url, '/'))
        end
        return url
    end
    
    return nothing
end

"""
    download_repository_files(reponame; data_dir=DEFAULT_DATA_DIR, timeout=120.0, max_downloads=nothing)

Downloads pending PDF/document files for a repository.
"""
function download_repository_files(
    reponame::AbstractString;
    data_dir=DEFAULT_DATA_DIR,
    timeout::Float64=120.0,
    max_downloads::Union{Int, Nothing}=nothing
)
    rdir = get_repo_dir(reponame; data_dir)
    files_dir = joinpath(rdir, "files")
    mkpath(files_dir)
    
    records = load_metadata_records(reponame; data_dir)
    isempty(records) && return (0, 0)
    
    downloaded_count = 0
    modified = false
    
    println("[$reponame] Checking $(length(records)) records for downloads...")
    
    for (i, r) in enumerate(records)
        max_downloads !== nothing && downloaded_count >= max_downloads && break
        
        # Check if already downloaded
        curr_file = get(r, "file", nothing)
        if curr_file !== nothing && isfile(curr_file)
            continue
        end
        
        xml = get(r, "xml", "")
        isempty(xml) && continue
        
        doc = try
            parsexml(xml)
        catch
            continue
        end
        
        # Find identifier URL in XML
        item_url = nothing
        for n in findall("//purl:identifier", root(doc), DEFAULT_OAI_NS)
            c = nodecontent(n)
            if startswith(c, "http")
                item_url = c
                break
            end
        end
        
        item_url === nothing && continue
        
        # Check if item_url itself is a direct file
        _, ext = splitext(parse(URI, item_url).path)
        doc_url = if lowercase(ext) in VALID_EXTENSIONS
            item_url
        else
            extract_document_url(item_url; timeout)
        end
        
        doc_url === nothing && continue
        
        # Target file path with SHA256 of XML
        file_hash = bytes2hex(sha256(xml))
        _, file_ext = splitext(parse(URI, doc_url).path)
        isempty(file_ext) && (file_ext = ".pdf")
        target_path = joinpath(files_dir, "$file_hash$file_ext")
        
        if isfile(target_path)
            r["file"] = target_path
            modified = true
            continue
        end
        
        # Download document
        out_buf = IOBuffer()
        res = request(doc_url; output=out_buf, timeout, throw=false, headers=DEFAULT_HEADERS)
        
        if res isa Downloads.Response && 200 <= res.status < 300
            open(target_path, "w") do f
                write(f, take!(out_buf))
            end
            r["file"] = target_path
            r["status"] = "200"
            downloaded_count += 1
            modified = true
            println(stderr, "[$reponame] Downloaded ($downloaded_count): $doc_url -> $target_path")
        else
            r["status"] = string(res)
            modified = true
        end
    end
    
    if modified
        save_metadata_records(reponame, records; data_dir)
    end
    
    println("[$reponame] Finished downloading: $downloaded_count new files.")
    return (length(records), downloaded_count)
end

"""
    download_all_files(; data_dir=DEFAULT_DATA_DIR, repos=nothing, timeout=120.0)

Runs document downloads across all repositories in parallel.
"""
function download_all_files(;
    data_dir=DEFAULT_DATA_DIR,
    repos::Union{Vector{String}, Nothing}=nothing,
    timeout::Float64=120.0
)
    from_repos = repos !== nothing ? repos : list_repo_names(; data_dir)
    println("Starting document downloads for $(length(from_repos)) repositories...")
    
    Threads.@threads for i in eachindex(from_repos)
        r = from_repos[i]
        try
            download_repository_files(r; data_dir, timeout)
        catch e
            println(stderr, "[$r] Error downloading files: $e")
        end
    end
end

end # module Downloader
