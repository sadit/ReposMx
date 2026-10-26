module Corpus

using EzXML, JSON, SHA
using ..Config: DEFAULT_DATA_DIR
using ..Storage: get_repo_dir, load_metadata_records, save_corpus_records, list_repo_names
using ..Catalogs: resolve_cti_code

export parse_xml_metadata, parse_author_names, parse_keywords, normalize_doc_type,
       extract_conclusions, extract_reference_section, parse_individual_references,
       extract_document_references, split_into_paragraphs,
       build_repository_corpus, build_all_corpus, build_authors_index_data, repair_author_names!

const DC_KEYS = ["title", "creator", "contributor", "date", "description", "subject", "language", "rights", "publisher", "type"]
const DC_QUERIES = ["//$k" for k in DC_KEYS]

"""
    normalize_author_name(name::AbstractString)

Normalizes author name format (e.g., 'Flores, Alfinio' -> 'Alfinio Flores').
"""
function normalize_author_name(name::AbstractString)
    clean = strip(name)
    if occursin(",", clean)
        parts = split(clean, ","; limit=2)
        if length(parts) == 2
            last_part = strip(parts[1])
            first_part = strip(parts[2])
            if !isempty(last_part) && !isempty(first_part)
                return "$first_part $last_part"
            end
        end
    end
    return clean
end

"""
    _ROLE_MARKER_RE

Thesis-metadata role/title markers (advisor, co-advisor, director, and common academic-title
abbreviations) that some repositories embed INSIDE the author/contributor name field itself, not
only as a string PREFIX -- confirmed live on the real 93-repo corpus, in all three positions:
`"Adrián, asesor Acosta Silva"` (middle), `"Ana Verónica Asesor Charles Rodríguez"` (middle, no
commas at all), `"Ayala López, Carmen Leticia Co-Asesor"` (end), `"ASESOR DE LA CRUZ BRETÓN"`
(inside a longer garbled field). A narrower prefix-only version of this regex existed before and
missed all of these. Case-insensitive, whole-word matched (`\\b`) so it can never eat into a real
surname that merely contains one of these letter sequences. A trailing colon (`"Director:"`,
`"Asesor:"`) is consumed as part of the SAME match, deliberately -- an earlier version stripped
colons separately, anywhere in the string, which silently corrupted a real ORCID/URL's own `":"`
downstream (`"https://..."` -> `"https //..."`, no longer recognized as a URL at all).
"""
const _ROLE_MARKER_RE = r"\b(co[-\s]*)?asesor[a]?\s*tesis\b|\b(co[-\s]*)?asesor[a]?\b:?|\bco[-\s]*ordinador[a]?\b:?|\bdirector[a]?\b:?|\b(dr|dra|mtro|mtra|lic|ing)\b\.?"i

"""
    _ID_CODE_RE

The core shape of a Mexican researcher/student id code, matched WITHOUT any `"#"`/position
anchor -- reused both as a whole-segment reject ([`_CURP_RE`](@ref)/[`_CVU_RE`](@ref)) and as the
payload [`_EMBEDDED_ID_RE`](@ref) strips out when the SAME kind of code is glued onto an otherwise
real name. Three shapes, confirmed live on the real 93-repo corpus:
- CURP (Clave Única de Registro de Población): 4 letters, 6-digit birthdate, sex letter (H/M),
  4-5 letter state/consonant code, 0-2 digit homoclave -- the last piece is sometimes truncated
  entirely in the source data (`"...HGTLRM"`, no homoclave digits at all), hence `\\d{0,2}` rather
  than requiring exactly 2.
- A bare ORCID (4-4-4-4 digit/`X`-checksum grouping) -- also sometimes truncated
  (`"0000-0002-6380-368"`, one digit short in the last group), hence `\\d{1,4}[\\dXx]?` rather than
  requiring exactly 4.
- CVU (Clave Única de Registro, CONACYT's separate researcher-id scheme) -- just `"CVU"` + digits.
- RFC (Registro Federal de Contribuyentes, the Mexican tax id, a THIRD separate scheme from CURP)
  -- 4 letters, 6-digit birthdate, 3-character alphanumeric homoclave (13 characters total, no
  sex-letter/state-code the way CURP has -- distinguishable from CURP by checking `[HM]` right
  after the digits fails to match, so there is no ambiguity between the two shapes).
"""
const _ID_CODE_RE = raw"[A-Z]{4}\d{6}[HM][A-Z]{4,5}\d{0,2}|\d{4}-\d{4}-\d{4}-\d{1,4}[\dXx]?|cvu\d+|[A-Z]{4}\d{6}[A-Z0-9]{3}"

