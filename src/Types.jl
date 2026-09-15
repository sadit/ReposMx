module Types

export ParagraphHit, get_document_references

function get_document_references end

"""
    ParagraphHit

A relevant paragraph match found inside a long document.
"""
struct ParagraphHit
    paragraph_num::Int
    section::String
    text::String
    score::Float32
end

end # module Types
