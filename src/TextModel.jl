module TextModel

using TextSearch, SimilaritySearch

export BilingualConfig, create_bilingual_textconfig, sample_bilingual_corpus,
       fit_bilingual_vocabulary, fit_bilingual_bm25

"""
    create_bilingual_textconfig(; nlist=[1, 2], del_diac=true, del_punc=true, lc=true)

Creates a TextConfig optimized for bilingual (Spanish / English) academic texts.
"""
function create_bilingual_textconfig(; nlist=[1, 2], del_diac=true, del_punc=true, lc=true)
    return TextConfig(
        del_diac=del_diac,
        del_dup=false,
        del_punc=del_punc,
        lc=lc,
        nlist=nlist
    )
end

"""
    sample_bilingual_corpus(corpus_es::Vector{String}, corpus_en::Vector{String}; target_size=100000)

Samples and balances Spanish and English documents with 50-50 importance for vocabulary fitting and refit.
"""
function sample_bilingual_corpus(
    corpus_es::Vector{String},
    corpus_en::Vector{String};
    target_size::Int=min(100000, length(corpus_es) + length(corpus_en))
)
    half = div(target_size, 2)
    sample_es = isempty(corpus_es) ? String[] : corpus_es[1:min(half, end)]
    sample_en = isempty(corpus_en) ? String[] : corpus_en[1:min(half, end)]
    
    # Combined with 50-50 balance
    bilingual = [sample_es; sample_en]
    return bilingual
end

"""
    fit_bilingual_vocabulary(config::TextConfig, bilingual_corpus::Vector{String}; min_freq::Int=2)

Builds a balanced bilingual vocabulary for Spanish and English.
"""
function fit_bilingual_vocabulary(
    config::TextConfig,
    bilingual_corpus::Vector{String};
    min_freq::Int=2
)
    voc = Vocabulary(config, bilingual_corpus)
    return voc
end

"""
    fit_bilingual_bm25(config::TextConfig, bilingual_corpus::Vector{String})

Creates and fits a BM25 inverted index on a bilingual corpus using TextSearch 1.1+.
"""
function fit_bilingual_bm25(config::TextConfig, bilingual_corpus::Vector{String})
    voc = fit_bilingual_vocabulary(config, bilingual_corpus)
    invfile = BM25InvertedFile(voc)
    ctx = InvertedFileContext()
    append_items!(invfile, ctx, bilingual_corpus)
    return (invfile, ctx)
end

end # module TextModel
