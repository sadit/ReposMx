module Server

using HTTP, JSON, URIs
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Storage: get_repo_stats, list_repo_names, get_repo_dir
using ..Search: SearchEngine, query_index, search_authors, find_similar_authors_by_profile,
                find_similar_documents_by_references, search_references,
                get_document_references, get_author_documents, get_coauthors,
                get_topic_elements, search_document_paragraphs, get_detailed_statistics,
                get_author_network
using ..Wikipedia: explain_concept

export start_server

const ASSETS_DIR = let
    pkg = pkgdir(@__MODULE__)
    pkg !== nothing ? normpath(joinpath(pkg, "assets")) : normpath(joinpath(@__DIR__, "..", "assets"))
end

"""
    parse_int(params, key, default)

Parses an integer query parameter, falling back to `default` when absent or invalid.
"""
function parse_int(params, key::AbstractString, default::Int)
    v = tryparse(Int, get(params, key, ""))
    return v === nothing ? default : v
end

"""
    parse_opt_str(params, key)

Returns a non-empty string query parameter, or `nothing`.
"""
function parse_opt_str(params, key::AbstractString)
    v = get(params, key, nothing)
    return (v !== nothing && !isempty(v)) ? v : nothing
end

"""
    parse_opt_int(params, key)

Returns a parsed integer query parameter, or `nothing` when absent/invalid.
"""
function parse_opt_int(params, key::AbstractString)
    v = get(params, key, nothing)
    (v === nothing || isempty(v)) && return nothing
    return tryparse(Int, v)
end

const JSON_HEADERS = ["Content-Type" => "application/json; charset=utf-8"]
json_response(data; status::Int=200) = HTTP.Response(status, JSON_HEADERS, JSON.json(data))

