module Server

using HTTP, JSON, URIs
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Storage: get_repo_stats, list_repo_names, get_repo_dir
using ..Search: SearchEngine, query_index, search_authors, search_references, get_document_references, search_document_paragraphs, get_detailed_statistics
using ..Wikipedia: explain_concept

export start_server

function get_html_ui()
    return """
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ReposMx - Repositorios Institucionales de México</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0f172a;
      --card-bg: #1e293b;
      --card-border: #334155;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #38bdf8;
      --accent-hover: #0ea5e9;
      --badge-bg: #0369a1;
      --wiki-bg: #1e1b4b;
      --wiki-border: #4338ca;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: 'Inter', sans-serif; background-color: var(--bg); color: var(--text); min-height: 100vh; line-height: 1.5; }
    header { background: #1e293b; border-bottom: 1px solid var(--card-border); padding: 1.25rem 2rem; }
    .header-content { max-width: 1200px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; }
    .logo-title { font-size: 1.35rem; font-weight: 700; color: var(--accent); }
    .tagline { font-size: 0.85rem; color: var(--text-muted); }
    .stats-pill { background: rgba(56, 189, 248, 0.1); color: var(--accent); padding: 0.35rem 0.8rem; border-radius: 9999px; font-size: 0.8rem; font-weight: 600; }
    main { max-width: 1200px; margin: 2rem auto; padding: 0 1.5rem; }
    
    .nav-tabs { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
    .tab-btn { background: transparent; border: 1px solid var(--card-border); color: var(--text-muted); padding: 0.5rem 1rem; border-radius: 0.375rem; cursor: pointer; font-weight: 600; font-size: 0.9rem; }
    .tab-btn.active { background: var(--accent); color: #0f172a; border-color: var(--accent); }
    
    .search-box-container { display: flex; gap: 0.75rem; margin-bottom: 1rem; flex-wrap: wrap; }
    .search-input { flex: 1; min-width: 250px; padding: 0.85rem 1.25rem; font-size: 1rem; border-radius: 0.5rem; border: 1px solid var(--card-border); background: var(--card-bg); color: var(--text); outline: none; }
    .search-input:focus { border-color: var(--accent); }
    .filter-select { padding: 0.85rem 1rem; font-size: 0.9rem; border-radius: 0.5rem; border: 1px solid var(--card-border); background: var(--card-bg); color: var(--text); outline: none; }
    .btn-search { padding: 0.85rem 1.75rem; background: var(--accent); color: #0f172a; font-weight: 600; border: none; border-radius: 0.5rem; cursor: pointer; transition: background 0.2s; }
    .btn-search:hover { background: var(--accent-hover); }
    
    .wiki-card { background: var(--wiki-bg); border: 1px solid var(--wiki-border); border-radius: 0.5rem; padding: 1.25rem; margin-bottom: 2rem; display: flex; gap: 1rem; align-items: flex-start; }
    .wiki-thumb { width: 64px; height: 64px; object-fit: cover; border-radius: 0.35rem; }
    .wiki-title { font-weight: 600; font-size: 1.1rem; color: #a5b4fc; margin-bottom: 0.3rem; }
    .wiki-extract { font-size: 0.9rem; color: #e2e8f0; }
    .wiki-badge { font-size: 0.7rem; background: #3730a3; padding: 0.15rem 0.5rem; border-radius: 4px; text-transform: uppercase; font-weight: bold; margin-left: 0.5rem; color: #c7d2fe; }
    
    .results-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; color: var(--text-muted); font-size: 0.9rem; }
    .results-grid { display: grid; gap: 1rem; }
    .result-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 0.5rem; padding: 1.25rem; transition: border-color 0.15s; }
    .result-card:hover { border-color: var(--accent); }
    .card-top { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 0.4rem; }
    .card-repo { font-size: 0.75rem; background: var(--badge-bg); color: #fff; padding: 0.2rem 0.6rem; border-radius: 4px; font-weight: 600; text-transform: uppercase; }
    .card-type { font-size: 0.75rem; background: #334155; color: #f1f5f9; padding: 0.2rem 0.5rem; border-radius: 4px; font-weight: 500; margin-left: 0.4rem; }
    .card-date { font-size: 0.8rem; color: var(--text-muted); }
    .card-title { font-size: 1.1rem; font-weight: 600; color: #38bdf8; margin-bottom: 0.4rem; text-decoration: none; display: inline-block; }
    .card-author { font-size: 0.85rem; color: #cbd5e1; margin-bottom: 0.6rem; font-weight: 500; }
    .card-snippet { font-size: 0.9rem; color: var(--text-muted); line-height: 1.4; }
    .card-tags { margin-top: 0.6rem; display: flex; flex-wrap: wrap; gap: 0.35rem; }
    .tag-badge { font-size: 0.75rem; background: rgba(56, 189, 248, 0.15); color: var(--accent); padding: 0.15rem 0.5rem; border-radius: 4px; }
    
    .card-footer { display: flex; justify-content: space-between; align-items: center; margin-top: 0.75rem; padding-top: 0.75rem; border-top: 1px solid rgba(255,255,255,0.05); }
    .btn-action { font-size: 0.8rem; background: #0284c7; color: #fff; padding: 0.25rem 0.6rem; border-radius: 4px; text-decoration: none; font-weight: 600; cursor: pointer; border: none; margin-right: 0.5rem; }
    .btn-action-sec { font-size: 0.8rem; background: #334155; color: #fff; padding: 0.25rem 0.6rem; border-radius: 4px; text-decoration: none; font-weight: 600; cursor: pointer; border: none; margin-right: 0.5rem; }
    .btn-file { font-size: 0.8rem; color: var(--accent); text-decoration: none; font-weight: 600; }
    
    .in-depth-box { margin-top: 1rem; padding: 1rem; background: #0f172a; border: 1px solid #0284c7; border-radius: 0.375rem; display: none; }
    .in-depth-header { font-weight: 600; font-size: 0.9rem; color: #38bdf8; margin-bottom: 0.5rem; }
    .paragraph-item { margin-top: 0.5rem; padding: 0.5rem; background: #1e293b; border-left: 3px solid #38bdf8; font-size: 0.85rem; }
    .ref-item { margin-top: 0.5rem; padding: 0.5rem; background: #1e293b; border-left: 3px solid #10b981; font-size: 0.85rem; }
    
    .empty-state { text-align: center; padding: 4rem 1rem; color: var(--text-muted); }
  </style>
</head>
<body>
  <header>
    <div class="header-content">
      <div>
        <div class="logo-title">ReposMx</div>
        <div class="tagline">Búsqueda Multicapa Trazable: Metadatos, Autores, Citas Bibliográficas y Párrafos en PDFs</div>
      </div>
      <div id="stats-badge" class="stats-pill">Cargando estadísticas...</div>
    </div>
  </header>
  
  <main>
    <div class="nav-tabs">
      <button class="tab-btn active" id="tab-docs" onclick="switchMode('docs')">📚 Documentos y Publicaciones</button>
      <button class="tab-btn" id="tab-authors" onclick="switchMode('authors')">👤 Autores e Investigadores</button>
      <button class="tab-btn" id="tab-refs" onclick="switchMode('refs')">📖 Corpus de Citas / Referencias</button>
    </div>
    
    <div class="search-box-container">
      <input type="text" id="query-input" class="search-input" placeholder="Buscar por tema, conceptos, palabras clave (ej. redes neuronales, optimización)..." autofocus>
      <select id="repo-select" class="filter-select">
        <option value="">Todos los repositorios</option>
      </select>
      <select id="type-select" class="filter-select">
        <option value="">Todos los tipos</option>
        <option value="Tesis">Tesis</option>
        <option value="Artículo">Artículos</option>
        <option value="Libro">Libros</option>
        <option value="Reporte">Reportes</option>
      </select>
      <button id="search-btn" class="btn-search">Buscar</button>
    </div>
    
    <div id="wiki-container"></div>
    
    <div class="results-header" id="results-header" style="display: none;">
      <span id="results-count"></span>
      <span id="results-time"></span>
    </div>
    
    <div id="results-grid" class="results-grid">
      <div class="empty-state">Ingresa una consulta para buscar en el acervo académico nacional.</div>
    </div>
  </main>

  <script>
    let currentMode = 'docs';
    
    async function loadStats() {
      try {
        const res = await fetch('/api/stats');
        const data = await res.json();
        document.getElementById('stats-badge').textContent = `\${data.total_repos} repositorios | \${data.total_records.toLocaleString()} registros`;
        
        const sel = document.getElementById('repo-select');
        (data.repos || []).forEach(r => {
          const opt = document.createElement('option');
          opt.value = r.repo;
          opt.textContent = `\${r.repo} (\${r.total_records.toLocaleString()})`;
          sel.appendChild(opt);
        });
      } catch (e) {
        console.error(e);
      }
    }
    
    function switchMode(mode) {
      currentMode = mode;
      document.getElementById('tab-docs').classList.toggle('active', mode === 'docs');
      document.getElementById('tab-authors').classList.toggle('active', mode === 'authors');
      document.getElementById('tab-refs').classList.toggle('active', mode === 'refs');
      
      document.getElementById('type-select').style.display = mode === 'docs' ? 'block' : 'none';
      
      if (mode === 'docs') {
        document.getElementById('query-input').placeholder = 'Buscar por tema, conceptos, palabras clave (ej. redes neuronales, optimización)...';
      } else if (mode === 'authors') {
        document.getElementById('query-input').placeholder = 'Buscar investigador o colaborador (ej. Eric Tellez, Samaniego)...';
      } else if (mode === 'refs') {
        document.getElementById('query-input').placeholder = 'Buscar en referencias citadas (ej. Knuth, Deep Learning, Goodfellow, IEEE)...';
      }
      
      doSearch();
    }
    
    async function doSearch() {
      const q = document.getElementById('query-input').value.trim();
      if (!q) return;
      
      const grid = document.getElementById('results-grid');
      grid.innerHTML = '<div class="empty-state">Buscando en repositorios...</div>';
      
      if (currentMode === 'authors') {
        const res = await fetch(`/api/authors?q=\${encodeURIComponent(q)}`);
        const data = await res.json();
        renderAuthors(data);
        return;
      }
      
      if (currentMode === 'refs') {
        const repo = document.getElementById('repo-select').value;
        const res = await fetch(`/api/references?q=\${encodeURIComponent(q)}&repo=\${encodeURIComponent(repo)}`);
        const data = await res.json();
        renderReferences(data);
        return;
      }
      
      const repo = document.getElementById('repo-select').value;
      const type = document.getElementById('type-select').value;
      const url = `/api/search?q=\${encodeURIComponent(q)}&repo=\${encodeURIComponent(repo)}&doc_type=\${encodeURIComponent(type)}&wiki=true`;
      
      try {
        const res = await fetch(url);
        const data = await res.json();
        renderResults(data);
      } catch (e) {
        grid.innerHTML = '<div class="empty-state">Error al realizar la búsqueda.</div>';
      }
    }
    
    function renderAuthors(data) {
      document.getElementById('wiki-container').innerHTML = '';
      const header = document.getElementById('results-header');
      header.style.display = 'flex';
      document.getElementById('results-count').textContent = `\${data.total_hits} autores encontrados`;
      document.getElementById('results-time').textContent = `\${data.time_ms} ms`;
      
      const grid = document.getElementById('results-grid');
      if (!data.authors || data.authors.length === 0) {
        grid.innerHTML = '<div class="empty-state">No se encontraron investigadores o colaboradores.</div>';
        return;
      }
      
      grid.innerHTML = data.authors.map(a => `
        <div class="result-card">
          <div class="card-top">
            <span class="card-repo">\${a.role}</span>
            <span class="card-date">\${a.doc_count} publicaciones</span>
          </div>
          <div class="card-title">\${a.name}</div>
          <div class="card-author">🏛️ Repositorios: \${(a.repos || []).join(', ')}</div>
          <div class="card-snippet">👥 Coautores: \${(a.coauthors || []).join(' ; ') || 'N/A'}</div>
          <div class="card-tags">
            \${(a.keywords || []).slice(0, 6).map(k => `<span class="tag-badge">\${k}</span>`).join('')}
          </div>
        </div>
      `).join('');
    }
    
    function renderReferences(data) {
      document.getElementById('wiki-container').innerHTML = '';
      const header = document.getElementById('results-header');
      header.style.display = 'flex';
      document.getElementById('results-count').textContent = `\${data.total_hits} citas / referencias encontradas`;
      document.getElementById('results-time').textContent = `\${data.time_ms} ms`;
      
      const grid = document.getElementById('results-grid');
      if (!data.references || data.references.length === 0) {
        grid.innerHTML = '<div class="empty-state">No se encontraron referencias que coincidan.</div>';
        return;
      }
      
      grid.innerHTML = data.references.map(r => `
        <div class="result-card">
          <div class="card-top">
            <span class="card-repo">\${r.repo}</span>
            <span class="card-date">Ref #\${r.ref_num}</span>
          </div>
          <div class="card-snippet" style="font-size:0.95rem; color:#f8fafc; font-style:italic;">
            "\${r.text}"
          </div>
          <div style="margin-top:0.6rem; font-size:0.85rem; color:#38bdf8;">
            🏛️ Citado en documento: <strong>\${r.doc_title}</strong>
          </div>
        </div>
      `).join('');
    }
    
    function renderResults(data) {
      const wikiBox = document.getElementById('wiki-container');
      if (data.wiki_concept) {
        const w = data.wiki_concept;
        wikiBox.innerHTML = `
          <div class="wiki-card">
            \${w.thumbnail ? `<img src="\${w.thumbnail}" class="wiki-thumb">` : ''}
            <div>
              <div class="wiki-title">\${w.title} <span class="wiki-badge">Wikipedia \${w.lang}</span></div>
              <div class="wiki-extract">\${w.extract}</div>
            </div>
          </div>
        `;
      } else {
        wikiBox.innerHTML = '';
      }
      
      const header = document.getElementById('results-header');
      header.style.display = 'flex';
      document.getElementById('results-count').textContent = `\${data.total_hits} resultados`;
      document.getElementById('results-time').textContent = `\${data.time_ms} ms`;
      
      const grid = document.getElementById('results-grid');
      if (!data.hits || data.hits.length === 0) {
        grid.innerHTML = '<div class="empty-state">No se encontraron documentos para esta búsqueda.</div>';
        return;
      }
      
      grid.innerHTML = data.hits.map(h => `
        <div class="result-card">
          <div class="card-top">
            <div>
              <span class="card-repo">\${h.repo}</span>
              <span class="card-type">\${h.type || 'Doc'}</span>
            </div>
            <span class="card-date">\${h.date ? h.date.substring(0, 10) : ''}</span>
          </div>
          <div class="card-title">\${h.title || 'Sin título'}</div>
          <div class="card-author">\${h.creator ? '👤 ' + h.creator : ''}</div>
          <div class="card-snippet">\${h.snippet}</div>
          
          <div class="card-tags">
            \${(h.keywords || []).slice(0, 5).map(k => `<span class="tag-badge">\${k}</span>`).join('')}
          </div>
          
          <div class="card-footer">
            <span style="font-size:0.75rem; color:var(--text-muted);">Score: \${h.score.toFixed(1)} \${h.reference_count > 0 ? `| 📚 \${h.reference_count} refs` : ''}</span>
            <div>
              <button class="btn-action" onclick="searchInside(\${h.doc_idx})">🔍 Buscar párrafos</button>
              <button class="btn-action-sec" onclick="showRefs(\${h.doc_idx})">📚 Referencias</button>
              \${h.file ? `<a href="/file?path=\${encodeURIComponent(h.file)}" target="_blank" class="btn-file">📄 PDF</a>` : ''}
            </div>
          </div>
          <div id="in-depth-\${h.doc_idx}" class="in-depth-box">
            <div class="in-depth-header">Búsqueda de pasajes y párrafos dentro del documento:</div>
            <div style="display:flex; gap:0.5rem;">
              <input type="text" id="inside-q-\${h.doc_idx}" class="search-input" placeholder="Término o pregunta dentro del documento...">
              <button class="btn-search" onclick="runSearchInside(\${h.doc_idx})">Buscar Párrafos</button>
            </div>
            <div id="inside-res-\${h.doc_idx}" style="margin-top:0.75rem;"></div>
          </div>
          <div id="refs-box-\${h.doc_idx}" class="in-depth-box">
            <div class="in-depth-header">Referencias Bibliográficas Citadas:</div>
            <div id="refs-res-\${h.doc_idx}"></div>
          </div>
        </div>
      `).join('');
    }
    
    function searchInside(docIdx) {
      const box = document.getElementById(`in-depth-\${docIdx}`);
      box.style.display = box.style.display === 'block' ? 'none' : 'block';
    }
    
    async function showRefs(docIdx) {
      const box = document.getElementById(`refs-box-\${docIdx}`);
      box.style.display = box.style.display === 'block' ? 'none' : 'block';
      const container = document.getElementById(`refs-res-\${docIdx}`);
      if (box.style.display === 'block' && !container.innerHTML) {
        container.innerHTML = '<div style="color:var(--accent);">Cargando referencias...</div>';
        try {
          const res = await fetch(`/api/document/references?doc_idx=\${docIdx}`);
          const data = await res.json();
          if (!data.references || data.references.length === 0) {
            container.innerHTML = '<div style="color:var(--text-muted);">No se encontraron referencias extraídas para este documento.</div>';
            return;
          }
          container.innerHTML = data.references.map((r, i) => `
            <div class="ref-item">
              <strong>[\${i+1}]</strong> \${r.text}
            </div>
          `).join('');
        } catch (e) {
          container.innerHTML = '<div style="color:#ef4444;">Error al cargar referencias.</div>';
        }
      }
    }
    
    async function runSearchInside(docIdx) {
      const q = document.getElementById(`inside-q-\${docIdx}`).value.trim();
      const resContainer = document.getElementById(`inside-res-\${docIdx}`);
      if (!q) return;
      
      resContainer.innerHTML = '<div style="color:var(--accent);">Analizando párrafos...</div>';
      try {
        const res = await fetch(`/api/document/paragraphs?doc_idx=\${docIdx}&q=\${encodeURIComponent(q)}`);
        const data = await res.json();
        if (data.error) {
          resContainer.innerHTML = `<div style="color:#ef4444;">\${data.error}</div>`;
          return;
        }
        resContainer.innerHTML = (data.hits || []).map((h, i) => `
          <div class="paragraph-item">
            <div style="font-weight:600; color:#38bdf8; margin-bottom:0.25rem;">[Párrafo \${h.paragraph_num} - \${h.section} | Score: \${h.score.toFixed(1)}]</div>
            <div>\${h.text}</div>
          </div>
        `).join('');
      } catch (e) {
        resContainer.innerHTML = '<div style="color:#ef4444;">Error al buscar párrafos.</div>';
      }
    }
    
    document.getElementById('search-btn').addEventListener('click', doSearch);
    document.getElementById('query-input').addEventListener('keydown', e => { if (e.key === 'Enter') doSearch(); });
    document.getElementById('type-select').addEventListener('change', doSearch);
    document.getElementById('repo-select').addEventListener('change', doSearch);
    
    loadStats();
  </script>
</body>
</html>
"""
end

