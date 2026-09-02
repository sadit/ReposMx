module AuthorConsolidation

using TextSearch
using SimilaritySearch: SearchGraph, SearchGraphContext, VectorDatabase, index!,
                        bichromatic_metricjoin, Dist
using TOML
using JSON
using SHA
using ..Config: DEFAULT_AUTHOR_OVERRIDES_JSON

export build_and_persist, load_all, name_keys, compute_groups, load_overrides, assign_raw_ids,
       assign_id, compute_similarity_merges

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
    _surname_of_name(raw::AbstractString) -> String

Last tokenized word of `raw` (order-normalized, same `AUTHOR_NAME_CONFIG` tokenization as
[`name_keys`](@ref)) — the "apellido" convention already implicit in `initials_key`, factored
out here since both [`_bucket_for`](@ref) (one name) and [`compute_similarity_merges`](@ref)
(pairs of names) need it.
"""
function _surname_of_name(raw::AbstractString)
    toks = String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(raw))))
    isempty(toks) ? "" : toks[end]
end

"""
    _strip_parenthetical(s::AbstractString) -> String

Removes any "(...)" span. A citation-style raw name like `"Anaya, A. (Alejandro)"` redundantly
spells out the abbreviated given name in parentheses — left in, `"(Alejandro)"` tokenizes into
its own given-name token, making a genuine match (`"Alejandro Anaya"`) look like it has a
different number of given-name components than the abbreviated form. Stripped before tokenizing
in [`_name_tokens`](@ref) so both forms reduce to the same given-name token.
"""
_strip_parenthetical(s::AbstractString) = replace(s, r"\([^)]*\)" => "")

"""
    _name_tokens(raw::AbstractString) -> (given::Vector{String}, surname::String)

`raw`, order-normalized and parenthetical-stripped, tokenized (same `AUTHOR_NAME_CONFIG` as
[`name_keys`](@ref)) and split into given-name tokens (all but the last) and surname (the last
one, matching [`_surname_of_name`](@ref)/`initials_key`'s "apellido" convention).
"""
function _name_tokens(raw::AbstractString)
    toks = String.(collect(tokenize(AUTHOR_NAME_CONFIG, _order_normalize(_strip_parenthetical(raw)))))
    isempty(toks) && return (String[], "")
    return (toks[1:end-1], toks[end])
end

"""
    _given_name_token_compatible(a, b) -> Bool

Two given-name tokens are compatible if they're equal, or if one is a single-character initial
matching the other's first letter (e.g. `"j"` / `"juan"`) — but NOT merely sharing a first
letter (`"juan"` vs `"julio"` is `false`): that distinction is exactly what separates a real name
abbreviation from two different people who happen to start with the same letter.
"""
function _given_name_token_compatible(a::AbstractString, b::AbstractString)
    a == b && return true
    (length(a) == 1 && !isempty(b) && a[1] == first(b)) && return true
    (length(b) == 1 && !isempty(a) && b[1] == first(a)) && return true
    return false
end

"""
    _plausibly_same_person(name_a, name_b) -> Bool

Name-based gate for [`compute_similarity_merges`](@ref): requires the surname (last token) to
match exactly, and the **first given-name token** to be equal or an initial-abbreviation of the
other's (see [`_given_name_token_compatible`](@ref)) — deliberately does not require every
given-name token to match, since middle names are routinely dropped or added between how the
same person's name appears in different raw records (e.g. `"Jewel Todd"` vs
`"JEWEL NICOLE ANNA TODD"`).

Two weaker gates were tried and rejected empirically, on a real 10-repo rebuild, before landing
on this one:
- **surname alone**: let through pairs like `("A. Alberto R. Fernandes", "PATRICIA FERNANDES")`
  and `("ADDY LETICIA ZARZA GARCIA", "Jesús Ortega García")` — different people sharing only a
  common (often maternal, in the "Nombre ApellidoPaterno ApellidoMaterno" convention the
  last-token rule picks up) surname.
- **surname + bare first-letter-of-first-token**: still let through clusters of clearly
  different people sharing a common surname (Pérez, González, Hernández...) and a coincidental
  first initial — e.g. `("JHON LEANDRO PEREZ", "JULIO CESAR PEREZ PEREZ")` and
  `("RIGOBERTO ORTEGA PEREZ", "RODOLFO ORTIZ PEREZ")` all pass a bare "same starting letter"
  check, but none of those given names is actually an abbreviation of the other.

