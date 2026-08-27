module Config

using JSON

export DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR, DEFAULT_HEADERS, DEFAULT_OAI_NS, get_repositories, get_repository_url

const DEFAULT_DATA_DIR = let
    if haskey(ENV, "REPOSMX_DATA_DIR") && !isempty(ENV["REPOSMX_DATA_DIR"])
        abspath(ENV["REPOSMX_DATA_DIR"])
    else
        pkg = pkgdir(@__MODULE__)
        if pkg !== nothing && isdir(joinpath(pkg, "data", "repos"))
            normpath(joinpath(pkg, "data", "repos"))
        elseif isdir(joinpath(pwd(), "data", "repos"))
            abspath(joinpath(pwd(), "data", "repos"))
        else
            normpath(joinpath(homedir(), ".reposmx", "data", "repos"))
        end
    end
end

const DEFAULT_INDEX_DIR = let
    if haskey(ENV, "REPOSMX_INDEX_DIR") && !isempty(ENV["REPOSMX_INDEX_DIR"])
        abspath(ENV["REPOSMX_INDEX_DIR"])
    else
        pkg = pkgdir(@__MODULE__)
        if pkg !== nothing && isdir(joinpath(pkg, "data", "index"))
            normpath(joinpath(pkg, "data", "index"))
        elseif isdir(joinpath(pwd(), "data", "index"))
            abspath(joinpath(pwd(), "data", "index"))
        else
            normpath(joinpath(homedir(), ".reposmx", "data", "index"))
        end
    end
end

const DEFAULT_REPOS_JSON = let
    if haskey(ENV, "REPOSMX_CONFIG") && !isempty(ENV["REPOSMX_CONFIG"])
        abspath(ENV["REPOSMX_CONFIG"])
    else
        pkg = pkgdir(@__MODULE__)
        if pkg !== nothing && isfile(joinpath(pkg, "repos.json"))
            normpath(joinpath(pkg, "repos.json"))
        elseif isfile(joinpath(pwd(), "repos.json"))
            abspath(joinpath(pwd(), "repos.json"))
        else
            normpath(joinpath(homedir(), ".reposmx", "repos.json"))
        end
    end
end

const DEFAULT_HEADERS = Dict(
    "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

const DEFAULT_OAI_NS = [
    "oai" => "http://www.openarchives.org/OAI/2.0/",
    "dc" => "http://www.openarchives.org/OAI/2.0/oai_dc/",
    "purl" => "http://purl.org/dc/elements/1.1/"
]

"""
    get_repositories(; config_file=DEFAULT_REPOS_JSON)

Loads the dictionary of repository names and their OAI-PMH endpoints.
"""
function get_repositories(; config_file=DEFAULT_REPOS_JSON)
    if isfile(config_file)
        return open(JSON.parse, config_file)
    else
        return Dict{String,String}()
    end
end

"""
    get_repository_url(reponame; config_file=DEFAULT_REPOS_JSON)

Gets the endpoint URL for a specific repository.
"""
function get_repository_url(reponame::AbstractString; config_file=DEFAULT_REPOS_JSON)
    repos = get_repositories(; config_file)
    return get(repos, String(reponame), nothing)
end

end # module Config
