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
    active_repo::Union{String, Nothing}
    active_type::Union{String, Nothing}
    active_keyword::Union{String, Nothing}
    top_k::Int
    include_wiki::Bool
    last_hits::Vector{Dict{String, Any}}
    last_authors::Vector{Dict{String, Any}}
    context_doc::Union{Tuple{String, String}, Nothing} # (repo, doc_id)
    context_author::Union{String, Nothing}            # norm_name or canonical name
    data_dir::String
    index_dir::String
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
  {cyan}/?{/cyan} o {cyan}/? <cmd>{/cyan}           Ayuda interactiva general o de un comando
  {cyan}<consulta>{/cyan}             Búsqueda general de publicaciones por contenido
  {cyan}/author <nombre>{/cyan}       Búsqueda de investigadores por nombre
  {cyan}/set-author <N|nombre>{/cyan} Fija el autor en contexto para operaciones derivadas
  {cyan}/author-docs{/cyan}           Lista publicaciones del autor en contexto
  {cyan}/author-coauth{/cyan}         Muestra la red de coautores del autor en contexto
  {cyan}/author-similar{/cyan}        Investigadores afines por perfil y referencias
  {cyan}/doc <N>{/cyan}               Abre ficha de un documento y lo fija en contexto
  {cyan}/doc-refs{/cyan}              Referencias bibliográficas del documento en contexto
  {cyan}/doc-similar-refs{/cyan}     Documentos similares por referencias citadas
  {cyan}/doc-find <query>{/cyan}      Búsqueda profunda en párrafos del documento en contexto
  {cyan}/topic <tema>{/cyan}          Operaciones de conjuntos (autores y docs por tema/centro)
  {cyan}/repo <nombre|all>{/cyan}     Filtro post-processing por centro institucional
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
    {yellow}<texto>{/yellow}                       Búsqueda de publicaciones por título, abstract, conclusiones y temas
    {yellow}/doc <N>{/yellow}                     Abre ficha completa y establece el documento como {bold}Contexto Activo{/bold}
    {yellow}/doc-refs{/yellow} o {yellow}/refs{/yellow}             Lista las citas bibliográficas del documento en contexto
    {yellow}/doc-similar-refs{/yellow} o {yellow}/sim-refs{/yellow}  Busca artículos/tesis con bibliografía afín al documento en contexto
    {yellow}/doc-find <texto>{/yellow} o {yellow}/find{/yellow}     Búsqueda profunda de pasajes/párrafos dentro del documento en contexto

  {bold bright_yellow}2. BÚSQUEDA Y CONTEXTO DE AUTORES:{/bold bright_yellow}
    {yellow}/author <nombre>{/yellow}              Búsqueda de investigadores por coincidencia léxica de nombre
    {yellow}/set-author <N|nombre>{/yellow}        Establece un autor como {bold}Contexto Activo{/bold}
    {yellow}/author-docs{/yellow}                  Lista todas las publicaciones del autor en contexto
    {yellow}/author-coauth{/yellow}                Muestra la red de coautoría y pesos del autor en contexto
    {yellow}/author-similar{/yellow} o {yellow}/sim-authors{/yellow} Autores afines por acoplamiento bibliográfico y perfil temático

  {bold bright_yellow}3. TÓPICOS Y OPERACIONES DE CONJUNTOS:{/bold bright_yellow}
    {yellow}/topic <tema>{/yellow}                 Lista documentos y autores en el tema (intersecta con /repo si está activo)

  {bold bright_yellow}4. FILTROS Y ESTADÍSTICAS:{/bold bright_yellow}
    {yellow}/repo <nombre|all>{/yellow}            Filtro de repositorio institucional (post-processing)
    {yellow}/type <tipo|all>{/yellow}              Filtro por tipo de documento (Tesis, Artículo, etc.)
    {yellow}/tag <keyword|all>{/yellow}            Filtro por disciplina / keyword
    {yellow}/top <número>{/yellow}                 Resultados devueltos por página (ej. /top 10)
    {yellow}/info [repo]{/yellow}                  Estadísticas detalladas del repositorio o acervo global
    {yellow}/clear-context{/yellow}                Limpia los contextos activos de documento y autor
    {yellow}/clear{/yellow} | {yellow}/exit{/yellow}              Limpia la pantalla o sale del shell