This version rejects every one of those while still passing genuine variants like
`("Juan Antonio Garcia Lopez", "J. A. Garcia-Lopez")` and citation-style forms like
`("Alejandro Anaya", "Anaya, A. (Alejandro)")`.
"""
function _plausibly_same_person(name_a::AbstractString, name_b::AbstractString)
    given_a, surname_a = _name_tokens(name_a)
    given_b, surname_b = _name_tokens(name_b)
    # length >= 2: a raw "name" that is actually garbage data (e.g. a bare ORCID literal, seen on
    # a real rebuild) can tokenize down to single-character tokens like "0" — too short to carry
    # any real identifying signal, so never treat those as a surname match.
    (surname_a == surname_b && length(surname_a) >= 2) || return false
    (!isempty(given_a) && !isempty(given_b)) || return false
    _given_name_token_compatible(given_a[1], given_b[1])
end

function _bucket_for(raw_names_in_group::Vector{String})
    s = _surname_of_name(sort(raw_names_in_group)[1])
    isempty(s) ? "misc" : s
end

"""
    _short_hash(n_digits, parts) -> String

Deterministic `n_digits`-digit numeric string from the first 32 bits of `sha256(join(parts, sep))`
— `parts` sorted/deduped by the caller so the result depends only on the *set* of inputs. Not
cryptographic; just a small, stable fingerprint (this project already depends on `SHA`, no new dep).
"""
function _short_hash(n_digits::Int, parts::Vector{String})
    h = bytes2hex(sha256(join(parts, "\x1f")))  # \x1f: unit separator, won't appear in real names
    v = parse(UInt32, h[1:8]; base=16)
    lpad(string(v % 10^n_digits), n_digits, '0')
end

"""
    assign_id(names, institutions, used_ids, disambig_digits) -> (id::String, collided::Bool)

Short, readable id: `<apellido>_<hash de 4 dígitos>` de `names` (el o los nombres crudos que
representa) + `institutions`. `<apellido>` viene de [`_bucket_for`](@ref) sobre `names` — mismo
criterio que ya usa la organización en disco. Con ~300K perfiles, un espacio de 4 dígitos por sí
solo colisiona seguido dentro de un mismo apellido común (paradoja del cumpleaños) — por eso, si la
base ya está en `used_ids`, se le agrega un sufijo `_<n dígitos>` probando 0, 1, 2... hasta hallar
uno libre. Muta `used_ids` (agrega el id devuelto). El resultado es reproducible entre corridas
solo si quien llama procesa siempre en el mismo orden — ver [`assign_raw_ids`](@ref) y
[`build_and_persist`](@ref).
"""
function assign_id(names::Vector{String}, institutions::Vector{String}, used_ids::Set{String}, disambig_digits::Int)
    base = "$(_bucket_for(names))_$(_short_hash(4, vcat(sort(unique(names)), sort(unique(institutions)))))"
    if base ∉ used_ids
        push!(used_ids, base)
        return base, false
    end
    for suf in 0:(10^disambig_digits - 1)
        cand = "$(base)_$(lpad(suf, disambig_digits, '0'))"
        if cand ∉ used_ids
            push!(used_ids, cand)
            return cand, true
        end
    end
    error("Espacio de desambiguación agotado para '$base' ($disambig_digits dígitos) — subir disambig_digits")
end

"""
    assign_raw_ids(authors_data) -> (ids::Dict{String,String}, n_collisions::Int)

One id per raw profile (2 disambiguation digits — raw profiles vastly outnumber consolidated
ones, but each id only has to be unique among raw profiles sharing the same surname+hash4, which
in practice is a small pool). Processes `authors_data` sorted by name so the assignment is the
same across rebuilds regardless of corpus scan order.
"""
function assign_raw_ids(authors_data::Vector{<:AbstractDict})
    used = Set{String}()
    ids = Dict{String,String}()
    n_collisions = 0
    for a in sort(authors_data; by=x -> x["name"])
        id, collided = assign_id([a["name"]], collect(get(a, "institutions", String[])), used, 2)
        ids[a["name"]] = id
        collided && (n_collisions += 1)
    end
    return ids, n_collisions
end

"""
    rollup(raw_names_in_group, by_name, raw_id_of, used_ids) -> (Dict{String,Any}, Bool)

