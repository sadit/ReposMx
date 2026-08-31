using Test
using ReposMx
using ReposMx: LazyBM25, IndexShellIO, VocabIO
using RocksDB
using SimilaritySearch, TextSearch

@testset "ReposMx Tests" begin
    @testset "IndexShellIO round-trip (bm25/doclens/len/query, isolated)" begin
        # Guards the JSON3/zip replacement for what used to be a JLD2 jldsave/load round-trip
        # (see IndexShellIO's docstring): BM25Scorer's Float32 fields, QueryPipeline's
        # Union{Nothing,Dict} fields (variants/expansion/distances), and QueryPolicy's Symbol
        # field must all survive the trip unchanged.
        docs = [
            "el gato negro corre en el jardin",
            "el perro blanco duerme en la casa",
            "un gato y un perro juegan juntos",
            "the black cat runs fast",
        ]
        config = TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])
        voc = Vocabulary(config, docs)
        invfile = BM25InvertedFile(voc)
        ctx = InvertedFileContext()
        append_items!(invfile, ctx, docs)

        tmpdir = mktempdir()
        shell_path = joinpath(tmpdir, "shell.zip")
        IndexShellIO.save_index_shell_zip(shell_path;
            bm25=invfile.bm25, doclens=invfile.doclens, len=invfile.len[], query=invfile.query)
        d = IndexShellIO.load_index_shell_zip(shell_path)

        @test d.bm25.k1_plus_1 ≈ invfile.bm25.k1_plus_1
        @test d.bm25.k1_mult_1_min_b ≈ invfile.bm25.k1_mult_1_min_b
        @test d.bm25.k1_mult_b_div_avg_doc_len ≈ invfile.bm25.k1_mult_b_div_avg_doc_len
        @test d.bm25.δ ≈ invfile.bm25.δ
        @test d.bm25.trainsize == invfile.bm25.trainsize
        @test d.doclens == invfile.doclens
        @test d.len == invfile.len[]
        @test d.query.policy.correction == invfile.query.policy.correction
        @test d.query.policy.expansion == invfile.query.policy.expansion
        @test d.query.policy.expansion_k == invfile.query.policy.expansion_k
        @test d.query.policy.negligible_ratio == invfile.query.policy.negligible_ratio
        @test d.query.variants === invfile.query.variants  # both nothing here
        @test d.query.expansion === invfile.query.expansion
        @test d.query.distances === invfile.query.distances

        # A round-tripped shell must assemble into a lazily-backed index whose search results
        # are identical to the original in-memory one — the actual end-to-end gate.
        db_path = joinpath(tmpdir, "rocksdb")
        init_db = opendb(db_path; create_if_missing=true)
        for cf in ["postings", "docvecs"]
            create_column_family(init_db, cf)
        end
        close(init_db)
        db = opendb(db_path; column_families=["default", "postings", "docvecs"])
        try
            LazyBM25.export_to_rocksdb!(db, LazyBM25.DOCS_CONTENT, invfile)
            lazy_invfile = LazyBM25.assemble_bm25(
                db, LazyBM25.DOCS_CONTENT, voc, d.bm25, d.doclens, d.len, d.query
            )
            for q in ["gato jardin", "perro casa", "cat dog"]
                ctx_a = InvertedFileContext()
                res_a = search(invfile, ctx_a, q, knnqueue(ctx_a, 10))
                ctx_b = InvertedFileContext()
                res_b = search(lazy_invfile, ctx_b, q, knnqueue(ctx_b, 10))
                @test [item.id for item in res_a] == [item.id for item in res_b]
                @test [item.dist for item in res_a] ≈ [item.dist for item in res_b]
            end
        finally
            close(db)
        end
    end

    @testset "LazyBM25 round-trip (isolated, synthetic corpus)" begin
        # Builds a tiny in-memory BM25InvertedFile, exports it to a temp RocksDB via
        # LazyBM25.export_to_rocksdb!, reassembles it as a lazily-backed index via
        # LazyBM25.assemble_bm25, and checks that search() returns byte-identical
        # results (doc ids, order, and scores) from both versions. This is the
        # correctness gate for the whole lazy-index design: if TextSearch.jl ever
        # reorders BM25InvertedFile's fields, this test fails loudly instead of
        # silently corrupting production search results.
        docs = [
            "el gato negro corre en el jardin",
            "el perro blanco duerme en la casa",
            "un gato y un perro juegan juntos",
            "the black cat runs fast",
            "the white dog sleeps all day",
            "cats and dogs play together in the garden",
            "la casa tiene un jardin grande",
            "grandes jardines con gatos y perros",
            "el sol brilla sobre el jardin",
            "un dia soleado en el parque",
        ]
        config = TextConfig(del_diac=true, del_punc=true, lc=true, nlist=[1])
        voc = Vocabulary(config, docs)
        invfile = BM25InvertedFile(voc)
        ctx = InvertedFileContext()
        append_items!(invfile, ctx, docs)

        tmpdir = mktempdir()
        db_path = joinpath(tmpdir, "rocksdb")
        init_db = opendb(db_path; create_if_missing=true)
        for cf in ["postings", "docvecs"]
            create_column_family(init_db, cf)
        end
        close(init_db)

        db = opendb(db_path; column_families=["default", "postings", "docvecs"])
        try
            LazyBM25.export_to_rocksdb!(db, LazyBM25.DOCS_CONTENT, invfile)
            lazy_invfile = LazyBM25.assemble_bm25(
                db, LazyBM25.DOCS_CONTENT, invfile.voc, invfile.bm25, invfile.doclens, invfile.len[], invfile.query
            )

            for q in ["gato jardin", "perro casa", "cat dog garden", "sol parque", "inexistente xyz123"]
                ctx_a = InvertedFileContext()
                res_a = search(invfile, ctx_a, q, knnqueue(ctx_a, 10))
                ctx_b = InvertedFileContext()
                res_b = search(lazy_invfile, ctx_b, q, knnqueue(ctx_b, 10))

                @test [item.id for item in res_a] == [item.id for item in res_b]
                @test [item.dist for item in res_a] ≈ [item.dist for item in res_b]
            end
        finally
            close(db)
        end
    end

    @testset "Database and Column Families" begin
        db = open_database(ReposMx.DEFAULT_ROCKSDB_DIR; read_only=true)
        @test db !== nothing
        @test db.is_open == true
        
        # Test author normalization
        norm1 = normalize_author_name("González, Carlos")
        norm2 = normalize_author_name("Carlos González")
        @test !isempty(norm1)
        @test norm1 == norm2
        
        # Test topic operations
        topic_docs = get_topic_docs(db, "optimizacion")
        @test topic_docs isa Vector{Pair{String, String}}
        
        topic_authors = get_topic_authors(db, "optimizacion")
        @test topic_authors isa Vector{String}
        
        close_database(db)
    end

    @testset "SearchEngine & 4 Segregated Indices" begin
        engine = SearchEngine()
        @test engine !== nothing
        @test length(engine.doc_keys) > 0
        @test length(engine.author_keys) > 0
        
        # 1. Content query
        res_doc = query_index(engine, "inteligencia artificial"; top=5)
        @test res_doc["total_hits"] >= 0
        @test haskey(res_doc, "hits")
        if !isempty(res_doc["hits"])
            first_hit = res_doc["hits"][1]
            @test haskey(first_hit, "title")
            @test haskey(first_hit, "repo")
            @test haskey(first_hit, "score")
        end
        
        # 2. Author query by name
        res_auth = search_authors(engine, "Gonzalez"; top=5)
        @test haskey(res_auth, "authors")
        if !isempty(res_auth["authors"])
            first_auth = res_auth["authors"][1]
            @test haskey(first_auth, "name")
            @test haskey(first_auth, "doc_count")
            
            # Author contextual operations
            auth_name = first_auth["name"]
            auth_docs = get_author_documents(engine, auth_name; limit=5)
            @test haskey(auth_docs, "documents")
            
            auth_sim = find_similar_authors_by_profile(engine, auth_name; top=5)
            @test haskey(auth_sim, "similar_authors")
        end
        
        # 3. Document contextual operations & Bibliographic coupling
        if !isempty(res_doc["hits"])
            hit = res_doc["hits"][1]
            repo = hit["repo"]
            doc_id = hit["id"]
            
            doc_refs = get_document_references(engine, repo, doc_id)
            @test haskey(doc_refs, "references")
            
            sim_refs = find_similar_documents_by_references(engine, repo, doc_id; top=5)
            @test haskey(sim_refs, "similar_documents")
        end
        
        # 4. Topic set listing & intersection
        topic_res = get_topic_elements(engine, "optimizacion"; repo="cimat", limit=5)
        @test haskey(topic_res, "documents")
        @test haskey(topic_res, "authors")

        # 5. Detailed stats (global and repo-scoped). Repo-scoped stats regressed silently
        #    earlier this session (`strip(repo)::SubString{String}` didn't match a `::String`
        #    parameter) because nothing exercised this path with a real repo string — cover it.
        stats = get_detailed_statistics(engine)
        @test stats["total_docs"] > 0
        @test stats["total_authors"] > 0
        @test haskey(stats, "years_histogram")
        @test haskey(stats, "top_researchers")

        repo_stats = get_detailed_statistics(engine; repo="cimat")
        @test !haskey(repo_stats, "error")
        @test repo_stats["total_docs"] > 0
        @test repo_stats["total_docs"] < stats["total_docs"]

        # 6. Pagination: two pages of the same query must not overlap, and
        #    has_more must be consistent with there being further results.
        page1 = query_index(engine, "inteligencia artificial"; top=5, offset=0)
        page2 = query_index(engine, "inteligencia artificial"; top=5, offset=5)
        @test haskey(page1, "has_more")
        if !isempty(page1["hits"]) && !isempty(page2["hits"])
            ids1 = Set(h["doc_idx"] for h in page1["hits"])
            ids2 = Set(h["doc_idx"] for h in page2["hits"])
            @test isempty(intersect(ids1, ids2))
        end

        # 7. Year-range post-filter: every returned hit's date must fall in range.
        year_res = query_index(engine, "optimizacion"; top=5, year_min=2010, year_max=2020)
        for h in year_res["hits"]
            m = match(r"\b(19\d\d|20\d\d)\b", h["date"])
            @test m !== nothing
            y = parse(Int, m.match)
            @test 2010 <= y <= 2020
        end

        # 8. Author network: nodes/edges around a real author from the results above.
        if !isempty(res_doc["hits"]) && !isempty(res_doc["hits"][1]["creator"])
            net = get_author_network(engine, res_doc["hits"][1]["creator"])
            @test haskey(net, "nodes")
            @test haskey(net, "edges")
        end

        close(engine)
    end
end
