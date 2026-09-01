module AuthorConsolidation

using TextSearch
using TOML
using JSON
using SHA
using ..Config: DEFAULT_AUTHOR_OVERRIDES_JSON

export build_and_persist, load_all, name_keys, compute_groups, load_overrides

"""
    AUTHOR_NAME_CONFIG

Shared with `Indexing.jl`'s `authors_name` index — same tokenization must be used for clustering
(this module) and for indexing, or the two would disagree on what counts as the same token.
"""
const AUTHOR_NAME_CONFIG = TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])

const CONSOLIDATED_SUBDIR = "authors_consolidated"

"""
    _order_normalize(s) -> String

Same "Apellido, Nombre" -> "Nombre Apellido" swap as `DB.normalize_author_name` (duplicated, not
imported: `Corpus.jl`/this module load before `DB.jl` in `ReposMx.jl`'s include order, and this is
five lines of pure string logic with no reason to fight that order for).
"""
function _order_normalize(s::AbstractString)
    s = strip(s)
    if occursin(",", s)
        parts = split(s, ","; limit=2)
        if length(parts) == 2 && !isempty(strip(parts[1])) && !isempty(strip(parts[2]))
            s = strip(parts[2]) * " " * strip(parts[1])
        end
    end
    return s
end

"""
    name_keys(raw::AbstractString) -> (full_key, initials_key, initials_text)

Two matching keys for `raw`, both computed from the same order-normalized, tokenized
(`AUTHOR_NAME_CONFIG`: accents stripped, lowercased, punctuation removed) name:

- `full_key`: every token, in order, joined by `_` — matches only near-exact name variants.
- `initials_key` / `initials_text`: every token except the last reduced to its first letter, last
  token (assumed surname) kept whole — matches "Juan García" with "J. García". `initials_key` is
  underscore-joined (for hashing/comparison); `initials_text` is space-joined (for display and for
  the extra text appended to the indexed `authors_name` document).

Two raw names sharing either key are assumed to be the same person by [`compute_groups`](@ref).
"""
function name_keys(raw::AbstractString)
    toks = String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(raw))))
    isempty(toks) && return (full_key="", initials_key="", initials_text="")
    full_key = join(toks, "_")
    initials_toks = length(toks) == 1 ? toks : vcat([string(first(t)) for t in toks[1:end-1]], [toks[end]])
    return (full_key=full_key, initials_key=join(initials_toks, "_"), initials_text=join(initials_toks, " "))
end

"""
    load_overrides(path=DEFAULT_AUTHOR_OVERRIDES_JSON) -> (; merges, splits)

Reads the human-curated consolidation overrides. Missing file = no overrides (not an error) so a
fresh checkout with no `author_overrides.json` still works.
"""
function load_overrides(path::AbstractString=DEFAULT_AUTHOR_OVERRIDES_JSON)
    merges = Vector{Vector{String}}()
    splits = Vector{Tuple{String,String}}()
    if isfile(path)
        d = JSON.parsefile(path)
        for g in get(d, "merge", [])
            length(g) >= 2 && push!(merges, String.(collect(g)))
        end
        for p in get(d, "split", [])
            length(p) == 2 && push!(splits, (String(p[1]), String(p[2])))
        end
    end
    return (; merges, splits)
end

"""
    compute_groups(raw_names::Vector{String}, overrides) -> Vector{Vector{String}}

Connected components of the graph whose nodes are `raw_names` and whose edges are: same
`full_key`, same `initials_key`, or an explicit `merge` pair — minus any explicit `split` pair.
Plain BFS over an adjacency `Dict`, no graph library needed.
"""
function compute_groups(raw_names::Vector{String}, overrides)
    adj = Dict{String,Vector{String}}(n => String[] for n in raw_names)

    connect!(a, b) = begin
        a == b && return
        push!(adj[a], b)
        push!(adj[b], a)
    end

    by_full = Dict{String,Vector{String}}()
    by_init = Dict{String,Vector{String}}()
    for n in raw_names
        k = name_keys(n)
        isempty(k.full_key) || push!(get!(by_full, k.full_key, String[]), n)
        isempty(k.initials_key) || push!(get!(by_init, k.initials_key, String[]), n)
    end
    for bucket in (by_full, by_init)
        for (_, group) in bucket
            for i in 1:length(group), j in (i+1):length(group)
                connect!(group[i], group[j])
            end
        end
    end
    for g in overrides.merges
        present = filter(n -> haskey(adj, n), g)
        for i in 1:length(present), j in (i+1):length(present)
            connect!(present[i], present[j])
        end
    end

    excluded = Set{Tuple{String,String}}()
    for (a, b) in overrides.splits
        push!(excluded, (a, b))
        push!(excluded, (b, a))
    end
    if !isempty(excluded)
        for n in keys(adj)
            adj[n] = filter(m -> !((n, m) in excluded), adj[n])
        end
    end

    visited = Set{String}()
    groups = Vector{Vector{String}}()
    for n in raw_names
        n in visited && continue
        comp = String[]
        queue = [n]
        push!(visited, n)
        while !isempty(queue)
            cur = popfirst!(queue)
            push!(comp, cur)
            for m in adj[cur]
                if !(m in visited)
                    push!(visited, m)
                    push!(queue, m)
                end
            end
        end
        push!(groups, comp)
    end
    return groups
