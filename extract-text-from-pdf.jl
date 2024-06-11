using PDFIO, Glob, JSON

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


function main(; repolist = glob("repositorios/metadata-2024-05-29/*.json+urls"))
    for filename in repolist
        @info "REPO $filename"

        P = JSON.parse.(eachline(filename))
        Threads.@threads for i in eachindex(P)
            p = P[i]
            f = get(p, "file", nothing)
            if f !== nothing
                outname = replace(f, r".pdf" => "") * ".txt"
                isfile(outname) && continue
                @info "converting $f to $outname" 
                
                D = try
                    parse_pdf(f)
                catch err
                    err isa InterruptException && rethrow()
                    @info "ERROR while parsing PDF file $f"
                    @info err
                    continue
                end

                open(outname, "w") do out
                    write(out, D["text"])
                end
            end
        end
    end
end
