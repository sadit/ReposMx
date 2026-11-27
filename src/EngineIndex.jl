"""
    EngineIndex

The four text indices of ReposMx as projects of `SimilaritySearchEngine` (docs/plan-motor.md,
phase 2). Each index is a text project (`TextDocuments` with a `BM25` index), stored under
`<index_dir>/engine/<name>/`:

| project           | text of each item                         | `doc_id`           | partitions       |
|-------------------|-------------------------------------------|--------------------|------------------|
| `docs_content`    | `extract_index_text`                      | `"<repo>:<id>"`    | `repo`           |
| `docs_refs`       | the texts of the document's references    | `"<repo>:<id>"`    | `repo`           |
| `authors_name`    | `"<name> . <initials form>"`              | consolidated id    | `repos` (a list) |
| `authors_profile` | name, keywords, topics, cited references  | consolidated id    | `repos` (a list) |

`docs_content` keeps the metadata of each document in `meta`: it is where ReposMx reads a
document from. The other three keep only the partition field.

Each project receives its vocabulary as a profile (`BaseProfile`), built here from the
vocabulary ReposMx fitted for it. The profile has no expansion network, and its tokenizer is the
one the vocabulary was counted with (`index_profile` checks it).
"""
module EngineIndex

using TextSearch
import SimilaritySearchEngine
const SSE = SimilaritySearchEngine

export DOCS_CONTENT, DOCS_REFS, AUTHORS_NAME, AUTHORS_PROFILE, PROJECT_NAMES, QUERY_POLICY, TOKENS_POLICY,
       engine_workdir, index_profile, build_text_project!, open_index, split_doc_key, doc_key_of,
       CTI_FOLLOWERS, create_partition_followers!

const DOCS_CONTENT = "docs_content"
const DOCS_REFS = "docs_refs"
const AUTHORS_NAME = "authors_name"
const AUTHORS_PROFILE = "authors_profile"
const PROJECT_NAMES = (DOCS_CONTENT, DOCS_REFS, AUTHORS_NAME, AUTHORS_PROFILE)

"""
    QUERY_POLICY

The policy of every query typed by a person. Correction is `:auto`: a spelling that the
vocabulary does not hold, or holds in far fewer documents than another form of the same word,
is searched as that other form (`REMOCION` -> `remoción`). Expansion is off, because the
profiles carry no expansion network.

Before the engine, ReposMx corrected only the forms that differ in case and accents and can be
computed from the typed token. The engine also uses the variant map it derives from the
vocabulary, so some queries in capital letters without accents find more documents now.
"""
const QUERY_POLICY = QueryPolicy(correction=:auto, expansion=false)

"""
    TOKENS_POLICY

The policy of a query given as a list of vocabulary tokens (`Search.informative_tokens`): the
tokens are searched as they are.
"""
const TOKENS_POLICY = QueryPolicy(correction=:off, expansion=false)

"""
    engine_workdir(index_dir) -> String

The directory that holds the four projects.
"""
engine_workdir(index_dir::AbstractString) = joinpath(index_dir, "engine")

"""
    doc_key_of(repo, id) -> String

The `doc_id` of a document in `docs_content` and `docs_refs`. Repository names do not contain
`:`, so [`split_doc_key`](@ref) recovers both parts.
"""
doc_key_of(repo::AbstractString, id::AbstractString) = string(strip(repo), ":", strip(id))

"""
    split_doc_key(key) -> (repo, id)

The inverse of [`doc_key_of`](@ref). The id itself may contain `:`.
"""
function split_doc_key(key::AbstractString)
    parts = split(key, ':'; limit=2)
    length(parts) == 2 || error("not a document key: $(repr(key))")
    return (String(parts[1]), String(parts[2]))
end

