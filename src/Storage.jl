module Storage

using JSON, Dates
using ..Config: DEFAULT_DATA_DIR, get_repositories

export get_repo_dir, get_repo_info, save_repo_info, list_repo_names,
       load_metadata_records, save_metadata_records, append_metadata_record,
       load_corpus_records, save_corpus_records, get_repo_stats

"""
    get_repo_dir(reponame; data_dir=DEFAULT_DATA_DIR)

Returns the absolute path to a repository directory.
"""
function get_repo_dir(reponame::AbstractString; data_dir=DEFAULT_DATA_DIR)
    return joinpath(data_dir, reponame)
end

"""
    list_repo_names(; data_dir=DEFAULT_DATA_DIR)

Lists all repository names present in the data directory.
"""
function list_repo_names(; data_dir=DEFAULT_DATA_DIR)
    isdir(data_dir) || return String[]
    return filter(d -> isdir(joinpath(data_dir, d)) && !startswith(d, "."), readdir(data_dir))
end

"""
    get_repo_info(reponame; data_dir=DEFAULT_DATA_DIR)

Reads `info.json` for a repository.
"""
function get_repo_info(reponame::AbstractString; data_dir=DEFAULT_DATA_DIR)
    info_file = joinpath(get_repo_dir(reponame; data_dir), "info.json")
    if isfile(info_file)
        return try
            open(JSON.parse, info_file)
        catch
            Dict{String, Any}()
        end
    else
        return Dict{String, Any}("repo" => reponame, "total_records" => 0, "last_harvest" => nothing)
    end
end

"""
    save_repo_info(reponame, info::Dict; data_dir=DEFAULT_DATA_DIR)

Saves `info.json` for a repository.
"""
function save_repo_info(reponame::AbstractString, info::Dict; data_dir=DEFAULT_DATA_DIR)
    rdir = get_repo_dir(reponame; data_dir)
    mkpath(rdir)
    info_file = joinpath(rdir, "info.json")
    open(info_file, "w") do f
        println(f, JSON.json(info, 2))
    end
end

"""
    load_metadata_records(reponame; data_dir=DEFAULT_DATA_DIR)

Loads all raw metadata records from `metadata.jsonl` as an array of Dicts.
"""
function load_metadata_records(reponame::AbstractString; data_dir=DEFAULT_DATA_DIR)
    path = joinpath(get_repo_dir(reponame; data_dir), "metadata.jsonl")
    isfile(path) || return Dict{String, Any}[]
    records = Dict{String, Any}[]
    for line in eachline(path)
        isempty(strip(line)) && continue
        try
            push!(records, JSON.parse(line))
        catch
        end
    end
    return records
end

"""
    save_metadata_records(reponame, records::Vector{<:Dict}; data_dir=DEFAULT_DATA_DIR)

Saves an array of metadata records to `metadata.jsonl`.
"""
function save_metadata_records(reponame::AbstractString, records::Vector{<:Dict}; data_dir=DEFAULT_DATA_DIR)
    rdir = get_repo_dir(reponame; data_dir)
    mkpath(rdir)
    path = joinpath(rdir, "metadata.jsonl")
    open(path, "w") do f
        for r in records
            println(f, JSON.json(r))
        end
    end
end

"""
    load_corpus_records(reponame; data_dir=DEFAULT_DATA_DIR)

Loads structured corpus records from `corpus.jsonl`.
"""
function load_corpus_records(reponame::AbstractString; data_dir=DEFAULT_DATA_DIR)
    path = joinpath(get_repo_dir(reponame; data_dir), "corpus.jsonl")
    isfile(path) || return Dict{String, Any}[]
    records = Dict{String, Any}[]
    for line in eachline(path)
        isempty(strip(line)) && continue
        try
            push!(records, JSON.parse(line))
        catch
        end
    end
    return records
end

"""
    save_corpus_records(reponame, records::Vector{<:Dict}; data_dir=DEFAULT_DATA_DIR)

Saves structured corpus records to `corpus.jsonl`.
"""
function save_corpus_records(reponame::AbstractString, records::Vector{<:Dict}; data_dir=DEFAULT_DATA_DIR)
    rdir = get_repo_dir(reponame; data_dir)
    mkpath(rdir)
    path = joinpath(rdir, "corpus.jsonl")
    open(path, "w") do f
        for r in records
            println(f, JSON.json(r))
        end
    end
end

"""
    get_repo_stats(; data_dir=DEFAULT_DATA_DIR)

Computes statistics across all repositories in `data_dir`.
"""
function get_repo_stats(; data_dir=DEFAULT_DATA_DIR)
    repos = list_repo_names(; data_dir)
    stats = []
    total_records = 0
    total_with_files = 0
    total_with_corpus = 0

    for r in repos
        rdir = get_repo_dir(r; data_dir)
        info = get_repo_info(r; data_dir)
        meta_file = joinpath(rdir, "metadata.jsonl")
        corpus_file = joinpath(rdir, "corpus.jsonl")
        
        n_records = isfile(meta_file) ? countlines(meta_file) : 0
        n_corpus = isfile(corpus_file) ? countlines(corpus_file) : 0
        
        files_dir = joinpath(rdir, "files")
        n_files = isdir(files_dir) ? length(readdir(files_dir)) : 0
        
        total_records += n_records
        total_with_files += n_files
        total_with_corpus += n_corpus

        push!(stats, Dict(
            "repo" => r,
            "total_records" => n_records,
            "files_downloaded" => n_files,
            "corpus_records" => n_corpus,
            "last_harvest" => get(info, "last_harvest", nothing)
        ))
    end
    
    return Dict(
        "repos" => stats,
        "summary" => Dict(
            "total_repos" => length(repos),
            "total_records" => total_records,
            "total_files" => total_with_files,
            "total_corpus" => total_with_corpus
        )
    )
end

end # module Storage
