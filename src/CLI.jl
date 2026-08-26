module CLI

using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR, get_repositories
using ..Storage: get_repo_stats, list_repo_names
using ..OAI: harvest_all, harvest_repository
using ..Downloader: download_all_files, download_repository_files
using ..Parser: parse_all_documents, parse_repository_documents
using ..Corpus: build_all_corpus, build_repository_corpus
using ..Indexing: build_search_index
using ..DB: open_database, close_database, ingest_all_to_db!, get_stats, scan_facet
using ..Search: SearchEngine, query_index, get_detailed_statistics
using ..Server: start_server
using ..TUI: launch_interactive_shell
using ..Wikipedia: explain_concept

export main_cli

function print_usage()
    println("""
ReposMx - Repositorios Institucionales de México CLI (Julia 1.12)

USO:
  reposmx [subcomando] [opciones] [repositorios...]

MODO INTERACTIVO:
  reposmx                    Inicia el shell de búsqueda interactiva (Term.jl TUI)
  reposmx shell              Inicia el shell interactivo explícitamente

SUBCOMANDOS PRINCIPALES DE FLUJO:
  update-db [repos...]       1. Cosecha OAI-PMH + 2. Descarga PDFs + 3. Extrae texto
  prepare-index [repos...]   Toma lo no indexado, construye corpus y genera índices bilingües
  populate-db [repos...]     Puebla la base de datos embebida RocksDB (Documentos, Autores, Citas, Facetas)
  update-all [repos...]      Ejecuta 'update-db' seguido de 'prepare-index' (todo-en-uno)
  serve [--port N]           Lanza el servidor HTTP y la interfaz web interactiva

SUBCOMANDOS INDIVIDUALES:
  harvest [repos...]         Cosecha metadatos vía OAI-PMH (incremental)
  download [repos...]        Descarga documentos (PDFs/DOCs) enlazados
  parse [repos...]           Extrae texto estructurado desde los PDFs/documentos
  build-corpus [repos...]    Genera 'corpus.jsonl' fusionando metadatos y texto
  index [repos...]           Construye el índice de búsqueda léxico y semántico
  search "<query>"           Busca directamente en la terminal (BM25 + Wikipedia)
  info [repo]                Estadísticas detalladas de publicaciones, disciplinas y autores
  status                     Muestra estadísticas de cobertura y estado de los repositorios
  install-cli [--bin-dir DIR] Instala el comando ejecutable 'reposmx' en ~/.julia/bin o ~/.local/bin

EJEMPLOS:
  reposmx                    # Abre el buscador interactivo rápido
  reposmx info               # Panorama global del acervo
  reposmx info cimat         # Estadísticas del CIMAT
  reposmx update-all iteso cideteq
  reposmx search "aprendizaje profundo"
  reposmx serve --port 8080
  reposmx install-cli        # Instala el comando 'reposmx' globalmente en PATH
""")
end

"""
    update_db(; repos=nothing, data_dir=DEFAULT_DATA_DIR)

Orchestrated pipeline step 1: Harvest -> Download -> Parse.
"""
function update_db(; repos=nothing, data_dir=DEFAULT_DATA_DIR)
    println("\n=======================================================")
    println("  🔄 PASO 1/3: Cosechando metadatos OAI-PMH...")
    println("=======================================================\n")
    harvest_all(; data_dir, repos, incremental=true)
    
    println("\n=======================================================")
    println("  📥 PASO 2/3: Descargando documentos (PDFs/DOCs)...")
    println("=======================================================")
    download_all_files(; data_dir, repos)
    
    println("\n=======================================================")
    println("  📄 PASO 3/3: Extrayendo texto plano estructurado...")
    println("=======================================================")
    parse_all_documents(; data_dir, repos)
    
    println("\n✅ Base de datos actualizada con éxito.")
end