"""
    _CURP_RE / _CVU_RE / _BARE_ORCID_RE

Whole-segment reject patterns -- when, after splitting/stripping, an entire author segment IS just
one of [`_ID_CODE_RE`](@ref)'s shapes (matched as a PREFIX since a suffix like `"=asesorTesis"`
sometimes follows, e.g. `"BEGC770820HDFCNR08=asesorTesis"`, `"CVU102349=asesorTesis"`), it is
dropped entirely -- never a name under any circumstance.
"""
const _CURP_RE = Regex("^(?:$(_ID_CODE_RE))", "i")
const _CVU_RE = r"^cvu\d+"i
const _BARE_ORCID_RE = Regex("^#?(?:$(_ID_CODE_RE))\$", "i")

"""
    _EMBEDDED_ID_RE

An id code glued directly onto an otherwise-real name via a literal `"#"` -- confirmed live in all
three positions: prefix (`"#MARIA TERESA"` -- no code at all here, just a stray `"#"`, see below),
suffix (`"Aguilera Garcia Hugo Armando#AUGH810413HGTGRG08"`), and infix
(`"Adolfo Alberto:#0000-0002-5130-5475 Cervantes Baqué"`). Unlike [`_CURP_RE`](@ref) et al., this
does NOT reject the whole segment -- it strips just the `"#" [+ optional separator] [+ id code] [+
optional "=asesorTesis" suffix]` chunk, keeping the real name text around it. The leading `"#"` is
REQUIRED in the match (not `#?`) -- everything after it is optional, so making `"#"` itself
optional too would let the whole pattern match a zero-width empty string at every position, which
`replace` would then "substitute" between every single character. A bare stray `"#"` with no code
following it (`"#MARIA TERESA"`) is still removed by this same replace call: the code and suffix
groups simply match nothing, leaving only the required `"#"` (and any separator chars) consumed.
"""
const _EMBEDDED_ID_RE = Regex("#[\\s/:]*(?:$(_ID_CODE_RE))?(=?\\s*asesor\\s*tesis)?", "i")

"""
    _DIGIT_TOKEN_RE

A token that contains a digit, with the separator that joins it to a name. A personal name has no
digits, so every such token is removed. Shapes measured on the 93-repo corpus (2026-10-24):

- life dates of library authority records: `"Burgos, Juan Manuel, 1961-"`, `"..., 1673-1743"`,
  `"fl. 1725"` (about 600 names);
- an id joined with `":"`, `":-"`, `"%"` or `"*"`: `"HERIBERTO ORTIZ BECERRIL:3176060"`,
  `"HERRERA GARCÍA, FERNANDO:-HEGF870702HMNRRR03"`, `"Valencia Palomo %200705, Guillermo"`,
  `"*CA1218347"` (about 400 names);
- a bare id or number: `"201476"`, `"RN3191515"`, `"D 224701"` (about 2,600 names).

Before this pattern, the tokenizer turned a date or an id into the token `"0"`, and that token took
the place of a given name or a surname. The letter prefix of an id has at most 4 letters and must
start a word, so a name word followed by a digit (`"Garcia2"`) is not removed.
"""
const _DIGIT_TOKEN_RE = r"(?:\b(?:fl|ca)\.\s*)?(?:[#%*:=\-]+\s*|\b)[a-z]{0,4}\d[\da-z\-]*\.?"i

