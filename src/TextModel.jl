module TextModel

using TextSearch
using ..Config: DEFAULT_DATA_DIR

export TextProfile,
       create_bilingual_profile,
       get_or_create_bilingual_base_profile,
       refit_bilingual_profile,
       create_bilingual_textconfig,
       save_profile,
       load_profile

"""
    create_bilingual_textconfig(; nlist=[1], del_diac=false, del_punc=true, lc=false)

Returns a base TextConfig for bilingual texts matching the default TextSearch profile policy.
"""
function create_bilingual_textconfig(; nlist=[1], del_diac=false, del_punc=true, lc=false)
    return TextConfig(
        del_diac=del_diac,
        del_dup=false,
        del_punc=del_punc,
        group_num=true,
        group_url=true,
        lc=lc,
        nlist=nlist
    )
end

"""
    create_bilingual_profile(p_es::TextProfile, p_en::TextProfile;
                             language::Symbol=:bilingual,
                             doc_freq_threshold::Real=0.5,
                             query_expansion_k::Integer=0,
                             rrf_k::Real=60) -> TextProfile

Merges the pre-trained Spanish (`es`) and English (`en`) `TextProfile`s into a single
unified bilingual profile. Fuses vocabularies, stopwords, lemmas, and query expansion networks.
"""
function create_bilingual_profile(
    p_es::TextProfile,
    p_en::TextProfile;
    language::Symbol=:bilingual,
    doc_freq_threshold::Real=0.5,
    query_expansion_k::Integer=0,
    rrf_k::Real=60
)
    pol_es = TextSearch.getpolicy(p_es)
    pol_en = TextSearch.getpolicy(p_en)
    
    # 1. Bilingual Policy (shares identical normalization and tokenization configs)
    bilingual_policy = TextConfig(
        normalization=pol_es.normalization,
        tokenization=pol_es.tokenization,
        language=language
    )
    
    # 2. Merge Vocabularies
    voc_es = p_es.model.voc
    voc_en = p_en.model.voc
    total_trainsize = TextSearch.gettrainsize(voc_es) + TextSearch.gettrainsize(voc_en)
    total_numtokens = TextSearch.getnumtokens(voc_es) + TextSearch.getnumtokens(voc_en)
    
    voc = Vocabulary(bilingual_policy, total_trainsize, total_numtokens)
    TextSearch.update_voc!(voc, voc_es)
    TextSearch.update_voc!(voc, voc_en)
    
    # 3. Merge Artifacts
    stopwords = union(p_es.stopwords, p_en.stopwords)
    lemmas = merge(p_es.lemmas, p_en.lemmas)
    
    # Query expansion rank fusion
    fused_qe = TextSearch._fuse_query_expansion([p_es, p_en], voc, query_expansion_k, rrf_k)
    query_expansion = fused_qe.query_expansion
    query_expansion_distances = fused_qe.distances
    
    applied = TextSearch.AppliedArtifacts(
        stopwords=p_es.applied.stopwords || p_en.applied.stopwords,
        lemmas=p_es.applied.lemmas || p_en.applied.lemmas,
        query_expansion=p_es.applied.query_expansion || p_en.applied.query_expansion
    )
    
    lineage = TextSearch.LineageStep[
        p_es.lineage...,
        p_en.lineage...,
        TextSearch.LineageStep(:bilingual_merge; languages="es+en")
    ]
    
    gw = p_es.model.global_weighting
    lw = p_es.model.local_weighting
    model = VectorModel(gw, lw, voc)
    
    return TextProfile(
        model,
        stopwords,
        lemmas,
        query_expansion,
        query_expansion_distances,
        applied,
        lineage
    )
end

"""
    get_or_create_bilingual_base_profile(; cache_dir=nothing, force=false, verbose=true) -> TextProfile

Retrieves or builds the bilingual base profile from pre-trained Spanish and English models.
Caches the resulting profile to avoid repeating the merge on every run.
"""
function get_or_create_bilingual_base_profile(;
    cache_dir::Union{String, Nothing}=nothing,
    force::Bool=false,
    verbose::Bool=true
)
    target_dir = cache_dir !== nothing ? cache_dir : joinpath(DEFAULT_DATA_DIR, "profiles", "bilingual_base")
    
    if !force && isdir(target_dir) && isfile(joinpath(target_dir, "manifest.json"))
        verbose && println("Loading cached bilingual base profile from: $target_dir")
        return TextSearch.load_profile(target_dir)
    end
    
    verbose && println("Downloading/loading pre-trained 'es' and 'en' profiles...")
    path_es = TextSearch.download_profile("es")
    path_en = TextSearch.download_profile("en")
    
    p_es = TextSearch.load_profile(path_es)
    p_en = TextSearch.load_profile(path_en)
    
    verbose && println("Merging Spanish and English profiles into unified bilingual profile...")
    p_bilingual = create_bilingual_profile(p_es, p_en)
    
    try
        mkpath(dirname(target_dir))
        verbose && println("Caching bilingual base profile to: $target_dir")
        TextSearch.save_profile(target_dir, p_bilingual)
    catch e
        @warn "Could not cache bilingual base profile to disk: $e"
    end
    
    return p_bilingual
end

"""
    refit_bilingual_profile(base::TextProfile, sample_corpus::Vector{String};
                            kappa::Real=0,
                            apply_lemmas::Bool=true,
                            extend_lemmas::Bool=false,
                            verbose::Bool=true,
                            kwargs...) -> TextProfile

Adapts and refits the unified bilingual base profile using a national academic corpus sample.
"""
function refit_bilingual_profile(
    base::TextProfile,
    sample_corpus::Vector{String};
    kappa::Real=0,
    apply_lemmas::Bool=true,
    extend_lemmas::Bool=false,
    verbose::Bool=true,
    kwargs...
)
    κ = kappa <= 0 ? max(Float64(length(sample_corpus)), 5000.0) : Float64(kappa)
    return TextSearch.refit_profile(
        base,
        sample_corpus;
        kappa=κ,
        apply_lemmas=apply_lemmas,
        extend_lemmas=extend_lemmas,
        verbose=verbose,
        kwargs...
    )
end

end # module TextModel
