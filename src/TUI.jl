module TUI

using REPL
using REPL.LineEdit
using Term
using Term.Tables
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Storage: get_repo_stats, list_repo_names
using ..Search: SearchEngine, query_index, search_authors, search_authors_by_topic,
               find_similar_authors_by_references, search_references,
               get_document_references, search_document_paragraphs, get_detailed_statistics
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
    selected_doc_idx::Union{Int, Nothing}
    data_dir::String
    index_dir::String
end

function tprintln(str)
    println(Term.apply_style(str))
end

function render_banner(state::ShellState)
    n_docs = state.engine.docs !== nothing ? length(state.engine.docs) : 0
    n_repos = length(list_repo_names(; data_dir=state.data_dir))
    n_authors = state.engine.authors_data !== nothing ? length(state.engine.authors_data) : 0
    n_refs = state.engine.references_data !== nothing ? length(state.engine.references_data) : 0
    
    content = """
{bold bright_cyan}ReposMx - Buscador Interactivo de Repositorios de México{/bold bright_cyan}
{dim}Búsqueda Multicapa: Metadatos, Autores por Tema, Citas Bibliográficas y Párrafos en PDFs{/dim}

• {bold green}Documentos indexados:{/bold green} $(string(n_docs))
• {bold green}Autores e investigadores:{/bold green} $(string(n_authors))
• {bold green}Citas / Referencias bibliográficas:{/bold green} $(string(n_refs))
• {bold green}Repositorios institucionales:{/bold green} $(string(n_repos))

{bold yellow}Comandos principales:{/bold yellow}
  {cyan}/?{/cyan} o {cyan}/? <comando>{/cyan}       Ayuda general o específica para cualquier comando
  {cyan}/info [repo]{/cyan}          Estadísticas globales o por repositorio (tipos, disciplinas, autores)
  {cyan}/topic-authors <tema>{/cyan}  Investigadores expertos en un campo del conocimiento
  {cyan}/sim-authors <autor>{/cyan}   Autores con bibliografía similar (acoplamiento bibliográfico)
  {cyan}/author <nombre>{/cyan}       Busca perfil de un autor / colaborador
  {cyan}/cited <autor|obra>{/cyan}     ¿Quién cita a este autor/obra en el repositorio?
  {cyan}/find <consulta>{/cyan}       Busca párrafos dentro del documento actual
  {cyan}/type <tipo>{/cyan} | {cyan}/repo <nombre>{/cyan} Filtra por tipo o repositorio
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
{bold cyan}GUÍA DE COMANDOS DE REPOSMX (Usa '/? <comando>' para ayuda detallada):{/bold cyan}

  {bold bright_yellow}BÚSQUEDA GENERAL:{/bold bright_yellow}
    {yellow}<texto>{/yellow}                       Búsqueda global sobre títulos, abstracts, conclusiones y keywords
    {yellow}/doc <N>{/yellow}                     Abre ficha detallada y abstract del resultado #N
    {yellow}/find <consulta>{/yellow}              Busca párrafos relevantes dentro del documento actual
    {yellow}/in <N> <consulta>{/yellow}            Busca párrafos dentro del documento resultado #N

  {bold bright_yellow}ESTADÍSTICAS Y PANORAMA ACADÉMICO:{/bold bright_yellow}
    {yellow}/info [repo]{/yellow}                  Estadísticas detalladas de publicaciones, disciplinas y autores
    {yellow}/status{/yellow} o {yellow}/repos{/yellow}             Tabla de estado de cosecha y archivos por repositorio

  {bold bright_yellow}INVESTIGADORES Y REDES CIENTÍFICAS:{/bold bright_yellow}
    {yellow}/author <nombre>{/yellow}              Busca investigadores por nombre, coautores e instituciones
    {yellow}/topic-authors <tema>{/yellow}         Rankea autores expertos según un campo o disciplina
    {yellow}/sim-authors <nombre>{/yellow}         Encuentra autores similares por referencias y citas compartidas

  {bold bright_yellow}CITAS Y REFERENCIAS BIBLIOGRÁFICAS:{/bold bright_yellow}
    {yellow}/cited <autor|obra>{/yellow}           Busca en el corpus de referencias quién cita a ese autor/obra
    {yellow}/refs [N]{/yellow}                     Muestra la bibliografía del resultado #N o del /doc actual

  {bold bright_yellow}FILTROS Y CONFIGURACIÓN:{/bold bright_yellow}
    {yellow}/repo <nombre|all>{/yellow}            Filtra por repositorio (ej. {italic}/repo cimat{/italic})
    {yellow}/type <tesis|articulo|all>{/yellow}    Filtra por tipo de publicación
    {yellow}/tag <keyword|all>{/yellow}            Filtra por palabra clave
    {yellow}/top <número>{/yellow}                 Cantidad de resultados devueltos (ej. {italic}/top 5{/italic})
    {yellow}/wiki <on|off>{/yellow}                Alterna explicaciones de conceptos con Wikipedia
    {yellow}/explain <concepto>{/yellow}           Consulta directa de un concepto en Wikipedia
    {yellow}/clear{/yellow} | {yellow}/exit{/yellow}              Limpia la terminal o sale del shell
"""
    println(Panel(content, title="Guía de Comandos Generales", style="cyan", box=:ROUNDED, width=min(105, displaysize(stdout)[2] - 4)))