"""
    _ET_AL_RE

The marks of an author list that continues: `"Finck, Fernando... [y otros]"`, `"Marquet, Antonio
... [et al.]"`, `"Ramírez, Jorge y otros"` (270 names on the 93-repo corpus, 2026-10-24).
"""
const _ET_AL_RE = r"(?:\.\.\.|…)?\s*\[?\s*\b(?:y otros|et al\b\.?)\s*\]?"i

"""
    _ROLE_SEGMENT_RE

A comma segment that names the role of a person, not the person: `"Verdugo Córdoba, Joel,
sinodal"`, `"Padilla Galicia, Sergio, compilador"`. On the 93-repo corpus (2026-10-24), 234 names
end in `sinodal` and 203 in `sustentante`. The role is removed only when it is a whole segment,
because some of these words are also surnames: `"Roberto García Jurado"`, `"Aritz Tutor Anton"`.
The comma before the role is removed with it, and so are dashes before the role (`"--impresor"`).
"""
const _ROLE_SEGMENT_RE = r"(?:^|,)[\s\-]*(?:sinodal|sustentante|autora?|compiladora?|comp\.|traductora?|tr\.|editora?|ed\.|ilustradora?|impresor|estudiante|revisor|presidente)\.?\s*(?=,|$)"i

"""
    _ACADEMIC_TITLE_RE

Academic and professional titles written inside the name: `"M. en C. HERNANDEZ GARCIA, JOSUE
AARON"`, `"MORENO AVALOS, MVZ. CUAHUTEMOC"`, `"RUBÉN C.P.C. y E.I. LÓPEZ SÁNCHEZ"`. On the 93-repo
corpus (2026-10-24), 857 names contain `"M. en X."` and about 400 contain one of the others. Before
this pattern, the letters of a title became given-name initials (`"m"`, `"en"`, `"c"`).
[`_ROLE_MARKER_RE`](@ref) already removes `Dr.`, `Lic.`, `Ing.` and `Mtro.`.

`"M.C."` (204 names) and `"C.P."` (29 names) are not in the list. They are also the initials of
real given names (`"García, M.C."`), and the text alone does not tell the two cases apart.
"""
const _ACADEMIC_TITLE_RE = r"\bM(?:\.\s?|\s)en\s[a-z]{1,2}\b\.?|\bC\.P\.C\.(?:\s*y\s*E\.I\.)?|\bM\.?V\.?Z\b\.?|\bQ\.?F\.?B\b\.?|\bQ\.B\.P\.|\bI\.Q\.(?:I\.)?|\bL\.A\.E\.T\.|\bIBQ\b\.?|\bPh\.?\s?D\b\.?|\bBi[oó]l\b\.?|\bArq\b\.?|\bEsp\."i

"""
    _INSTITUTION_RE

Words that name an organization, not a person: `"Tecnológico de Monterrey, Universidad
Virtual"`, `"Consejo Nacional para Prevenir la Discriminación (México)."`, `"Raynor & Co.,
Samuel"`. A name with one of these words is dropped. `"Colegio"`, `"Centro"` and `"Unidad"` are
not in the list, because they are also surnames (`"Jorge Yahir Colegio Chiu"`). `"Centro de"` is in
the list.
"""
const _INSTITUTION_RE = r"\b(?:univer\p{L}{0,3}dad|universit(?:y|é|ät|à)|institut[oe]?|tecnol[oó]gico|polit[eé]cnico|facultad|faculty|escuela|school|departamento|department|secretar[ií]a|direcci[oó]n|divisi[oó]n|coordinaci[oó]n|programa|centro de|cent(?:er|re)|campus|consejo|comit[eé]|committee|laboratorio|laboratory|academia|editorial|imprenta|oficina|gobierno|government|ayuntamiento|biblioteca|library|museo|fundaci[oó]n|asociaci[oó]n|sociedad|society|maestr[ií]a|doctorado|licenciatura|compa[ñn][ií]a|itesm|unam|ipn|conah?cyt|scielo)\b|&\s*(?:co\b|cía|sons\b)|\bInc\b\.?|\bLtd\b\.?"i

