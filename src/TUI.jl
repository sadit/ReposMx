module TUI

using REPL
using REPL.LineEdit
using Term
using Term.Tables
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Storage: get_repo_stats, list_repo_names
using ..Search: SearchEngine, query_index, search_authors, find_similar_authors_by_profile,
               find_similar_documents_by_references, search_references,
               get_document_references, get_author_documents, get_coauthors,
               get_topic_elements, search_document_paragraphs, get_detailed_statistics
using ..DB: normalize_author_name
using ..Wikipedia: explain_concept

export launch_interactive_shell

mutable struct ShellState
    engine::SearchEngine
    last_hits::Vector{Dict{String, Any}}
    last_authors::Vector{Dict{String, Any}}
    context_doc::Union{Tuple{String, String}, Nothing} # (repo, doc_id)
    data_dir::String
    index_dir::String
end

const DEFAULT_TOP_K = 10

const _FLAG_NAMES = ("--top", "-k", "--repo", "--type", "--tag", "--wiki", "--no-wiki")
_clears_filter(v::AbstractString) = v in ("all", "todos", "none", "*")

"""
    extract_flags(args::AbstractString) -> (clean_text::String, flags::NamedTuple)

Scans `args` token by token for the shell-style flags this TUI supports, removes them, and
returns the remaining text (the command's actual argument — a query, a name) plus a NamedTuple
of resolved values (fixed defaults when a flag is absent):

    flags = (; top::Int, repo::Union{String,Nothing}, doc_type::Union{String,Nothing},
                tag::Union{String,Nothing}, wiki::Bool)

`--top N` / `-k N` take exactly one numeric token. `--repo`/`--type`/`--tag` are greedy — they
consume every token up to the next recognized flag or the end of input, so multi-word values work
without quoting (`--type Reporte Técnico`); `all`/`todos`/`none`/`*` as a value clears the filter
(equivalent to omitting the flag), kept for muscle memory from the old `/repo all` style.
`--wiki`/`--no-wiki` are boolean, no value. Flags may appear anywhere in `args`, not just at the
end, and are matched by name — commands with their own positional argument (`/doc <N>`, `/refs
[N]`) are unaffected as long as they parse that positional from the text `extract_flags` returns.
"""
function extract_flags(args::AbstractString)
    tokens = split(args)
    n = length(tokens)
    top = DEFAULT_TOP_K
    repo = nothing
    doc_type = nothing
    tag = nothing
    wiki = true
    keep = String[]

    i = 1
    while i <= n
        t = tokens[i]
        if (t == "--top" || t == "-k") && i < n
            v = tryparse(Int, tokens[i+1])
            (v !== nothing && v > 0) && (top = v)
            i += 2
        elseif t in ("--repo", "--type", "--tag")
            j = i + 1
            val_tokens = String[]
            while j <= n && !(tokens[j] in _FLAG_NAMES)
                push!(val_tokens, tokens[j])
                j += 1
            end
            value = isempty(val_tokens) ? nothing : join(val_tokens, " ")
            value = (value === nothing || _clears_filter(value)) ? nothing : value
            t == "--repo" && (repo = value)
            t == "--type" && (doc_type = value)
            t == "--tag" && (tag = value)
            i = j
        elseif t == "--wiki"
            wiki = true
            i += 1
        elseif t == "--no-wiki"
            wiki = false
            i += 1
        else
            push!(keep, t)
            i += 1
        end
    end

    return join(keep, " "), (; top, repo, doc_type, tag, wiki)
end

function tprintln(str)
    println(Term.apply_style(str))
end

function render_banner(state::ShellState)
    n_docs = length(state.engine.doc_keys)
    n_repos = length(list_repo_names(; data_dir=state.data_dir))
    n_authors = length(state.engine.author_keys)
    
    content = """
{bold bright_cyan}ReposMx - Buscador Interactivo de Repositorios de México{/bold bright_cyan}
{dim}Búsqueda Homogénea en RocksDB: Contenido, Redes de Autores, Citas Bibliográficas y Párrafos{/dim}

• {bold green}Documentos en acervo:{/bold green} $(string(n_docs))
• {bold green}Autores e investigadores:{/bold green} $(string(n_authors))
• {bold green}Repositorios institucionales:{/bold green} $(string(n_repos))

{bold yellow}Comandos principales:{/bold yellow}
  {cyan}/?{/cyan} o {cyan}/? <cmd>{/cyan}                     Ayuda interactiva general o de un comando
  {cyan}/search <consulta> [flags]{/cyan}       Búsqueda general de publicaciones por contenido
  {cyan}/author <nombre> [flags]{/cyan}         Búsqueda de investigadores por nombre (muestra su ID)
  {cyan}/author-docs <ID|#N> [--top N]{/cyan}   Lista publicaciones del autor indicado
  {cyan}/author-coauth <ID|#N> [--top N]{/cyan} Muestra la red de coautores del autor indicado
  {cyan}/author-similar <ID|#N|nombre> [flags]{/cyan} Investigadores afines por perfil y referencias
  {cyan}/doc <N>{/cyan}                         Abre ficha de un documento y lo fija en contexto
  {cyan}/doc-refs{/cyan}                        Referencias bibliográficas del documento en contexto
  {cyan}/doc-similar-refs [--top N]{/cyan}      Documentos similares por referencias citadas
  {cyan}/doc-search <query> [--top N]{/cyan}    Búsqueda profunda en párrafos del documento en contexto
  {cyan}/topic <tema> [flags]{/cyan}            Operaciones de conjuntos (autores y docs por tema/centro)

{bold yellow}Flags disponibles (después del comando, en cualquier orden):{/bold yellow}
  {dim}--top N | -k N        --repo <nombre>       --type <tipo>{/dim}
  {dim}--tag <keyword>       --wiki | --no-wiki    -h | --help (ayuda del comando){/dim}
"""
    p = Panel(
        content,
        title="{bold bright_blue}🔍 ReposMx Shell{/bold bright_blue}",
        style="bright_blue",
        box=:ROUNDED,
        padding=(2, 2, 1, 1),
        width=min(105, displaysize(stdout)[2] - 4)
    )
    println(p)