end

"""
    rollup(raw_names_in_group, by_name) -> Dict{String,Any}

Combines the raw author profiles (`by_name[raw]` for each `raw` in the group, as produced by
`Corpus.build_authors_index_data`) into one consolidated profile — sums, unions, and a stable id.
Nothing here is written by hand; it's entirely computed from the raw profiles.
"""
function rollup(raw_names_in_group::Vector{String}, by_name::AbstractDict)
    entries = [by_name[n] for n in raw_names_in_group]
    sorted_raw = sort(raw_names_in_group)
    consolidated_id = bytes2hex(sha256(join(sorted_raw, "|")))[1:16]
    canonical_entry = entries[argmax([e["doc_count"] for e in entries])]
    canonical = canonical_entry["name"]
    k = name_keys(canonical)

    cap(v, n) = first(v, min(n, length(v)))

    Dict{String,Any}(
        "consolidated_id" => consolidated_id,
        "name" => canonical,
        "name_initials_form" => k.initials_text,
        "role" => get(canonical_entry, "role", "Autor"),
        "raw_names" => sorted_raw,
        "doc_count" => sum(e["doc_count"] for e in entries),
        "doc_ids" => unique(vcat([collect(get(e, "doc_ids", String[])) for e in entries]...)),
        "institutions" => sort(unique(vcat([collect(get(e, "institutions", String[])) for e in entries]...))),
        "keywords" => cap(unique(vcat([collect(get(e, "keywords", String[])) for e in entries]...)), 40),
        "repos" => sort(unique(vcat([collect(get(e, "repos", String[])) for e in entries]...))),
        "coauthors" => cap(unique(vcat([collect(get(e, "coauthors", String[])) for e in entries]...)), 15),
        "topic_texts" => cap(unique(vcat([collect(get(e, "topic_texts", String[])) for e in entries]...)), 10),
        "cited_references" => cap(unique(vcat([collect(get(e, "cited_references", String[])) for e in entries]...)), 30),
    )
end

function _bucket_for(raw_names_in_group::Vector{String})
    first_raw = sort(raw_names_in_group)[1]
    toks = String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(first_raw))))
    isempty(toks) ? "misc" : toks[end]
end

"""
    build_and_persist(authors_data, index_dir; overrides_path=DEFAULT_AUTHOR_OVERRIDES_JSON) -> Int

Clusters `authors_data` (raw profiles, as returned by `Corpus.build_authors_index_data`) into
consolidated profiles and writes one `.toml` file per group under
`<index_dir>/authors_consolidated/<apellido_bucket>/<consolidated_id>.toml` — see this module's
docs for why TOML, and why the bucket directory is purely organizational (2 levels: the
consolidated-authors directory itself, then the bucket). Wipes and rewrites the whole directory
each call, since group membership/ids can change between rebuilds. Returns the number of groups
written.
"""
function build_and_persist(authors_data::Vector{<:AbstractDict}, index_dir::AbstractString;
                            overrides_path::AbstractString=DEFAULT_AUTHOR_OVERRIDES_JSON)
    by_name = Dict{String,Any}(a["name"] => a for a in authors_data)
    raw_names = collect(keys(by_name))
    overrides = load_overrides(overrides_path)
    groups = compute_groups(raw_names, overrides)

    base_dir = joinpath(index_dir, CONSOLIDATED_SUBDIR)
    isdir(base_dir) && rm(base_dir; recursive=true, force=true)
    mkpath(base_dir)

    for g in groups
        profile = rollup(g, by_name)
        dir = joinpath(base_dir, _bucket_for(g))
        mkpath(dir)
        open(joinpath(dir, "$(profile["consolidated_id"]).toml"), "w") do io
            TOML.print(io, profile)
        end
    end
    return length(groups)
end

"""
    load_all(index_dir::AbstractString) -> Vector{Dict{String,Any}}

Reads back every consolidated profile written by [`build_and_persist`](@ref). Walks the whole
`authors_consolidated` subtree (`walkdir`, not a fixed-depth glob) so a future change to the
bucketing scheme in `_bucket_for` can't silently drop profiles from the index.
"""
function load_all(index_dir::AbstractString)
    base_dir = joinpath(index_dir, CONSOLIDATED_SUBDIR)
    isdir(base_dir) || return Dict{String,Any}[]
    profiles = Dict{String,Any}[]
    for (root, _, files) in walkdir(base_dir)
        for f in files
            endswith(f, ".toml") || continue
            push!(profiles, TOML.parsefile(joinpath(root, f)))
        end
    end
    return profiles
end

end # module AuthorConsolidation