const _INVISIBLE_CHARS_RE = Regex("[\u200b-\u200f\u202a-\u202e\u00ad\ufeff]")

const _ACUTE = Dict('a' => 'á', 'e' => 'é', 'i' => 'í', 'ı' => 'í', 'o' => 'ó', 'u' => 'ú',
                    'A' => 'Á', 'E' => 'É', 'I' => 'Í', 'O' => 'Ó', 'U' => 'Ú')

"""
    _normalize_name_chars(s) -> String

Character repairs applied to a name segment:

- Unicode dashes (`‐ ‑ ‒ – —`) become `-`: `"Macias‐Velasquez"`.
- Invisible characters are removed: zero-width spaces, bidirectional marks, the soft hyphen and
  the byte order mark.
- An acute accent written as its own character (`´` or `` ` ``) is joined to a vowel. The vowel
  before it is used first (`"Caldero´n"` becomes `"Calderón"`), then the vowel after it
  (`"Hern´andez"` becomes `"Hernández"`). A space after the accent is removed first:
  `"RODR´ IGUEZ"` becomes `"RODRÍGUEZ"`. After a one-letter word and before an uppercase letter,
  the accent is an apostrophe: `"O´Sullivan"` becomes `"O'Sullivan"`. Any other accent also
  becomes `'`.
- A tilde written as its own character next to an `n` is joined to it: `"NU˜NEZ"` becomes
  `"NUÑEZ"`.
- Text in parentheses is removed: `"Anaya, A. (Alejandro)"`, `"Víctor Santos (hijo)"`. Brackets
  are removed and their content is kept: `"Alo[n]so"` becomes `"Alonso"`.
- Quotes and the symbols `: © ° * + ¢ ± ˜ ¿ { }` become spaces.
- The replacement character `�` becomes `?`. A `?` that is not next to a letter is removed. A `?`
  next to a letter marks a lost letter, which [`repair_author_names!`](@ref) repairs.
"""
function _normalize_name_chars(s::AbstractString)
    s = replace(s, r"[‐‑‒–—]" => "-", _INVISIBLE_CHARS_RE => "")
    s = replace(s, r"(?<=\p{L})([´`])\s+(?=\p{L})" => s"\1")
    s = replace(s, r"(?<=\b\p{L})[´`](?=\p{Lu})" => "'")
    s = replace(s, r"[aeiouıAEIOU][´`]" => m -> string(_ACUTE[first(m)]))
    s = replace(s, r"[´`][aeiouAEIOU]" => m -> string(_ACUTE[last(m)]))
    s = replace(s, r"˜n|n˜" => "ñ", r"˜N|N˜" => "Ñ")
    s = replace(s, r"[´`]" => "'", r"\([^)]*\)?" => " ", r"[\[\]()]" => "")
    s = replace(s, r"[:\"“”«»©°*+¢±˜¿{}]" => " ", '�' => '?')
    return replace(s, r"(?<!\p{L})\?(?!\p{L})" => " ")
end

"""
    _MAX_NAME_WORDS

A name with more words than this is dropped. Such a segment is a citation, a sentence or a list
that [`_split_person_list`](@ref) does not split: `"González-Pérez, L.-I., Ramírez Montoya, M. S., &
García-Peñalvo, F. J. Habilitadores tecnológicos para..."`. `AuthorConsolidation._is_garbage_name`
uses the same limit of 10 tokens.
"""
const _MAX_NAME_WORDS = 10

const _NAME_PARTICLES = Set(["de", "del", "la", "las", "los", "y", "e", "da", "das", "do", "dos",
                             "di", "du", "le", "van", "von", "der"])

