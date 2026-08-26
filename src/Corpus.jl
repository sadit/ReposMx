module Corpus

using EzXML, JSON
using ..Config: DEFAULT_DATA_DIR, DEFAULT_OAI_NS
using ..Types: ReferenceRecord
using ..Storage: get_repo_dir, load_metadata_records, save_corpus_records, list_repo_names

export parse_xml_metadata, parse_author_names, parse_keywords, normalize_doc_type,
       extract_conclusions, extract_reference_section, parse_individual_references,
       extract_document_references, split_into_paragraphs,
       build_repository_corpus, build_all_corpus, build_authors_index_data, build_references_index_data

const DC_KEYS = ["title", "creator", "contributor", "date", "description", "subject", "language", "rights", "publisher", "type"]
const DC_QUERIES = ["//$k" for k in DC_KEYS]

"""
    parse_author_names(author_str::AbstractString)

Splits and cleans authors or contributors separated by ';' or commas.
"""
function parse_author_names(author_str::AbstractString)
    isempty(strip(author_str)) && return String[]
    parts = split(author_str, r"[;\n\|]")
    names = String[]
    for p in parts
        clean = strip(p)
        isempty(clean) && continue
        length(clean) < 3 && continue
        clean = replace(clean, r"^(Dr\.|Dra\.|Mtro\.|Mtra\.|Lic\.|Ing\.|Director(a)?:|Asesor(a)?:)\s*"i => "")
        clean = strip(clean)
        !isempty(clean) && push!(names, clean)
    end
    return unique(names)
end

"""
    parse_keywords(subject_str::AbstractString)

Extracts individual keywords, topics and disciplines from the Dublin Core subject string.
"""
function parse_keywords(subject_str::AbstractString)
    isempty(strip(subject_str)) && return String[]
    parts = split(subject_str, r"[;\n\|/,]")
    keywords = String[]
    for p in parts
        clean = strip(p)
        isempty(clean) && continue
        length(clean) < 2 && continue
        push!(keywords, clean)
    end
    return unique(keywords)
end

"""
    normalize_doc_type(type_str::AbstractString)

Categorizes publication type: Tesis, Artículo, Libro, Capítulo, Reporte, Otro.
"""
function normalize_doc_type(type_str::AbstractString)
    t = lowercase(type_str)
    if occursin(r"tesis|thesis|dissertation|grado|maestr|doctor"i, t)
        return "Tesis"
    elseif occursin(r"art[ií]culo|article|journal|paper|revista"i, t)
        return "Artículo"
    elseif occursin(r"libro|book|monograph"i, t)
        return "Libro"
    elseif occursin(r"cap[ií]tulo|chapter|secci[oó]n"i, t)
        return "Capítulo de Libro"
    elseif occursin(r"reporte|informe|technical report"i, t)
        return "Reporte Técnico"
    elseif occursin(r"conferencia|conference|proceedings|ponencia|memorias"i, t)
        return "Conferencia / Ponencia"
    else
        return "Documento Académico"
    end
end

"""
    extract_conclusions(fulltext::AbstractString)

Heuristically extracts the conclusions / discussion section from the full manuscript text.
"""
function extract_conclusions(fulltext::AbstractString)
    isempty(strip(fulltext)) && return ""
    m = match(r"(?i)\n(?:[0-9IVX\.\s]{0,6})?(conclusi(?:ones|ón)|concluding remarks|conclusions|discusión y conclusiones|conclusiones y recomendaciones)[\s:\.]*\n+(.+?)(?:\n+(?:[0-9IVX\.\s]{0,6})?(?:referencias|bibliograf[ií]a|agradecimientos|anexos|ap[eé]ndice|references|bibliography)|\Z)"s, fulltext)
    if m !== nothing
        extracted = strip(m.captures[2])
        return first(extracted, min(3500, length(extracted)))
    end
    return ""
end

