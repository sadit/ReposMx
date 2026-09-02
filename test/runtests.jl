using Test
using ReposMx
using ReposMx: LazyBM25, IndexShellIO, VocabIO, AuthorConsolidation
using RocksDB
using SimilaritySearch, TextSearch

@testset "ReposMx Tests" begin
    @testset "AuthorConsolidation (clustering + overrides, isolated)" begin
        # Guards the graph-based clustering that groups raw author profiles into consolidated
        # ones: full-name matches, initials-vs-full-name matches (the whole reason for the
        # initials key), and human overrides (merge forces an edge the auto-key can't find;
        # split removes one the auto-key would otherwise create) — see AuthorConsolidation.jl.
        mk(name) = Dict{String,Any}("name" => name, "doc_count" => 1)

        names = ["Juan Perez Gonzalez", "J. Perez Gonzalez", "JUAN PEREZ GONZALEZ",
                  "Ana Ruiz", "A. Ruiz",
                  "Pedro Soto", "Maria Soto"]  # last two share no key at all -> must stay separate

        no_overrides = (merges=Vector{Vector{String}}(), splits=Vector{Tuple{String,String}}())
        groups = AuthorConsolidation.compute_groups(names, no_overrides)
        by_first = Dict(sort(g)[1] => sort(g) for g in groups)

        @test by_first["J. Perez Gonzalez"] == sort(["Juan Perez Gonzalez", "J. Perez Gonzalez", "JUAN PEREZ GONZALEZ"])
        @test by_first["A. Ruiz"] == sort(["Ana Ruiz", "A. Ruiz"])
        @test any(g -> g == ["Pedro Soto"], groups)
        @test any(g -> g == ["Maria Soto"], groups)

        # merge: force two names together that share no automatic key at all
        merge_overrides = (merges=[["Pedro Soto", "Maria Soto"]], splits=Tuple{String,String}[])
        merged_groups = AuthorConsolidation.compute_groups(names, merge_overrides)
        @test any(g -> sort(g) == ["Maria Soto", "Pedro Soto"], merged_groups)

        # split: break an automatic match apart (isolated pair, no third name bridging them
        # transitively — with one in `names` this would stay connected via "JUAN PEREZ GONZALEZ",
        # which is the real, documented limit of a single pairwise split, not a bug)
        split_names = ["Carla Nunez", "C. Nunez"]
        no_overrides_2 = (merges=Vector{Vector{String}}(), splits=Tuple{String,String}[])
        @test length(AuthorConsolidation.compute_groups(split_names, no_overrides_2)) == 1

        split_overrides = (merges=Vector{Vector{String}}(), splits=[("Carla Nunez", "C. Nunez")])
        split_groups = AuthorConsolidation.compute_groups(split_names, split_overrides)
        @test length(split_groups) == 2
        @test !any(g -> "Carla Nunez" in g && "C. Nunez" in g, split_groups)

        # round-trip through the TOML corpus on disk
        by_name = Dict(n => mk(n) for n in names)
        authors_data = [by_name[n] for n in names]
        raw_id_of, _ = AuthorConsolidation.assign_raw_ids(authors_data)
        tmpdir = mktempdir()
        n = AuthorConsolidation.build_and_persist(authors_data, tmpdir, raw_id_of)
        reloaded = AuthorConsolidation.load_all(tmpdir)
        @test length(reloaded) == n
        @test sum(p["doc_count"] for p in reloaded) == length(names)

        # a singleton consolidated group ("Pedro Soto" and "Maria Soto" stay separate above)
        # must reuse its one raw profile's own id verbatim, not compute a new one.
        pedro_profile = only(filter(p -> p["raw_names"] == ["Pedro Soto"], reloaded))
        @test pedro_profile["consolidated_id"] == raw_id_of["Pedro Soto"]
    end

    @testset "AuthorConsolidation similarity-join merges (compute_similarity_merges, isolated)" begin
        # Guards the TFIDF + SimilaritySearch bichromatic_metricjoin clustering signal that
        # complements name-key matching: it should catch a same-surname near-duplicate profile
        # that shares no name key at all, while a surname-mismatched pair must NEVER be proposed
        # regardless of how similar its content looks — the veto is a hard filter, not a nudge.
        mkp(name, kws, topics, insts) = Dict{String,Any}(
            "name" => name, "doc_count" => 1, "keywords" => kws, "topic_texts" => topics,
            "cited_references" => String[], "institutions" => insts,
        )
        authors_data = [
            mkp("Juan Antonio Garcia Lopez",
                ["redes neuronales", "aprendizaje profundo", "vision computacional"],
                ["clasificacion de imagenes con redes convolucionales"], ["cimat"]),
            mkp("J. A. Garcia-Lopez",  # no full_key/initials_key overlap with the name above
                ["redes neuronales", "aprendizaje profundo", "vision por computadora"],
                ["clasificacion de imagenes usando redes convolucionales"], ["cimat"]),
            mkp("Roberto Hernandez Diaz",  # same content as the Garcia Lopez profiles on purpose
                ["redes neuronales", "aprendizaje profundo", "vision computacional"],
                ["clasificacion de imagenes con redes convolucionales"], ["cimat"]),
            mkp("Maria Fernanda Torres",
                ["ecologia marina", "biodiversidad", "cambio climatico"],
                ["impacto del cambio climatico en arrecifes de coral"], ["cicese"]),
            mkp("Pedro Ramirez Soto",
                ["historia colonial", "independencia de mexico"],
                ["la lucha por la independencia en el bajio"], ["cide"]),
        ]

        # sanity: _surname_of_name matches what name_keys already treats as "apellido"
        @test AuthorConsolidation._surname_of_name("Juan Antonio Garcia Lopez") == "lopez"
        @test AuthorConsolidation._surname_of_name("J. A. Garcia-Lopez") == "lopez"
        @test AuthorConsolidation._surname_of_name("Roberto Hernandez Diaz") == "diaz"

        # regression: two weaker gates were tried and rejected on a real 10-repo rebuild before
        # landing on "surname + first given-name token, exact-or-initial" (see
        # _plausibly_same_person's docstring) — these are real examples from that rebuild.

        # surname-only: different people sharing only a common (often maternal, per the
        # "Nombre ApellidoPaterno ApellidoMaterno" convention) surname.
        @test !AuthorConsolidation._plausibly_same_person("A. Alberto R. Fernandes", "PATRICIA FERNANDES")
        @test !AuthorConsolidation._plausibly_same_person("ADDY LETICIA ZARZA GARCIA", "Jesús Ortega García")
        @test !AuthorConsolidation._plausibly_same_person("Carlos Corona-García", "Salomon Vasquez-Garcia")
        @test !AuthorConsolidation._plausibly_same_person("Méndez Cabrera, Socorro", "Valdez Cabrera, Celia")
        @test !AuthorConsolidation._plausibly_same_person("Paul Dupree", "ray dupree")

        # surname + bare first-letter: still let through different people sharing a common
        # surname AND a coincidental first initial (none of these given names is actually an
        # abbreviation of the other, just the same starting letter).
        @test !AuthorConsolidation._plausibly_same_person("JHON LEANDRO PEREZ", "JULIO CESAR PEREZ PEREZ")
        @test !AuthorConsolidation._plausibly_same_person("JULIAN RAMIREZ GONZALEZ", "Javier Rendón González")
        @test !AuthorConsolidation._plausibly_same_person("RIGOBERTO ORTEGA PEREZ", "RODOLFO ORTIZ PEREZ")
        @test !AuthorConsolidation._plausibly_same_person("MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ")
        @test !AuthorConsolidation._plausibly_same_person("MIGUEL ANGEL LARA TREJO", "Mario Trejo")

        # still passes genuine variants, including ones a full given-name-token-count match would
        # have missed (middle name dropped, or a citation-style "Apellido, A. (Nombre)" form)
        @test AuthorConsolidation._plausibly_same_person("Juan Antonio Garcia Lopez", "J. A. Garcia-Lopez")
        @test AuthorConsolidation._plausibly_same_person("JEWEL NICOLE ANNA TODD", "Jewel Todd")
        @test AuthorConsolidation._plausibly_same_person("Alejandro Anaya", "Anaya, A. (Alejandro)")
        @test AuthorConsolidation._plausibly_same_person("Barrón, L. (Luis)", "Luis Felipe Barrón")

        # regression: a garbage "name" (e.g. a bare ORCID literal from bad upstream data, seen on
        # a real rebuild) degenerates to single-character tokens under this tokenization — must
        # never count as a surname match no matter how identical the degenerate tokens look.
        @test !AuthorConsolidation._plausibly_same_person("0000-0001-7887-7580", "0000-0002-8080-8186")

        merges = AuthorConsolidation.compute_similarity_merges(authors_data; k=4)
        pair_present(a, b) = any(p -> Set(p) == Set((a, b)), merges)

        @test pair_present("Juan Antonio Garcia Lopez", "J. A. Garcia-Lopez")
        # same content as the Garcia Lopez pair, but a different surname -> must be vetoed no
        # matter how similar the profile text is (this is the whole point of the gate)
        @test !pair_present("Juan Antonio Garcia Lopez", "Roberto Hernandez Diaz")
        @test !pair_present("J. A. Garcia-Lopez", "Roberto Hernandez Diaz")

        # regression: verified on a real 10-repo rebuild that bichromatic_metricjoin's candidate
        # set is sensitive to the *order* authors_data arrives in (SearchGraph insertion order),
        # and that order isn't reproducible across process runs on its own (Corpus.build_authors_
        # index_data collects raw profiles via a Dict, whose iteration order depends on Julia's
        # per-process randomized string hashing) — compute_similarity_merges must sort internally
        # so the same underlying profiles, in ANY input order, give the same result.
        shuffled = authors_data[[5, 3, 1, 4, 2]]
        @test Set(AuthorConsolidation.compute_similarity_merges(shuffled; k=4)) ==
              Set(AuthorConsolidation.compute_similarity_merges(authors_data; k=4))

        # too few profiles for a self-join to mean anything -> returns empty, doesn't error
        @test AuthorConsolidation.compute_similarity_merges(authors_data[1:2]) == Tuple{String,String}[]

        # profiles with no content text at all (matches build_and_persist's own round-trip test
        # above, which uses bare {"name"=>..., "doc_count"=>...} dicts) -> empty vocabulary,
        # returns no merges instead of erroring
        bare = [Dict{String,Any}("name" => n, "doc_count" => 1) for n in ("Ana Ruiz", "A. Ruiz", "Pedro Soto")]
        @test AuthorConsolidation.compute_similarity_merges(bare) == Tuple{String,String}[]
    end

    @testset "AuthorConsolidation short id assignment (assign_id/_short_hash, isolated)" begin
        # Guards the short, readable id scheme (<apellido>_<hash4> + disambiguation suffix on
        # real collision) that replaced UUID5/16-hex-hash ids — see AuthorConsolidation.jl.

        # Deterministic: same names+institutions -> same id, across independent calls.
        used1 = Set{String}()
        id1, collided1 = AuthorConsolidation.assign_id(["Juan Garcia"], ["cimat"], used1, 2)
        used2 = Set{String}()
        id2, collided2 = AuthorConsolidation.assign_id(["Juan Garcia"], ["cimat"], used2, 2)
        @test id1 == id2
        @test !collided1 && !collided2
        @test startswith(id1, "garcia_")

        # A different institution set changes the hash (and thus, almost always, the id).
        used3 = Set{String}()
        id3, _ = AuthorConsolidation.assign_id(["Juan Garcia"], ["cicese"], used3, 2)
        @test id3 != id1

        # Real collision: pre-seed used_ids with the exact base id assign_id would compute for
        # this input, and confirm it resolves the clash via the disambiguation suffix (0, 1, 2..)
        # instead of silently overwriting whoever's already there.
        base = "lopez_$(AuthorConsolidation._short_hash(4, ["Someone Lopez"]))"
        used_forced = Set{String}([base])
        forced_id, collided = AuthorConsolidation.assign_id(["Someone Lopez"], String[], used_forced, 2)
        @test collided
        @test forced_id != base
        @test startswith(forced_id, base * "_")
        @test forced_id in used_forced  # assign_id mutates used_ids with the id it returns
    end

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
