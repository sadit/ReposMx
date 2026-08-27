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
include("DB.jl")
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
using .DB
using .Search
using .Server
using .TUI
using .CLI
import Pkg

export Record, RepoInfo, SearchHit, SearchResponse, AuthorProfile, ParagraphHit, ReferenceRecord,
       DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR, get_repositories,
       get_repo_dir, get_repo_info, get_repo_stats, list_repo_names,
       load_metadata_records, load_corpus_records,
       harvest_repository, harvest_all,
       download_repository_files, download_all_files,
       extract_text_from_file, parse_repository_documents, parse_all_documents,
       build_repository_corpus, build_all_corpus,
       TextProfile, create_bilingual_profile, get_or_create_bilingual_base_profile, refit_bilingual_profile, create_bilingual_textconfig,
       get_wikipedia_summary, explain_concept,
       build_search_index, load_search_index, load_authors_index, load_references_index,
       Database, open_database, close_database, put_document!, get_document,
       get_author_documents, get_coauthors, get_document_references, get_documents_citing_author,
       scan_facet, get_documents_by_year, get_documents_by_type, get_documents_by_repo, get_documents_by_keyword,
       get_fulltext, get_paragraphs, ingest_repository_to_db!, ingest_all_to_db!,
       SearchEngine, query_index, search_authors, search_authors_by_topic, find_similar_authors_by_references,
       search_references, get_document_references, search_document_paragraphs, get_detailed_statistics,
       start_server, launch_interactive_shell, main_cli, install_cli

"""
    install_cli(; dev::Bool=true)

Registers and installs the `reposmx` executable application into `~/.julia/bin`
via official Julia Pkg.Apps specification.
"""
function install_cli(; dev::Bool=true)
    pkg_dir = dirname(@__DIR__)
    if dev
        Pkg.Apps.develop(path=pkg_dir)
    else
        Pkg.Apps.add(path=pkg_dir)
    end
    j_bin = joinpath(homedir(), ".julia", "bin")
    println("✅ ReposMx instalado como Julia App en: $(joinpath(j_bin, "reposmx"))")
    if !occursin(j_bin, get(ENV, "PATH", ""))
        println("ℹ️  Asegúrate de que '$(j_bin)' esté en tu variable de entorno PATH:")
        println("    export PATH=\"$(j_bin):\$PATH\"")
    end
    return joinpath(j_bin, "reposmx")
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