"""
    extract_reference_section(fulltext::AbstractString)

Locates and extracts the raw bibliography / references section from the manuscript.
"""
function extract_reference_section(fulltext::AbstractString)
    isempty(strip(fulltext)) && return ""
    m = match(r"(?i)\n(?:\d+\.|\b[IVXLCDM]+\b\.?)?\s*(referencias(?:\s+bibliogr[aá]ficas)?|bibliograf[ií]a|references|bibliography|fuentes\s+consultadas)[\s:\.]*\n+(.+?)(?:\n+(?:\d+\.|\b[IVXLCDM]+\b\.?)?\s*(?:anexos|ap[eé]ndice|appendix|ap[eé]ndices)\b|\Z)"s, fulltext)
    if m !== nothing
        return strip(m.captures[2])
    end
    return ""
end

"""
    parse_individual_references(ref_block::AbstractString)

Parses individual bibliographic citations from a reference text block.
"""
function parse_individual_references(ref_block::AbstractString)
    isempty(strip(ref_block)) && return String[]
    
    # Split by numbered prefixes ([1], 1., etc.) or blank lines
    raw_entries = split(ref_block, r"\n\s*(?:\[\d+\]|\d+\.|\n)")
    clean_entries = String[]
    
    for r in raw_entries
        clean = strip(replace(r, r"\s+" => " "))
        # Remove stray leading brackets or numbers
        clean = replace(clean, r"^(\[\d+\]|\d+\.|\-)\s*" => "")
        # Valid references generally have at least 25 characters
        if length(clean) >= 25 && !occursin(r"^(página\s+\d+|page\s+\d+)$"i, clean)
            push!(clean_entries, clean)
        end
    end
    
    return clean_entries
end

"""
    extract_document_references(doc_id::AbstractString, repo::AbstractString, doc_title::AbstractString, fulltext::AbstractString)

Extracts structured ReferenceRecords with full traceability to source doc and repository.
"""
function extract_document_references(doc_id::AbstractString, repo::AbstractString, doc_title::AbstractString, fulltext::AbstractString)
    ref_block = extract_reference_section(fulltext)
    isempty(ref_block) && return Dict{String, Any}[]
    
    raw_citations = parse_individual_references(ref_block)
    citations = Dict{String, Any}[]
    
    for (i, cit) in enumerate(raw_citations)
        # Heuristically extract year (e.g. (2018) or 2018.)
        year_match = match(r"\b(19\d{2}|20[0-2]\d)\b", cit)
        inferred_year = year_match !== nothing ? year_match.match : ""
        
        # Inferred authors (first token up to year or parenthesis)
        author_part = first(split(cit, r"\(\d{4}\)|\b\d{4}\b"), 1)[1]
        inferred_authors = parse_author_names(author_part)
        
        ref_id = "$repo:$doc_id#$i"
        
        push!(citations, Dict{String, Any}(
            "ref_id" => ref_id,
            "doc_id" => doc_id,
            "doc_title" => doc_title,
            "repo" => repo,
            "ref_num" => i,
            "text" => cit,
            "year" => inferred_year,
            "authors" => inferred_authors
        ))
    end
    
    return citations
end

"""
    split_into_paragraphs(fulltext::AbstractString; min_len=80, max_len=1500)

Splits a long manuscript text into clean, structured paragraphs for in-depth document search.
"""
function split_into_paragraphs(fulltext::AbstractString; min_len::Int=80, max_len::Int=1500)
    isempty(strip(fulltext)) && return String[]
    
    raw_blocks = split(fulltext, r"\n\s*\n+|\f+")
    paragraphs = String[]
    curr = IOBuffer()
    
    for block in raw_blocks
        clean_block = strip(replace(block, r"\s+" => " "))
        isempty(clean_block) && continue
        
        if occursin(r"^(\d+|página\s+\d+|page\s+\d+)$"i, clean_block)
            continue
        end
        
        if (position(curr) + length(clean_block)) < max_len
            print(curr, clean_block, " ")
        else
            text_p = strip(String(take!(curr)))
            if length(text_p) >= min_len
                push!(paragraphs, text_p)
            end
            print(curr, clean_block, " ")
        end
    end
    
    final_p = strip(String(take!(curr)))
    if length(final_p) >= min_len
        push!(paragraphs, final_p)
    end
    
    return paragraphs
end