"""
    index_profile(voc::Vocabulary, artifacts::Union{TextProfile,Nothing}) -> TextProfile

A profile whose vocabulary is `voc`, for `BaseProfile`. A `TextProfile` builds its tokenizer
from its own stopwords and lemmas, so a profile made from `voc` alone would tokenize without
the lemmas `voc` was counted with. `artifacts` supplies them: the profile `voc` was taken from,
or `nothing` for a vocabulary counted without stopwords or lemmas. The query expansion network
is not copied. Raises an error if the tokenizer of the result differs from the one of `voc`.
"""
function index_profile(voc::Vocabulary, artifacts::Union{TextProfile,Nothing})
    stopwords = artifacts === nothing ? Set{String}() : artifacts.stopwords
    lemmas = artifacts === nothing ? Dict{String,String}() : artifacts.lemmas
    applied = artifacts === nothing ? TextSearch.AppliedArtifacts() :
        TextSearch.AppliedArtifacts(stopwords=artifacts.applied.stopwords, lemmas=artifacts.applied.lemmas)
    lineage = artifacts === nothing ? TextSearch.LineageStep[] : artifacts.lineage
    p = TextProfile(VectorModel(voc), stopwords, lemmas, Dict{String,Vector{String}}(), nothing, applied, lineage)
    p.model.voc.textconfig == voc.textconfig ||
        error("the profile would tokenize differently from the vocabulary it was built from")
    return p
end

"""
    CTI_FOLLOWERS

The partition followers of the document projects (`docs_content` and the dense `docs_dense`), one per
level of the CTI classification that the repositories declare (`Corpus.cti_codes`; the catalogs are those
of SECIHTI, formerly CONACYT): follower name =>
field of the `meta`. A document is in every partition it names (`disjoint=false`); one without
classification is in none. `open_follower(h, "disciplina=CIENCIA DE LOS ORDENADORES")` restricts a
search to one value, with the same score as the global search (SimilaritySearchEngine, followers).

The CTI is metadata as declared, not training data (decision of the user, 2026-11-26): a classifier trained
on it reached 0.50 on the disciplina of held-out documents, and only half of the labeled documents agree with
their neighborhood (experiments/rag_web/cti_inferencia.jl).
"""
const CTI_FOLLOWERS = ["area" => "areas", "campo" => "campos", "disciplina" => "disciplinas"]

"""
    create_partition_followers!(h, followers) -> Nothing

Creates on the open, writable project `h` one `PartitionFollower(MetaValue(field); disjoint=false)` per
`name => field` of `followers`, and closes them.
"""
function create_partition_followers!(h, followers)
    for (name, field) in followers
        f = SSE.create_follower(h, name, SSE.PartitionFollower(SSE.MetaValue(field); disjoint=false))
        SSE.close_follower!(f)
    end
    return nothing
end

"""
    build_text_project!(workdir, name, profile, texts, doc_ids, metas; partition_by, followers=[]) -> Nothing

Creates the project `name` under `workdir`, appends one item per text, and indexes them. Item
`i` gets the text `texts[i]`, the `doc_id` `doc_ids[i]` and the meta `metas[i]`, so the items of
the four projects keep the order of the corpus. An empty text is appended too: it is never
found, and it keeps item `i` in its place. `followers` (`name => meta field`) are partition followers
created after indexing ([`create_partition_followers!`](@ref)).
"""
function build_text_project!(workdir::AbstractString, name::AbstractString, profile::TextProfile,
                             texts::AbstractVector{<:AbstractString}, doc_ids::AbstractVector{<:AbstractString},
                             metas::AbstractVector; partition_by::Union{Nothing,AbstractString}, followers=Pair{String,String}[])
    length(texts) == length(doc_ids) == length(metas) || error("texts, doc_ids and metas differ in length")
    h = SSE.create_project(workdir, name, SSE.TextDocuments(SSE.BaseProfile(profile); index=SSE.BM25());
                           partitions=partition_by === nothing ? nothing : SSE.PartitionBy(partition_by))
    try
        batch = 50_000
        for sp in 1:batch:length(texts)
            ep = min(sp + batch - 1, length(texts))
            SSE.append_items!(h, [SSE.TextItem(texts[i]; doc_id=doc_ids[i], meta=metas[i]) for i in sp:ep])
        end
        SSE.index!(h)
        create_partition_followers!(h, followers)
    finally
        SSE.close_project!(h)
    end
    return nothing
end

"""
    open_index(index_dir, name) -> Union{EmbeddedEngine,Nothing}

Opens the project `name` read-only, or returns `nothing` when it has not been built.
"""
function open_index(index_dir::AbstractString, name::AbstractString)
    workdir = engine_workdir(index_dir)
    isdir(joinpath(workdir, name)) || return nothing
    return SSE.open_project(workdir, name; read_only=true)
end

end # module EngineIndex