end

function print_general_help()
    content = """
{bold cyan}GUÍA DE COMANDOS DE REPOSMX:{/bold cyan}

  {bold bright_yellow}1. BÚSQUEDA Y CONTEXTO DE DOCUMENTOS:{/bold bright_yellow}
    {yellow}/search <texto> [flags]{/yellow}       Búsqueda de publicaciones por título, abstract, conclusiones y temas
    {yellow}/doc <N>{/yellow}                     Abre ficha completa y establece el documento como {bold}Contexto Activo{/bold}
    {yellow}/doc-refs{/yellow} o {yellow}/refs{/yellow}             Lista las citas bibliográficas del documento en contexto
    {yellow}/doc-similar-refs{/yellow} o {yellow}/sim-refs{/yellow} {yellow}[--top N]{/yellow}  Busca artículos/tesis con bibliografía afín al documento en contexto
    {yellow}/doc-search <texto> [--top N]{/yellow}  Búsqueda profunda de pasajes/párrafos dentro del documento en contexto

  {bold bright_yellow}2. BÚSQUEDA Y OPERACIONES DE AUTORES:{/bold bright_yellow}
    {yellow}/author <nombre> [flags]{/yellow}      Búsqueda de investigadores por coincidencia léxica de nombre; cada tarjeta muestra su ID
    {yellow}/author-docs <ID|#N> [--top N]{/yellow}        Lista todas las publicaciones del autor indicado (ID de una tarjeta, o #N del último /author)
    {yellow}/author-coauth <ID|#N> [--top N]{/yellow}      Muestra la red de coautoría y pesos del autor indicado
    {yellow}/author-similar{/yellow} o {yellow}/sim-authors{/yellow} {yellow}<ID|#N|nombre> [flags]{/yellow} Autores afines por acoplamiento bibliográfico y perfil temático

  {bold bright_yellow}3. TÓPICOS Y OPERACIONES DE CONJUNTOS:{/bold bright_yellow}
    {yellow}/topic <tema> [flags]{/yellow}         Lista documentos y autores en el tema (intersecta con --repo si se da)

  {bold bright_yellow}4. FLAGS Y ESTADÍSTICAS:{/bold bright_yellow}
    {yellow}--top N{/yellow} o {yellow}-k N{/yellow}              Cantidad de resultados (default $DEFAULT_TOP_K) — cualquier comando de búsqueda
    {yellow}--repo <nombre>{/yellow}               Filtro de repositorio institucional — /search, /author, /author-similar, /topic
    {yellow}--type <tipo>{/yellow}                 Filtro por tipo de documento (Tesis, Artículo, etc.) — solo /search
    {yellow}--tag <keyword>{/yellow}                Filtro por disciplina / keyword — solo /search
    {yellow}--wiki{/yellow} / {yellow}--no-wiki{/yellow}            Activa/desactiva tarjetas de Wikipedia — solo /search
    {yellow}-h{/yellow} / {yellow}--help{/yellow}                Muestra la ayuda de ese comando en vez de ejecutarlo (cualquier comando con '/')
    {yellow}/info [repo]{/yellow}                  Estadísticas detalladas del repositorio o acervo global
    {yellow}/clear-context{/yellow}                Limpia el contexto activo de documento
    {yellow}/clear{/yellow} | {yellow}/exit{/yellow}              Limpia la pantalla o sale del shell

  {dim}Los flags van después del comando y su argumento principal, en cualquier orden (ej. '/author garcia --top 5 --repo cimat'). No hay filtros de sesión ni autor en contexto: cada búsqueda y cada operación de autor declara su propio ID/nombre. Un comando no reconocido no se interpreta como búsqueda — usa '/search <consulta>' explícitamente.{/dim}
"""
    println(Panel(content, title="Guía de Comandos Generales", style="cyan", box=:ROUNDED, width=min(105, displaysize(stdout)[2] - 4)))
end

const _HELP_ALIASES = Dict("find" => "search", "doc-find" => "doc-search", "sim-refs" => "doc-similar-refs", "sim-authors" => "author-similar")

