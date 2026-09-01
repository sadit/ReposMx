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
include("DB.jl")
include("VocabIO.jl")
include("IndexShellIO.jl")
include("LazyBM25.jl")
include("AuthorConsolidation.jl")
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
using .DB
using .VocabIO
using .IndexShellIO
using .LazyBM25
using .AuthorConsolidation
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
       TextProfile, create_bilingual_profile, get_or_create_bilingual_base_profile, refit_bilingual_profile, create_bilingual_textconfig,
       get_wikipedia_summary, explain_concept,
       build_search_index, rebuild_authors_index, load_docs_content_index, load_docs_refs_index, load_authors_name_index, load_authors_profile_index,
       Database, open_database, close_database, put_document!, get_document,
       put_author_profile!, get_author_profile, get_author_documents, get_coauthors, normalize_author_name,
       put_reference!, get_reference, get_document_references, get_documents_citing_author,
       put_topics!, get_topic_docs, get_topic_authors, intersect_topic_repo_docs, intersect_topic_repo_authors,
       get_fulltext, get_paragraphs, ingest_repository_to_db!, ingest_all_to_db!,
       SearchEngine, query_index, search_authors, find_similar_authors_by_profile, find_similar_documents_by_references,
       search_references, search_document_paragraphs, get_detailed_statistics, get_topic_elements, get_author_network,
       start_server, launch_interactive_shell, main_cli

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
