"""
    get_text_and_meta_from_pdf(inputfile; npages=0) 

- `inputfile` Input PDF file path from where text is to be extracted

- `npages` the number of pages to parse; if `npages=0` then it will retrieve all pages

returns a medata dictionary with a "text" entry containing the entire text of this document in convenient blocks of text
"""
function get_text_and_meta(src; npages)
    # handle that can be used for subsequence operations on the document.
    doc = pdDocOpen(src)
    
    # Metadata extracted from the PDF document. 
    # This value is retained and returned as the return from the function. 
    data = pdDocGetInfo(doc)
    
    # Returns number of pages in the document       

    npages = min(npages, pdDocGetPageCount(doc))
    data["npages"] = npages

    out = IOBuffer()
    data["text"] = textlist = String[]

    for i in 1:npages
        # handle to the specific page given the number index. 
        page = pdDocGetPage(doc, i)
        
        # Extract text from the page and write it to the output file.
        pdPageExtractText(out, page)
        append!(textlist, String(take!(out)))
    end

    # Close the document handle. 
    pdDocClose(doc)
    data
end