function print_specific_help(cmd::AbstractString)
    c = lowercase(strip(replace(cmd, r"^/+" => "")))
    c = get(_HELP_ALIASES, c, c)

    docs = Dict(
        "search" => ("Búsqueda General de Publicaciones",
            """
{bold}Sintaxis:{/bold} {cyan}/search <consulta> [--top N] [--repo <nombre>] [--type <tipo>] [--tag <keyword>] [--wiki|--no-wiki]{/cyan}

{bold}Descripción:{/bold}
Búsqueda de publicaciones por título, palabras clave, resumen y conclusiones — el punto de
entrada principal del acervo. Un comando no reconocido ya no se interpreta como una búsqueda:
hay que declararla explícitamente con `/search`.
"""),
        "author" => ("Búsqueda de Autores por Nombre",
            """
{bold}Sintaxis:{/bold} {cyan}/author <nombre o apellido> [--top N] [--repo <nombre>]{/cyan}

{bold}Descripción:{/bold}
Busca perfiles de investigadores y colaboradores por coincidencia de nombre. Cada tarjeta de
resultado muestra el {bold}ID{/bold} corto del autor (ej. `garcia_4821`) — úsalo, o el número
`#N` de la tarjeta, para operar sobre ese autor con {italic}/author-docs{/italic},
{italic}/author-coauth{/italic} o {italic}/author-similar{/italic}.
"""),
        "author-docs" => ("Publicaciones de un Autor",
            """
{bold}Sintaxis:{/bold} {cyan}/author-docs <ID|#N> [--top N]{/cyan}

{bold}Descripción:{/bold}
Recupera directamente de RocksDB todas las obras, tesis y artículos registrados para el autor
indicado (su ID, o el `#N` de la última búsqueda `/author`).
"""),
        "author-coauth" => ("Red de Coautores de un Autor",
            """
{bold}Sintaxis:{/bold} {cyan}/author-coauth <ID|#N> [--top N]{/cyan}

{bold}Descripción:{/bold}
Muestra los colaboradores y coautores más frecuentes del autor indicado.
"""),
        "author-similar" => ("Similitud de Autores por Perfil y Citas",
            """
{bold}Sintaxis:{/bold} {cyan}/author-similar <ID|#N|nombre>{/cyan} o {cyan}/sim-authors <ID|#N|nombre> [flags]{/cyan}

{bold}Descripción:{/bold}
Evalúa el índice semántico de autores (`authors_profile_shell.zip`) para descubrir investigadores que comparten marco conceptual, tópicos y literatura citada con el autor indicado.
"""),
        "doc" => ("Fijar Documento en Contexto y Ver Ficha",
            """
{bold}Sintaxis:{/bold} {cyan}/doc <número_resultado>{/cyan}

{bold}Descripción:{/bold}
Abre la ficha técnica completa del documento desde RocksDB y lo fija como contexto activo.
Permite ejecutar {italic}/doc-refs{/italic}, {italic}/doc-similar-refs{/italic}, y {italic}/doc-search{/italic}.
"""),
        "doc-refs" => ("Referencias Bibliográficas del Documento",
            """
{bold}Sintaxis:{/bold} {cyan}/doc-refs{/cyan} o {cyan}/refs [N]{/cyan}

{bold}Descripción:{/bold}
Muestra las citas bibliográficas extraídas del documento en contexto activo.
"""),
        "doc-similar-refs" => ("Documentos con Bibliografía Similar",
            """
{bold}Sintaxis:{/bold} {cyan}/doc-similar-refs [--top N]{/cyan} o {cyan}/sim-refs [--top N]{/cyan}

{bold}Descripción:{/bold}
Toma las referencias citadas por el documento en contexto y consulta el índice bibliográfico (`docs_refs_shell.zip`) para descubrir publicaciones con acoplamiento bibliográfico afín. `--top N` / `-k N` controla cuántos resultados devuelve (default $DEFAULT_TOP_K).
"""),
        "doc-search" => ("Búsqueda Profunda en Párrafos",
            """
{bold}Sintaxis:{/bold} {cyan}/doc-search <consulta> [--top N]{/cyan}

{bold}Descripción:{/bold}
Realiza una búsqueda de párrafos y pasajes relevantes dentro del texto completo del documento en contexto activo (no confundir con {italic}/search{/italic}, que busca en todo el acervo). `--top N` / `-k N` controla cuántos pasajes devuelve (default $DEFAULT_TOP_K).
"""),
        "topic" => ("Operaciones de Conjuntos por Tópico",
            """
{bold}Sintaxis:{/bold} {cyan}/topic <nombre_tema> [--top N] [--repo <nombre>]{/cyan}

{bold}Descripción:{/bold}
Lista los documentos y autores asociados a un tópico. Con `--repo <nombre>`, realiza la intersección de conjuntos en RocksDB en vez de listar sobre todo el acervo.
""")
    )
    
    if haskey(docs, c)
        title, body = docs[c]
        println(Panel(body, title="Ayuda: /$c - $title", style="cyan", box=:ROUNDED, width=min(95, displaysize(stdout)[2] - 4)))
    else
        tprintln("{bold yellow}No hay ayuda específica para el comando '$cmd'. Escribe '/?' para ver la lista de comandos.{/bold yellow}\n")
    end
end

function show_info_command(state::ShellState, repo_arg::Union{AbstractString, Nothing}=nothing)
    target = (repo_arg !== nothing && !isempty(strip(repo_arg))) ? String(strip(repo_arg)) : nothing
    stats = get_detailed_statistics(state.engine; repo=target)
    
    if haskey(stats, "error")
        tprintln("{bold red}$(stats["error"]){/bold red}\n")
        return
    end
    
    is_global = stats["is_global"]
    title_str = is_global ? "🇲🇽 Panorama General: Estadísticas del Acervo" : "🏛️ Estadísticas: $(stats["target_repo"])"
    
    docs_cnt = string(stats["total_docs"])
    files_cnt = string(stats["total_files"])
    fulltext_cnt = string(stats["total_fulltext"])
    refs_cnt = string(stats["total_references"])
    auth_cnt = string(stats["total_authors"])
    
    summary_text = """
📚 {bold}Documentos Totales:{/bold}    $docs_cnt
📄 {bold}PDFs Descargados:{/bold}      $files_cnt
📖 {bold}Textos Procesados:{/bold}     $fulltext_cnt
👥 {bold}Investigadores:{/bold}        $auth_cnt
🔗 {bold}Citas Bibliográficas:{/bold}  $refs_cnt
📅 {bold}Rango de Años:{/bold}         $(stats["year_min"]) - $(stats["year_max"])
"""
    p_summary = Panel(summary_text, title=title_str, style="bright_cyan", box=:ROUNDED, width=min(105, displaysize(stdout)[2] - 4))
    println(p_summary)
    
    disciplines = get(stats, "top_disciplines", Dict{String, Any}[])
    if !isempty(disciplines)
        d_sub = first(disciplines, 10)
        d_tab = Table(Dict(
            "Área / Disciplina" => [d["discipline"] for d in d_sub],
            "Publicaciones" => [string(d["count"]) for d in d_sub]
        ); style="magenta", box=:ROUNDED)
        println(Panel(string(d_tab), title="🏷️ Principales Disciplinas", style="magenta", box=:ROUNDED, width=min(105, displaysize(stdout)[2] - 4)))
    end
    println()
end

