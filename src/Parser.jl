module Parser

using PDFIO
using ..Storage: get_repo_dir, list_repo_names

export extract_text_from_file, parse_repository_documents, parse_all_documents

"""
    parse_pdf_fallback(src; max_pages=100)

Extracts text using PDFIO.jl as a pure Julia fallback.
"""
function parse_pdf_fallback(src::AbstractString; max_pages::Int=100)
    doc = pdDocOpen(src)
    n = min(pdDocGetPageCount(doc), max_pages)
    out = IOBuffer()
    for i in 1:n
        page = pdDocGetPage(doc, i)
        pdPageExtractText(out, page)
    end
    pdDocClose(doc)
    return String(take!(out))
end

"""
    extract_text_from_file(filepath; max_pages=200)

Extracts plain text from PDF, DOCX, DOC, HTML or TXT.
Tries fast system utilities (pdftotext, pandoc) with Julia fallback.
"""
function extract_text_from_file(filepath::AbstractString; max_pages::Int=200)
    isfile(filepath) || return ""
    _, ext = splitext(filepath)
    ext_l = lowercase(ext)
    
    if ext_l == ".txt"
        return try read(filepath, String) catch; "" end
    elseif ext_l == ".pdf"
        # 1. Try pdftotext
        try
            return read(`pdftotext -l $max_pages $filepath -`, String)
        catch
        end
        # 2. Try PDFIO fallback
        try
            return parse_pdf_fallback(filepath; max_pages)
        catch
        end
        return ""
    elseif ext_l in (".doc", ".docx", ".odt", ".html", ".htm", ".epub")
        # Try pandoc
        try
            return read(`pandoc -t plain -o - $filepath`, String)
        catch
            return ""
        end
    else
        return ""
    end
end

"""
    parse_repository_documents(reponame; data_dir=DEFAULT_DATA_DIR)

Parses all downloaded documents in `data/repos/<repo>/files/` and writes extracted text to `data/repos/<repo>/text/<hash>.txt`.
"""
function parse_repository_documents(reponame::AbstractString; data_dir=DEFAULT_DATA_DIR)
    rdir = get_repo_dir(reponame; data_dir)
    files_dir = joinpath(rdir, "files")
    text_dir = joinpath(rdir, "text")
    
    isdir(files_dir) || return 0
    mkpath(text_dir)
    
    files = readdir(files_dir; join=true)
    parsed_count = 0
    
    for f in files
        base, _ = splitext(basename(f))
        out_txt = joinpath(text_dir, "$base.txt")
        if isfile(out_txt) && filesize(out_txt) > 0
            continue
        end
        
        txt = extract_text_from_file(f)
        if !isempty(strip(txt))
            open(out_txt, "w") do out
                write(out, txt)
            end
            parsed_count += 1
        end
    end
    
    println("[$reponame] Extracted text from $parsed_count documents.")
    return parsed_count
end

"""
    parse_all_documents(; data_dir=DEFAULT_DATA_DIR, repos=nothing)

Runs text extraction across all repositories in parallel.
"""
function parse_all_documents(; data_dir=DEFAULT_DATA_DIR, repos=nothing)
    from_repos = repos !== nothing ? repos : list_repo_names(; data_dir)
    println("Starting document text extraction for $(length(from_repos)) repositories...")
    
    Threads.@threads for i in eachindex(from_repos)
        r = from_repos[i]
        try
            parse_repository_documents(r; data_dir)
        catch e
            println(stderr, "[$r] Error extracting text: $e")
        end
    end
end

end # module Parser
