"""
    Units

The texts of a document that the dense index encodes (docs/plan-rag-web.md, section 4):

- the record (`record_text`): title, authors, keywords and abstract, for every document;
- for a document with full text, its first and last parts (`fulltext_units`): the abstract and the
  introduction are at the start, the discussion and the conclusions at the end, before the
  bibliography. The bibliography itself is not encoded: `Corpus.extract_document_references`
  already takes the references out of it, and they are searched with BM25.

A part is a run of consecutive paragraphs of at most `max_chars` characters, cut at paragraph
boundaries, without overlap (as the units of the environmental RAG). A paragraph longer than
`max_chars` is cut at line boundaries, and a line longer than that is cut where it reaches the
limit.

Where the parts start and end comes from the headings of the text when they are found, and from
the position otherwise: on a sample of 3,000 documents (`experiments/rag_web/mide_secciones.jl`),
an introduction heading is found in 61 % of them, a conclusions heading in 59 %, a bibliography
heading in 64 %, and none of abstract, introduction or conclusions in 25 %.
"""
module Units

using Unicode

export SECTIONS, heading, valid_utf8, normalize_text, split_units, fulltext_units, record_text

"""
    SECTIONS

The headings that `heading` recognizes, by the section they open. The first four delimit the
parts; the bibliography marks the end of the body.
"""
const SECTIONS = [
    :abstract => r"^(resumen|abstract|summary|sintesis)$"i,
    :introduction => r"^(introduccion|introduction)( general)?$"i,
    :discussion => r"^(discusion( de (los )?resultados)?|discussion)$"i,
    :conclusions => r"^(conclusion(es)?( generales| y recomendaciones| y trabajo futuro| y perspectivas)?|discusion y conclusiones|conclusions?( and future work)?|concluding remarks|consideraciones finales|reflexiones finales)$"i,
    :bibliography => r"^(referencias( bibliograficas| citadas)?|bibliografia( citada| consultada)?|literatura citada|references|bibliography|literature cited|fuentes consultadas)$"i,
]

"""
    heading(line) -> Union{Symbol,Nothing}

The section a line opens, if it is a heading of [`SECTIONS`](@ref): a short line with optional
numbering in front (`1`, `1.2`, `IV.`, `Capítulo 3`) and nothing else but the name. A line of a
table of contents (dot leaders, or a page number after the name) is not a heading. Accents are
ignored, and so is the dotless `ı` that some PDFs write for `í` (`Capı́tulo`).
"""
function heading(line::AbstractString)
    l = strip(replace(line, r"[\t\f ]+" => " "))
    (isempty(l) || length(l) > 80) && return nothing
    _toc_like(l) && return nothing
    l = Unicode.normalize(replace(l, 'ı' => 'i'); stripmark=true)
    l = replace(l, r"^(capitulo|chapter|seccion)\s+[0-9IVXLC]+\s*[\.:\-–]?\s*"i => "")
    l = replace(l, r"^[0-9IVXLC]+(\.[0-9]+)*\s*[\.\-–:)]?\s+"i => "")
    l = replace(l, r"\s*[\.:]\s*$" => "")
    for (s, re) in SECTIONS
        occursin(re, l) && return s
    end
    return nothing
end

"""
    valid_utf8(s) -> String

`s` with each invalid UTF-8 sequence replaced by U+FFFD. Some texts extracted from PDFs have them.
"""
valid_utf8(s::AbstractString) = isvalid(s) ? String(s) : String(map(c -> isvalid(c) ? c : '\ufffd', s))

"""
    normalize_text(text) -> Vector{String}

The lines of a text extracted from a PDF, with tabs and runs of spaces collapsed, a page break
taken as a blank line, and trailing spaces removed. Blank lines are kept: they separate
paragraphs.
"""
function normalize_text(text::AbstractString)
    t = replace(valid_utf8(text), '\r' => '\n', '\f' => "\n\n")
    return [String(strip(replace(l, r"[\t ]+" => " "))) for l in split(t, '\n')]
end

# A line of a table of contents: dot leaders, or text followed by a page number.
_toc_like(l::AbstractString) = occursin(r"\.{4,}|…{2,}|(\. ){3,}|\S\s+\d{1,4}$", l)

# A heading is real when prose follows it: among the next 8 non-blank lines, at least two of 50
# characters or more without dot leaders and not starting with a section number. A heading listed
# in a table of contents is followed by more entries.
function _prose_follows(lines, i::Int)
    seen = 0
    long = 0
    for j in i+1:length(lines)
        l = lines[j]
        isempty(l) && continue
        seen += 1
        length(l) >= 50 && !occursin(r"\.{4,}|…{2,}|(\. ){3,}|^\d+(\.\d+)*\.?\s", l) && (long += 1)
        long >= 2 && return true
        seen >= 8 && break
    end
    return false
end

# Paragraphs of `lines`: runs of non-blank lines, joined with spaces. A line that ends in a hyphen
# after a letter is joined to the next without the hyphen.
function _paragraphs(lines::AbstractVector{<:AbstractString})
    pars = String[]
    buf = IOBuffer()
    flush_par() = (s = String(take!(buf)); isempty(s) || push!(pars, s))
    for l in lines
        if isempty(l)
            flush_par()
            continue
        end
        if position(buf) > 0
            s = String(take!(buf))
            s = occursin(r"\p{L}-$", s) ? chop(s) : s * " "
            print(buf, s)
        end
        print(buf, l)
    end
    flush_par()
    return pars