function show_repos_table(state::ShellState)
    stats = get_repo_stats(; data_dir=state.data_dir)
    has_idx = isfile(joinpath(state.index_dir, "docs_content_shell.zip")) ? "✓" : "✗"
    repos_sorted = sort(stats["repos"]; by=x -> x["repo"])
    fmt_harvest(h) = h === nothing ? "Nunca" : first(h, min(16, length(h)))

    tab = Table(Dict(
        "Repositorio" => [r["repo"] for r in repos_sorted],
        "Registros" => [string(r["total_records"]) for r in repos_sorted],
        "Corpus JSONL" => [string(r["corpus_records"]) for r in repos_sorted],
        "Archivos" => [string(r["files_downloaded"]) for r in repos_sorted],
        "Último Harvest" => [fmt_harvest(r["last_harvest"]) for r in repos_sorted],
        "Índice Global" => [has_idx for _ in repos_sorted],
    ); style="blue", box=:ROUNDED)
    println(tab)
    tprintln("{dim}Total: $(length(repos_sorted)) repositorios.{/dim}\n")
end

function show_author_search(state::ShellState, author_query::AbstractString; top::Int=DEFAULT_TOP_K, repo::Union{AbstractString, Nothing}=nothing)
    res = search_authors(state.engine, author_query; top, repo)
    authors = get(res, "authors", [])
    state.last_authors = authors
    
    if isempty(authors)
        tprintln("{yellow}No se encontraron autores que coincidan con '$author_query'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Encontrados {bold bright_cyan}$(length(authors)) autores{/bold bright_cyan} para \"{bold bright_white}$author_query{/bold bright_white}\" en {dim}$(res["time_ms"]) ms{/dim}:\n")
    
    for (i, a) in enumerate(authors)
        name = a["name"]
        role = a["role"]
        cnt = a["doc_count"]
        id = a["consolidated_id"]
        repos = join(a["repos"], ", ")
        coauth = !isempty(a["coauthors"]) ? join(first(a["coauthors"], 4), " ; ") : "N/A"
        kws = !isempty(a["keywords"]) ? join(first(a["keywords"], 6), " , ") : "N/A"

        content = """
👤 {bold bright_white}$name{/bold bright_white}  {cyan}[$role]{/cyan}
🆔 {bold}ID:{/bold} {bright_magenta}$id{/bright_magenta}

🏛️  {bold}Institución(es):{/bold} $repos
📚 {bold}Publicaciones registradas:{/bold} $cnt
👥 {bold}Coautores:{/bold} $coauth
🏷️  {bold}Áreas / Keywords:{/bold} $kws
"""
        p = Panel(
            content,
            title="[Autor #$i]",
            style="bright_cyan",
            box=:ROUNDED,
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p)
    end

    tprintln("{dim}Tip: Usa el ID o el #N con /author-docs, /author-coauth o /author-similar (ej. '/author-docs $(authors[1]["consolidated_id"])' o '/author-docs 1').{/dim}\n")
end

"""
    resolve_author_ref(state::ShellState, author_ref::AbstractString) -> Union{String,Nothing}

`author_ref` is either a numeric index into `state.last_authors` (the last `/author` results,
same convention as `/doc <N>` for documents) or an id/name passed straight through to
`resolve_consolidated_profile`. Returns the resolved reference to hand to the `Search` functions,
or `nothing` if a numeric index was out of range.
"""
function resolve_author_ref(state::ShellState, author_ref::AbstractString)
    idx = tryparse(Int, author_ref)
    if idx !== nothing
        if isempty(state.last_authors) || idx < 1 || idx > length(state.last_authors)
            tprintln("{bold red}Número de autor inválido. Primero busca con '/author <nombre>'.{/bold red}\n")
            return nothing
        end
        return state.last_authors[idx]["consolidated_id"]
    end
    return strip(author_ref)
end

function show_author_docs(state::ShellState, author_ref::AbstractString; top::Int=DEFAULT_TOP_K)
    ref = resolve_author_ref(state, author_ref)
    ref === nothing && return

    res = get_author_documents(state.engine, ref; limit=top*2)
    docs = get(res, "documents", Dict{String, Any}[])

    if isempty(docs)
        tprintln("{yellow}No se encontraron documentos en RocksDB para el autor '$ref'.{/yellow}\n")
        return
    end

    tprintln("\n{bold green}✓{/bold green} Publicaciones de {bold bright_white}$(res["author"]){/bold bright_white} ({bold bright_cyan}$(length(docs)) registros{/bold bright_cyan}):\n")

    for (i, d) in enumerate(first(docs, top))
        title = get(d, "title", "Sin título")
        repo = get(d, "repo", "")
        date = get(d, "date", "")
        dtype = get(d, "type", "Doc")
        role = get(d, "author_role", "Autor")
        
        card_content = """
{bold bright_white}$title{/bold bright_white}
🏛️  {cyan}$repo{/cyan} | {yellow}📑 $dtype{/yellow} | {dim}📅 $date{/dim} | {green}Rol: $role{/green}
"""
        println(Panel(card_content, title="[#$i]", style="blue", box=:SQUARE, width=min(100, displaysize(stdout)[2] - 4)))
    end
    println()
end

function show_author_coauthors(state::ShellState, author_ref::AbstractString; top::Int=DEFAULT_TOP_K)
    ref = resolve_author_ref(state, author_ref)
    ref === nothing && return

    coauths = get_coauthors(state.engine, ref; limit=top*2)
    if isempty(coauths)
        tprintln("{yellow}No se registraron coautorías para el autor '$ref'.{/yellow}\n")
        return
    end

    tprintln("\n{bold green}✓{/bold green} Red de coautoría para {bold bright_white}$ref{/bold bright_white}:\n")
    tab = Table(Dict(
        "Coautor / Colaborador" => [c.first for c in coauths],
        "Trabajos Conjuntos" => [string(c.second) for c in coauths]
    ); box=:ROUNDED, style="cyan")
    println(tab)
    println()
end

