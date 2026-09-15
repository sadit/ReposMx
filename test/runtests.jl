using Test
using Random
using ReposMx
using ReposMx: LazyBM25, IndexShellIO, VocabIO, AuthorConsolidation, Corpus, NameVocabulary,
               PrecisionClustering, Imputation
using RocksDB
using SimilaritySearch, TextSearch
using TOML

@testset "ReposMx Tests" begin
    @testset "Corpus keyword parsing (parse_keywords / CTI catalog resolution, isolated)" begin
        # Guards the fix for the most common dc:subject shape in this corpus, the DRIVER/OpenAIRE
        # "info:eu-repo/classification/<esquema>/<valor>" convention: parse_keywords used to split
        # every ";"-joined segment further on "/" and "," too, shredding this structure into
        # meaningless fragments (a raw CTI numeric code kept as if it were a real keyword) and
        # breaking legitimate comma-containing free text the same way. See Corpus.jl's
        # parse_keywords docstring for the real repos these came from.

        # resolve_cti_code against a synthetic catalog (no network, no dependency on the real
        # fetched data/catalogs) -- exercises the digit-length level dispatch and the "unknown
        # code -> nothing" contract in isolation.
        tmpdir = mktempdir()
        write(joinpath(tmpdir, "cti_areacono.json"),
              """[{"cveArea":"1","descripcion":"CIENCIAS FÍSICO MATEMÁTICAS Y CIENCIAS DE LA TIERRA"}]""")
        write(joinpath(tmpdir, "cti_campocono.json"),
              """[{"cveCampo":"23","descripcion":"QUÍMICA"}]""")
        write(joinpath(tmpdir, "cti_disciplinacono.json"),
              """[{"cveDisciplina":"2399","descripcion":"OTRAS ESPECIALIDADES QUÍMICAS"}]""")
        write(joinpath(tmpdir, "cti_subdisciplinacono.json"),
              """[{"cveSubdisciplina":"239999","descripcion":"OTRAS"}]""")

        @test resolve_cti_code("1"; catalogs_dir=tmpdir) == "CIENCIAS FÍSICO MATEMÁTICAS Y CIENCIAS DE LA TIERRA"
        @test resolve_cti_code("23"; catalogs_dir=tmpdir) == "QUÍMICA"
        @test resolve_cti_code("2399"; catalogs_dir=tmpdir) == "OTRAS ESPECIALIDADES QUÍMICAS"
        @test resolve_cti_code("239999"; catalogs_dir=tmpdir) == "OTRAS"
        @test resolve_cti_code("9"; catalogs_dir=tmpdir) === nothing        # right length, unknown code
        @test resolve_cti_code("12345"; catalogs_dir=tmpdir) === nothing    # no level has 5-digit codes
        @test resolve_cti_code("1"; catalogs_dir=mktempdir()) === nothing   # catalogs not fetched at all

        # parse_keywords: segment splitting and per-scheme handling. cti resolution here uses the
        # real catalogs fetched via `reposmx fetch-catalogs` into DEFAULT_CATALOGS_DIR -- real
        # examples pulled straight from data/repos/*/corpus.jsonl during this exploration.
        @test Corpus.parse_keywords("") == String[]

        # ciqa: a chain of cti codes at every hierarchy level, one dc:subject segment each.
        ciqa = Corpus.parse_keywords("info:eu-repo/classification/cti/2 ; info:eu-repo/classification/cti/23 ; " *
                               "info:eu-repo/classification/cti/2399 ; info:eu-repo/classification/cti/239999")
        @test "BIOLOGÍA Y QUÍMICA" in ciqa
        @test "QUÍMICA" in ciqa
        @test "OTRAS ESPECIALIDADES QUÍMICAS" in ciqa
        @test "OTRAS" in ciqa
        @test !any(occursin("info:eu-repo", k) || k in ("classification", "cti") for k in ciqa)
        @test !any(all(isdigit, k) for k in ciqa)  # no bare numeric code ever kept as a keyword

        # cide: a non-cti scheme (LCSH, already free text) mixed with a cti code in the same field.
        cide = Corpus.parse_keywords("info:eu-repo/classification/LCSH/Mexico -- Economic conditions -- Regional disparities ; " *
                               "info:eu-repo/classification/cti/5")
        @test "Mexico -- Economic conditions -- Regional disparities" in cide
        @test "CIENCIAS SOCIALES" in cide

        # flacso: a scheme name that itself contains commas -- must not be split apart.
        flacso = Corpus.parse_keywords("info:eu-repo/classification/Tesauros UNESCO, POPIN, INE, OIT, CIDH, GENERO, LEMB/Producción Agrícola ; " *
                                 "info:eu-repo/classification/Tesauros UNESCO, POPIN, INE, OIT, CIDH, GENERO, LEMB/Trabajador Agrícola")
        @test flacso == ["Producción Agrícola", "Trabajador Agrícola"]

        # uam: regression for the comma-in-free-text bug -- "Estado, el" must survive as one
        # keyword, not be split into "Estado" and "el".
        uam = Corpus.parse_keywords("Sindicatos ; Salario mínimo ; Estado, el")
        @test "Estado, el" in uam
        @test "Estado" ∉ uam
        @test "el" ∉ uam

        # an unresolvable cti code (not in any catalog) is dropped, not kept as a raw number.
        @test Corpus.parse_keywords("info:eu-repo/classification/cti/999999") == String[]
    end

    @testset "Corpus.parse_author_names (role-marker/CURP/ORCID cleanup, isolated)" begin
        # Found live on the real 93-repo corpus while building experiments/author_matching's
        # vocabulary artifact: role markers embedded INSIDE the name field (not just as a prefix,
        # the only case an earlier version of this function handled), in all three positions.
        @test Corpus.parse_author_names("Acosta Silva, Adrián, asesor") ==
              ["Acosta Silva, Adrián", "Adrián Acosta Silva"]
        @test "Ana Verónica Charles Rodríguez" in Corpus.parse_author_names("Ana Verónica Asesor Charles Rodríguez")
        @test "Ana Verónica Charles Rodríguez" in Corpus.parse_author_names("Ana Verónica Co-Asesor Charles Rodríguez")
        @test Corpus.parse_author_names("Ayala López, Carmen Leticia Co-Asesor") ==
              ["Ayala López, Carmen Leticia", "Carmen Leticia Ayala López"]
        # a trailing colon right after the marker is consumed too, without corrupting anything
        # ELSE in the string (see the ORCID/URL regression check below).
        @test "Juan Perez" in Corpus.parse_author_names("Director: Juan Perez")
        @test "Juan Perez" in Corpus.parse_author_names("Asesor: Juan Perez")

        # underscore-joined compound surname (some repos' export convention) -> real space, not a
        # glued/leading-underscore token downstream.
        @test Corpus.parse_author_names("Adrian Rodriguez_Garcia") == ["Adrian Rodriguez Garcia"]

        # CURP-as-name, CVU-as-name, and bare/hash-prefixed ORCID: never a real name, dropped
        # entirely -- including the truncated/variant-separator ORCID forms found live at 93-repo
        # scale ("# " with a space, "#/" with a slash, and a checksum-digit short by one).
        @test Corpus.parse_author_names("BEGC770820HDFCNR08=asesorTesis") == String[]
        @test Corpus.parse_author_names("#0000-0001-5058-804X") == String[]
        @test Corpus.parse_author_names("# 0000-0001-5587-4467") == String[]
        @test Corpus.parse_author_names("#/0000-0001-5587-4467") == String[]
        @test Corpus.parse_author_names("#0000-0002-6380-368") == String[]
        @test Corpus.parse_author_names("CVU102349=asesorTesis") == String[]
        # RFC (Registro Federal de Contribuyentes, a THIRD separate Mexican id scheme from CURP)
        # + "=asesorTesis", and the bare glued-word "asesorTesis" with no "#"/"=" at all.
        @test Corpus.parse_author_names("JICB820212TJ0=asesorTesis") == String[]
        @test Corpus.parse_author_names("PEHV860712R55=asesorTesis") == String[]
        @test Corpus.parse_author_names("asesorTesis") == String[]

        # an id code GLUED onto an otherwise-real name via "#" (prefix/suffix/infix) is stripped,
        # keeping the real name -- unlike the whole-segment reject cases above, since there IS a
        # real name here. Found live at 93-repo scale in all three positions.
        @test Corpus.parse_author_names("#MARIA TERESA") == ["MARIA TERESA"]
        @test Corpus.parse_author_names("Aguilera Garcia Hugo Armando#AUGH810413HGTGRG08") ==
              ["Aguilera Garcia Hugo Armando"]
        @test "Almanza Lara Omar" in Corpus.parse_author_names("Almanza Lara Omar#AALO980509HGTLRM")  # truncated homoclave
        adolfo = Corpus.parse_author_names("Adolfo Alberto:#0000-0002-5130-5475 Cervantes Baqué")
        @test any(nm -> occursin("Adolfo", nm) && occursin("Cervantes", nm), adolfo)

        # a parenthetical ORCID annotation attached to a real name, plus "coordinador(a)" as an
        # additional role marker (both found live at 93-repo scale together in the same record).
        coord = Corpus.parse_author_names(
            "Bernardez de la Granja, Maria del Carmen, coordinadora (https://orcid.org/0000-0001-5114-9225)")
        @test any(nm -> occursin("Bernardez", nm) && occursin("Carmen", nm) && !occursin("orcid", lowercase(nm)) &&
                        !occursin("coordinadora", lowercase(nm)), coord)

        # regression: role-marker/colon cleanup must NEVER corrupt a real URL/ORCID elsewhere in
        # the corpus (an earlier version's blanket colon-strip turned "https://" into "https //").
        @test Corpus.parse_author_names("https://orcid.org/0000-0001-5058-1227") ==
              ["https://orcid.org/0000-0001-5058-1227"]

        # plain real names and the existing comma-order-swap must be completely untouched.
        @test Corpus.parse_author_names("Juan Perez") == ["Juan Perez"]
        @test Corpus.parse_author_names("Perez, Juan") == ["Perez, Juan", "Juan Perez"]
    end

    @testset "AuthorConsolidation (clustering + overrides, isolated)" begin
        # Guards the graph-based clustering that groups raw author profiles into consolidated
        # ones: q-gram-based name matching (compute_name_clusters — see its own testset below for
        # the cases it exists to get right) and human overrides (merge forces an edge the
        # algorithm can't find; split removes one it shouldn't have made) — see
        # AuthorConsolidation.jl.
        mk(name) = Dict{String,Any}("name" => name, "doc_count" => 1)

        names = ["Juan Perez Gonzalez", "J. Perez Gonzalez", "JUAN PEREZ GONZALEZ",
                  "Ana Ruiz", "A. Ruiz",
                  "Pedro Soto", "Maria Soto"]  # last two share no key at all -> must stay separate

        no_overrides = (merges=Vector{Vector{String}}(), splits=Vector{Tuple{String,String}}(), imputes=Vector{Vector{String}}())
        groups = AuthorConsolidation.compute_groups(names, no_overrides)
        by_first = Dict(sort(g)[1] => sort(g) for g in groups)

        @test by_first["J. Perez Gonzalez"] == sort(["Juan Perez Gonzalez", "J. Perez Gonzalez", "JUAN PEREZ GONZALEZ"])
        @test by_first["A. Ruiz"] == sort(["Ana Ruiz", "A. Ruiz"])
        @test any(g -> g == ["Pedro Soto"], groups)
        @test any(g -> g == ["Maria Soto"], groups)

        # merge: force two names together that share no automatic key at all
        merge_overrides = (merges=[["Pedro Soto", "Maria Soto"]], splits=Tuple{String,String}[], imputes=Vector{Vector{String}}())
        merged_groups = AuthorConsolidation.compute_groups(names, merge_overrides)
        @test any(g -> sort(g) == ["Maria Soto", "Pedro Soto"], merged_groups)

        # split: break an automatic match apart (isolated pair, no third name bridging them
        # transitively — with one in `names` this would stay connected via "JUAN PEREZ GONZALEZ",
        # which is the real, documented limit of a single pairwise split, not a bug)
        split_names = ["Carla Nunez", "C. Nunez"]
        no_overrides_2 = (merges=Vector{Vector{String}}(), splits=Tuple{String,String}[], imputes=Vector{Vector{String}}())
        @test length(AuthorConsolidation.compute_groups(split_names, no_overrides_2)) == 1

        split_overrides = (merges=Vector{Vector{String}}(), splits=[("Carla Nunez", "C. Nunez")], imputes=Vector{Vector{String}}())
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

    @testset "AuthorConsolidation stable leader/id across rebuilds (isolated)" begin
        mk(name, doc_count) = Dict{String,Any}("name" => name, "doc_count" => doc_count)
        no_ov = (merges=Vector{Vector{String}}(), splits=Tuple{String,String}[], imputes=Vector{Vector{String}}())

        function rebuild(names_with_counts, tmpdir; overrides=no_ov)
            authors_data = [mk(n, c) for (n, c) in names_with_counts]
            raw_id_of, _ = AuthorConsolidation.assign_raw_ids(authors_data)
            by_name = Dict{String,Any}(a["name"] => a for a in authors_data)
            raw_names = collect(keys(by_name))
            groups = AuthorConsolidation.compute_groups(raw_names, overrides)
            prev_leaders = AuthorConsolidation.previous_leader_info(AuthorConsolidation.load_all(tmpdir))
            base_dir = joinpath(tmpdir, AuthorConsolidation.CONSOLIDATED_SUBDIR)
            isdir(base_dir) && rm(base_dir; recursive=true, force=true)
            mkpath(base_dir)
            for g in groups
                profile = AuthorConsolidation.rollup(g, by_name, raw_id_of, prev_leaders)
                dir = joinpath(base_dir, AuthorConsolidation._bucket_for(g))
                mkpath(dir)
                open(joinpath(dir, "$(profile["consolidated_id"]).toml"), "w") do io
                    TOML.print(io, profile)
                end
            end
            return raw_id_of, Dict(p["raw_names"] => p for p in AuthorConsolidation.load_all(tmpdir))
        end

        # unchanged corpus across two rebuilds -> identical id
        tmp1 = mktempdir()
        raw_id_of_1, profiles_1 = rebuild([("Juan Perez Gonzalez", 2), ("JUAN PEREZ GONZALEZ", 1)], tmp1)
        group_key_1 = sort(["Juan Perez Gonzalez", "JUAN PEREZ GONZALEZ"])
        first_id = profiles_1[group_key_1]["consolidated_id"]
        @test first_id == raw_id_of_1["Juan Perez Gonzalez"]  # leader = higher doc_count
        _, profiles_1b = rebuild([("Juan Perez Gonzalez", 2), ("JUAN PEREZ GONZALEZ", 1)], tmp1)
        @test profiles_1b[group_key_1]["consolidated_id"] == first_id

        # corpus grows (a genuine variant of the same person added) -> id unchanged
        tmp2 = mktempdir()
        raw_id_of_2, profiles_2 = rebuild([("Juan Perez Gonzalez", 2), ("JUAN PEREZ GONZALEZ", 1)], tmp2)
        id_before_growth = profiles_2[group_key_1]["consolidated_id"]
        _, profiles_2b = rebuild([("Juan Perez Gonzalez", 2), ("JUAN PEREZ GONZALEZ", 1),
                                    ("J. Perez Gonzalez", 1)], tmp2)
        grown_key = sort(["Juan Perez Gonzalez", "JUAN PEREZ GONZALEZ", "J. Perez Gonzalez"])
        @test profiles_2b[grown_key]["consolidated_id"] == id_before_growth

        # split: two names with NO natural key in common, together only via an override merge --
        # the piece that keeps the old leader ("Pedro Soto", higher doc_count) keeps the old id;
        # the other piece ("Maria Soto") gets its OWN fresh id, not a leftover of the old one.
        tmp3 = mktempdir()
        merge_ov = (merges=[["Pedro Soto", "Maria Soto"]], splits=Tuple{String,String}[], imputes=Vector{Vector{String}}())
        raw_id_of_3, profiles_3 = rebuild([("Pedro Soto", 2), ("Maria Soto", 1)], tmp3; overrides=merge_ov)
        merged_key = sort(["Pedro Soto", "Maria Soto"])
        old_id = profiles_3[merged_key]["consolidated_id"]
        @test old_id == raw_id_of_3["Pedro Soto"]
        _, profiles_3b = rebuild([("Pedro Soto", 2), ("Maria Soto", 1)], tmp3)  # no merge override this time -> splits apart
        @test profiles_3b[["Pedro Soto"]]["consolidated_id"] == old_id
        @test profiles_3b[["Maria Soto"]]["consolidated_id"] == raw_id_of_3["Maria Soto"]
        @test profiles_3b[["Maria Soto"]]["consolidated_id"] != old_id

        # merge: two previously-separate groups (one with 2 raw names, one with 1) forced together
        # -> the LARGER previous group's id/leader survives.
        tmp4 = mktempdir()
        raw_id_of_4, profiles_4 = rebuild([("Roberto Diaz", 2), ("ROBERTO DIAZ", 1), ("Elena Diaz", 1)], tmp4)
        bigger_key = sort(["Roberto Diaz", "ROBERTO DIAZ"])
        bigger_old_id = profiles_4[bigger_key]["consolidated_id"]
        @test bigger_old_id == raw_id_of_4["Roberto Diaz"]
        merge_diaz_ov = (merges=[["Roberto Diaz", "Elena Diaz"]], splits=Tuple{String,String}[], imputes=Vector{Vector{String}}())
        _, profiles_4b = rebuild([("Roberto Diaz", 2), ("ROBERTO DIAZ", 1), ("Elena Diaz", 1)], tmp4; overrides=merge_diaz_ov)
        all_merged_key = sort(["Roberto Diaz", "ROBERTO DIAZ", "Elena Diaz"])
        @test profiles_4b[all_merged_key]["consolidated_id"] == bigger_old_id
    end

    @testset "AuthorConsolidation overrides TOML (load_overrides/save_imputes, isolated)" begin
        tmpdir = mktempdir()
        path = joinpath(tmpdir, "author_overrides.toml")

        # missing file: no overrides, not an error
        empty = AuthorConsolidation.load_overrides(path)
        @test isempty(empty.merges) && isempty(empty.splits) && isempty(empty.imputes)

        # hand-authored merge/split, read back correctly, impute empty
        open(path, "w") do io
            TOML.print(io, Dict("merge" => [["A", "B"]], "split" => [["C", "D"]]))
        end
        loaded = AuthorConsolidation.load_overrides(path)
        @test loaded.merges == [["A", "B"]]
        @test loaded.splits == [("C", "D")]
        @test isempty(loaded.imputes)

        # save_imputes: preserves merge/split verbatim, writes only impute
        AuthorConsolidation.save_imputes([["E", "F"], ["G", "H"]], path)
        after = AuthorConsolidation.load_overrides(path)
        @test after.merges == [["A", "B"]]
        @test after.splits == [("C", "D")]
        @test Set(after.imputes) == Set([["E", "F"], ["G", "H"]])

        # a second save_imputes call fully REPLACES the previous impute contents, doesn't accumulate
        AuthorConsolidation.save_imputes([["I", "J"]], path)
        replaced = AuthorConsolidation.load_overrides(path)
        @test replaced.imputes == [["I", "J"]]
        @test replaced.merges == [["A", "B"]]  # still untouched

        # compute_groups treats merge and impute identically as forced edges
        names = ["X Y", "Z W"]
        ov = (merges=Vector{Vector{String}}(), splits=Tuple{String,String}[], imputes=[["X Y", "Z W"]])
        groups = AuthorConsolidation.compute_groups(names, ov)
        @test any(g -> sort(g) == sort(names), groups)
    end

    @testset "AuthorConsolidation.compute_name_clusters (q-gram + oracle, isolated)" begin
        # Replaces the old full_key/initials_key exact-match clustering (see the
        # project_initials_key_collision_bug note this fixes). initials_key reduced every
        # non-final token to its first letter, so different real people sharing two initials and
        # a surname collided into one exact-match key -- confirmed live on a real 10-repo rebuild
        # for these three names.
        function same_cluster(groups, a, b)
            for g in groups
                (a in g) && (b in g) && return true
            end
            return false
        end

        perez_names = ["JOSE CAMARGO PEREZ", "JUAN CONTRERAS PEREZ", "JULIO CANDELA PEREZ",
                        "Juan Contreras Perez", "J. Contreras Perez"]
        perez_groups = AuthorConsolidation.compute_name_clusters(perez_names)
        @test !same_cluster(perez_groups, "JOSE CAMARGO PEREZ", "JUAN CONTRERAS PEREZ")
        @test !same_cluster(perez_groups, "JOSE CAMARGO PEREZ", "JULIO CANDELA PEREZ")
        @test !same_cluster(perez_groups, "JUAN CONTRERAS PEREZ", "JULIO CANDELA PEREZ")
        # ... while genuine variants of the SAME person still merge, in the same run.
        @test same_cluster(perez_groups, "JUAN CONTRERAS PEREZ", "Juan Contreras Perez")
        @test same_cluster(perez_groups, "JUAN CONTRERAS PEREZ", "J. Contreras Perez")

        # regression: identical DOUBLE surname, different given name -- a harder counter-example
        # than the one above (initials_key wouldn't even have collided these; a naive q-gram bag
        # score would have, since "chavez gonzalez" shared verbatim dominates a blended score).
        chavez_names = ["MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ"]
        @test !same_cluster(AuthorConsolidation.compute_name_clusters(chavez_names),
                             "MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ")

        # real typo/transliteration variants of one person still merge (exact-key matching, and a
        # strict pairwise veto alone, both miss this -- it needs the generous phase-1 + oracle
        # design specifically).
        alexei_names = ["ALEXEI FEDOROVISH LICEA NAVARRO", "Alexei Federovish Licea Navarro"]
        @test same_cluster(AuthorConsolidation.compute_name_clusters(alexei_names),
                            alexei_names[1], alexei_names[2])

        # compound surname ("Torres De La Cruz") truncated to just its paternal component
        # ("Torres") must still match -- the whole point of _split_given_surname recognizing "de la
        # cruz" as one maternal-surname unit instead of "la"/"de" leaking in as fake given names.
        cruz_names = ["Victor Manuel Torres De La Cruz", "Victor Torres"]
        @test same_cluster(AuthorConsolidation.compute_name_clusters(cruz_names),
                            cruz_names[1], cruz_names[2])

        # garbage ORCID/URL "names" collapse to identical tokens under this tokenizer (the
        # pre-existing 117-member "_url" blob) -- must never be treated as a match.
        orcid_names = ["https://orcid.org/0000-0001-5058-1227", "https://orcid.org/0000-0002-4870-4803"]
        @test !same_cluster(AuthorConsolidation.compute_name_clusters(orcid_names),
                             orcid_names[1], orcid_names[2])
    end

    @testset "NameVocabulary (vocabulary + correction, isolated)" begin
        names = ["ALEXEI FEDOROVISH LICEA NAVARRO", "Juan Contreras Perez",
                  "MARIA GUADALUPE LOPEZ", "Guadalupe Lopez De La Cruz",
                  "https://orcid.org/0000-0001-5058-1227"]
        v = NameVocabulary.build_name_vocabulary(names)

        # compound names split into individual per-token popularity, not one joint unit
        @test NameVocabulary.popularity(v, "alexei", :given) == 1
        # "guadalupe" splits differently by name: "MARIA GUADALUPE LOPEZ" has 2 given-position
        # tokens before "lopez", so AC._split_given_surname's paternal-surname absorption (see its
        # own docstring) treats "guadalupe" as the paternal surname there (surname=[guadalupe,lopez]) --
        # a real, accepted ambiguity ("Guadalupe" is common as BOTH a given name and a surname in
        # Mexican naming, and token position alone can't tell them apart). "Guadalupe Lopez De La
        # Cruz" has only ONE given-position token before its surname span, so "guadalupe" stays
        # given there.
        @test NameVocabulary.popularity(v, "guadalupe", :given) == 1    # "Guadalupe Lopez De La Cruz"
        @test NameVocabulary.popularity(v, "guadalupe", :surname) == 1  # "MARIA GUADALUPE LOPEZ"
        @test NameVocabulary.popularity(v, "juan", :given) == 1
        @test NameVocabulary.popularity(v, "cruz", :surname) == 1

        # bare initials never enter the vocabulary, even if the raw name has one
        @test !NameVocabulary.in_vocab(v, "j", :given)
        @test NameVocabulary.popularity(v, "j", :given) == 0

        # surname particles (de/la/...) are part of the surname SPAN but never their own entry
        @test !NameVocabulary.in_vocab(v, "de", :surname)
        @test !NameVocabulary.in_vocab(v, "la", :surname)

        # garbage (ORCID/URL) names contribute nothing
        @test NameVocabulary.popularity(v, "url", :given) == 0
        @test NameVocabulary.popularity(v, "url", :surname) == 0

        # exact vocabulary hit: returned as-is, full confidence
        @test NameVocabulary.correct_token(v, "guadalupe", :given) == ("guadalupe", 1.0)
        # bare initial: never corrected, never looked up
        @test NameVocabulary.correct_token(v, "j", :given) == ("j", 1.0)

        # real typo correction against a slightly larger vocabulary (needs enough tokens for the
        # popularity-ratio gate to have somewhere to point at)
        bigger = vcat(names, ["Jose Ramirez", "Jose Torres", "Jose Martinez", "Jose Alvarez",
                                "Jose Gutierrez", "Jose Ruiz", "Jose Flores",
                                "Guadalupe Sanchez", "Guadalupe Morales", "Guadalupe Vargas"])
        v2 = NameVocabulary.build_name_vocabulary(bigger)
        # "jsoe" is a single transposition of "jose" (distance 1 under DamerauLevenshtein) -- the
        # BK-tree candidate generation finds it directly by edit-distance radius, fixing a real
        # limitation the earlier q-gram-index candidate generation had (a transposition on a token
        # this short shares ZERO q-grams with the correct spelling, so it was never even a
        # candidate).
        @test NameVocabulary.correct_token(v2, "jsoe", :given) == ("jose", 0.5)
        # "guadalup" (missing trailing "e") must correct to "guadalupe" -- a real truncation typo.
        c2, conf2 = NameVocabulary.correct_token(v2, "guadalup", :given)
        @test c2 == "guadalupe"
        @test conf2 > 0.0

        # a token that's ALREADY a distinct, real, independently-popular name must NOT be
        # "corrected" into a different real name just because they're similar (e.g. must not
        # rewrite "juan" into anything else) -- correction never fires when there's no exact-vocab
        # gap to fill.
        @test NameVocabulary.correct_token(v2, "juan", :given) == ("juan", 1.0)

        # nothing plausible in the vocabulary: left unchanged, confidence 0.0 (not 1.0 -- distinct
        # from "nothing needed correcting")
        far_corrected, far_conf = NameVocabulary.correct_token(v2, "xyzzyx", :given)
        @test far_corrected == "xyzzyx"
        @test far_conf == 0.0

        # regression: an earlier version short-circuited on ANY exact vocabulary hit before ever
        # searching for a more popular candidate -- a no-op whenever the vocabulary is built from
        # the SAME corpus being corrected, since every token (even a one-off typo) is trivially
        # "in vocabulary" against itself. Confirmed live: this changed ZERO of 19,412 raw names on
        # the real 10-repo corpus under the old logic. "hernandes" (s/z typo, popularity 1, q-gram
        # similarity 0.6 to "hernandez" -- long enough a token that a single-letter change still
        # leaves most 4-grams intact, unlike a short name) appears once against 5 "hernandez"s.
        v3 = NameVocabulary.build_name_vocabulary(vcat(bigger,
            ["Ana Hernandes", "Luis Hernandez", "Rosa Hernandez", "Pedro Hernandez",
             "Sofia Hernandez", "Marco Hernandez"]))
        @test NameVocabulary.in_vocab(v3, "hernandes", :surname)  # exact hit against itself, by construction
        c3, conf3 = NameVocabulary.correct_token(v3, "hernandes", :surname)
        @test c3 == "hernandez"
        @test conf3 > 0.0

        # the max_own_popularity gate: a token seen MORE than once is treated as an established,
        # real spelling and never touched, no matter how popular a q-gram-similar alternative is --
        # found live: without this gate, genuinely distinct real names (not typos) got flattened
        # into a more-common one (e.g. "Alejandra"->"alejandro") purely from a 2x popularity edge.
        v4 = NameVocabulary.build_name_vocabulary(vcat(bigger,
            ["Ana Hernandes", "Eva Hernandes", "Luis Hernandez", "Rosa Hernandez", "Pedro Hernandez",
             "Sofia Hernandez", "Marco Hernandez"]))
        @test NameVocabulary.popularity(v4, "hernandes", :surname) == 2
        @test NameVocabulary.correct_token(v4, "hernandes", :surname) == ("hernandes", 1.0)
    end

    @testset "PrecisionClustering (precision-first, full-words-only, isolated)" begin
        function same_cluster(groups, a, b)
            for g in groups
                (a in g) && (b in g) && return true
            end
            return false
        end

        names = ["JOSE CAMARGO PEREZ", "JUAN CONTRERAS PEREZ", "JULIO CANDELA PEREZ",
                  "Juan Contreras Perez", "J. Contreras Perez",
                  "MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ",
                  "ALEXEI FEDOROVISH LICEA NAVARRO", "Alexei Federovish Licea Navarro",
                  "Victor Manuel Torres De La Cruz", "Victor Torres",
                  "Juan Tellez Avila", "Juan Tellez", "J. Tellez Avila",
                  "https://orcid.org/0000-0001-5058-1227", "https://orcid.org/0000-0002-4870-4803",
                  "Allyson Benton", "Allyson Lucinda Benton"]
        vocab = NameVocabulary.build_name_vocabulary(names)
        groups = PrecisionClustering.compute_precision_clusters(names, vocab)

        @test !same_cluster(groups, "JOSE CAMARGO PEREZ", "JUAN CONTRERAS PEREZ")
        @test !same_cluster(groups, "JOSE CAMARGO PEREZ", "JULIO CANDELA PEREZ")
        @test !same_cluster(groups, "JUAN CONTRERAS PEREZ", "JULIO CANDELA PEREZ")
        @test same_cluster(groups, "JUAN CONTRERAS PEREZ", "Juan Contreras Perez")
        # bare initial -- must NOT merge in this stage, unlike AC.compute_name_clusters
        @test !same_cluster(groups, "JUAN CONTRERAS PEREZ", "J. Contreras Perez")
        @test !same_cluster(groups, "J. Tellez Avila", "Juan Tellez")
        @test !same_cluster(groups, "MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ")
        # a genuine transposition typo ("Fedorovish"/"Federovish", distance 1 under :damerau,
        # length 10 -> score 1-1/10=0.9, right at this stage's threshold) DOES connect here --
        # this is exactly what motivated switching this stage's default scoring metric from
        # q-gram Jaccard (where the same pair only scored ~0.79, comfortably below 0.9) to
        # edit-distance scoring.
        @test same_cluster(groups, "ALEXEI FEDOROVISH LICEA NAVARRO", "Alexei Federovish Licea Navarro")
        # compound-surname truncation, full words only -- still must merge
        @test same_cluster(groups, "Victor Manuel Torres De La Cruz", "Victor Torres")
        @test same_cluster(groups, "Juan Tellez Avila", "Juan Tellez")
        @test !same_cluster(groups, "https://orcid.org/0000-0001-5058-1227", "https://orcid.org/0000-0002-4870-4803")
        @test same_cluster(groups, "Allyson Benton", "Allyson Lucinda Benton")

        # regression: the truncation rule in precision_match_score (a short single-given/
        # single-surname name's surname equalling a longer name's LAST given-name token) scores a
        # PERFECT match=1.0/surname=1.0 for an ACCIDENTAL collision through a common surname
        # ("gonzalez") sitting as an unrelated longer name's paternal-surname CANDIDATE next to a
        # totally different real surname -- found live on the real 10-repo corpus as a 32-member
        # blob of unrelated "Carlos"/"Ricardo González ..." people. No connect threshold can catch
        # this (both cases score identically); only precision_contradiction/precision_split (run
        # automatically by compute_precision_clusters) does, by checking the DIRECT surname score
        # between every pair in the resulting component, not just the pairs that formed an edge.
        gonzalez_names = ["Carlos González", "CARLOS RICARDO GONZALEZ RUIZ", "RICARDO GONZALEZ SANCHEZ",
                            "CARLOS ERNESTO GONZALEZ CHICAS", "Ricardo Gonzalez", "Ricardo González"]
        gv = NameVocabulary.build_name_vocabulary(gonzalez_names)
        ggroups = PrecisionClustering.compute_precision_clusters(gonzalez_names, gv)
        # the three genuinely different real surnames (ruiz/sanchez/chicas) must never collapse
        # into the same group, however the split happens to partition the rest.
        @test !same_cluster(ggroups, "CARLOS RICARDO GONZALEZ RUIZ", "RICARDO GONZALEZ SANCHEZ")
        @test !same_cluster(ggroups, "CARLOS RICARDO GONZALEZ RUIZ", "CARLOS ERNESTO GONZALEZ CHICAS")
        @test !same_cluster(ggroups, "RICARDO GONZALEZ SANCHEZ", "CARLOS ERNESTO GONZALEZ CHICAS")
        # ... while genuine same-format-and-surname duplicates still merge
        @test same_cluster(ggroups, "Ricardo Gonzalez", "Ricardo González")
    end

    @testset "PrecisionClustering hybrid bucket parallelization (small-path vs large-path agree)" begin
        function same_cluster(groups, a, b)
            for g in groups
                (a in g) && (b in g) && return true
            end
            return false
        end
        canon(groups) = Set(Tuple(sort(g)) for g in groups)

        # A single ~150-member bucket (all sharing surname "Hernandez") -- large enough to force
        # the LARGE-bucket code path (its own O(size^2) loop split across batches/threads) when
        # `large_bucket_threshold` is set low, vs the SMALL-bucket path (one bucket among many,
        # batched with others) when set high. Given names are random 8-letter strings so any two
        # are, overwhelmingly likely, far apart in edit distance -- no incidental connections.
        rng = Random.MersenneTwister(42)
        alphabet = collect("abcdefghijklmnopqrstuvwxyz")
        given_pool = [String(rand(rng, alphabet, 8)) for _ in 1:150]
        big_names = [uppercasefirst(g) * " Hernandez" for g in given_pool]
        # 3 same-person format duplicates, to confirm real merges still happen under BOTH paths
        dup_targets = (1, 50, 100)
        for i in dup_targets
            push!(big_names, uppercase(big_names[i]))
        end

        bv = NameVocabulary.build_name_vocabulary(big_names)
        groups_small_path = PrecisionClustering.compute_precision_clusters(big_names, bv; large_bucket_threshold=10_000)
        groups_large_path = PrecisionClustering.compute_precision_clusters(big_names, bv; large_bucket_threshold=10)
        # the whole point: both code paths must agree on EVERY group, not just on aggregate counts
        @test canon(groups_small_path) == canon(groups_large_path)

        for i in dup_targets
            @test same_cluster(groups_large_path, big_names[i], uppercase(big_names[i]))
        end
        @test !same_cluster(groups_large_path, big_names[1], big_names[2])
    end

    @testset "Imputation (v2: recover initials via a purpose-built strict test, isolated)" begin
        function same_cluster(groups, a, b)
            for g in groups
                (a in g) && (b in g) && return true
            end
            return false
        end
        noauth(names) = Dict{String,Any}(nm => Dict{String,Any}("coauthors" => String[]) for nm in names)

        names = ["JUAN CONTRERAS PEREZ", "Juan Contreras Perez", "J. Contreras Perez",
                  "ALEXEI FEDOROVISH LICEA NAVARRO", "Alexei Federovish Licea Navarro",
                  "MANUEL ALBERTO CHAVEZ GONZALEZ", "MARIA ANTONIETA CHAVEZ GONZALEZ",
                  "https://orcid.org/0000-0001-5058-1227", "https://orcid.org/0000-0002-4870-4803"]
        vocab = NameVocabulary.build_name_vocabulary(names)
        groups = PrecisionClustering.compute_precision_clusters(names, vocab)
        # precision clustering defers the initials-only pair (see PrecisionClustering's own tests)
        @test !same_cluster(groups, "JUAN CONTRERAS PEREZ", "J. Contreras Perez")

        proposals = Imputation.impute_candidates(groups, noauth(names))
        # recovers the initials case -- Imputation._impute_edge's bare-initial match scores "J."
        # against "Juan"/"JUAN" a perfect match, unlike precision clustering's own initial-blind
        # scoring; this single bridge has no OTHER conflicting neighbor, so it's never "risky".
        @test any(p -> "JUAN CONTRERAS PEREZ" in p && "J. Contreras Perez" in p, proposals)
        # NEVER a candidate pair at all: neither side has a bare initial, so this different-given-
        # name/same-double-surname pair is never even re-examined here (precision clustering already
        # correctly rejected it with its own validated threshold).
        @test !any(p -> "MANUEL ALBERTO CHAVEZ GONZALEZ" in p && "MARIA ANTONIETA CHAVEZ GONZALEZ" in p, proposals)
        # garbage names are never touched
        @test !any(p -> any(occursin("orcid", x) for x in p), proposals)
        # NEVER a candidate pair: a genuine q-gram-typo-tolerant pair ("Fedorovish"/"Federovish")
        # has no bare initial on either side, so imputation (by design) leaves this entirely to
        # precision clustering/production, never re-litigating it here.
        @test !any(p -> "ALEXEI FEDOROVISH LICEA NAVARRO" in p && "Alexei Federovish Licea Navarro" in p, proposals)
    end

    @testset "Imputation (v2: structural ambiguity detection, coauthor-cluster rescue, no clique requirement)" begin
        function same_cluster(groups, a, b)
            for g in groups
                (a in g) && (b in g) && return true
            end
            return false
        end
        noauth(names) = Dict{String,Any}(nm => Dict{String,Any}("coauthors" => String[]) for nm in names)

        # Two DIFFERENT real people sharing a surname, plus an ambiguous bare-initial-only group
        # that independently satisfies Imputation._impute_edge against BOTH of them (found live on
        # the real 10-repo corpus, e.g. "A. Barrios" bridging "ABELARDO NUÑEZ BARRIOS" and "Alberto
        # Salazar Barrios") -- with no coauthor evidence to rescue either edge, BOTH must be dropped:
        # the ambiguity is detected because Abelardo's and Alberto's groups are NOT compatible with
        # each other (checked directly, even though they were never a name-based candidate pair
        # themselves), not by counting how many initials aligned in one single edge.
        names_bridge = ["ABELARDO NUÑEZ BARRIOS", "Alberto Salazar Barrios", "A. Barrios", "Barrios, A."]
        vocab_bridge = NameVocabulary.build_name_vocabulary(names_bridge)
        groups_bridge = PrecisionClustering.compute_precision_clusters(names_bridge, vocab_bridge)
        @test !same_cluster(groups_bridge, "ABELARDO NUÑEZ BARRIOS", "Alberto Salazar Barrios")
        proposals_bridge = Imputation.impute_candidates(groups_bridge, noauth(names_bridge))
        @test !any(p -> "ABELARDO NUÑEZ BARRIOS" in p, proposals_bridge)
        @test !any(p -> "Alberto Salazar Barrios" in p, proposals_bridge)

        # Same ambiguous bridge, but now "A. Barrios" and Abelardo's profile share a coauthor (whose
        # own name is itself part of this corpus, so its identity resolves through the SAME
        # clustering) -- that specific risky edge is rescued (Abelardo merges with "A. Barrios"),
        # while the OTHER risky edge (Alberto, uncorroborated) is still dropped. This is the
        # mechanism that replaces the old blanket clique requirement.
        names_bridge2 = ["ABELARDO NUÑEZ BARRIOS", "Alberto Salazar Barrios", "A. Barrios",
                          "MARIA LOPEZ SANCHEZ"]
        vocab_bridge2 = NameVocabulary.build_name_vocabulary(names_bridge2)
        groups_bridge2 = PrecisionClustering.compute_precision_clusters(names_bridge2, vocab_bridge2)
        by_name_bridge2 = Dict{String,Any}(
            "ABELARDO NUÑEZ BARRIOS" => Dict{String,Any}("coauthors" => ["MARIA LOPEZ SANCHEZ"]),
            "Alberto Salazar Barrios" => Dict{String,Any}("coauthors" => String[]),
            "A. Barrios" => Dict{String,Any}("coauthors" => ["MARIA LOPEZ SANCHEZ"]),
            "MARIA LOPEZ SANCHEZ" => Dict{String,Any}("coauthors" => String[]),
        )
        proposals_bridge2 = Imputation.impute_candidates(groups_bridge2, by_name_bridge2)
        @test any(p -> "ABELARDO NUÑEZ BARRIOS" in p && "A. Barrios" in p, proposals_bridge2)
        @test !any(p -> "Alberto Salazar Barrios" in p, proposals_bridge2)

        # Three formatting variants of the SAME person, forming a plain CHAIN (not required to be a
        # full clique any more) -- must still merge into ONE proposal covering all three groups.
        names_clique = ["JENARO LEOCADIO VARELA CASELIS", "Jenaro L. Varela Caselis",
                         "Varela Caselis, Jenaro L."]
        vocab_clique = NameVocabulary.build_name_vocabulary(names_clique)
        groups_clique = PrecisionClustering.compute_precision_clusters(names_clique, vocab_clique)
        proposals_clique = Imputation.impute_candidates(groups_clique, noauth(names_clique))
        @test any(proposals_clique) do p
            all(nm -> nm in p, names_clique)
        end
    end

    @testset "AuthorConsolidation._surname_of_name (bucket key, isolated)" begin
        # The "apellido" convention _bucket_for uses to pick a consolidated group's on-disk
        # directory: last tokenized word, with a hyphenated compound surname tokenizing exactly
        # like its space-separated form.
        @test AuthorConsolidation._surname_of_name("Juan Antonio Garcia Lopez") == "lopez"
        @test AuthorConsolidation._surname_of_name("J. A. Garcia-Lopez") == "lopez"
        @test AuthorConsolidation._surname_of_name("Roberto Hernandez Diaz") == "diaz"
        @test AuthorConsolidation._surname_of_name("") == ""
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