Combines the raw author profiles (`by_name[raw]` for each `raw` in the group, as produced by
`Corpus.build_authors_index_data`) into one consolidated profile — sums, unions, and an id. A
singleton group (one raw name, no real consolidation happened) reuses that raw profile's own id
from `raw_id_of` directly, no new hash computed; a group with 2+ raw names gets its own id via
[`assign_id`](@ref) (4 disambiguation digits — consolidated ids are far fewer than raw ones, but
each carries more weight, hence the extra margin), sharing `used_ids` with every other group so two
different groups can never end up with the same id. Returns whether that id needed disambiguation.
"""
function rollup(raw_names_in_group::Vector{String}, by_name::AbstractDict, raw_id_of::AbstractDict, used_ids::Set{String})
    entries = [by_name[n] for n in raw_names_in_group]
    sorted_raw = sort(raw_names_in_group)
    institutions = sort(unique(vcat([collect(get(e, "institutions", String[])) for e in entries]...)))

    consolidated_id, collided = if length(sorted_raw) == 1
        id = raw_id_of[sorted_raw[1]]
        push!(used_ids, id)
        (id, false)
    else
        assign_id(sorted_raw, institutions, used_ids, 4)
    end

    canonical_entry = entries[argmax([e["doc_count"] for e in entries])]
    canonical = canonical_entry["name"]
    k = name_keys(canonical)

    cap(v, n) = first(v, min(n, length(v)))

    profile = Dict{String,Any}(
        "consolidated_id" => consolidated_id,
        "name" => canonical,
        "name_initials_form" => k.initials_text,
        "role" => get(canonical_entry, "role", "Autor"),
        "raw_names" => sorted_raw,
        "doc_count" => sum(e["doc_count"] for e in entries),
        "doc_ids" => unique(vcat([collect(get(e, "doc_ids", String[])) for e in entries]...)),
        "institutions" => institutions,
        "keywords" => cap(unique(vcat([collect(get(e, "keywords", String[])) for e in entries]...)), 40),
        "repos" => sort(unique(vcat([collect(get(e, "repos", String[])) for e in entries]...))),
        "coauthors" => cap(unique(vcat([collect(get(e, "coauthors", String[])) for e in entries]...)), 15),
        "topic_texts" => cap(unique(vcat([collect(get(e, "topic_texts", String[])) for e in entries]...)), 10),
        "cited_references" => cap(unique(vcat([collect(get(e, "cited_references", String[])) for e in entries]...)), 30),
    )
    return profile, collided
end

"""
    compute_similarity_merges(authors_data; k::Int=16) -> Vector{Tuple{String,String}}

Finds pairs of raw profiles whose *content* (keywords, topics, cited references, institutions —
never the name) is similar enough to plausibly be the same person, complementing
[`compute_groups`](@ref)'s name-key matching: that catches near-identical name spellings, this
catches the opposite case — a genuinely different-looking name (typo, alternate transliteration,
married name) whose *work* is unmistakably the same person's.

Built with `TextSearch.VectorModel` (classical TFIDF, sparse) over a `SimilaritySearch.SearchGraph`
and `bichromatic_metricjoin` (self-join with an adaptive per-point threshold — no cosine cutoff to
tune by hand). Every candidate pair from the join is vetoed unless [`_plausibly_same_person`](@ref)
(surname AND given-name initial) holds between the two raw names — a real risk of pure content
similarity is two *different* people who coauthor constantly (near-identical topic/keyword
profiles) or who simply share a common surname; the gate rejects both cases while still letting
the join find same-name variants that the exact name-key match missed.

**Tried and reverted: partitioning by surname before joining.** The obvious way to cut the cost of
this at full-corpus scale (~100K+ raw profiles) is to bucket `authors_data` by
[`_surname_of_name`](@ref) and join each bucket independently — since
[`_plausibly_same_person`](@ref) requires an exact surname match anyway, a global join's
cross-surname candidates are guaranteed to be vetoed, so bucketing looks like pure waste avoided.
**Verified empirically on a real 10-repo rebuild that this silently breaks the join's precision**:
merges jumped from 4 (correct) to 5,575, with consolidated groups like "garcia" swallowing 47
raw names spanning obviously unrelated people (`"JESSICA ARBALLO GARCIA"`, `"JOEL ANTUNEZ GARCIA"`,
`"JOSE ALBERTO ALVARADO GARCIA"`, ...). Root cause: `bichromatic_metricjoin`'s adaptive per-point
threshold is a *quantile of the dataset it's given* — computed against the whole diverse corpus, it
is strict (most profiles are simply unlike most other profiles); computed within one surname's
bucket alone, that population is far more homogeneous (same language, overlapping general academic
vocabulary, often overlapping institutions), so many merely-similar pairs looked "unusually close"
*relative to their bucket*. That let far more pairs reach the veto, and the veto's own known-weak
spot — a bare single-letter initial (e.g. `"J."`) is compatible with *any* given name starting with
that letter — turned into a bridge: connected-component grouping in
[`compute_groups`](@ref) chained dozens of different "Jaime"/"Javier"/"Jessica"/"Joel"/"Jose*"
people together through such a bridge node. None of this showed up in the un-bucketed design
because the (properly calibrated) join rarely proposed a candidate needing the veto's help in the
first place. A real fix would need a similarity floor calibrated from the *whole* corpus, not
per-bucket — worth doing if full-corpus runtime turns out to actually require it, but not without
its own dedicated validation pass; until then this stays a single join over `authors_data` as a
whole, correctness over speed.