function show_similar_authors(state::ShellState, author_ref::AbstractString; top::Int=DEFAULT_TOP_K, repo::Union{AbstractString, Nothing}=nothing)
    target = resolve_author_ref(state, author_ref)
    target === nothing && return

    res = find_similar_authors_by_profile(state.engine, target; top, repo)
    sims = get(res, "similar_authors", [])
    
    if isempty(sims)
        tprintln("{yellow}No se encontraron investigadores afines para '$target'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Autores afines por acoplamiento bibliográfico y perfil semántico con \"{bold bright_white}$(res["target_author"]){/bold bright_white}\" ({dim}$(res["time_ms"]) ms{/dim}):\n")
    
    for (i, a) in enumerate(sims)
        name = a["name"]
        score = a["score"]
        repos = join(a["repos"], ", ")
        kws = !isempty(a["keywords"]) ? join(first(a["keywords"], 5), " , ") : "N/A"
        
        content = """
👤 {bold bright_white}$name{/bold bright_white}  {green}(Afinidad BM25: $(round(score, digits=1))){/green}
🏛️  {bold}Institución:{/bold} $repos
🏷️  {bold}Áreas de coincidencia:{/bold} $kws
"""
        p = Panel(content, title="[Autor Afín #$i]", style="magenta", box=:ROUNDED, width=min(100, displaysize(stdout)[2] - 4))
        println(p)
    end
    println()
end

function show_document_detail(state::ShellState, idx::Int)
    if isempty(state.last_hits) || idx < 1 || idx > length(state.last_hits)
        tprintln("{bold red}Número de documento inválido. Primero realiza una búsqueda y elige entre 1 y $(length(state.last_hits)).{/bold red}")
        return
    end
    
    doc = state.last_hits[idx]
    repo = get(doc, "repo", "")
    doc_id = get(doc, "id", "")
    state.context_doc = (repo, doc_id)
    
    title = get(doc, "title", "Sin título")
    date = get(doc, "date", "N/A")
    creator = get(doc, "creator", "N/A")
    contrib = get(doc, "contributor", "")
    desc = get(doc, "description", "Sin resumen disponible")
    dtype = get(doc, "type", "Documento")
    kws = get(doc, "keywords", String[])
    file = get(doc, "file", nothing)
    has_fulltext = get(doc, "has_fulltext", false)
    ref_cnt = get(doc, "reference_count", 0)
    score = get(doc, "score", 0.0)
    
    kw_str = !isempty(kws) ? join(kws, " | ") : "N/A"
    
    content = """
{bold bright_white}$title{/bold bright_white}

🏛️  {bold cyan}Institución:{/bold cyan}     $repo
📑 {bold cyan}Tipo:{/bold cyan}            $dtype
👤 {bold cyan}Autor(es):{/bold cyan}        $creator
$(!isempty(contrib) ? "🤝 {bold cyan}Colaborador(es):{/bold cyan} $contrib\n" : "")📅 {bold cyan}Fecha:{/bold cyan}            $date
🏷️  {bold cyan}Keywords:{/bold cyan}         $kw_str
🎯 {bold cyan}Score BM25:{/bold cyan}       $(round(score, digits=2))
📄 {bold cyan}PDF / Archivo:{/bold cyan}    $(file !== nothing ? file : "{dim}No descargado{/dim}")
📖 {bold cyan}Texto Completo:{/bold cyan}   $(has_fulltext ? "{bold green}Disponible para búsqueda por párrafos (/doc-search){/bold green}" : "{dim}No disponible{/dim}")
📚 {bold cyan}Referencias:{/bold cyan}      $(ref_cnt > 0 ? "{bold cyan}$ref_cnt citas extraídas (/doc-refs o /doc-similar-refs){/bold cyan}" : "{dim}No extraídas{/dim}")

{bold yellow}Resumen / Abstract:{/bold yellow}
$desc
"""
    p = Panel(
        content,
        title="[#$idx | Contexto Doc: $repo:$doc_id]",
        style="bright_yellow",
        box=:DOUBLE,
        width=min(105, displaysize(stdout)[2] - 4)
    )
    println(p)
    tprintln("{bold green}✓ Contexto de documento fijado:{/bold green} {cyan}$repo:$doc_id{/cyan}. Usa {yellow}/doc-refs{/yellow}, {yellow}/doc-similar-refs{/yellow} o {yellow}/doc-search <query>{/yellow}.\n")
end

function show_document_references_cli(state::ShellState, doc_idx_opt::Union{Int, Nothing}=nothing)
    target_repo, target_id = if doc_idx_opt !== nothing
        if isempty(state.last_hits) || doc_idx_opt < 1 || doc_idx_opt > length(state.last_hits)
            tprintln("{bold red}Número de documento inválido.{/bold red}\n")
            return
        end
        d = state.last_hits[doc_idx_opt]
        (d["repo"], d["id"])
    elseif state.context_doc !== nothing
        state.context_doc
    else
        tprintln("{bold red}Primero selecciona un documento con '/doc <N>'.{/bold red}\n")
        return
    end
    
    res = get_document_references(state.engine, target_repo, target_id)
    refs = get(res, "references", [])
    
    if isempty(refs)
        tprintln("{yellow}No se encontraron referencias estructuradas para el documento '$target_repo:$target_id'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Bibliografía de \"{bold bright_white}$(res["doc_title"]){/bold bright_white}\" ({bold bright_cyan}$(length(refs)) referencias{/bold bright_cyan}):\n")
    
    for (i, r) in enumerate(refs)
        txt = r isa AbstractDict ? get(r, "text", "") : string(r)
        p = Panel(txt, title="[Ref #$i]", style="blue", box=:SQUARE, width=min(100, displaysize(stdout)[2] - 4))
        println(p)
    end
    println()
end