"""
    parse_xml_metadata(xml_str)

Parses Dublin Core metadata fields from a raw OAI XML record string.
"""
function parse_xml_metadata(xml_str::AbstractString)
    result = Dict{String, String}()
    isempty(xml_str) && return result
    
    cleaned = replace(xml_str, r"\s?(xmlns|xsi):.*?>" => ">")
    cleaned = replace(cleaned, r"<(/?)(\w+):(\w+)(/?[>\s])" => s"<\1\3\4")
    
    doc = try
        parsexml(cleaned)
    catch
        return result
    end
    
    for (key, query) in zip(DC_KEYS, DC_QUERIES)
        values = String[]
        for node in findall(query, root(doc))
            push!(values, strip(nodecontent(node)))
        end
        result[key] = join(filter(!isempty, values), " ; ")
    end
    
    return result
end

"""
    build_repository_corpus(reponame; data_dir=DEFAULT_DATA_DIR, include_fulltext=true)

Unifies metadata records with extracted keywords, document types, extracted conclusions, and bibliographic citations into `corpus.jsonl`.
"""
function build_repository_corpus(reponame::AbstractString; data_dir=DEFAULT_DATA_DIR, include_fulltext::Bool=true)
    rdir = get_repo_dir(reponame; data_dir)
    records = load_metadata_records(reponame; data_dir)
    isempty(records) && return 0
    
    text_dir = joinpath(rdir, "text")
    corpus_records = Dict{String, Any}[]
    
    for r in records
        id = get(r, "id", "")
        xml = get(r, "xml", "")
        file = get(r, "file", nothing)
        
        meta = parse_xml_metadata(xml)
        
        title_str = get(meta, "title", "")
        creator_raw = get(meta, "creator", "")
        contrib_raw = get(meta, "contributor", "")
        subj_raw = get(meta, "subject", "")
        type_raw = get(meta, "type", "")
        desc_raw = get(meta, "description", "")
        
        creators = parse_author_names(creator_raw)
        contributors = parse_author_names(contrib_raw)
        keywords = parse_keywords(subj_raw)
        doc_type = normalize_doc_type(type_raw)
        
        conclusions = ""
        references = Dict{String, Any}[]
        fulltext_path = nothing
        has_text = false
        
        if include_fulltext
            txt_path = nothing
            if file !== nothing
                base, _ = splitext(basename(file))
                candidate = joinpath(text_dir, "$base.txt")
                if isfile(candidate)
                    txt_path = candidate
                end
            end
            if txt_path === nothing && !isempty(xml)
                file_hash = bytes2hex(sha256(xml))
                candidate = joinpath(text_dir, "$file_hash.txt")
                if isfile(candidate)
                    txt_path = candidate
                end
            end
            
            if txt_path !== nothing && isfile(txt_path)
                fulltext_path = txt_path
                txt = try read(txt_path, String) catch; "" end
                if !isempty(strip(txt))
                    has_text = true
                    conclusions = extract_conclusions(txt)
                    references = extract_document_references(id, reponame, title_str, txt)
                end
            end
        end
        
        doc = Dict{String, Any}(
            "id" => id,
            "repo" => reponame,
            "title" => title_str,
            "creator" => creator_raw,
            "creators" => creators,
            "contributor" => contrib_raw,
            "contributors" => contributors,
            "date" => get(meta, "date", ""),
            "description" => desc_raw,
            "subject" => subj_raw,
            "keywords" => keywords,
            "language" => get(meta, "language", ""),
            "publisher" => get(meta, "publisher", ""),
            "type" => doc_type,
            "conclusions" => conclusions,
            "references" => references,
            "reference_count" => length(references),
            "file" => file,
            "fulltext_file" => fulltext_path,
            "has_fulltext" => has_text
        )
        push!(corpus_records, doc)
    end
    
    save_corpus_records(reponame, corpus_records; data_dir)
    println("[$reponame] Built corpus with $(length(corpus_records)) documents.")
    return length(corpus_records)
end

"""
    build_all_corpus(; data_dir=DEFAULT_DATA_DIR, repos=nothing, include_fulltext=true)

Builds `corpus.jsonl` for all repositories.
"""
function build_all_corpus(; data_dir=DEFAULT_DATA_DIR, repos=nothing, include_fulltext::Bool=true)
    from_repos = repos !== nothing ? repos : list_repo_names(; data_dir)
    println("Building structured corpus for $(length(from_repos)) repositories...")
    
    Threads.@threads for i in eachindex(from_repos)
        r = from_repos[i]
        try
            build_repository_corpus(r; data_dir, include_fulltext)
        catch e
            println(stderr, "[$r] Error building corpus: $e")
        end
    end
