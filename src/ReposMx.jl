module ReposMx

include("Types.jl")
include("Config.jl")
include("Storage.jl")
include("OAI.jl")
include("Downloader.jl")
include("Parser.jl")
include("Corpus.jl")
include("TextModel.jl")
include("Wikipedia.jl")
include("Indexing.jl")
include("Search.jl")
include("Server.jl")
include("TUI.jl")
include("CLI.jl")

using .Types
using .Config
using .Storage
using .OAI
using .Downloader
using .Parser
using .Corpus
using .TextModel
using .Wikipedia
using .Indexing
using .Search
using .Server
using .TUI
using .CLI

export Record, RepoInfo, SearchHit, SearchResponse, AuthorProfile, ParagraphHit, ReferenceRecord,
       DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR, get_repositories,
       get_repo_dir, get_repo_info, get_repo_stats, list_repo_names,
       load_metadata_records, load_corpus_records,
       harvest_repository, harvest_all,
       download_repository_files, download_all_files,
       extract_text_from_file, parse_repository_documents, parse_all_documents,
       build_repository_corpus, build_all_corpus,
       create_bilingual_textconfig, sample_bilingual_corpus, fit_bilingual_bm25,
       get_wikipedia_summary, explain_concept,
       build_search_index, load_search_index, load_authors_index, load_references_index,
       SearchEngine, query_index, search_authors, search_references, get_document_references, search_document_paragraphs, get_detailed_statistics,
       start_server, launch_interactive_shell, main_cli, install_cli

"""
    install_cli(; bin_dir=nothing)

Installs the `reposmx` executable wrapper script into `~/.julia/bin` (or `~/.local/bin`),
making `reposmx` available directly in the user's terminal.
"""
function install_cli(; bin_dir::Union{String, Nothing}=nothing)
    target_dir = if bin_dir !== nothing
        bin_dir
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
    return target_file
end

"""
    main(args=ARGS)

Entry point for the ReposMx executable application.
Enables direct invocation via `julia -m ReposMx [subcommand] [options...]`
"""
function main(args::Vector{String}=ARGS)::Cint
    try
        main_cli(args)
        return 0
    catch e
        if !(e isa InterruptException)
            showerror(stderr, e, catch_backtrace())
            println(stderr)
        end
        return 1
    end
end
@main

end # module ReposMx