"""
    prepare_index(; repos=nothing, data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)

Orchestrated pipeline step 2: Build Corpus -> Fit Bilingual TextConfig -> Index BM25 & SimilaritySearch.
"""
function prepare_index(; repos=nothing, data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
    println("\n=======================================================")
    println("  🧱 PASO 1/2: Construyendo corpus estructurado...")
    println("=======================================================")
    build_all_corpus(; data_dir, repos)
    
    println("\n=======================================================")
    println("  ⚡ PASO 2/2: Construyendo índices de búsqueda bilingüe...")
    println("=======================================================")
    build_search_index(; data_dir, index_dir, repos)
    
    println("\n✅ Índices de búsqueda generados con éxito.")
end

"""
    update_all(; repos=nothing, data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)

Orchestrated pipeline step 3: update-db -> prepare-index.
"""
function update_all(; repos=nothing, data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
    println("\n🚀 EJECUTANDO PIPELINE COMPLETO DE ACTUALIZACIÓN E INDEXACIÓN...")
    update_db(; repos, data_dir)
    prepare_index(; repos, data_dir, index_dir)
    println("\n🎉 Pipeline completado al 100%.")
end

"""
    show_status(; data_dir=DEFAULT_DATA_DIR)

Prints repository statistics table.
"""
function show_status(; data_dir=DEFAULT_DATA_DIR)
    stats = get_repo_stats(; data_dir)
    s = stats["summary"]
    
    try
        println("\n=======================================================")
        println("  📊 ESTADO DE LOS REPOSITORIOS INSTITUCIONALES (ReposMx)")
        println("=======================================================")
        println("  • Total de repositorios:       $(s["total_repos"])")
        println("  • Total de registros en DB:    $(s["total_records"])")
        println("  • Documentos (archivos) descargados: $(s["total_files"])")
        println("  • Documentos en corpus:        $(s["total_corpus"])")
        println("=======================================================\n")
        
        for r in stats["repos"]
            rname = r["repo"]
            tot = r["total_records"]
            fil = r["files_downloaded"]
            cor = r["corpus_records"]
            harv = r["last_harvest"] === nothing ? "Nunca" : first(r["last_harvest"], min(16, length(r["last_harvest"])))
            println("  $(rpad(rname, 22)) Registros: $(lpad(tot, 7)) | Archivos: $(lpad(fil, 6)) | Corpus: $(lpad(cor, 7)) | Último: $harv")
        end
    catch e
        if !(e isa Base.IOError)
            rethrow(e)
        end
    end
end

"""
    show_info_cli(repo=nothing; index_dir=DEFAULT_INDEX_DIR)

Displays rich summary statistics for global or repository level.
"""
function show_info_cli(repo=nothing; index_dir=DEFAULT_INDEX_DIR)
    engine = SearchEngine(; index_dir)
    stats = get_detailed_statistics(engine; repo)
    
    if haskey(stats, "error")
        println(stderr, "Error: ", stats["error"])
        return
    end
    
    is_global = stats["is_global"]
    header = is_global ? "PANORAMA GLOBAL DEL ACERVO ACADÉMICO NACIONAL" : "ESTADÍSTICAS DEL REPOSITORIO: $(stats["target_repo"])"
    
    println("\n=======================================================")
    println("  📊 $header")
    println("=======================================================")
    println("  • Documentos y publicaciones indexadas: $(stats["total_docs"])")
    println("  • Documentos con PDF descargado:        $(stats["total_files"])")
    println("  • Documentos con texto completo:        $(stats["total_fulltext"])")
    println("  • Citas bibliográficas extraídas:       $(stats["total_references"])")
    println("  • Rango temporal de publicaciones:      $(stats["year_min"]) — $(stats["year_max"])")
    println("=======================================================\n")
    
    println("📚 TIPOS DE PUBLICACIÓN:")
    for t in stats["types_distribution"]
        println("  • $(rpad(t["type"], 25)) $(lpad(t["count"], 6))")
    end
    
    println("\n🏷️  DISCIPLINAS Y ÁREAS DE CONOCIMIENTO PRINCIPALES:")
    for d in stats["top_disciplines"]
        println("  • $(rpad(d["discipline"], 45)) $(lpad(d["count"], 5))")
    end
    
    println("\n👤 INVESTIGADORES Y COLABORADORES PRINCIPALES:")
    for a in stats["top_authors"]
        println("  • $(rpad(a["name"], 35)) [$(a["role"])] - $(a["doc_count"]) publicaciones ($(join(a["repos"], ", ")))")
    end
    
    if is_global
        println("\n🏛️  DISTRIBUCIÓN POR REPOSITORIO:")
        for r in stats["top_repositories"]
            println("  • $(rpad(r["repo"], 25)) $(lpad(r["count"], 6)) publicaciones")
        end
    end
    println()
end

"""
    search_cli(query; top=10, repo=nothing, index_dir=DEFAULT_INDEX_DIR)

Runs interactive terminal search.
"""
function search_cli(query::AbstractString; top::Int=10, repo=nothing, index_dir=DEFAULT_INDEX_DIR)
    engine = SearchEngine(; index_dir)
    res = query_index(engine, query; top, repo, include_wiki=true)
    
    println("\n=======================================================")
    println("  🔍 RESULTADOS PARA: \"$query\" ($(res["total_hits"]) hits en $(res["time_ms"]) ms)")
    println("=======================================================")
    
    if res["wiki_concept"] !== nothing
        w = res["wiki_concept"]
        println("\n📖 Concepto Wikipedia ($(uppercase(w["lang"]))): $(w["title"])")
        println("   $(w["extract"])")
        println("   URL: $(w["url"])")
    end
    
    println("\n--- Documentos Encontrados ---")
    for (i, h) in enumerate(res["hits"])
        println("\n[$i] $(h["title"])")
        println("    🏛️  Repo: $(h["repo"]) | 📅 $(h["date"]) | 👤 $(h["creator"]) | Score: $(round(h["score"], digits=2))")
        println("    📝 $(h["snippet"])")
        if h["file"] !== nothing
            println("    📄 Archivo: $(h["file"])")
        end
    end
    println()
end

"""
    main_cli(args=ARGS)

Main entry point for command line interface.
"""
function main_cli(args=ARGS)
    if isempty(args)
        # Default action: launch the Term.jl interactive shell!
        launch_interactive_shell()
        return 0
    end

    if args[1] in ("-h", "--help", "help")
        print_usage()
        return 0
    end
    
    cmd = args[1]
    subargs = args[2:end]
    
    # Check interactive subcommands
    if cmd in ("shell", "interactive", "i", "tui")
        launch_interactive_shell()
        return 0
    end
    
    # Parse options and repos
    repos = String[]
    port = 8000
    host = "0.0.0.0"
    top = 10
    
    i = 1
    while i <= length(subargs)
        arg = subargs[i]
        if arg == "--port" && i < length(subargs)
            port = parse(Int, subargs[i+1])
            i += 2
        elseif arg == "--host" && i < length(subargs)
            host = subargs[i+1]
            i += 2
        elseif arg == "--top" && i < length(subargs)
            top = parse(Int, subargs[i+1])
            i += 2
        elseif !startswith(arg, "-")
            push!(repos, arg)
            i += 1
        else
            i += 1
        end
    end
    
    target_repos = isempty(repos) ? nothing : repos
    
    if cmd == "update-db"
        update_db(; repos=target_repos)
    elseif cmd == "prepare-index"
        prepare_index(; repos=target_repos)
    elseif cmd == "populate-db"
        db_inst = open_database()
        try
            ingest_all_to_db!(db_inst; repos=target_repos)
        finally
            close_database(db_inst)
        end
    elseif cmd == "update-all"
        update_all(; repos=target_repos)
    elseif cmd == "serve" || cmd == "server"
        start_server(; port, host)
    elseif cmd == "harvest"
        harvest_all(; repos=target_repos)
    elseif cmd == "download"
        download_all_files(; repos=target_repos)
    elseif cmd == "parse"
        parse_all_documents(; repos=target_repos)
    elseif cmd == "build-corpus"
        build_all_corpus(; repos=target_repos)
    elseif cmd == "index"
        build_search_index(; repos=target_repos)
    elseif cmd == "search"
        q = isempty(repos) ? (isempty(subargs) ? "" : subargs[1]) : join(repos, " ")
        if isempty(q)
            println(stderr, "Error: Debe especificar una consulta de búsqueda.")
        else
            search_cli(q; top)
        end
    elseif cmd == "status"
        show_status()
    elseif cmd == "info"
        target = isempty(repos) ? nothing : first(repos)
        show_info_cli(target)
    elseif cmd == "install-cli"
        bin_dir_arg = nothing
        for j in 1:length(subargs)
            if subargs[j] == "--bin-dir" && j < length(subargs)
                bin_dir_arg = subargs[j+1]
            end
        end
        target_dir = if bin_dir_arg !== nothing
            bin_dir_arg
        else
            j_bin = joinpath(homedir(), ".julia", "bin")
            l_bin = joinpath(homedir(), ".local", "bin")
            isdir(j_bin) ? j_bin : l_bin
        end
        mkpath(target_dir)
        target_file = joinpath(target_dir, "reposmx")
        script_content = """#!/usr/bin/env bash
# ReposMx Launcher
exec julia -m ReposMx "\$@"
"""
        write(target_file, script_content)
        chmod(target_file, 0o755)
        println("✅ ReposMx CLI instalado exitosamente en: $(target_file)")
        if !occursin(target_dir, get(ENV, "PATH", ""))
            println("ℹ️  Asegúrate de que '$(target_dir)' esté en tu variable de entorno PATH:")
            println("    export PATH=\"$(target_dir):\$PATH\"")
        end
    else
        println(stderr, "Subcomando desconocido: '$cmd'")
        print_usage()
        return 1
    end
    
    return 0
end

end # module CLI