end

"""
    build_authors_index_data(all_docs::Vector{Dict{String, Any}})

Extracts author and contributor profiles from all structured corpus documents, including their topic profile and cited references.
"""
function build_authors_index_data(all_docs::Vector{Dict{String, Any}})
    author_map = Dict{String, Dict{String, Any}}()
    
    for doc in all_docs
        doc_id = get(doc, "id", "")
        repo = get(doc, "repo", "")
        doc_title = get(doc, "title", "")
        doc_desc = get(doc, "description", "")
        doc_keywords = get(doc, "keywords", String[])
        creators = get(doc, "creators", String[])
        contributors = get(doc, "contributors", String[])
        refs = get(doc, "references", Dict{String, Any}[])
        ref_texts = [get(r, "text", "") for r in refs]
        
        doc_summary = "$doc_title . $(join(doc_keywords, " , ")) . $doc_desc"
        
        for c in creators
            entry = get!(author_map, c, Dict{String, Any}(
                "name" => c,
                "role" => "Autor",
                "doc_count" => 0,
                "doc_ids" => String[],
                "repos" => Set{String}(),
                "coauthors" => Set{String}(),
                "keywords" => Set{String}(),
                "topic_texts" => String[],
                "cited_references" => String[]
            ))
            entry["doc_count"] += 1
            push!(entry["doc_ids"], doc_id)
            push!(entry["repos"], repo)
            push!(entry["topic_texts"], doc_summary)
            for kw in doc_keywords; push!(entry["keywords"], kw); end
            for co in creators; co != c && push!(entry["coauthors"], co); end
            for rt in ref_texts; !isempty(rt) && push!(entry["cited_references"], rt); end
        end
        
        for c in contributors
            entry = get!(author_map, c, Dict{String, Any}(
                "name" => c,
                "role" => "Colaborador / Asesor",
                "doc_count" => 0,
                "doc_ids" => String[],
                "repos" => Set{String}(),
                "coauthors" => Set{String}(),
                "keywords" => Set{String}(),
                "topic_texts" => String[],
                "cited_references" => String[]
            ))
            entry["doc_count"] += 1
            push!(entry["doc_ids"], doc_id)
            push!(entry["repos"], repo)
            push!(entry["topic_texts"], doc_summary)
            for kw in doc_keywords; push!(entry["keywords"], kw); end
            for co in creators; push!(entry["coauthors"], co); end
            for rt in ref_texts; !isempty(rt) && push!(entry["cited_references"], rt); end
        end
    end
    
    profiles = Dict{String, Any}[]
    for (_, v) in author_map
        topic_sample = v["topic_texts"][1:min(10, length(v["topic_texts"]))]
        topic_str = join(topic_sample, " \n ")
        if length(topic_str) > 4000
            topic_str = first(topic_str, 4000)
        end
        
        all_refs = collect(Set(v["cited_references"]))
        ref_sample = all_refs[1:min(30, length(all_refs))]
        
        push!(profiles, Dict(
            "name" => v["name"],
            "role" => v["role"],
            "doc_count" => v["doc_count"],
            "doc_ids" => v["doc_ids"],
            "repos" => sort(collect(v["repos"])),
            "coauthors" => collect(v["coauthors"])[1:min(15, length(v["coauthors"]))],
            "keywords" => collect(v["keywords"])[1:min(20, length(v["keywords"]))],
            "topic_text" => topic_str,
            "cited_references" => ref_sample
        ))
    end
    
    sort!(profiles, by=x->x["doc_count"], rev=true)
    return profiles
end

"""
    build_references_index_data(all_docs::Vector{Dict{String, Any}})

Collects all references from structured documents into a unified, traceable citations corpus.
"""
function build_references_index_data(all_docs::Vector{Dict{String, Any}})
    all_refs = Dict{String, Any}[]
    for doc in all_docs
        refs = get(doc, "references", Dict{String, Any}[])
        for r in refs
            push!(all_refs, r)
        end
    end
    return all_refs
end

end # module Corpus