function show_similar_documents_by_refs(state::ShellState; top::Int=DEFAULT_TOP_K)
    if state.context_doc === nothing
        tprintln("{bold red}No hay un documento en contexto activo. Usa '/doc <N>' para seleccionar uno.{/bold red}\n")
        return
    end

    repo, doc_id = state.context_doc
    res = find_similar_documents_by_references(state.engine, repo, doc_id; top)
    docs = get(res, "similar_documents", Dict{String, Any}[])
    
    if isempty(docs)
        tprintln("{yellow}No se encontraron documentos con referencias afines para '$repo:$doc_id'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Documentos con acoplamiento bibliográfico similar a {bold bright_white}$repo:$doc_id{/bold bright_white} ({dim}$(res["time_ms"]) ms{/dim}):\n")
    
    for (i, d) in enumerate(docs)
        title = get(d, "title", "Sin título")
        d_repo = get(d, "repo", "")
        creator = get(d, "creator", "")
        dtype = get(d, "type", "Doc")
        score = get(d, "score", 0.0)
        
        card_content = """
{bold bright_white}$title{/bold bright_white}
🏛️  {cyan}$d_repo{/cyan} | {yellow}📑 $dtype{/yellow} | {dim}👤 $creator{/dim} | {green}Afinidad Bibliográfica BM25: $(round(score, digits=1)){/green}
"""
        println(Panel(card_content, title="[Doc Afín #$i]", style="green", box=:ROUNDED, width=min(100, displaysize(stdout)[2] - 4)))
    end
    println()
end

function search_in_document_cli(state::ShellState, query::AbstractString, doc_idx_opt::Union{Int, Nothing}=nothing; top::Int=DEFAULT_TOP_K)
    target_repo, target_id = if doc_idx_opt !== nothing
        if isempty(state.last_hits) || doc_idx_opt < 1 || doc_idx_opt > length(state.last_hits)
            tprintln("{bold red}Número de documento inválido.{/bold red}\n")
            return
        end
        d = state.last_hits[doc_idx_opt]
        (d["repo"], d["id"])
    elseif state.context_doc !== nothing
        state.context_doc
    else
        tprintln("{bold red}Primero selecciona un documento con '/doc <N>'.{/bold red}\n")
        return
    end
    
    tprintln("{dim}Buscando pasajes en: $target_repo:$target_id...{/dim}")
    res = search_document_paragraphs(state.engine, target_repo, target_id, query; top)
    
    if haskey(res, "error")
        tprintln("{bold red}$(res["error"]){/bold red}\n")
        return
    end
    
    hits = get(res, "hits", [])
    if isempty(hits)
        tprintln("{yellow}No se encontraron párrafos que coincidan con '$query'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Encontrados {bold bright_cyan}$(length(hits)) párrafos relevantes{/bold bright_cyan} para \"{bold bright_white}$query{/bold bright_white}\":\n")
    
    for (i, ph) in enumerate(hits)
        pnum = ph["paragraph_num"]
        section = ph["section"]
        score = ph["score"]
        txt = ph["text"]
        
        p_card = Panel(
            txt,
            title="[Pasaje #$i - Párrafo $pnum | $section | Score: $(round(score, digits=1))]",
            title_style="bold bright_cyan",
            style="cyan",
            box=:ROUNDED,
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p_card)
    end
    println()
end

function show_topic_elements_cli(state::ShellState, topic_str::AbstractString; top::Int=DEFAULT_TOP_K, repo::Union{AbstractString, Nothing}=nothing)
    res = get_topic_elements(state.engine, topic_str; repo, limit=top)
    docs = get(res, "documents", Dict{String, Any}[])
    authors = get(res, "authors", String[])
    
    repo_filter = res["repo_filter"] !== nothing ? " en centro: $(res["repo_filter"])" : ""
    tprintln("\n{bold green}✓{/bold green} Operación de conjuntos para tópico \"{bold bright_white}$topic_str{/bold bright_white}\"$repo_filter ({dim}$(res["time_ms"]) ms{/dim}):\n")
    
    if !isempty(authors)
        tprintln("👥 {bold bright_cyan}Investigadores en esta área ($(length(authors))):{/bold bright_cyan}")
        tprintln(join(["  • " * a for a in first(authors, 10)], "\n"))
        println()
    end
    
    if !isempty(docs)
        tprintln("📚 {bold bright_cyan}Publicaciones asociadas ($(length(docs))):{/bold bright_cyan}")
        for (i, d) in enumerate(first(docs, 6))
            println("  [#$i] {bold bright_white}$(d["title"]){/bold bright_white} {cyan}($(d["repo"])){/cyan}")
        end
        println()
    end
    
    if isempty(authors) && isempty(docs)
        tprintln("{yellow}No se encontraron autores o documentos para este tópico con los filtros activos.{/yellow}\n")
    end
end