Returns `(name_a, name_b)` pairs meant to be folded into `overrides.merges` before calling
`compute_groups` (see [`build_and_persist`](@ref)) — this function knows nothing about the
override/graph machinery, it just proposes additional edges from a different signal.

`authors_data` is sorted by name internally before building the index — verified empirically
that without this, the exact same underlying profiles in a different order (which happens
across separate rebuilds: `Corpus.build_authors_index_data` collects them via a `Dict`, whose
iteration order depends on Julia's per-process randomized string hashing) can make
`bichromatic_metricjoin` propose a different candidate set, since a `SearchGraph`'s structure is
sensitive to insertion order. Sorting first makes the result reproducible across rebuilds, same
as [`assign_raw_ids`](@ref)/[`build_and_persist`](@ref) already do for id assignment.
"""
function compute_similarity_merges(authors_data::Vector{<:AbstractDict}; k::Int=16)
    authors_data = sort(authors_data; by=a -> a["name"])
    n = length(authors_data)
    n < 3 && return Tuple{String,String}[]

    profile_text(a) = join(vcat(
        collect(get(a, "keywords", String[])),
        collect(get(a, "topic_texts", String[])),
        collect(get(a, "cited_references", String[])),
        collect(get(a, "institutions", String[])),
    ), " \n ")

    texts = [profile_text(a) for a in authors_data]
    voc = Vocabulary(AUTHOR_NAME_CONFIG, texts)
    vocsize(voc) == 0 && return Tuple{String,String}[]  # every profile had empty content text
    model = VectorModel(IdfWeighting(), TfWeighting(), voc)
    vecs = vectorize_corpus(model, texts; verbose=false)
    db = VectorDatabase(vecs)

    G = SearchGraph(Dist.NormCosine(), db)
    ctx = SearchGraphContext()
    index!(G, ctx)

    joined = bichromatic_metricjoin(G, ctx, db; k=min(k, n - 1), samedata=true)

    merges = Tuple{String,String}[]
    for (ia, ib, _dist) in joined
        ia == ib && continue
        na, nb = authors_data[ia]["name"], authors_data[ib]["name"]
        _plausibly_same_person(na, nb) || continue
        push!(merges, (na, nb))
    end
    return merges
end

"""
    build_and_persist(authors_data, index_dir, raw_id_of; overrides_path=DEFAULT_AUTHOR_OVERRIDES_JSON) -> Int

Clusters `authors_data` (raw profiles, as returned by `Corpus.build_authors_index_data`) into
consolidated profiles and writes one `.toml` file per group under
`<index_dir>/authors_consolidated/<apellido_bucket>/<consolidated_id>.toml` — see this module's
docs for why TOML, and why the bucket directory is purely organizational (2 levels: the
consolidated-authors directory itself, then the bucket). `raw_id_of` (from
[`assign_raw_ids`](@ref)) lets singleton groups reuse their one raw profile's own id instead of
computing a redundant new one. Wipes and rewrites the whole directory each call, since group
membership/ids can change between rebuilds. Prints how many consolidated ids needed
disambiguation (see [`assign_id`](@ref)). Returns the number of groups written.
"""
function build_and_persist(authors_data::Vector{<:AbstractDict}, index_dir::AbstractString, raw_id_of::AbstractDict;
                            overrides_path::AbstractString=DEFAULT_AUTHOR_OVERRIDES_JSON)
    by_name = Dict{String,Any}(a["name"] => a for a in authors_data)
    raw_names = collect(keys(by_name))
    overrides = load_overrides(overrides_path)

    sim_merges = compute_similarity_merges(authors_data)
    println("  similarity-join merges (apellido-vetados): $(length(sim_merges)) / $(length(authors_data)) perfiles")
    overrides = (; merges=vcat(overrides.merges, [[a, b] for (a, b) in sim_merges]), splits=overrides.splits)

    groups = compute_groups(raw_names, overrides)

    base_dir = joinpath(index_dir, CONSOLIDATED_SUBDIR)
    isdir(base_dir) && rm(base_dir; recursive=true, force=true)
    mkpath(base_dir)

    used_ids = Set{String}()
    n_collisions = 0
    for g in sort(groups; by=grp -> sort(grp)[1])
        profile, collided = rollup(g, by_name, raw_id_of, used_ids)
        collided && (n_collisions += 1)
        dir = joinpath(base_dir, _bucket_for(g))
        mkpath(dir)
        open(joinpath(dir, "$(profile["consolidated_id"]).toml"), "w") do io
            TOML.print(io, profile)
        end
    end
    println("  consolidated ids needing disambiguation: $n_collisions / $(length(groups))")
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