"""
    _split_person_list(name) -> Vector

Splits a segment that lists several people separated by commas: `"María Soledad Ramírez Montoya,
Anna Vater, José Vladimir Burgos Aguilar"`. The segment is split only when it has two or more
commas and every piece has 2 to 6 words, each word capitalized or a name particle (`de`, `la`,
`y`, ...). A piece cannot start or end with a particle, so `"Doña Benavides, Maria de Viuda de
Ribera, Juan de"` is not split. `"Rivas-Treviño, Brenda, J."` is one person and is not split. `"Herrera y Tordesillas,
Antonio de, m. Descripción de las Indias"` is not split either, because `m.` is not capitalized.
One comma is never a split point, because `"Ramírez Montoya, María Soledad"` is the most common
form of one name. On the 93-repo corpus (2026-10-25), this rule splits about 30 segments.
"""
function _split_person_list(name::AbstractString)
    pieces = split(name, ',')
    length(pieces) >= 3 || return [name]
    function is_name(x)
        words = filter(w -> occursin(r"\p{L}", w), split(x))
        2 <= length(words) <= 6 || return false
        isuppercase(first(first(words))) && !(lowercase(last(words)) in _NAME_PARTICLES) || return false
        return all(w -> isuppercase(first(w)) || lowercase(w) in _NAME_PARTICLES, words)
    end
    all(is_name, pieces) || return [name]
    return strip.(pieces)
end

"""
    parse_author_names(author_str::AbstractString)

Splits and cleans authors or contributors separated by ';' or commas, extracting original and
normalized names. Preprocessing happens here, on the raw harvested string, BEFORE any library
tokenization/normalization ever sees it (`AuthorConsolidation`'s `TextSearch`-based tokenizer runs
much later, on a name that's already gone through `build_authors_index_data`) -- catching garbage
and embedded role markers/id codes this early means they never become a raw author profile at all,
instead of relying on downstream consumers to filter them back out one at a time.

- A segment matching [`_CURP_RE`](@ref), [`_CVU_RE`](@ref), or [`_BARE_ORCID_RE`](@ref) (the WHOLE
  segment is just an id code, nothing else) is dropped entirely.
- Otherwise: a parenthetical URL annotation (`"(https://orcid.org/...)"`) is dropped:
  [`_EMBEDDED_ID_RE`](@ref) strips an id code glued on with `"#"` (prefix/suffix/infix, keeping the
  surrounding real name); underscores become spaces (some repositories join a compound surname
  with `"_"` instead of a space, e.g. `"Rodriguez_Garcia"`, which survives tokenization as one
  glued, leading-underscore token otherwise); [`_ROLE_MARKER_RE`](@ref) is stripped wherever it
  appears (not just as a prefix); whitespace/stray leading-or-trailing commas left behind are
  squeezed/trimmed.
- A segment that is a URL (`https://orcid.org/...`, `https://ror.org/...`) or starts with
  `info:eu-repo` is dropped. On the 93-repo corpus (2026-10-24), these segments became 561
  consolidated author profiles. A URL inside a segment is removed.
- A segment also loses the marks of a continued list ([`_ET_AL_RE`](@ref)), academic titles
  ([`_ACADEMIC_TITLE_RE`](@ref)), every token with a digit ([`_DIGIT_TOKEN_RE`](@ref)), the
  characters that [`_normalize_name_chars`](@ref) repairs or removes, and a role written as its own
  comma segment ([`_ROLE_SEGMENT_RE`](@ref)).
- A segment that lists several people is split into one name per person
  ([`_split_person_list`](@ref)).
- A name with no run of two letters left is dropped. A name with a word of
  [`_INSTITUTION_RE`](@ref) is dropped. A name with more than [`_MAX_NAME_WORDS`](@ref) words is
  dropped.
"""
function parse_author_names(author_str::AbstractString)
    isempty(strip(author_str)) && return String[]
    parts = split(author_str, r"[;\n\|]")
    names = String[]
    for p in parts
        clean = strip(p)
        isempty(clean) && continue
        length(clean) < 3 && continue
        occursin(_CURP_RE, clean) && continue
        occursin(_CVU_RE, clean) && continue
        occursin(_BARE_ORCID_RE, clean) && continue
        occursin(r"^(?:https?://|info:eu-repo)"i, clean) && continue
        clean = replace(clean, r"https?://\S+"i => " ")
        clean = replace(clean, _EMBEDDED_ID_RE => " ")
        clean = replace(clean, '_' => ' ')
        clean = replace(clean, _ROLE_MARKER_RE => " ")
        clean = replace(clean, _ET_AL_RE => " ")
        clean = replace(clean, _ACADEMIC_TITLE_RE => " ")
        clean = replace(clean, _DIGIT_TOKEN_RE => " ")
        clean = _normalize_name_chars(clean)
        clean = replace(clean, _ROLE_SEGMENT_RE => "")
        clean = replace(clean, r"\s*,(\s*,)*" => ",")
        clean = replace(clean, r"\s+" => " ")
        for piece in _split_person_list(strip(strip(clean), [',', ' ', '-']))
            piece = strip(piece, [',', ' ', '-'])
            length(piece) < 3 && continue
            occursin(r"\p{L}{2}", piece) || continue
            occursin(_INSTITUTION_RE, piece) && continue
            length(split(piece)) > _MAX_NAME_WORDS && continue
            push!(names, piece)
            norm = normalize_author_name(piece)
            if norm != piece && !isempty(norm)
                push!(names, norm)
            end
        end
    end
    return unique(names)