end

# Pieces of at most `max_chars` characters of a paragraph longer than that, cut at spaces.
function _cut(par::AbstractString, max_chars::Int)
    pieces = String[]
    rest = par
    while length(rest) > max_chars
        head = first(rest, max_chars)
        sp = findlast(' ', head)
        cut = (sp === nothing || sp < max_chars ÷ 2) ? lastindex(head) : prevind(head, sp)
        push!(pieces, strip(rest[1:cut]))
        rest = lstrip(rest[nextind(rest, cut):end])
    end
    isempty(rest) || push!(pieces, String(rest))
    return pieces
end

"""
    split_units(lines; max_chars=2000) -> Vector{String}

The units of `lines` (see [`normalize_text`](@ref)): consecutive paragraphs packed up to
`max_chars` characters, without overlap.
"""
function split_units(lines::AbstractVector{<:AbstractString}; max_chars::Int=2000)
    units = String[]
    cur = IOBuffer()
    n = 0
    for par in _paragraphs(lines), piece in (length(par) > max_chars ? _cut(par, max_chars) : (par,))
        m = length(piece)
        if n > 0 && n + 1 + m > max_chars
            push!(units, String(take!(cur)))
            n = 0
        end
        n > 0 && (print(cur, '\n'); n += 1)
        print(cur, piece)
        n += m
    end
    n > 0 && push!(units, String(take!(cur)))
    return units
end

"""
    fulltext_units(text; first_units=3, last_units=3, max_chars=2000) -> Vector{Pair{Symbol,String}}

The parts of a full text that are encoded, each with the section it comes from (`:start` or
`:end`), in the order of the text:

- the body starts at the first abstract or introduction heading in the first 30 % of the lines,
  or at the first line; it ends at the last bibliography heading in the last 40 %, or at the last
  line;
- the first `first_units` units of the body are `:start`;
- the last `last_units` units are `:end`. When there is a conclusions heading in the second half
  of the body (or else a discussion heading), they are the first `last_units` units from it
  instead, so that appendices before the bibliography do not take their place.

A unit is never taken twice, and a unit shorter than `min_chars` (a page number, the tail of a
section) is left out: a short body gives fewer parts. Headings count only when prose follows
them, so the entries of a table of contents are not taken for them.
"""
function fulltext_units(text::AbstractString; first_units::Int=3, last_units::Int=3, max_chars::Int=2000,
                        min_chars::Int=200)
    lines = normalize_text(text)
    n = length(lines)
    n == 0 && return Pair{Symbol,String}[]
    heads = [(i, heading(l)) for (i, l) in enumerate(lines) if length(l) <= 80]
    filter!(h -> h[2] !== nothing && _prose_follows(lines, h[1]), heads)
    start = 1
    for (i, s) in heads
        i > 0.3n && break
        if s in (:abstract, :introduction)
            start = i
            break
        end
    end
    stop = n
    for (i, s) in Iterators.reverse(heads)
        i < 0.6n && break
        if s === :bibliography && i > start
            stop = i - 1
            break
        end
    end
    in_second_half(i) = start + (stop - start) / 2 <= i <= stop
    tail_from = nothing
    for wanted in (:conclusions, :discussion)
        k = findfirst(h -> h[2] === wanted && in_second_half(h[1]), heads)
        k === nothing || (tail_from = heads[k][1]; break)
    end
    # A unit always starts at the heading of the tail, so that its first unit opens with it.
    body, tail_start = if tail_from === nothing
        split_units(view(lines, start:stop); max_chars), nothing
    else
        before = split_units(view(lines, start:tail_from-1); max_chars)
        vcat(before, split_units(view(lines, tail_from:stop); max_chars)), length(before) + 1
    end
    # Short units (a heading alone, a page number) are skipped and do not count.
    keep = [i for (i, u) in enumerate(body) if length(u) >= min_chars]
    head_idx = first(keep, first_units)
    tail_idx = tail_start === nothing ? last(keep, last_units) : first(filter(>=(tail_start), keep), last_units)
    out = Pair{Symbol,String}[]
    for i in head_idx
        push!(out, :start => body[i])
    end
    for i in tail_idx
        i in head_idx || push!(out, :end => body[i])
    end
    return out
end

"""
    record_text(doc) -> String

The text of the record of a document: its title, its authors, its keywords and its abstract, one
per line, the empty ones left out. The authors stay in the content, as in `docs_content`
(decision of 2026-11-26): the author collection is for finding a person, and the content for
finding documents.
"""
function record_text(doc::AbstractDict)
    title = strip(string(something(get(doc, "title", ""), "")))
    cs = get(doc, "creators", String[])
    authors = cs isa AbstractVector && !isempty(cs) ? join((strip(string(c)) for c in cs), "; ") :
              strip(string(something(get(doc, "creator", ""), "")))
    kws = get(doc, "keywords", String[])
    kw = kws isa AbstractVector ? join((strip(string(k)) for k in kws if !isempty(strip(string(k)))), ", ") : string(kws)
    isempty(kw) && (kw = strip(string(something(get(doc, "subject", ""), ""))))
    desc = strip(string(something(get(doc, "description", ""), "")))
    return valid_utf8(join(filter(!isempty, [title, authors, kw, desc]), "\n"))
end

end # module Units
