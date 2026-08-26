module Wikipedia

using Downloads, JSON, URIs
using Downloads: request, Curl
using ..Config: DEFAULT_HEADERS

export get_wikipedia_summary, explain_concept, search_wikipedia_topics

"""
    get_wikipedia_summary(title::AbstractString; lang::String="es", timeout::Float64=5.0)

Fetches a concise, plain-language summary of a topic from Wikipedia in Spanish (`es`) or English (`en`).
"""
function get_wikipedia_summary(title::AbstractString; lang::String="es", timeout::Float64=5.0)
    clean_title = strip(title)
    isempty(clean_title) && return nothing
    
    encoded = URIs.escapeuri(replace(clean_title, " " => "_"))
    url = "https://$lang.wikipedia.org/api/rest_v1/page/summary/$encoded"
    
    output = IOBuffer()
    res = request(url; output, timeout, throw=false, headers=DEFAULT_HEADERS)
    
    if res isa Downloads.Response && res.status == 200
        data = try
            JSON.parse(String(take!(output)))
        catch
            return nothing
        end
        
        return Dict(
            "title" => get(data, "title", title),
            "extract" => get(data, "extract", ""),
            "description" => get(data, "description", ""),
            "url" => get(get(data, "content_urls", Dict()), "desktop", Dict()) |> d -> get(d, "page", "https://$lang.wikipedia.org/wiki/$encoded"),
            "lang" => lang,
            "thumbnail" => get(get(data, "thumbnail", Dict()), "source", nothing)
        )
    end
    
    return nothing
end

"""
    explain_concept(concept::AbstractString; timeout::Float64=5.0)

Tries to explain a concept in Spanish first; if not found or brief, checks English Wikipedia.
"""
function explain_concept(concept::AbstractString; timeout::Float64=5.0)
    # 1. Try Spanish Wikipedia
    summary_es = get_wikipedia_summary(concept; lang="es", timeout)
    if summary_es !== nothing && !isempty(get(summary_es, "extract", ""))
        return summary_es
    end
    
    # 2. Try English Wikipedia
    summary_en = get_wikipedia_summary(concept; lang="en", timeout)
    if summary_en !== nothing && !isempty(get(summary_en, "extract", ""))
        return summary_en
    end
    
    return nothing
end

"""
    search_wikipedia_topics(query::AbstractString; lang::String="es", limit::Int=3, timeout::Float64=5.0)

Searches Wikipedia for relevant topic titles related to a search query.
"""
function search_wikipedia_topics(query::AbstractString; lang::String="es", limit::Int=3, timeout::Float64=5.0)
    encoded = URIs.escapeuri(query)
    url = "https://$lang.wikipedia.org/w/api.php?action=opensearch&search=$encoded&limit=$limit&namespace=0&format=json"
    
    output = IOBuffer()
    res = request(url; output, timeout, throw=false, headers=DEFAULT_HEADERS)
    
    if res isa Downloads.Response && res.status == 200
        try
            data = JSON.parse(String(take!(output)))
            if length(data) >= 2 && data[2] isa Vector
                return String.(data[2])
            end
        catch
        end
    end
    return String[]
end

end # module Wikipedia