function render_search_results(state::ShellState, res::Dict; repo::Union{AbstractString, Nothing}=nothing, doc_type::Union{AbstractString, Nothing}=nothing, tag::Union{AbstractString, Nothing}=nothing)
    hits = get(res, "hits", [])
    state.last_hits = hits
    
    if haskey(res, "wiki_concept") && res["wiki_concept"] !== nothing
        w = res["wiki_concept"]
        wiki_content = """
{bold bright_white}$(w["title"]){/bold bright_white} {dim}(Wikipedia $(uppercase(w["lang"])) - Concepto){/dim}

$(w["extract"])

🔗 {italic blue}$(w["url"]){/italic blue}
"""
        println(Panel(wiki_content, title="💡 Concepto Wikipedia", style="magenta", box=:ROUNDED, width=min(100, displaysize(stdout)[2] - 4)))
    end
    
    q = get(res, "query", "")
    total = get(res, "total_hits", 0)
    t_ms = get(res, "time_ms", 0.0)
    
    filters = String[]
    repo !== nothing && push!(filters, "repo:{bold}$repo{/bold}")
    doc_type !== nothing && push!(filters, "tipo:{bold}$doc_type{/bold}")
    tag !== nothing && push!(filters, "tag:{bold}$tag{/bold}")
    filter_txt = !isempty(filters) ? " [" * join(filters, " | ") * "]" : ""
    
    tprintln("\n{bold green}✓{/bold green} Encontrados {bold bright_cyan}$total resultados{/bold bright_cyan} para \"{bold bright_white}$q{/bold bright_white}\"$filter_txt en {dim}$t_ms ms{/dim}:\n")
    
    if isempty(hits)
        tprintln("{yellow}No se encontraron coincidencias para esta búsqueda. Intenta con otros términos o limpia los filtros.{/yellow}\n")
        return
    end
    
    for (i, h) in enumerate(hits)
        title = get(h, "title", "Sin título")
        repo = get(h, "repo", "")
        creator = get(h, "creator", "")
        date = get(h, "date", "")
        dtype = get(h, "type", "Doc")
        score = get(h, "score", 0.0)
        snippet = get(h, "snippet", "")
        
        meta_line = "{cyan}🏛️  $repo{/cyan} | {yellow}📑 $dtype{/yellow}"
        !isempty(date) && (meta_line *= " | {dim}📅 $(first(date, 10)){/dim}")
        !isempty(creator) && (meta_line *= " | {dim}👤 $(first(creator, 30)){/dim}")
        meta_line *= " | {green}Score: $(round(score, digits=1)){/green}"
        
        card_content = """
{bold bright_white}$title{/bold bright_white}
$meta_line

$snippet
"""
        card = Panel(card_content, title="[#$i]", style="blue", box=:SQUARE, width=min(100, displaysize(stdout)[2] - 4))
        println(card)
    end
    
    tprintln("{dim}Tip: Escribe '/doc <N>' para abrir la ficha y fijar el contexto.{/dim}\n")
end

const HISTORY_FILE = joinpath(homedir(), ".reposmx_history")

function append_history(cmd::AbstractString)
    clean = strip(cmd)
    isempty(clean) && return
    try
        open(HISTORY_FILE, "a") do f
            println(f, clean)
        end
    catch
    end
end

"""
    process_shell_input(state::ShellState, raw_input::AbstractString)::Bool

Dispatches one line of shell input to its handler. Every branch calls its handler through
`Base.invokelatest` rather than directly, for the same reason `CLI.main_cli` does (see that
function's docstring, and the `julia-app-compile-latency` skill): this function has ~20 branches
reaching into Search.jl/DB.jl/Wikipedia.jl, and it is itself compiled as a closure captured
inside `launch_interactive_shell` (the `on_done` callback passed to `REPL.LineEdit.Prompt`) — so
without `invokelatest`, every fresh `reposmx` process paid for compiling all ~20 command handlers
just to open the shell, not only the ones a session actually types. Measured with
`--trace-compile-timing`: `launch_interactive_shell` alone accounted for 22.15s of compile time
before this fix.
"""
function process_shell_input(state::ShellState, raw_input::AbstractString)::Bool
    input = strip(raw_input)
    isempty(input) && return true

    parts = split(input; limit=2)
    cmd = parts[1]
    rest = length(parts) >= 2 ? parts[2] : ""

    # -h/--help is a generic flag on any command: show that command's help instead of
    # running it, regardless of what other flags/arguments are present.
    if startswith(cmd, "/") && cmd ∉ ("/?", "/help") && ("-h" in split(rest) || "--help" in split(rest))
        Base.invokelatest(print_specific_help, cmd)
        return true
    end

    if input in ("/exit", "exit", "quit", ":q", "q")
        tprintln("\n{bold cyan}¡Hasta luego!{/bold cyan}\n")
        return false
    elseif cmd in ("/?", "/help", "help", "?")
        if !isempty(strip(rest))
            Base.invokelatest(print_specific_help, strip(rest))
        else
            Base.invokelatest(print_general_help)
        end
    elseif cmd in ("/clear", "clear", "cls")
        print("\033c")
        Base.invokelatest(render_banner, state)
    elseif cmd in ("/clear-context", "clear-context")
        state.context_doc = nothing
        tprintln("{bold green}Contexto activo de documento restablecido.{/bold green}\n")
    elseif cmd == "/info"
        Base.invokelatest(show_info_command, state, isempty(strip(rest)) ? nothing : strip(rest))
    elseif cmd in ("/author-docs", "author-docs")
        clean, f = extract_flags(rest)
        if !isempty(strip(clean))
            Base.invokelatest(show_author_docs, state, strip(clean); top=f.top)
        else
            tprintln("{bold red}Uso: /author-docs <ID|#N> [--top N]{/bold red}\n")
        end
    elseif cmd in ("/author-coauth", "author-coauth", "/coauth")
        clean, f = extract_flags(rest)
        if !isempty(strip(clean))
            Base.invokelatest(show_author_coauthors, state, strip(clean); top=f.top)
        else
            tprintln("{bold red}Uso: /author-coauth <ID|#N> [--top N]{/bold red}\n")
        end
    elseif cmd in ("/author-similar", "/sim-authors")
        clean, f = extract_flags(rest)
        if !isempty(strip(clean))
            Base.invokelatest(show_similar_authors, state, strip(clean); top=f.top, repo=f.repo)
        else
            tprintln("{bold red}Uso: /author-similar <ID|#N|nombre> [--top N] [--repo <nombre>]{/bold red}\n")
        end
    elseif cmd == "/author"
        clean, f = extract_flags(rest)
        if !isempty(strip(clean))
            Base.invokelatest(show_author_search, state, strip(clean); top=f.top, repo=f.repo)
        else
            tprintln("{bold red}Uso: /author <nombre_investigador> [--top N] [--repo <nombre>]{/bold red}\n")
        end
    elseif cmd == "/topic"
        clean, f = extract_flags(rest)
        if !isempty(strip(clean))
            Base.invokelatest(show_topic_elements_cli, state, strip(clean); top=f.top, repo=f.repo)
        else
            tprintln("{bold red}Uso: /topic <nombre_tema_o_disciplina> [--top N] [--repo <nombre>]{/bold red}\n")
        end
    elseif cmd in ("/doc-similar-refs", "doc-similar-refs", "/sim-refs")
        _, f = extract_flags(rest)
        Base.invokelatest(show_similar_documents_by_refs, state; top=f.top)
    elseif cmd in ("/doc-refs", "doc-refs")
        Base.invokelatest(show_document_references_cli, state, nothing)
    elseif cmd == "/refs"
        idx = !isempty(rest) ? tryparse(Int, split(rest)[1]) : nothing
        Base.invokelatest(show_document_references_cli, state, idx)
    elseif cmd == "/doc-search"
        clean, f = extract_flags(rest)
        if !isempty(strip(clean))
            Base.invokelatest(search_in_document_cli, state, strip(clean); top=f.top)
        else
            tprintln("{bold red}Uso: /doc-search <consulta_dentro_del_documento> [--top N]{/bold red}\n")
        end
    elseif cmd == "/search"
        clean, f = extract_flags(rest)
        if !isempty(strip(clean))
            Base.invokelatest() do
                res = query_index(
                    state.engine,
                    clean;
                    top=f.top,
                    repo=f.repo,
                    keyword=f.tag,
                    doc_type=f.doc_type,
                    include_wiki=f.wiki
                )
                render_search_results(state, res; repo=f.repo, doc_type=f.doc_type, tag=f.tag)
            end
        else
            tprintln("{bold red}Uso: /search <consulta> [--top N] [--repo <nombre>] [--type <tipo>] [--tag <keyword>] [--wiki|--no-wiki]{/bold red}\n")
        end
    elseif cmd == "/doc"
        idx = !isempty(rest) ? tryparse(Int, split(rest)[1]) : nothing
        if idx !== nothing
            Base.invokelatest(show_document_detail, state, idx)
        else
            tprintln("{bold red}Uso: /doc <número_resultado>{/bold red}\n")
        end
    elseif cmd in ("/status", "/repos", "status", "repos")
        Base.invokelatest(show_repos_table, state)
    else
        tprintln("{bold red}Comando no reconocido: '$cmd'.{/bold red} {dim}¿Buscabas algo? Usa '/search <consulta>'. Escribe '/?' para ver la ayuda.{/dim}\n")
    end

    return true