end

const DRIVER_SUBJECT_RE = r"^info:eu-repo/classification/([^/]+)/(.+)$"i

"""
    parse_keywords(subject_str::AbstractString)

Extracts individual keywords, topics and disciplines from the Dublin Core subject string.

`subject_str` is `" ; "`-joined by [`parse_xml_metadata`](@ref) -- one segment per raw
`<dc:subject>` element -- so it's split *only* on `;`/newline/`|`, never on `/` or `,` generically.
Splitting on those too used to shred the most common `dc:subject` shape in this corpus, the
DRIVER/OpenAIRE `info:eu-repo/classification/<esquema>/<valor>` convention, into meaningless
fragments (`"info:eu-repo"`, `"classification"`, the bare scheme name, and — worst — a raw numeric
code kept as if it were a real keyword), and just as wrongly split legitimate comma-containing
free text (e.g. `"Estado, el"`) into garbage pieces.

A segment matching that DRIVER pattern is handled per scheme:
- `cti` (CONACYT/CTI Área/Campo/Disciplina/Subdisciplina del Conocimiento): `<valor>` is a bare
  hierarchical numeric code, meaningless on its own (`cti/1`, `cti/2399`, `cti/239999`, ...) --
  resolved to its real name via [`Catalogs.resolve_cti_code`](@ref); the whole segment is dropped
  if it can't be resolved (a raw number is never kept pretending to be a keyword).
- any other scheme (`lcc`, `LCSH`, `agrovoc`, `librunam`, combined thesaurus names, ...): `<valor>`
  is already human-readable text in this corpus -- kept as-is, only the boilerplate
  `info:eu-repo/classification/<esquema>/` prefix is dropped.

A segment that doesn't match the DRIVER pattern at all is kept whole and trimmed, never split
further -- this is what fixes the `"Estado, el"` case. The tradeoff: a `<dc:subject>` element that
itself crams several comma-separated keywords into one field (seen in a few repos, e.g.
`"Asthma, Impulse Oscillometry (IOS), lung function, soft computing"`) now stays one longer
compound keyword instead of being split into four — coarser, but still a real, searchable phrase,
unlike the garbage this used to produce for the far more common DRIVER/comma-in-free-text cases.
"""
function parse_keywords(subject_str::AbstractString)
    isempty(strip(subject_str)) && return String[]
    parts = split(subject_str, r"[;\n\|]")
    keywords = String[]
    for p in parts
        clean = strip(p)
        isempty(clean) && continue

        m = match(DRIVER_SUBJECT_RE, clean)
        if m !== nothing
            scheme, value = m.captures
            value = strip(value)
            isempty(value) && continue
            if lowercase(scheme) == "cti"
                resolved = resolve_cti_code(value)
                resolved === nothing && continue
                clean = resolved
            else
                clean = value
            end
        end

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

