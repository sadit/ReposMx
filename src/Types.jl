module Types

export Record, RepoInfo, SearchHit, SearchResponse, AuthorProfile, ParagraphHit, ReferenceRecord

"""
    Record

Represents a single document record in an institutional repository.
"""
struct Record
    id::String
    repo::String
    xml::String
    file::Union{String, Nothing}
    status::String
    title::String
    creator::String
    contributor::String
    date::String
    description::String
    subject::String
    type::String
    text::Union{String, Nothing}
end

function Record(;
    id::String,
    repo::String,
    xml::String="",
    file::Union{String, Nothing}=nothing,
    status::String="",
    title::String="",
    creator::String="",
    contributor::String="",
    date::String="",
    description::String="",
    subject::String="",
    type::String="",
    text::Union{String, Nothing}=nothing
)
    Record(id, repo, xml, file, status, title, creator, contributor, date, description, subject, type, text)
end

"""
    RepoInfo

Metadata and harvesting statistics for an institutional repository.
"""
struct RepoInfo
    repo::String
    url::String
    total_records::Int
    last_harvest::Union{String, Nothing}
    last_update::Union{String, Nothing}
end

"""
    AuthorProfile

An author or contributor profile with publication statistics and coauthors.
"""
struct AuthorProfile
    name::String
    role::String
    doc_count::Int
    doc_ids::Vector{String}
    repos::Vector{String}
    keywords::Vector{String}
end

"""
    ReferenceRecord

A single bibliographic citation / reference extracted from a document's full text.
Fully traceable to its source document and repository.
"""
struct ReferenceRecord
    ref_id::String
    doc_id::String
    doc_title::String
    repo::String
    ref_num::Int
    text::String
    year::String
    authors::Vector{String}
end

"""
    SearchHit

A single search result item with score, metadata, and tags.
"""
struct SearchHit
    id::String
    repo::String
    title::String
    creator::String
    contributor::String
    date::String
    description::String
    keywords::Vector{String}
    type::String
    score::Float32
    file::Union{String, Nothing}
    snippet::String
    has_fulltext::Bool
    reference_count::Int
end

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

"""
    SearchResponse

Search response container.
"""
struct SearchResponse
    query::String
    mode::Symbol
    total_hits::Int
    hits::Vector{SearchHit}
    time_ms::Float64
end

end # module Types