"""
    println(Panel(content, title="Guía de Comandos Generales", style="cyan", box=:ROUNDED, width=min(105, displaysize(stdout)[2] - 4)))
end

function print_specific_help(cmd::AbstractString)
    c = lowercase(strip(replace(cmd, r"^/+" => "")))
    
    docs = Dict(
        "author" => ("Búsqueda de Autores por Nombre",
            """
{bold}Sintaxis:{/bold} {cyan}/author <nombre o apellido>{/cyan}

{bold}Descripción:{/bold}
Busca perfiles de investigadores y colaboradores por coincidencia de nombre.
Para realizar operaciones sobre un autor (ver publicaciones, coautores o autores similares), usa {italic}/set-author <N>{/italic}.
"""),
        "set-author" => ("Fijar Autor en Contexto",
            """
{bold}Sintaxis:{/bold} {cyan}/set-author <número_resultado | nombre>{/cyan}

{bold}Descripción:{/bold}
Fija el autor indicado como contexto activo del shell.
Permite ejecutar {italic}/author-docs{/italic}, {italic}/author-coauth{/italic}, y {italic}/author-similar{/italic}.
"""),
        "author-docs" => ("Publicaciones del Autor en Contexto",
            """
{bold}Sintaxis:{/bold} {cyan}/author-docs{/cyan}

{bold}Descripción:{/bold}
Recupera directamente de RocksDB todas las obras, tesis y artículos registrados para el autor en contexto activo.
"""),
        "author-coauth" => ("Red de Coautores del Autor en Contexto",
            """
{bold}Sintaxis:{/bold} {cyan}/author-coauth{/cyan}

{bold}Descripción:{/bold}
Muestra los colaboradores y coautores más frecuentes del autor en contexto activo.
"""),
        "author-similar" => ("Similitud de Autores por Perfil y Citas",
            """
{bold}Sintaxis:{/bold} {cyan}/author-similar{/cyan} o {cyan}/sim-authors [nombre]{/cyan}

{bold}Descripción:{/bold}
Evalúa el índice semántico de autores (`authors_profile_bm25.jld2`) para descubrir investigadores que comparten marco conceptual, tópicos y literatura citada con el autor en contexto.
"""),
        "doc" => ("Fijar Documento en Contexto y Ver Ficha",
            """
{bold}Sintaxis:{/bold} {cyan}/doc <número_resultado>{/cyan}

{bold}Descripción:{/bold}
Abre la ficha técnica completa del documento desde RocksDB y lo fija como contexto activo.
Permite ejecutar {italic}/doc-refs{/italic}, {italic}/doc-similar-refs{/italic}, y {italic}/doc-find{/italic}.
"""),
        "doc-refs" => ("Referencias Bibliográficas del Documento",
            """
{bold}Sintaxis:{/bold} {cyan}/doc-refs{/cyan} o {cyan}/refs [N]{/cyan}

{bold}Descripción:{/bold}
Muestra las citas bibliográficas extraídas del documento en contexto activo.
"""),
        "doc-similar-refs" => ("Documentos con Bibliografía Similar",
            """
{bold}Sintaxis:{/bold} {cyan}/doc-similar-refs{/cyan} o {cyan}/sim-refs{/cyan}

{bold}Descripción:{/bold}
Toma las referencias citadas por el documento en contexto y consulta el índice bibliográfico (`docs_refs_bm25.jld2`) para descubrir publicaciones con acoplamiento bibliográfico afín.
"""),
        "doc-find" => ("Búsqueda Profunda en Párrafos",
            """
{bold}Sintaxis:{/bold} {cyan}/doc-find <consulta>{/cyan} o {cyan}/find <consulta>{/cyan}