Extracts the document's citations as a `Vector{Dict{String, Any}}`, one entry per reference,
each fully traceable back to its source doc and repository: `ref_id` (`"<repo>:<doc_id>#<n>"`),
`doc_id`, `doc_title`, `repo`, `ref_num`, the raw `text`, and the heuristically inferred
`year` and `authors`.
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

const _LOST_LETTER_WORD_RE = r"[\p{L}?]*\?[\p{L}?]*"

"""
    _lost_letter_repairs(names) -> Dict{String,String}

Some repositories export names with each accented letter replaced by `?`: `"Garc?a L?pez,
Mar?a"`. On the 93-repo corpus (2026-10-25), 3,818 names had a `?` next to a letter. This function
repairs them with the other names of the corpus. A word with a `?` takes the most frequent word,
among the names with no `?`, that has the same length and the same letters at every other
position: `"Garc?a"` becomes `"García"`. A word with two or more `?` is repaired in the same way:
`"N??ez"` becomes `"Núñez"`. The letter is uppercase when it is the first letter of the
word or when the rest of the word is uppercase. A `?` that no word explains is removed.

Returns a map from each name of `names` that has a `?` to its repaired form.
"""
function _lost_letter_repairs(names)
    freq = Dict{String,Int}()
    for n in names
        occursin('?', n) && continue
        for m in eachmatch(r"\p{L}+", n)
            w = lowercase(m.match)
            freq[w] = get(freq, w, 0) + 1
        end
    end
    wanted = Set{String}()
    multi = Set{String}()
    for n in names, m in eachmatch(_LOST_LETTER_WORD_RE, n)
        k = count(==('?'), m.match)
        length(m.match) > k || continue
        push!(k == 1 ? wanted : multi, lowercase(m.match))
    end
    best = Dict{String,Tuple{String,Int}}()
    for (w, f) in freq
        cs = collect(w)
        for i in eachindex(cs)
            c = cs[i]
            cs[i] = '?'
            key = String(cs)
            cs[i] = c
            key in wanted || continue
            b = get(best, key, ("", 0))
            (f > b[2] || (f == b[2] && w < b[1])) && (best[key] = (w, f))
        end
    end
    by_length = Dict{Int,Vector{String}}()
    isempty(multi) || for w in keys(freq)
        push!(get!(by_length, length(w), String[]), w)
    end
    for key in multi
        re = Regex("^" * replace(key, r"[^\p{L}?]" => "", '?' => "\\p{L}") * "\$")
        for w in get(by_length, length(key), String[])
            occursin(re, w) || continue
            b = get(best, key, ("", 0))
            f = freq[w]
            (f > b[2] || (f == b[2] && w < b[1])) && (best[key] = (w, f))
        end
    end
    function repair_word(word)
        hit = get(best, lowercase(word), nothing)
        hit === nothing && return word
        cs = collect(word)
        others = filter(isletter, cs)
        upper = !isempty(others) && all(isuppercase, others)
        for i in findall(==('?'), cs)
            letter = collect(hit[1])[i]
            cs[i] = (i == 1 || upper) ? uppercase(letter) : letter
        end
        return String(cs)
    end
    repairs = Dict{String,String}()
    for n in names
        occursin('?', n) || continue
        fixed = replace(n, _LOST_LETTER_WORD_RE => repair_word)
        repairs[n] = strip(replace(fixed, '?' => "", r"\s+" => " "), [',', ' ', '-'])
    end
    return repairs
end