end

"""
    launch_interactive_shell(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
"""
function launch_interactive_shell(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
    tprintln("{bold cyan}Cargando índices y conectando a RocksDB...{/bold cyan}")
    engine = @time "SearchEngine (total)" SearchEngine(; index_dir, data_dir)

    if engine.docs_content_invfile === nothing
        tprintln("{bold red}No se encontró el índice de búsqueda en '$index_dir'.{/bold red}")
        tprintln("{yellow}Ejecuta primero 'reposmx prepare-index' para generar los índices.{/yellow}")
        return
    end

    state = @time "ShellState init" ShellState(
        engine,
        Dict{String, Any}[],
        Dict{String, Any}[],
        nothing,  # context_doc
        data_dir,
        index_dir
    )

    @time "render_banner" render_banner(state)

    get_prompt_str = function()
        doc_badge = state.context_doc !== nothing ? " | Doc: $(state.context_doc[1]):$(state.context_doc[2])" : ""
        return "reposmx$doc_badge> "
    end
    
    if isa(stdin, Base.TTY)
        try
            term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm-256color"), stdin, stdout, stderr)
            
            main_prompt = REPL.LineEdit.Prompt(
                get_prompt_str;
                prompt_prefix = "\e[1;34m",
                prompt_suffix = "\e[0m",
                on_enter = REPL.LineEdit.default_enter_cb
            )
            
            hp = REPL.REPLHistoryProvider(Dict{Symbol, Any}(:reposmx => main_prompt))
            @time "history load" if isfile(HISTORY_FILE)
                try
                    for line in eachline(HISTORY_FILE)
                        s = strip(line)
                        if !isempty(s)
                            push!(hp.history, s)
                            push!(hp.modes, :reposmx)
                        end
                    end
                    hp.start_idx = length(hp.history)
                    hp.cur_idx = length(hp.history) + 1
                catch
                end
            end
            main_prompt.hist = hp

            @time "REPL/keymap setup" begin
                search_prompt, skeymap = REPL.LineEdit.setup_search_keymap(hp)
                prefix_prompt, pkeymap = REPL.LineEdit.setup_prefix_keymap(hp, main_prompt)

                main_prompt.keymap_dict = REPL.LineEdit.keymap([
                    skeymap,
                    pkeymap,
                    REPL.LineEdit.history_keymap,
                    REPL.LineEdit.default_keymap,
                    REPL.LineEdit.escape_defaults
                ])
            end
            
            main_prompt.on_done = (s, buf, ok) -> begin
                if !ok
                    return REPL.LineEdit.transition(s, :abort)
                end
                line = strip(String(take!(buf)))
                REPL.LineEdit.reset_state(s)
                if !isempty(line)
                    append_history(line)
                    push!(hp.history, line)
                    push!(hp.modes, :reposmx)
                    hp.cur_idx = length(hp.history) + 1
                    keep_running = process_shell_input(state, line)
                    if !keep_running
                        return REPL.LineEdit.transition(s, :abort)
                    end
                end
                return REPL.LineEdit.transition(s, main_prompt)
            end
            
            interface = REPL.LineEdit.ModalInterface([main_prompt, search_prompt, prefix_prompt])
            REPL.LineEdit.run_interface(term, interface)
            close(engine)
            return
        catch e
            # Fallback to standard readline loop if TTY initialization fails
        end
    end
    
    # Non-TTY / Fallback Loop
    while true
        print(get_prompt_str())
        flush(stdout)
        line = readline(stdin)
        if eof(stdin)
            println()
            break
        end
        clean_line = strip(line)
        isempty(clean_line) && continue
        append_history(clean_line)
        keep_running = process_shell_input(state, clean_line)
        !keep_running && break
    end
    
    close(engine)
end

end # module TUI