{bold}Descripción:{/bold}
Realiza una búsqueda de párrafos y pasajes relevantes dentro del texto completo del documento en contexto activo.
"""),
        "topic" => ("Operaciones de Conjuntos por Tópico",
            """
{bold}Sintaxis:{/bold} {cyan}/topic <nombre_tema>{/cyan}

{bold}Descripción:{/bold}
Lista los documentos y autores asociados a un tópico. Si hay un filtro de repositorio activo ({italic}/repo cimat{/italic}), realiza la intersección de conjuntos en RocksDB.
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
    target = (repo_arg !== nothing && !isempty(strip(repo_arg))) ? String(strip(repo_arg)) : (state.active_repo !== nothing ? String(state.active_repo) : nothing)
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
    repos = list_repo_names(; data_dir=state.data_dir)
    rows = Any[]
    
    for r in sort(repos)
        st = get_repo_stats(r; data_dir=state.data_dir)
        n_xml = st["xml_records"]
        n_corpus = st["corpus_records"]
        n_pdf = st["pdf_files"]
        n_txt = st["txt_files"]
        has_corpus = st["has_corpus"] ? "{green}✓{/green}" : "{dim}✗{/dim}"
        has_idx = isfile(joinpath(state.index_dir, "docs_content_bm25.jld2")) ? "{green}✓{/green}" : "{dim}✗{/dim}"
        
        push!(rows, [r, string(n_xml), string(n_corpus), string(n_pdf), string(n_txt), has_corpus, has_idx])
    end
    
    tab = Table(
        rows;
        header=["Repositorio", "XML Cosechados", "Corpus JSONL", "PDFs", "TXT Fulltext", "Corpus Listo", "Indexado"],
        box=:ROUNDED,
        style="blue"
    )
    println(tab)
    tprintln("{dim}Total: $(length(rows)) repositorios. Usa '/repo <nombre>' para filtrar.{/dim}\n")
end

