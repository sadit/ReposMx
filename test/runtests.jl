using Test
using ReposMx

@testset "ReposMx Tests" begin
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
        
        # 5. Detailed stats
        stats = get_detailed_statistics(engine)
        @test stats["total_docs"] > 0
        @test stats["total_authors"] > 0
        
        close(engine)
    end
end