"""
    start_server(; port=8000, host="0.0.0.0", data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)

Starts the HTTP server and API backend.
"""
function start_server(; port::Int=8000, host::String="0.0.0.0", data_dir=DEFAULT_DATA_DIR, index_dir=DEFAULT_INDEX_DIR)
    println("Loading search engines for server on port $port...")
    engine = SearchEngine(; index_dir)
    
    router = HTTP.Router()
    
    HTTP.register!(router, "GET", "/", function(req)
        return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], get_html_ui())
    end)
    
    HTTP.register!(router, "GET", "/api/stats", function(req)
        stats = get_repo_stats(; data_dir)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(stats))
    end)
    
    HTTP.register!(router, "GET", "/api/info", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        repo = get(params, "repo", nothing)
        repo = (repo !== nothing && !isempty(repo)) ? repo : nothing
        stats = get_detailed_statistics(engine; repo)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(stats))
    end)
    
    HTTP.register!(router, "GET", "/api/search", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        repo = get(params, "repo", nothing)
        repo = (repo !== nothing && !isempty(repo)) ? repo : nothing
        doc_type = get(params, "doc_type", nothing)
        doc_type = (doc_type !== nothing && !isempty(doc_type)) ? doc_type : nothing
        wiki = get(params, "wiki", "true") == "true"
        top = tryparse(Int, get(params, "top", "10"))
        top = top === nothing ? 10 : top
        
        res = query_index(engine, q; top, repo, doc_type, include_wiki=wiki)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(res))
    end)
    
    HTTP.register!(router, "GET", "/api/authors", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        top = tryparse(Int, get(params, "top", "10"))
        top = top === nothing ? 10 : top
        
        res = search_authors(engine, q; top)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(res))
    end)
    
    HTTP.register!(router, "GET", "/api/references", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        repo = get(params, "repo", nothing)
        repo = (repo !== nothing && !isempty(repo)) ? repo : nothing
        top = tryparse(Int, get(params, "top", "10"))
        top = top === nothing ? 10 : top
        
        res = search_references(engine, q; top, repo)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(res))
    end)
    
    HTTP.register!(router, "GET", "/api/document/references", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        doc_idx_str = get(params, "doc_idx", "")
        doc_idx = tryparse(Int, doc_idx_str)
        
        if doc_idx === nothing
            return HTTP.Response(400, ["Content-Type" => "application/json"], JSON.json(Dict("error" => "Parámetro doc_idx requerido")))
        end
        
        res = get_document_references(engine, doc_idx)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(res))
    end)
    
    HTTP.register!(router, "GET", "/api/document/paragraphs", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        doc_idx_str = get(params, "doc_idx", "")
        doc_idx = tryparse(Int, doc_idx_str)
        
        if doc_idx === nothing
            return HTTP.Response(400, ["Content-Type" => "application/json"], JSON.json(Dict("error" => "Parámetro doc_idx requerido")))
        end
        
        res = search_document_paragraphs(engine, doc_idx, q; top=5)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(res))
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
