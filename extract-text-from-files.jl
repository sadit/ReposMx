using PDFIO, Glob, JSON, LMDB

"""
    parse_pdf(inputfile; npages=0, password="") 

- `inputfile` Input PDF file path from where text is to be extracted

- `npages` the number of pages to parse; if `npages=0` then it will retrieve all pages

returns a medata dictionary with a "text" entry containing the entire text of this document in convenient blocks of text
"""
function parse_pdf(src; npages::Int=0, password="")
    doc = pdDocOpen(src; access=()->Base.SecretBuffer(password))
    D = Dict{String, Any}()
    D["meta"] = pdDocGetInfo(doc)
    D["npages"] = npages = npages == 0 ? pdDocGetPageCount(doc) : min(npages, pdDocGetPageCount(doc))
    out = IOBuffer()

    for i in 1:npages
        page = pdDocGetPage(doc, i) 
        pdPageExtractText(out, page)
    end
    D["text"] = String(take!(out))

    pdDocClose(doc)
    D
end

function save_text(outname, text)
    open(outname * ".tmp", "w") do out
        write(out, text)
    end
    mv(outname * ".tmp", outname)
end

function convert_pandoc_to_text(filename, outname, parsing_status)
    local text 
    try
        text = read(`pandoc -t plain -o - $filename`, String)
    catch err
        err isa InterruptException && rethrow()
        parsing_status[filename] = string(err)
    else 
        save_text(outname, text)
        @info "DONE pandoc $filename -> $outname"
        return
    end
end

function convert_pdf_to_text(filename, outname, parsing_status)
    local text 
    try
        text = read(`pdftotext $filename -`, String)
    catch err
        err isa InterruptException && rethrow()
        parsing_status[filename] = string(err)
    else 
        save_text(outname, text)
        @info "DONE pdftotext $filename -> $outname"
        return
    end

    # second try
    @info "RETRY $filename -> $outname" 
    try
        text = parse_pdf(filename)["text"]
    catch err 
        err isa InterruptException && rethrow()
        parsing_status[filename]= string(err)
    else
        save_text(outname, text)
        @info "DONE PDFIO $filename -> $outname" 
    end
end

function main(; files=readlines("files.txt"), outdir="repositorios/text")
    mkpath(outdir)
    lockio = Threads.SpinLock()
    env = "repositorios/parsing-status.lmdb"
    mkpath(env)
    parsing_status = LMDBDict{String,String}(env)

    Threads.@threads for i in eachindex(files)
        filename = files[i]
        ext = splitext(filename) |> last 
        if lowercase(ext) ∉ (".pdf", ".doc", ".docx", ".txt", ".htm", ".html")
            println(stderr, "Unknown type of file -- ext: $ext ; file: $filename")
            continue
        end
        #get(parsing_status, filename, nothing) === nothing || continue
    
        _, reponame, f = rsplit(filename, '/'; limit=3)
        outdir_ = joinpath(outdir, reponame)
        outname = joinpath(outdir_, first(splitext(f)) * ".txt")
        isfile(outname) && continue
        println(stderr, "converting $filename to $outname")
        lock(lockio) do
            mkpath(outdir_)
        end

        if ext == ".pdf"
            convert_pdf_to_text(filename, outname, parsing_status)
        elseif ext in (".doc", ".docx", ".html", ".htm")
            convert_pandoc_to_text(filename, outname, parsing_status)
        elseif ext == ".txt"
            cp(filename, outname)
        end
    end
end