"""
    start_server(; port=8000, host="0.0.0.0", data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)

Starts the HTTP server and web interface (Read-Only analytical client). Static assets (HTML/CSS/JS)
are served directly from the `assets/` directory via `HTTP.fileserver`; only `/api/*` and `/file` are
handled programmatically.
"""
function start_server(; port::Int=8000, host::String="0.0.0.0", data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
    println("Loading search engines for server on port $port...")
    engine = SearchEngine(; index_dir)

    router = HTTP.Router(HTTP.fileserver(ASSETS_DIR))

    HTTP.register!(router, "GET", "/api/stats", function(req)
        stats = get_repo_stats(; data_dir)
        return json_response(stats)
    end)

    HTTP.register!(router, "GET", "/api/info", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        repo = parse_opt_str(params, "repo")
        stats = get_detailed_statistics(engine; repo)
        return json_response(stats)
    end)

    HTTP.register!(router, "GET", "/api/search", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        repo = parse_opt_str(params, "repo")
        doc_type = parse_opt_str(params, "doc_type")
        year_min = parse_opt_int(params, "year_min")
        year_max = parse_opt_int(params, "year_max")
        wiki = get(params, "wiki", "true") == "true"
        top = parse_int(params, "top", 10)
        offset = parse_int(params, "offset", 0)

        res = query_index(engine, q; top, offset, repo, doc_type, year_min, year_max, include_wiki=wiki)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/authors", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        top = parse_int(params, "top", 10)
        offset = parse_int(params, "offset", 0)

        res = search_authors(engine, q; top, offset)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/authors/topic", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        repo = parse_opt_str(params, "repo")
        top = parse_int(params, "top", 10)

        res = get_topic_elements(engine, q; repo, limit=top)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/authors/similar", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        repo = parse_opt_str(params, "repo")
        top = parse_int(params, "top", 10)

        res = find_similar_authors_by_profile(engine, q; top, repo)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/authors/network", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        if isempty(strip(q))
            return json_response(Dict("error" => "Parámetro q requerido", "nodes" => [], "edges" => []); status=400)
        end
        res = get_author_network(engine, q)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/authors/docs", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        top = parse_int(params, "top", 50)

        res = get_author_documents(engine, q; limit=top)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/references", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        repo = parse_opt_str(params, "repo")
        top = parse_int(params, "top", 10)
        offset = parse_int(params, "offset", 0)

        res = search_references(engine, q; top, offset, repo)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/document/references", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        repo = get(params, "repo", "")
        doc_id = get(params, "doc_id", "")

        if isempty(repo) || isempty(doc_id)
            return json_response(Dict("error" => "Parámetros repo y doc_id requeridos"); status=400)
        end

        res = get_document_references(engine, repo, doc_id)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/document/similar_refs", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        repo = get(params, "repo", "")
        doc_id = get(params, "doc_id", "")
        top = parse_int(params, "top", 10)

        if isempty(repo) || isempty(doc_id)
            return json_response(Dict("error" => "Parámetros repo y doc_id requeridos"); status=400)
        end

        res = find_similar_documents_by_references(engine, repo, doc_id; top)
        return json_response(res)
    end)

    HTTP.register!(router, "GET", "/api/document/paragraphs", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        repo = get(params, "repo", "")
        doc_id = get(params, "doc_id", "")

        if isempty(repo) || isempty(doc_id)
            return json_response(Dict("error" => "Parámetros repo y doc_id requeridos"); status=400)
        end

        res = search_document_paragraphs(engine, repo, doc_id, q; top=5)
        return json_response(res)
    end)

    # Web Shell / Terminal Command Executor (Read-Only)
    HTTP.register!(router, "GET", "/api/cli/execute", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        raw_cmd = strip(get(params, "cmd", ""))

        if isempty(raw_cmd)
            return json_response(Dict("output" => ""))
        end

        output_str = if raw_cmd in ["/?", "/help", "help"]
            """
Comandos disponibles en ReposMx Shell:
  /?                      Muestra esta ayuda
  /info [repo]            Estadísticas detalladas de publicaciones, disciplinas y autores
  /author <nombre>        Busca perfiles de investigadores
  /topic-authors <tema>   Rankea investigadores por campo de conocimiento
  /sim-authors <autor>    Recomienda autores afines por acoplamiento bibliográfico
  /cited <autor|obra>     Busca en el corpus de citas bibliográficas
  /explain <concepto>     Explicación enciclopédica de Wikipedia
  /status                 Estado de repositorios disponibles
  <consulta libre>        Búsqueda global BM25 en el acervo"""
        elseif startswith(raw_cmd, "/info")
            parts = split(raw_cmd)
            target = length(parts) > 1 ? String(parts[2]) : nothing
            st = get_detailed_statistics(engine; repo=target)

            if haskey(st, "error")
                st["error"]
            else
                header_txt = target !== nothing ? "ESTADÍSTICAS DEL REPOSITORIO: $target" : "PANORAMA GLOBAL DEL ACERVO ACADÉMICO"
                lines = String["=======================================================",
                               "  📊 $header_txt",
                               "=======================================================",
                               "  • Documentos indexados: $(get(st, "total_docs", 0))",
                               "  • Archivos PDF:         $(get(st, "total_files", 0))",
                               "  • Texto completo:       $(get(st, "total_fulltext", 0))",
                               "  • Citas bibliográficas: $(get(st, "total_references", 0))",
                               "  • Rango temporal:       $(get(st, "year_min", "N/A")) — $(get(st, "year_max", "N/A"))",
                               "=======================================================",
                               "\n📚 TIPOS DE PUBLICACIÓN:"]
                for pt in get(st, "types_distribution", [])
                    push!(lines, "  • $(rpad(pt["type"], 25)) $(pt["count"])")
                end
                push!(lines, "\n🏷️  TOP DISCIPLINAS:")
                for td in first(get(st, "top_disciplines", []), 8)
                    push!(lines, "  • $(rpad(td["discipline"], 30)) $(td["count"])")
                end
                push!(lines, "\n👤 TOP INVESTIGADORES:")
                for tr in first(get(st, "top_researchers", []), 8)
                    push!(lines, "  • $(rpad(tr["name"], 30)) [$(tr["role"])] - $(tr["count"]) docs ($(tr["repo"]))")
                end
                join(lines, "\n")
            end
        elseif startswith(raw_cmd, "/topic-authors")
            q = strip(replace(raw_cmd, r"^/topic-authors\s*" => ""))
            res = get_topic_elements(engine, q; limit=10)
            if haskey(res, "error")
                res["error"]
            else
                lines = String["Autores activos en el tema \"$q\" ($(get(res, "total_authors", 0)) encontrados en $(get(res, "time_ms", 0.0)) ms):"]
                for (i, name) in enumerate(get(res, "authors", []))
                    push!(lines, "[$i] $name")
                end
                join(lines, "\n")
            end
        elseif startswith(raw_cmd, "/sim-authors")
            q = strip(replace(raw_cmd, r"^/sim-authors\s*" => ""))
            res = find_similar_authors_by_profile(engine, q; top=10)
            if haskey(res, "error")
                res["error"]
            else
                lines = String["Autores con acoplamiento bibliográfico a \"$(get(res, "target_author", q))\":"]
                for (i, a) in enumerate(get(res, "similar_authors", []))
                    push!(lines, "[$i] $(a["name"]) - $(a["doc_count"]) docs ($(join(a["repos"], ", "))) [Score: $(round(a["score"], digits=2))]")
                end
                join(lines, "\n")
            end
        elseif startswith(raw_cmd, "/author")
            q = strip(replace(raw_cmd, r"^/author\s*" => ""))
            res = search_authors(engine, q; top=10)
            lines = String["Investigadores encontrados para \"$q\" ($(get(res, "total_hits", 0)) hits):"]
            for (i, a) in enumerate(get(res, "authors", []))
                push!(lines, "[$i] $(a["name"]) [$(a["role"])] - $(a["doc_count"]) docs ($(join(a["repos"], ", ")))")
            end
            join(lines, "\n")
        elseif startswith(raw_cmd, "/cited")
            q = strip(replace(raw_cmd, r"^/cited\s*" => ""))
            res = search_references(engine, q; top=5)
            lines = String["Citas bibliográficas para \"$q\" ($(get(res, "total_hits", 0)) hits):"]
            for (i, r) in enumerate(get(res, "references", []))
                push!(lines, "[$i] $(r["text"]) [Citado en: $(r["doc_title"])]")
            end
            join(lines, "\n")
        elseif startswith(raw_cmd, "/explain")
            q = strip(replace(raw_cmd, r"^/explain\s*" => ""))
            c = explain_concept(q; lang="es")
            c !== nothing ? "📖 Wikipedia: $(c.title)\n$(c.extract)\n$(c.url)" : "No se encontró concepto en Wikipedia."
        elseif startswith(raw_cmd, "/status")
            st = get_repo_stats(; data_dir)
            summary = get(st, "summary", Dict())
            "Acervo total: $(get(summary, "total_repos", 0)) repositorios, $(get(summary, "total_records", 0)) registros."
        else
            # Default BM25 Search
            res = query_index(engine, raw_cmd; top=5, include_wiki=false)
            lines = String["Resultados para \"$raw_cmd\" ($(get(res, "total_hits", 0)) hits en $(get(res, "time_ms", 0.0)) ms):"]
            for (i, h) in enumerate(get(res, "hits", []))
                push!(lines, "[$i] $(get(h, "title", ""))\n    🏛️ $(get(h, "repo", "")) | 👤 $(get(h, "creator", "")) | Score: $(round(get(h, "score", 0.0), digits=2))")
            end
            join(lines, "\n")
        end

        return json_response(Dict("output" => output_str))
    end)

    HTTP.register!(router, "GET", "/file", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        path = get(params, "path", "")
        if isempty(path) || !isfile(path)
            return HTTP.Response(404, "Archivo no encontrado")
        end
        data = read(path)
        mime = endswith(path, ".pdf") ? "application/pdf" : "application/octet-stream"
        return HTTP.Response(200, ["Content-Type" => mime], data)
    end)

    println("✓ ReposMx Server running at http://$host:$port")
    HTTP.serve(router, host, port)
end

end # module Server