"""
    repair_author_names!(all_docs) -> Int

Repairs the lost letters (`"Garc?a"`) in the `"creators"` and `"contributors"` of every document of
`all_docs`, in place, with [`_lost_letter_repairs`](@ref) computed over the names of all the
documents. It must run before [`build_authors_index_data`](@ref) and before anything else reads
those lists, because `Indexing` looks up each name of a document among the author profiles.
Returns the number of distinct names repaired.
"""
function repair_author_names!(all_docs::Vector{Dict{String, Any}})
    all_names = Set{String}()
    for doc in all_docs, key in ("creators", "contributors")
        union!(all_names, get(doc, key, String[]))
    end
    repairs = _lost_letter_repairs(all_names)
    isempty(repairs) && return 0
    for doc in all_docs, key in ("creators", "contributors")
        haskey(doc, key) || continue
        doc[key] = unique!(filter!(c -> length(c) >= 3 && occursin(r"\p{L}{2}", c),
                                   [String(get(repairs, c, c)) for c in doc[key]]))
    end
    return length(repairs)
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
        doc_publisher = strip(get(doc, "publisher", ""))
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
                "institutions" => Set{String}(),
                "coauthors" => Set{String}(),
                "keywords" => Set{String}(),
                "topic_texts" => String[],
                "cited_references" => String[]
            ))
            entry["doc_count"] += 1
            push!(entry["doc_ids"], doc_id)
            push!(entry["repos"], repo)
            isempty(repo) || push!(entry["institutions"], repo)
            isempty(doc_publisher) || push!(entry["institutions"], doc_publisher)
            length(entry["topic_texts"]) < 10 && push!(entry["topic_texts"], doc_summary)
            for kw in doc_keywords
                length(entry["keywords"]) < 30 && push!(entry["keywords"], kw)
            end
            for co in creators
                co != c && length(entry["coauthors"]) < 25 && push!(entry["coauthors"], co)
            end
            for rt in ref_texts
                !isempty(rt) && length(entry["cited_references"]) < 30 && push!(entry["cited_references"], rt)
            end
        end
        
        for c in contributors
            entry = get!(author_map, c, Dict{String, Any}(
                "name" => c,
                "role" => "Colaborador / Asesor",
                "doc_count" => 0,
                "doc_ids" => String[],
                "repos" => Set{String}(),
                "institutions" => Set{String}(),
                "coauthors" => Set{String}(),
                "keywords" => Set{String}(),
                "topic_texts" => String[],
                "cited_references" => String[]
            ))
            entry["doc_count"] += 1
            push!(entry["doc_ids"], doc_id)
            push!(entry["repos"], repo)
            isempty(repo) || push!(entry["institutions"], repo)
            isempty(doc_publisher) || push!(entry["institutions"], doc_publisher)
            length(entry["topic_texts"]) < 10 && push!(entry["topic_texts"], doc_summary)
            for kw in doc_keywords
                length(entry["keywords"]) < 30 && push!(entry["keywords"], kw)
            end
            for co in creators
                length(entry["coauthors"]) < 25 && push!(entry["coauthors"], co)
            end
            for rt in ref_texts
                !isempty(rt) && length(entry["cited_references"]) < 30 && push!(entry["cited_references"], rt)
            end
        end
    end
    
    profiles = Dict{String, Any}[]
    for (_, v) in author_map
        topic_sample = v["topic_texts"][1:min(10, length(v["topic_texts"]))]

        all_refs = collect(Set(v["cited_references"]))
        ref_sample = all_refs[1:min(30, length(all_refs))]

        push!(profiles, Dict(
            "name" => v["name"],
            "role" => v["role"],
            "doc_count" => v["doc_count"],
            "doc_ids" => v["doc_ids"],
            "repos" => sort(collect(v["repos"])),
            "institutions" => sort(collect(v["institutions"])),
            "coauthors" => collect(v["coauthors"])[1:min(15, length(v["coauthors"]))],
            "keywords" => collect(v["keywords"])[1:min(20, length(v["keywords"]))],
            "topic_texts" => topic_sample,
            "cited_references" => ref_sample
        ))
    end
    
    sort!(profiles, by=x->x["doc_count"], rev=true)
    return profiles
end

end # module Corpus