end

function print_specific_help(cmd::AbstractString)
    c = lowercase(strip(replace(cmd, r"^/+" => "")))
    
    docs = Dict(
        "info" => ("Estadísticas Globales y por Repositorio",
            """
{bold}Sintaxis:{/bold} {cyan}/info [nombre_repositorio]{/cyan}

{bold}Descripción:{/bold}
Genera un informe analítico completo del acervo académico:
• Si se ejecuta sin argumentos (o {italic}/info all{/italic}), despliega el panorama global de todos los repositorios: total de documentos, PDFs, textos procesados, citas extraídas, distribución por tipo de publicación (Tesis, Artículos, Libros), principales disciplinas científicas, investigadores más prolíficos y distribución por repositorio.
• Si se especifica un repositorio (o hay uno activo con {italic}/repo{/italic}), desglosa las estadísticas focalizadas exclusivamente en esa institución.

{bold}Ejemplos:{/bold}
  • {italic}/info{/italic}
  • {italic}/info cimat{/italic}
  • {italic}/info iteso{/italic}
"""),
        "topic-authors" => ("Búsqueda de Investigadores por Campo de Conocimiento",
            """
{bold}Sintaxis:{/bold} {cyan}/topic-authors <campo del conocimiento o tema>{/cyan}

{bold}Descripción:{/bold}
Analiza los perfiles temáticos de todos los autores (títulos de sus obras, palabras clave y resúmenes) y rankea a los investigadores que más han publicado y contribuido en esa disciplina específica.

{bold}Ejemplos:{/bold}
  • {italic}/topic-authors optimización combinatoria{/italic}
  • {italic}/topic-authors electroquímica y corrosión{/italic}
  • {italic}/topic-authors redes neuronales convolucionales{/italic}
"""),
        "sim-authors" => ("Autores Similares por Referencias (Bibliographic Coupling)",
            """
{bold}Sintaxis:{/bold} {cyan}/sim-authors <nombre del autor>{/cyan}

{bold}Descripción:{/bold}
Calcula el acoplamiento bibliográfico (Bibliographic Coupling) entre investigadores. Encuentra qué otros autores citan la misma literatura, marcos teóricos y metodologías, revelando conexiones científicas e investigativas directas o interdisciplinarias.

{bold}Ejemplos:{/bold}
  • {italic}/sim-authors Samaniego{/italic}
  • {italic}/sim-authors Tellez{/italic}
"""),
        "author" => ("Búsqueda de Perfil de Autor / Colaborador",
            """
{bold}Sintaxis:{/bold} {cyan}/author <nombre o apellido>{/cyan}

{bold}Descripción:{/bold}
Busca en el índice de personas académicas (autores y asesores/colaboradores), mostrando su rol, total de publicaciones, repositorios asociados, red de coautores y principales áreas de investigación.

{bold}Ejemplos:{/bold}
  • {italic}/author Eric Tellez{/italic}
  • {italic}/author Carlos González{/italic}
"""),
        "cited" => ("Búsqueda en el Corpus de Referencias Citadas",
            """
{bold}Sintaxis:{/bold} {cyan}/cited <autor, libro, revista o teoría citada>{/cyan}

{bold}Descripción:{/bold}
Busca en el corpus de todas las referencias bibliográficas extraídas de los PDFs para identificar qué documentos y autores dentro del repositorio institucional han citado a una obra o autor específico.

{bold}Ejemplos:{/bold}
  • {italic}/cited Goodfellow{/italic}
  • {italic}/cited Knuth The Art of Computer Programming{/italic}
  • {italic}/cited IEEE Transactions on Pattern Analysis{/italic}
"""),
        "refs" => ("Exploración Bibliográfica del Documento",
            """
{bold}Sintaxis:{/bold} {cyan}/refs [número_resultado]{/cyan}

{bold}Descripción:{/bold}
Muestra la lista estructurada de todas las referencias bibliográficas citadas por el documento seleccionado.

{bold}Ejemplos:{/bold}
  • {italic}/refs{/italic} (para el documento actualmente abierto con /doc)
  • {italic}/refs 3{/italic} (para el resultado #3 de la última búsqueda)
"""),
        "find" => ("Búsqueda Profunda de Párrafos en PDF",
            """
{bold}Sintaxis:{/bold} {cyan}/find <término o pregunta>{/cyan}
{bold}Sintaxis alternativa:{/bold} {cyan}/in <N> <término>{/cyan}

{bold}Descripción:{/bold}
Segmenta el texto completo del documento seleccionado en párrafos, crea un índice BM25 dinámico al vuelo y recupera los pasajes más relevantes con su número de párrafo y sección identificada.

{bold}Ejemplos:{/bold}
  • {italic}/find función de costo y regularización{/italic}
  • {italic}/in 2 límites de detección electroquímica{/italic}
"""),
        "repo" => ("Filtro de Repositorio Institucional",
            """
{bold}Sintaxis:{/bold} {cyan}/repo <nombre_repo | all>{/cyan}

{bold}Descripción:{/bold}
Limita todas las búsquedas subsiguientes al repositorio seleccionado (ej. iteso, cimat, cideteq) o restablece a todos con 'all'.

{bold}Ejemplos:{/bold}
  • {italic}/repo cimat{/italic}
  • {italic}/repo all{/italic}
"""),
        "type" => ("Filtro por Tipo de Publicación",
            """
{bold}Sintaxis:{/bold} {cyan}/type <tesis | articulo | libro | reporte | all>{/cyan}

{bold}Descripción:{/bold}
Filtra las búsquedas por la tipología del documento académico.

{bold}Ejemplos:{/bold}
  • {italic}/type Tesis{/italic}
  • {italic}/type Artículo{/italic}
  • {italic}/type all{/italic}
"""),
        "doc" => ("Visualizador Detallado del Documento",
            """
{bold}Sintaxis:{/bold} {cyan}/doc <número_resultado>{/cyan}

{bold}Descripción:{/bold}
Abre la ficha completa de metadatos, abstract, autores, colaboradores, materias, ruta al PDF y número de referencias bibliográficas.

{bold}Ejemplos:{/bold}
  • {italic}/doc 1{/italic}
  • {italic}/doc 4{/italic}
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
    title_str = is_global ? "🇲🇽 Panorama General: Estadísticas Globales del Acervo Académico Nacional" : "🏛️ Estadísticas del Repositorio: $(stats["target_repo"])"
    
    docs_cnt = string(stats["total_docs"])
    files_cnt = string(stats["total_files"])
    fulltext_cnt = string(stats["total_fulltext"])
    refs_cnt = string(stats["total_references"])
    auth_cnt = string(stats["total_authors"])
    yr_min = stats["year_min"]
    yr_max = stats["year_max"]
    
    summary_box = """
• {bold green}Documentos y publicaciones indexadas:{/bold green} $docs_cnt
• {bold green}Documentos con PDF descargado:{/bold green} $files_cnt
• {bold green}Documentos con texto completo procesado:{/bold green} $fulltext_cnt
• {bold green}Citas y referencias bibliográficas extraídas:{/bold green} $refs_cnt
• {bold green}Autores e investigadores registrados:{/bold green} $auth_cnt
• {bold green}Rango temporal de publicaciones:{/bold green} $yr_min — $yr_max
"""
    println(Panel(summary_box, title="{bold bright_cyan}$title_str{/bold bright_cyan}", style="bright_cyan", box=:ROUNDED, width=min(105, displaysize(stdout)[2] - 4)))
    
    # 1. Publication types table
    types = stats["types_distribution"]
    if !isempty(types)
        t_names = [t["type"] for t in types]
        t_counts = [t["count"] for t in types]
        t_pcts = [string(round((t["count"] / max(1, stats["total_docs"])) * 100, digits=1), " %") for t in types]
        println(Table(Dict("Tipo de Publicación" => t_names, "Cantidad" => t_counts, "Porcentaje" => t_pcts); style="yellow", box=:ROUNDED))
    end
    
    # 2. Top disciplines / keywords
    discs = stats["top_disciplines"]
    if !isempty(discs)
        d_sub = discs[1:min(10, length(discs))]
        d_names = [d["discipline"] for d in d_sub]
        d_counts = [d["count"] for d in d_sub]
        println(Table(Dict("Área de Conocimiento / Disciplina" => d_names, "Frecuencia" => d_counts); style="cyan", box=:ROUNDED))
    end
    
    # 3. Top authors
    auths = stats["top_authors"]
    if !isempty(auths)
        a_sub = auths[1:min(8, length(auths))]
        a_names = [a["name"] for a in a_sub]
        a_roles = [a["role"] for a in a_sub]
        a_counts = [a["doc_count"] for a in a_sub]
        a_insts = [join(a["repos"], ", ") for a in a_sub]
        println(Table(Dict("Investigador / Colaborador" => a_names, "Rol" => a_roles, "Publicaciones" => a_counts, "Institución" => a_insts); style="green", box=:ROUNDED))
    end
    
    # 4. If global, top repositories
    if is_global
        repos = stats["top_repositories"]
        if !isempty(repos)
            r_sub = repos[1:min(8, length(repos))]
            r_names = [r["repo"] for r in r_sub]
            r_counts = [r["count"] for r in r_sub]
            println(Table(Dict("Repositorio Institucional" => r_names, "Total Documentos" => r_counts); style="blue", box=:ROUNDED))
        end
    end
    
    println()
end

function show_repos_table(state::ShellState)
    stats = get_repo_stats(; data_dir=state.data_dir)
    repos_data = stats["repos"]
    
    headers = ["Repositorio", "Registros DB", "Archivos", "En Corpus", "Última Cosecha"]
    rows = []
    
    for r in repos_data
        rname = r["repo"]
        tot = string(r["total_records"])
        fil = string(r["files_downloaded"])
        cor = string(r["corpus_records"])
        harv = r["last_harvest"] === nothing ? "Nunca" : first(r["last_harvest"], min(10, length(r["last_harvest"])))
        push!(rows, [rname, tot, fil, cor, harv])
    end
    
    sort!(rows, by=x->parse(Int, x[2]), rev=true)
    display_rows = rows[1:min(35, length(rows))]
    
    tab = Table(
        display_rows;
        header=headers,
        box=:ROUNDED,
        style="blue"
    )
    
    println(tab)
    tprintln("{dim}Mostrando $(length(display_rows)) de $(length(rows)) repositorios. Usa '/repo <nombre>' para filtrar.{/dim}\n")
end

function show_author_profile(state::ShellState, author_query::AbstractString)
    res = search_authors(state.engine, author_query; top=state.top_k)
    authors = get(res, "authors", [])
    
    if isempty(authors)
        tprintln("{yellow}No se encontraron autores o colaboradores que coincidan con '$author_query'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Encontrados {bold bright_cyan}$(length(authors)) autores/colaboradores{/bold bright_cyan} para \"{bold bright_white}$author_query{/bold bright_white}\" en {dim}$(res["time_ms"]) ms{/dim}:\n")
    
    for (i, a) in enumerate(authors)
        name = a["name"]
        role = a["role"]
        cnt = a["doc_count"]
        repos = join(a["repos"], ", ")
        coauth = !isempty(a["coauthors"]) ? join(first(a["coauthors"], 5), " ; ") : "N/A"
        kws = !isempty(a["keywords"]) ? join(first(a["keywords"], 8), " , ") : "N/A"
        
        content = """
👤 {bold bright_white}$name{/bold bright_white}  {cyan}[$role]{/cyan}

🏛️  {bold}Repositorios:{/bold} $repos
📚 {bold}Publicaciones registradas:{/bold} $cnt
👥 {bold}Coautores / Colaboradores:{/bold} $coauth
🏷️  {bold}Áreas / Keywords:{/bold} $kws
"""
        p = Panel(
            content,
            title="[#$i] Perfil de Investigador",
            style="bright_cyan",
            box=:ROUNDED,
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p)
    end
    
    tprintln("{dim}Tip: Escribe '/sim-authors $author_query' para encontrar autores similares por citas.{/dim}\n")
end

function show_topic_authors(state::ShellState, topic_query::AbstractString)
    res = search_authors_by_topic(state.engine, topic_query; top=state.top_k)
    authors = get(res, "authors", [])
    
    if isempty(authors)
        tprintln("{yellow}No se encontraron autores asociados al tema '$topic_query'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Autores especializados en \"{bold bright_white}$topic_query{/bold bright_white}\" ({bold bright_cyan}$(length(authors)) encontrados{/bold bright_cyan} en {dim}$(res["time_ms"]) ms{/dim}):\n")
    
    for (i, a) in enumerate(authors)
        name = a["name"]
        role = a["role"]
        cnt = a["doc_count"]
        repos = join(a["repos"], ", ")
        kws = !isempty(a["keywords"]) ? join(first(a["keywords"], 6), " , ") : "N/A"
        
        content = """
👤 {bold bright_white}$name{/bold bright_white}  {cyan}[$role]{/cyan}  {green}(Score Relevancia: $(round(a["score"], digits=1))){/green}

🏛️  {bold}Institución(es):{/bold} $repos
📚 {bold}Publicaciones en el área:{/bold} $cnt
🏷️  {bold}Temas afines:{/bold} $kws
"""
        p = Panel(
            content,
            title="[Especialista #$i]",
            style="bright_cyan",
            box=:ROUNDED,
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p)
    end
    println()
end

function show_similar_authors(state::ShellState, author_name::AbstractString)
    res = find_similar_authors_by_references(state.engine, author_name; top=state.top_k)
    sims = get(res, "similar_authors", [])
    
    if isempty(sims)
        tprintln("{yellow}No se encontraron autores con acoplamiento bibliográfico similar para '$author_name'.{/yellow}\n")
        return
    end
    
    target = get(res, "target_author", author_name)
    tprintln("\n{bold green}✓{/bold green} Autores similares por referencias y citas compartidas con \"{bold bright_white}$target{/bold bright_white}\" ({dim}$(res["time_ms"]) ms{/dim}):\n")
    
    for (i, a) in enumerate(sims)
        name = a["name"]
        shared = a["shared_citation_matches"]
        score = a["similarity_score"]
        repos = join(a["repos"], ", ")
        kws = !isempty(a["keywords"]) ? join(first(a["keywords"], 5), " , ") : "N/A"
        
        content = """
👤 {bold bright_white}$name{/bold bright_white}
🏛️  {bold}Institución:{/bold} $repos
🔗 {bold cyan}Coincidencias en literatura citada:{/bold cyan} {bold green}$shared referencias compartidas{/bold green} (Score: $score)
🏷️  {bold}Áreas de investigación:{/bold} $kws
"""
        p = Panel(
            content,
            title="[Autor Similar #$i]",
            style="magenta",
            box=:ROUNDED,
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p)
    end
    println()
end

function show_cited_references(state::ShellState, query::AbstractString)
    res = search_references(state.engine, query; top=state.top_k, repo=state.active_repo)
    refs = get(res, "references", [])
    
    if isempty(refs)
        tprintln("{yellow}No se encontraron citas o referencias bibliográficas que coincidan con '$query'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Encontradas {bold bright_cyan}$(length(refs)) referencias citadas{/bold bright_cyan} para \"{bold bright_white}$query{/bold bright_white}\" en {dim}$(res["time_ms"]) ms{/dim}:\n")
    
    for (i, r) in enumerate(refs)
        ref_text = r["text"]
        repo = r["repo"]
        doc_title = r["doc_title"]
        doc_id = r["doc_id"]
        ref_num = r["ref_num"]
        
        content = """
📖 {italic bright_white}\"$ref_text\"{/italic bright_white}

🏛️  {bold cyan}Citado en documento:{/bold cyan} $doc_title
📍 {bold cyan}Origen / Proveniencia:{/bold cyan} $repo (Ref #$ref_num) [ID: $doc_id]
"""
        p = Panel(
            content,
            title="[Cita #$i - $repo]",
            style="green",
            box=:ROUNDED,
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p)
    end
    println()
end

function show_document_references_cli(state::ShellState, doc_idx::Union{Int, Nothing}=nothing)
    target_idx = doc_idx !== nothing ? doc_idx : state.selected_doc_idx
    if target_idx === nothing || isempty(state.last_hits) || target_idx < 1 || target_idx > length(state.last_hits)
        tprintln("{bold red}Primero selecciona un documento con '/doc <N>' o usa '/refs <N>'.{/bold red}\n")
        return
    end
    
    doc = state.last_hits[target_idx]
    actual_doc_id = get(doc, "doc_idx", target_idx)
    
    res = get_document_references(state.engine, actual_doc_id)
    refs = get(res, "references", [])
    
    if isempty(refs)
        tprintln("{yellow}No se extrajeron referencias bibliográficas estructuradas para este documento.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Bibliografía de \"{bold bright_white}$(res["doc_title"]){/bold bright_white}\" ({bold bright_cyan}$(length(refs)) referencias{/bold bright_cyan}):\n")
    
    for (i, r) in enumerate(refs)
        txt = get(r, "text", "")
        p = Panel(
            txt,
            title="[Ref #$i]",
            style="blue",
            box=:SQUARE,
            padding=(1, 1, 0, 0),
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p)
    end
    println()
end

function show_document_detail(state::ShellState, idx::Int)
    if isempty(state.last_hits) || idx < 1 || idx > length(state.last_hits)
        tprintln("{bold red}Número de documento inválido. Primero realiza una búsqueda y elige entre 1 y $(length(state.last_hits)).{/bold red}")
        return
    end
    
    state.selected_doc_idx = idx
    doc = state.last_hits[idx]
    
    title = get(doc, "title", "Sin título")
    repo = get(doc, "repo", "")
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
📖 {bold cyan}Texto Completo:{/bold cyan}   $(has_fulltext ? "{bold green}Disponible para búsqueda por párrafos{/bold green}" : "{dim}No disponible{/dim}")
📚 {bold cyan}Referencias:{/bold cyan}      $(ref_cnt > 0 ? "{bold cyan}$ref_cnt citas bibliográficas extraídas{/bold cyan} (Usa {bold yellow}/refs{/bold yellow} para verlas)" : "{dim}No extraídas{/dim}")

{bold yellow}Resumen / Abstract:{/bold yellow}
$desc
"""
    p = Panel(
        content,
        title="[#$idx] Ficha Detallada del Documento",
        style="bright_yellow",
        box=:DOUBLE,
        width=min(105, displaysize(stdout)[2] - 4)
    )
    println(p)
    
    if has_fulltext
        tprintln("{bold bright_green}💡 Búsqueda profunda:{/bold bright_green} Escribe {cyan}/find <consulta>{/cyan} para buscar párrafos dentro de este documento.\n")
    end
end

function search_in_document_cli(state::ShellState, query::AbstractString, doc_idx::Union{Int, Nothing}=nothing)
    target_idx = doc_idx !== nothing ? doc_idx : state.selected_doc_idx
    if target_idx === nothing || isempty(state.last_hits) || target_idx < 1 || target_idx > length(state.last_hits)
        tprintln("{bold red}Primero selecciona un documento con '/doc <N>' o usa '/in <N> <consulta>'.{/bold red}\n")
        return
    end
    
    doc = state.last_hits[target_idx]
    actual_doc_id = get(doc, "doc_idx", target_idx)
    
    tprintln("{dim}Buscando párrafos en: '$(get(doc, "title", ""))'...{/dim}")
    res = search_document_paragraphs(state.engine, actual_doc_id, query; top=5)
    
    if haskey(res, "error")
        tprintln("{bold red}$(res["error"]){/bold red}\n")
        return
    end
    
    hits = get(res, "hits", [])
    if isempty(hits)
        tprintln("{yellow}No se encontraron párrafos en este documento que coincidan con '$query'.{/yellow}\n")
        return
    end
    
    tprintln("\n{bold green}✓{/bold green} Encontrados {bold bright_cyan}$(length(hits)) párrafos relevantes{/bold bright_cyan} para \"{bold bright_white}$query{/bold bright_white}\" dentro del documento:\n")
    
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
            padding=(1, 1, 0, 0),
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p_card)
    end
    println()
end

function render_search_results(state::ShellState, res::Dict)
    hits = get(res, "hits", [])
    state.last_hits = hits
    state.selected_doc_idx = !isempty(hits) ? 1 : nothing
    
    # 1. Wikipedia summary card if present
    if haskey(res, "wiki_concept") && res["wiki_concept"] !== nothing
        w = res["wiki_concept"]
        wiki_content = """
{bold bright_white}$(w["title"]){/bold bright_white} {dim}(Wikipedia $(uppercase(w["lang"])) - Concepto Simplificado){/dim}

$(w["extract"])

🔗 {italic blue}$(w["url"]){/italic blue}
"""
        p_wiki = Panel(
            wiki_content,
            title="💡 Explicación de Concepto (Wikipedia)",
            style="magenta",
            box=:ROUNDED,
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(p_wiki)
    end
    
    # 2. Results header
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
    
    # 3. Render result cards
    for (i, h) in enumerate(hits)
        title = get(h, "title", "Sin título")
        repo = get(h, "repo", "")
        creator = get(h, "creator", "")
        date = get(h, "date", "")
        dtype = get(h, "type", "Doc")
        score = get(h, "score", 0.0)
        snippet = get(h, "snippet", "")
        has_file = get(h, "file", nothing) !== nothing
        has_text = get(h, "has_fulltext", false)
        ref_cnt = get(h, "reference_count", 0)
        
        meta_line = "{cyan}🏛️  $repo{/cyan} | {yellow}📑 $dtype{/yellow}"
        !isempty(date) && (meta_line *= " | {dim}📅 $(first(date, min(10, length(date)))){/dim}")
        !isempty(creator) && (meta_line *= " | {dim}👤 $(first(creator, min(40, length(creator)))){/dim}")
        meta_line *= " | {green}Score: $(round(score, digits=1)){/green}"
        ref_cnt > 0 && (meta_line *= " | {cyan}📚 $ref_cnt refs{/cyan}")
        has_text && (meta_line *= " | {bold bright_green}🔍 Texto{/bold bright_green}")
        has_file && (meta_line *= " | {bold magenta}📄 PDF{/bold magenta}")
        
        card_content = """
{bold bright_white}$title{/bold bright_white}
$meta_line

$snippet
"""
        card = Panel(
            card_content,
            title="[#$i]",
            title_style="bold bright_blue",
            style="blue",
            box=:SQUARE,
            padding=(1, 1, 0, 0),
            width=min(100, displaysize(stdout)[2] - 4)
        )
        println(card)
    end
    
    tprintln("{dim}Tip: Escribe '/doc <N>' para abrir la ficha, '/refs' para ver bibliografía o '/find <tema>' para buscar en el texto.{/dim}\n")
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

Processes a single command line in the interactive shell. Returns `false` if exiting, `true` otherwise.
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
    elseif startswith(input, "/info")
        parts = split(input; limit=2)
        if length(parts) >= 2 && !isempty(strip(parts[2]))
            show_info_command(state, strip(parts[2]))
        else
            show_info_command(state, nothing)
        end
    elseif startswith(input, "/topic-authors") || startswith(input, "/author-topic")
        parts = split(input; limit=2)
        if length(parts) >= 2
            show_topic_authors(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /topic-authors <campo del conocimiento o tema>{/bold red}\n")
        end
    elseif startswith(input, "/sim-authors") || startswith(input, "/author-sim")
        parts = split(input; limit=2)
        if length(parts) >= 2
            show_similar_authors(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /sim-authors <nombre del autor>{/bold red}\n")
        end
    elseif startswith(input, "/author")
        parts = split(input; limit=2)
        if length(parts) >= 2
            show_author_profile(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /author <nombre_investigador>{/bold red}\n")
        end
    elseif startswith(input, "/cited")
        parts = split(input; limit=2)
        if length(parts) >= 2
            show_cited_references(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /cited <autor_o_publicacion_citada>{/bold red}\n")
        end
    elseif startswith(input, "/refs")
        parts = split(input)
        if length(parts) >= 2
            idx = tryparse(Int, parts[2])
            show_document_references_cli(state, idx)
        else
            show_document_references_cli(state, state.selected_doc_idx)
        end
    elseif startswith(input, "/find")
        parts = split(input; limit=2)
        if length(parts) >= 2
            search_in_document_cli(state, strip(parts[2]))
        else
            tprintln("{bold red}Uso: /find <consulta_dentro_del_documento>{/bold red}\n")
        end
    elseif startswith(input, "/in")
        parts = split(input; limit=3)
        if length(parts) >= 3
            idx = tryparse(Int, parts[2])
            if idx !== nothing
                search_in_document_cli(state, strip(parts[3]), idx)
            else
                tprintln("{bold red}Uso: /in <doc_num> <consulta>{/bold red}\n")
            end
        else
            tprintln("{bold red}Uso: /in <doc_num> <consulta>{/bold red}\n")
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
    elseif startswith(input, "/wiki")
        parts = split(input)
        if length(parts) >= 2
            opt = lowercase(parts[2])
            state.include_wiki = opt in ("on", "1", "true", "si", "sí")
            status_str = state.include_wiki ? "activadas" : "desactivadas"
            tprintln("{bold green}Explicaciones de Wikipedia $status_str.{/bold green}\n")
        else
            state.include_wiki = !state.include_wiki
            status_str = state.include_wiki ? "activadas" : "desactivadas"
            tprintln("{bold green}Explicaciones de Wikipedia $status_str.{/bold green}\n")
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
    elseif startswith(input, "/explain")
        parts = split(input; limit=2)
        if length(parts) >= 2
            concept = parts[2]
            tprintln("{dim}Consultando Wikipedia para '$concept'...{/dim}")
            info = explain_concept(concept)
            if info !== nothing
                wiki_content = """
{bold bright_white}$(info["title"]){/bold bright_white} {dim}(Wikipedia $(uppercase(info["lang"]))){/dim}

$(info["extract"])

🔗 {italic blue}$(info["url"]){/italic blue}
"""
                println(Panel(wiki_content, title="💡 Concepto Wikipedia", style="magenta", box=:ROUNDED))
            else
                tprintln("{yellow}No se encontró resumen en Wikipedia para '$concept'.{/yellow}\n")
            end
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

Launches the interactive Term.jl search shell with full multi-corpus, citations, help system and command history.
"""
function launch_interactive_shell(; data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
    tprintln("{bold cyan}Cargando índices de búsqueda en memoria...{/bold cyan}")
    engine = SearchEngine(; index_dir)
    
    if engine.invfile === nothing
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
        nothing,  # selected_doc_idx
        data_dir,
        index_dir
    )
    
    render_banner(state)
    
    get_prompt_str = function()
        repo_badge = state.active_repo === nothing ? "todos" : state.active_repo
        type_badge = state.active_type !== nothing ? " | $(state.active_type)" : ""
        tag_badge = state.active_keyword !== nothing ? " | tag:$(state.active_keyword)" : ""
        return "reposmx [$repo_badge$type_badge$tag_badge | top:$(state.top_k)]> "
    end
    
    # Check if stdin is a TTY terminal with interactive line-editing support
    if isa(stdin, Base.TTY)
        try
            term = REPL.Terminals.TTYTerminal(get(ENV, "TERM", "xterm-256color"), stdin, stdout, stderr)
            repl = REPL.LineEditREPL(term, true)
            mirepl = REPL.setup_interface(repl)
            main_mode = mirepl.modes[1]
            main_mode.prompt = get_prompt_str
            main_mode.prompt_prefix = "\e[1;34m"
            main_mode.prompt_suffix = "\e[0m"
            
            # Setup persistent history
            main_mode.hist.file_path = HISTORY_FILE
            
            main_mode.on_done = (s, buf, ok) -> begin
                if !ok
                    return LineEdit.transition(s, :abort)
                end
                line = String(take!(buf))
                clean_line = strip(line)
                if !isempty(clean_line)
                    append_history(clean_line)
                end
                keep_running = process_shell_input(state, clean_line)
                if keep_running
                    return LineEdit.transition(s, main_mode)
                else
                    return LineEdit.transition(s, :abort)
                end
            end
            
            LineEdit.run_interface(term, mirepl)
            return
        catch err
            # Graceful fallback to standard reader loop
        end
    end
    
    # Fallback standard loop
    while true
        prompt = Term.apply_style("{bold bright_blue}$(get_prompt_str()){/bold bright_blue}")
        print(prompt)
        flush(stdout)
        
        line = readline(stdin)
        line === nothing && break
        input = strip(line)
        isempty(input) && continue
        
        append_history(input)
        keep_running = process_shell_input(state, input)
        !keep_running && break
    end
end

end # module TUI