function show_author_search(state::ShellState, author_query::AbstractString)
    res = search_authors(state.engine, author_query; top=state.top_k, repo=state.active_repo)
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
        repos = join(a["repos"], ", ")
        coauth = !isempty(a["coauthors"]) ? join(first(a["coauthors"], 4), " ; ") : "N/A"
        kws = !isempty(a["keywords"]) ? join(first(a["keywords"], 6), " , ") : "N/A"
        
        content = """
👤 {bold bright_white}$name{/bold bright_white}  {cyan}[$role]{/cyan}

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
    
    tprintln("{dim}Tip: Escribe '/set-author <N>' para fijar un autor en contexto y explorar sus obras, coautores y afinidad.{/dim}\n")
end

function set_author_context(state::ShellState, target::AbstractString)
    idx = tryparse(Int, target)
    if idx !== nothing
        if isempty(state.last_authors) || idx < 1 || idx > length(state.last_authors)
            tprintln("{bold red}Número de autor inválido. Primero busca con '/author <nombre>'.{/bold red}\n")
            return
        end
        auth = state.last_authors[idx]
        state.context_author = auth["name"]
        tprintln("{bold green}✓ Autor en contexto fijado:{/bold green} {bold bright_white}$(auth["name"]){/bold bright_white} ({cyan}$(auth["role"]){/cyan})\n")
    else
        clean_name = strip(target)
        if !isempty(clean_name)
            state.context_author = clean_name
            tprintln("{bold green}✓ Autor en contexto fijado:{/bold green} {bold bright_white}$clean_name{/bold bright_white}\n")
        end
    end
end

function show_author_docs(state::ShellState)
    if state.context_author === nothing
        tprintln("{bold red}No hay un autor en contexto activo. Usa '/author <nombre>' y '/set-author <N>'.{/bold red}\n")
        return
    end
    
    res = get_author_documents(state.engine, state.context_author; limit=state.top_k*2)
    docs = get(res, "documents", Dict{String, Any}[])
    
    if isempty(docs)
        tprintln("{yellow}No se encontraron documentos en RocksDB para el autor '$(state.context_author)'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Publicaciones de {bold bright_white}$(res["author"]){/bold bright_white} ({bold bright_cyan}$(length(docs)) registros{/bold bright_cyan}):\n")
    
    for (i, d) in enumerate(first(docs, state.top_k))
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

function show_author_coauthors(state::ShellState)
    if state.context_author === nothing
        tprintln("{bold red}No hay un autor en contexto activo. Usa '/author <nombre>' y '/set-author <N>'.{/bold red}\n")
        return
    end
    
    coauths = get_coauthors(state.engine, state.context_author; limit=state.top_k*2)
    if isempty(coauths)
        tprintln("{yellow}No se registraron coautorías para el autor '$(state.context_author)'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Red de coautoría para {bold bright_white}$(state.context_author){/bold bright_white}:\n")
    tab = Table(Dict(
        "Coautor / Colaborador" => [c.first for c in coauths],
        "Trabajos Conjuntos" => [string(c.second) for c in coauths]
    ); box=:ROUNDED, style="cyan")
    println(tab)
    println()
end

function show_similar_authors(state::ShellState, target_author_opt::Union{AbstractString, Nothing}=nothing)
    target = target_author_opt !== nothing && !isempty(strip(target_author_opt)) ? strip(target_author_opt) : state.context_author
    if target === nothing
        tprintln("{bold red}Indica un autor o fija uno en contexto con '/set-author <N>'.{/bold red}\n")
        return
    end
    
    res = find_similar_authors_by_profile(state.engine, target; top=state.top_k, repo=state.active_repo)
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
📖 {bold cyan}Texto Completo:{/bold cyan}   $(has_fulltext ? "{bold green}Disponible para búsqueda por párrafos (/doc-find){/bold green}" : "{dim}No disponible{/dim}")
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
    tprintln("{bold green}✓ Contexto de documento fijado:{/bold green} {cyan}$repo:$doc_id{/cyan}. Usa {yellow}/doc-refs{/yellow}, {yellow}/doc-similar-refs{/yellow} o {yellow}/doc-find <query>{/yellow}.\n")
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

function show_similar_documents_by_refs(state::ShellState)
    if state.context_doc === nothing
        tprintln("{bold red}No hay un documento en contexto activo. Usa '/doc <N>' para seleccionar uno.{/bold red}\n")
        return
    end
    
    repo, doc_id = state.context_doc
    res = find_similar_documents_by_references(state.engine, repo, doc_id; top=state.top_k)
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

function search_in_document_cli(state::ShellState, query::AbstractString, doc_idx_opt::Union{Int, Nothing}=nothing)
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
    res = search_document_paragraphs(state.engine, target_repo, target_id, query; top=5)
    
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

function show_topic_elements_cli(state::ShellState, topic_str::AbstractString)
    res = get_topic_elements(state.engine, topic_str; repo=state.active_repo, limit=state.top_k)
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

function render_search_results(state::ShellState, res::Dict)
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
    state.active_repo !== nothing && push!(filters, "repo:{bold}$(state.active_repo){/bold}")
    state.active_type !== nothing && push!(filters, "tipo:{bold}$(state.active_type){/bold}")
    state.active_keyword !== nothing && push!(filters, "tag:{bold}$(state.active_keyword){/bold}")
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
"""
function process_shell_input(state::ShellState, raw_input::AbstractString)::Bool
    input = strip(raw_input)
    isempty(input) && return true
    
    if input in ("/exit", "exit", "quit", ":q", "q")
        tprintln("\n{bold cyan}¡Hasta luego!{/bold cyan}\n")
        return false
    elseif input in ("/?", "/help", "help", "?")
        print_general_help()
    elseif startswith(input, "/?") || startswith(input, "/help ")
        parts = split(input; limit=2)
        if length(parts) >= 2 && !isempty(strip(parts[2]))
            print_specific_help(strip(parts[2]))
        else
            print_general_help()
        end
    elseif input in ("/clear", "clear", "cls")
        print("\033c")
        render_banner(state)
    elseif input in ("/clear-context", "clear-context")
        state.context_doc = nothing
        state.context_author = nothing
        tprintln("{bold green}Contextos activos de documento y autor restablecidos.{/bold green}\n")
    elseif startswith(input, "/info")
        parts = split(input; limit=2)
        if length(parts) >= 2 && !isempty(strip(parts[2]))
            show_info_command(state, strip(parts[2]))
        else
            show_info_command(state, nothing)
        end
    elseif startswith(input, "/set-author")
        parts = split(input; limit=2)
        if length(parts) >= 2
            set_author_context(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /set-author <número_resultado | nombre_autor>{/bold red}\n")
        end
    elseif input in ("/author-docs", "author-docs")
        show_author_docs(state)
    elseif input in ("/author-coauth", "author-coauth", "/coauth")
        show_author_coauthors(state)
    elseif startswith(input, "/author-similar") || startswith(input, "/sim-authors")
        parts = split(input; limit=2)
        opt_arg = length(parts) >= 2 ? strip(parts[2]) : nothing
        show_similar_authors(state, opt_arg)
    elseif startswith(input, "/author")
        parts = split(input; limit=2)
        if length(parts) >= 2
            show_author_search(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /author <nombre_investigador>{/bold red}\n")
        end
    elseif startswith(input, "/topic")
        parts = split(input; limit=2)
        if length(parts) >= 2
            show_topic_elements_cli(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /topic <nombre_tema_o_disciplina>{/bold red}\n")
        end
    elseif input in ("/doc-similar-refs", "doc-similar-refs", "/sim-refs")
        show_similar_documents_by_refs(state)
    elseif input in ("/doc-refs", "doc-refs")
        show_document_references_cli(state, nothing)
    elseif startswith(input, "/refs")
        parts = split(input)
        idx = length(parts) >= 2 ? tryparse(Int, parts[2]) : nothing
        show_document_references_cli(state, idx)
    elseif startswith(input, "/doc-find") || startswith(input, "/find")
        parts = split(input; limit=2)
        if length(parts) >= 2
            search_in_document_cli(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /doc-find <consulta_dentro_del_documento>{/bold red}\n")
        end
    elseif startswith(input, "/repo")
        parts = split(input)
        if length(parts) == 1 || parts[2] in ("all", "todos", "none", "*")
            state.active_repo = nothing
            tprintln("{bold green}Filtro de repositorio eliminado. Buscando en todos.{/bold green}\n")
        else
            state.active_repo = parts[2]
            tprintln("{bold green}Filtro activo: repositorio '$(parts[2])'.{/bold green}\n")
        end
    elseif startswith(input, "/type")
        parts = split(input; limit=2)
        if length(parts) == 1 || parts[2] in ("all", "todos", "none", "*")
            state.active_type = nothing
            tprintln("{bold green}Filtro de tipo eliminado.{/bold green}\n")
        else
            state.active_type = strip(parts[2])
            tprintln("{bold green}Filtro activo: tipo '$(parts[2])'.{/bold green}\n")
        end
    elseif startswith(input, "/tag")
        parts = split(input; limit=2)
        if length(parts) == 1 || parts[2] in ("all", "todos", "none", "*")
            state.active_keyword = nothing
            tprintln("{bold green}Filtro de keyword/tag eliminado.{/bold green}\n")
        else
            state.active_keyword = strip(parts[2])
            tprintln("{bold green}Filtro activo: tag '$(parts[2])'.{/bold green}\n")
        end
    elseif startswith(input, "/top")
        parts = split(input)
        if length(parts) >= 2
            val = tryparse(Int, parts[2])
            if val !== nothing && val > 0
                state.top_k = val
                tprintln("{bold green}Cantidad de resultados configurada a $val.{/bold green}\n")
            else
                tprintln("{bold red}Número inválido para /top.{/bold red}\n")
            end
        end
    elseif startswith(input, "/doc")
        parts = split(input)
        if length(parts) >= 2
            idx = tryparse(Int, parts[2])
            if idx !== nothing
                show_document_detail(state, idx)
            else
                tprintln("{bold red}Uso: /doc <número_resultado>{/bold red}\n")
            end
        else
            tprintln("{bold red}Uso: /doc <número_resultado>{/bold red}\n")
        end
    elseif input in ("/status", "/repos", "status", "repos")
        show_repos_table(state)
    else
        res = query_index(
            state.engine,
            input;
            top=state.top_k,
            repo=state.active_repo,
            keyword=state.active_keyword,
            doc_type=state.active_type,
            include_wiki=state.include_wiki
        )
        render_search_results(state, res)
    end
    
    return true
end

"""
    launch_interactive_shell(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
"""
function launch_interactive_shell(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
    tprintln("{bold cyan}Cargando índices JLD2 y conectando a RocksDB...{/bold cyan}")
    engine = SearchEngine(; index_dir, data_dir)
    
    if engine.docs_content_invfile === nothing
        tprintln("{bold red}No se encontró el índice de búsqueda en '$index_dir'.{/bold red}")
        tprintln("{yellow}Ejecuta primero 'reposmx prepare-index' para generar los índices.{/yellow}")
        return
    end
    
    state = ShellState(
        engine,
        nothing,  # active_repo
        nothing,  # active_type
        nothing,  # active_keyword
        10,       # top_k
        true,     # include_wiki
        Dict{String, Any}[],
        Dict{String, Any}[],
        nothing,  # context_doc
        nothing,  # context_author
        data_dir,
        index_dir
    )
    
    render_banner(state)
    
    get_prompt_str = function()
        repo_badge = state.active_repo === nothing ? "todos" : state.active_repo
        type_badge = state.active_type !== nothing ? " | $(state.active_type)" : ""
        tag_badge = state.active_keyword !== nothing ? " | tag:$(state.active_keyword)" : ""
        doc_badge = state.context_doc !== nothing ? " | Doc: $(state.context_doc[1]):$(state.context_doc[2])" : ""
        auth_badge = state.context_author !== nothing ? " | Autor: $(state.context_author)" : ""
        return "reposmx [$repo_badge$type_badge$tag_badge$doc_badge$auth_badge | top:$(state.top_k)]> "
    end
    
    if isa(stdin, Base.TTY)
        try
            term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm-256color"), stdin, stdout, stderr)
            
            main_prompt = REPL.LineEdit.Prompt(
                get_prompt_str;
                prompt_prefix = "\e[1;34m",
                prompt_suffix = "\e[0m",
                on_enter = REPL.LineEdit.default_enter
            )
            
            hp = REPL.REPLHistoryProvider(Dict{Symbol, Any}(:reposmx => main_prompt))
            if isfile(HISTORY_FILE)
                try
                    REPL.hist_from_file(hp, HISTORY_FILE)
                catch
                end
            end
            main_prompt.hist = hp
            
            main_prompt.keymap_dict = REPL.LineEdit.keymap([
                REPL.LineEdit.default_keymap,
                REPL.LineEdit.escape_defaults,
                REPL.LineEdit.history_keymap,
                REPL.LineEdit.prefix_history_keymap
            ])
            
            main_prompt.on_done = (s, buf, ok) -> begin
                if !ok
                    return REPL.LineEdit.transition(s, :abort)
                end
                line = strip(String(take!(buf)))
                REPL.LineEdit.reset_state(s)
                if !isempty(line)
                    append_history(line)
                    keep_running = process_shell_input(state, line)
                    if !keep_running
                        return REPL.LineEdit.transition(s, :abort)
                    end
                end
                return REPL.LineEdit.transition(s, main_prompt)
            end
            
            interface = REPL.LineEdit.ModalInterface([main_prompt])
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
