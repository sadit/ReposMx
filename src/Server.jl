module Server

using HTTP, JSON, URIs
using ..Config: DEFAULT_DATA_DIR, DEFAULT_INDEX_DIR
using ..Storage: get_repo_stats, list_repo_names, get_repo_dir
using ..Search: SearchEngine, query_index, search_authors, search_authors_by_topic,
                find_similar_authors_by_references, search_references,
                get_document_references, search_document_paragraphs, get_detailed_statistics
using ..Wikipedia: explain_concept

export start_server

function get_html_ui()
    return """<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ReposMx - Repositorios Institucionales de México</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=Fira+Code:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0b0f19;
      --header-bg: #111827;
      --card-bg: #1e293b;
      --card-hover: #273549;
      --card-border: #334155;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #38bdf8;
      --accent-hover: #0ea5e9;
      --badge-bg: #0369a1;
      --wiki-bg: #1e1b4b;
      --wiki-border: #4338ca;
      --term-bg: #050811;
      --term-border: #1e293b;
      --green: #10b981;
      --amber: #f59e0b;
      --purple: #a855f7;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: 'Inter', sans-serif; background-color: var(--bg); color: var(--text); min-height: 100vh; line-height: 1.5; }
    header { background: var(--header-bg); border-bottom: 1px solid var(--card-border); padding: 1.25rem 2rem; position: sticky; top: 0; z-index: 100; }
    .header-content { max-width: 1280px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; }
    .logo-title { font-size: 1.4rem; font-weight: 700; color: var(--accent); display: flex; align-items: center; gap: 0.5rem; }
    .tagline { font-size: 0.85rem; color: var(--text-muted); }
    .stats-pill { background: rgba(56, 189, 248, 0.1); color: var(--accent); padding: 0.35rem 0.85rem; border-radius: 9999px; font-size: 0.8rem; font-weight: 600; border: 1px solid rgba(56, 189, 248, 0.2); }
    main { max-width: 1280px; margin: 2rem auto; padding: 0 1.5rem; }
    
    .nav-tabs { display: flex; gap: 0.5rem; margin-bottom: 1.5rem; border-bottom: 1px solid var(--card-border); padding-bottom: 0.75rem; flex-wrap: wrap; }
    .tab-btn { background: transparent; border: 1px solid var(--card-border); color: var(--text-muted); padding: 0.6rem 1.2rem; border-radius: 0.5rem; cursor: pointer; font-weight: 600; font-size: 0.9rem; transition: all 0.15s; }
    .tab-btn:hover { background: rgba(255,255,255,0.05); color: var(--text); }
    .tab-btn.active { background: var(--accent); color: #0b0f19; border-color: var(--accent); }
    
    .search-box-container { display: flex; gap: 0.75rem; margin-bottom: 1.25rem; flex-wrap: wrap; }
    .search-input { flex: 1; min-width: 260px; padding: 0.85rem 1.25rem; font-size: 1rem; border-radius: 0.5rem; border: 1px solid var(--card-border); background: var(--card-bg); color: var(--text); outline: none; transition: border-color 0.2s; }
    .search-input:focus { border-color: var(--accent); }
    .filter-select { padding: 0.85rem 1rem; font-size: 0.9rem; border-radius: 0.5rem; border: 1px solid var(--card-border); background: var(--card-bg); color: var(--text); outline: none; }
    .btn-search { padding: 0.85rem 1.75rem; background: var(--accent); color: #0b0f19; font-weight: 600; border: none; border-radius: 0.5rem; cursor: pointer; transition: background 0.2s; }
    .btn-search:hover { background: var(--accent-hover); }
    
    .sub-filters { display: flex; gap: 0.75rem; margin-bottom: 1.5rem; flex-wrap: wrap; align-items: center; }
    .sub-filter-btn { background: var(--card-bg); border: 1px solid var(--card-border); color: var(--text-muted); padding: 0.4rem 0.85rem; border-radius: 9999px; font-size: 0.8rem; cursor: pointer; font-weight: 500; }
    .sub-filter-btn.active { background: #0284c7; color: #fff; border-color: #0284c7; }
    
    .wiki-card { background: var(--wiki-bg); border: 1px solid var(--wiki-border); border-radius: 0.5rem; padding: 1.25rem; margin-bottom: 1.75rem; display: flex; gap: 1rem; align-items: flex-start; }
    .wiki-thumb { width: 64px; height: 64px; object-fit: cover; border-radius: 0.35rem; }
    .wiki-title { font-weight: 600; font-size: 1.1rem; color: #a5b4fc; margin-bottom: 0.3rem; }
    .wiki-extract { font-size: 0.9rem; color: #e2e8f0; }
    .wiki-badge { font-size: 0.7rem; background: #3730a3; padding: 0.15rem 0.5rem; border-radius: 4px; text-transform: uppercase; font-weight: bold; margin-left: 0.5rem; color: #c7d2fe; }
    
    .results-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; color: var(--text-muted); font-size: 0.9rem; }
    .results-grid { display: grid; gap: 1rem; }
    .result-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 0.5rem; padding: 1.25rem; transition: all 0.15s; }
    .result-card:hover { border-color: var(--accent); background: var(--card-hover); }
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
    .btn-action { font-size: 0.8rem; background: #0284c7; color: #fff; padding: 0.3rem 0.7rem; border-radius: 4px; text-decoration: none; font-weight: 600; cursor: pointer; border: none; margin-right: 0.5rem; }
    .btn-action-sec { font-size: 0.8rem; background: #334155; color: #fff; padding: 0.3rem 0.7rem; border-radius: 4px; text-decoration: none; font-weight: 600; cursor: pointer; border: none; margin-right: 0.5rem; }
    .btn-file { font-size: 0.8rem; color: var(--accent); text-decoration: none; font-weight: 600; }
    
    .in-depth-box { margin-top: 1rem; padding: 1rem; background: #0b0f19; border: 1px solid #0284c7; border-radius: 0.375rem; display: none; }
    .in-depth-header { font-weight: 600; font-size: 0.9rem; color: #38bdf8; margin-bottom: 0.5rem; }
    .paragraph-item { margin-top: 0.5rem; padding: 0.75rem; background: #1e293b; border-left: 3px solid #38bdf8; font-size: 0.85rem; border-radius: 0 4px 4px 0; }
    .ref-item { margin-top: 0.5rem; padding: 0.75rem; background: #1e293b; border-left: 3px solid #10b981; font-size: 0.85rem; border-radius: 0 4px 4px 0; }
    
    /* Stats & Info Dashboard */
    .dashboard-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
    .metric-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 0.5rem; padding: 1.25rem; }
    .metric-title { font-size: 0.8rem; text-transform: uppercase; color: var(--text-muted); font-weight: 600; }
    .metric-value { font-size: 1.75rem; font-weight: 700; color: var(--accent); margin: 0.3rem 0; }
    .metric-sub { font-size: 0.8rem; color: var(--text-muted); }
    .table-container { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 0.5rem; padding: 1.25rem; margin-bottom: 1.5rem; }
    .table-header { font-size: 1.1rem; font-weight: 600; color: var(--text); margin-bottom: 1rem; display: flex; align-items: center; gap: 0.5rem; }
    .data-table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
    .data-table th, .data-table td { padding: 0.6rem 0.8rem; text-align: left; border-bottom: 1px solid var(--card-border); }
    .data-table th { color: var(--text-muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; }
    
    /* Web Shell / Terminal */
    .terminal-container { background: var(--term-bg); border: 1px solid var(--term-border); border-radius: 0.5rem; font-family: 'Fira Code', monospace; padding: 1.25rem; min-height: 500px; display: flex; flex-direction: column; }
    .terminal-output { flex: 1; overflow-y: auto; max-height: 550px; font-size: 0.9rem; line-height: 1.6; white-space: pre-wrap; word-break: break-word; color: #e2e8f0; }
    .terminal-input-line { display: flex; align-items: center; gap: 0.5rem; margin-top: 1rem; border-top: 1px solid var(--card-border); padding-top: 0.75rem; }
    .term-prompt { color: var(--green); font-weight: 600; }
    .term-input { flex: 1; background: transparent; border: none; color: #fff; font-family: 'Fira Code', monospace; font-size: 0.95rem; outline: none; }
    
    .empty-state { text-align: center; padding: 4rem 1rem; color: var(--text-muted); }
  </style>
</head>
<body>
  <header>
    <div class="header-content">
      <div>
        <div class="logo-title">🇲🇽 ReposMx</div>
        <div class="tagline">Búsqueda Multicapa: Metadatos, Autores, Citas Bibliográficas, Párrafos e Inteligencia Institucional</div>
      </div>
      <div id="stats-badge" class="stats-pill">Cargando acervo...</div>
    </div>
  </header>
  
  <main>
    <!-- Navigation Tabs -->
    <div class="nav-tabs">
      <button class="tab-btn active" id="tab-docs" onclick="switchMode('docs')">📚 Documentos y Publicaciones</button>
      <button class="tab-btn" id="tab-authors" onclick="switchMode('authors')">👤 Autores e Investigadores</button>
      <button class="tab-btn" id="tab-refs" onclick="switchMode('refs')">📖 Corpus de Citas / Referencias</button>
      <button class="tab-btn" id="tab-info" onclick="switchMode('info')">📊 Inteligencia & Estadísticas (/info)</button>
      <button class="tab-btn" id="tab-shell" onclick="switchMode('shell')">💻 Consola Web (Shell TUI)</button>
    </div>
    
    <!-- Main Search Container (Hidden in info/shell modes) -->
    <div id="search-section">
      <div class="search-box-container">
        <input type="text" id="query-input" class="search-input" placeholder="Buscar por tema, conceptos, palabras clave (ej. redes neuronales, sistemas de información geográfica)..." autofocus>
        <select id="repo-select" class="filter-select">
          <option value="">Todos los repositorios</option>
        </select>
        <select id="type-select" class="filter-select">
          <option value="">Todos los tipos</option>
          <option value="Tesis">Tesis</option>
          <option value="Artículo">Artículos</option>
          <option value="Libro">Libros</option>
          <option value="Conferencia">Conferencias / Ponencias</option>
        </select>
        <button id="search-btn" class="btn-search">Buscar</button>
      </div>
      
      <!-- Sub-modes for Authors Tab -->
      <div id="author-subfilters" class="sub-filters" style="display: none;">
        <span style="font-size:0.85rem; color:var(--text-muted); font-weight:600;">Modo de Análisis:</span>
        <button class="sub-filter-btn active" id="btn-auth-name" onclick="setAuthorSubmode('name')">🔤 Por Nombre (/author)</button>
        <button class="sub-filter-btn" id="btn-auth-topic" onclick="setAuthorSubmode('topic')">🎯 Por Campo / Tema (/topic-authors)</button>
        <button class="sub-filter-btn" id="btn-auth-sim" onclick="setAuthorSubmode('sim')">🔗 Por Afinidad / Co-citación (/sim-authors)</button>
      </div>
      
      <div id="wiki-container"></div>
      
      <div class="results-header" id="results-header" style="display: none;">
        <span id="results-count"></span>
        <span id="results-time"></span>
      </div>
      
      <div id="results-grid" class="results-grid">
        <div class="empty-state">Ingresa una consulta para explorar el acervo académico nacional.</div>
      </div>
    </div>
    
    <!-- Info & Analytics Section -->
    <div id="info-section" style="display: none;">
      <div style="display: flex; gap: 1rem; align-items: center; margin-bottom: 1.5rem;">
        <label for="info-repo-select" style="font-weight: 600; color: var(--text-muted);">Seleccionar Repositorio:</label>
        <select id="info-repo-select" class="filter-select" onchange="loadInfoView(this.value)">
          <option value="">Panorama Global (Todos los repositorios)</option>
        </select>
        <button class="btn-search" onclick="loadInfoView(document.getElementById('info-repo-select').value)">Actualizar</button>
      </div>
      <div id="info-content">
        <div class="empty-state">Cargando análisis estadístico...</div>
      </div>
    </div>
    
    <!-- Web Shell Section -->
    <div id="shell-section" style="display: none;">
      <div class="terminal-container">
        <div class="terminal-output" id="term-output">
╔══════════════════════════════════════════════════════════════════════════════╗
║  🇲🇽 ReposMx - Consola Web Interactiva (Modo Consulta)                       ║
║  Escribe /? o /help para ver la lista de comandos disponibles.               ║
║  Ejemplos:                                                                   ║
║    /? info              -> Ver ayuda de estadísticas                         ║
║    /info cimat          -> Ver ficha estadística del CIMAT                   ║
║    /topic-authors optica-> Rankear autores por tema                          ║
║    /sim-authors tellez  -> Encontrar autores afines por acoplamiento         ║
║    /cited knuth         -> Buscar citas a Donald Knuth                       ║
║    aprendizaje profundo -> Búsqueda general BM25                             ║
╚══════════════════════════════════════════════════════════════════════════════╝
</div>
        <div class="terminal-input-line">
          <span class="term-prompt">reposmx&gt;</span>
          <input type="text" id="term-input" class="term-input" placeholder="Escribe un comando o consulta (ej. /info, /topic-authors grafos)..." autofocus>
        </div>
      </div>
    </div>
  </main>

  <script>
    let currentMode = 'docs';
    let authorSubmode = 'name';
    
    async function loadStats() {
      try {
        const res = await fetch('/api/stats');
        const data = await res.json();
        document.getElementById('stats-badge').textContent = `\${data.total_repos} repositorios | \${data.total_records.toLocaleString()} registros`;
        
        const sel = document.getElementById('repo-select');
        const infoSel = document.getElementById('info-repo-select');
        (data.repos || []).forEach(r => {
          const opt = document.createElement('option');
          opt.value = r.repo;
          opt.textContent = `\${r.repo} (\${r.total_records.toLocaleString()})`;
          sel.appendChild(opt);
          
          const opt2 = document.createElement('option');
          opt2.value = r.repo;
          opt2.textContent = `\${r.repo} (\${r.total_records.toLocaleString()})`;
          infoSel.appendChild(opt2);
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
      document.getElementById('tab-info').classList.toggle('active', mode === 'info');
      document.getElementById('tab-shell').classList.toggle('active', mode === 'shell');
      
      document.getElementById('search-section').style.display = (mode === 'info' || mode === 'shell') ? 'none' : 'block';
      document.getElementById('info-section').style.display = mode === 'info' ? 'block' : 'none';
      document.getElementById('shell-section').style.display = mode === 'shell' ? 'block' : 'none';
      
      document.getElementById('author-subfilters').style.display = mode === 'authors' ? 'flex' : 'none';
      document.getElementById('type-select').style.display = mode === 'docs' ? 'block' : 'none';
      
      if (mode === 'docs') {
        document.getElementById('query-input').placeholder = 'Buscar por tema, conceptos, palabras clave (ej. redes neuronales, optimización)...';
        doSearch();
      } else if (mode === 'authors') {
        updateAuthorPlaceholder();
        doSearch();
      } else if (mode === 'refs') {
        document.getElementById('query-input').placeholder = 'Buscar en referencias citadas (ej. Knuth, Deep Learning, Goodfellow, IEEE)...';
        doSearch();
      } else if (mode === 'info') {
        loadInfoView(document.getElementById('info-repo-select').value);
      } else if (mode === 'shell') {
        document.getElementById('term-input').focus();
      }
    }
    
    function setAuthorSubmode(sub) {
      authorSubmode = sub;
      document.getElementById('btn-auth-name').classList.toggle('active', sub === 'name');
      document.getElementById('btn-auth-topic').classList.toggle('active', sub === 'topic');
      document.getElementById('btn-auth-sim').classList.toggle('active', sub === 'sim');
      updateAuthorPlaceholder();
      doSearch();
    }
    
    function updateAuthorPlaceholder() {
      if (authorSubmode === 'name') {
        document.getElementById('query-input').placeholder = 'Buscar investigador o colaborador por nombre (ej. Eric Tellez, Samaniego)...';
      } else if (authorSubmode === 'topic') {
        document.getElementById('query-input').placeholder = 'Rankear autores por campo del conocimiento / tema (ej. visión por computadora, bioinformática)...';
      } else if (authorSubmode === 'sim') {
        document.getElementById('query-input').placeholder = 'Recomendar investigadores afines por acoplamiento bibliográfico (ej. Flores, Gonzalez)...';
      }
    }
    
    async function doSearch() {
      const q = document.getElementById('query-input').value.trim();
      if (!q) return;
      
      const grid = document.getElementById('results-grid');
      grid.innerHTML = '<div class="empty-state">Buscando en repositorios...</div>';
      
      if (currentMode === 'authors') {
        let endpoint = `/api/authors?q=\${encodeURIComponent(q)}`;
        if (authorSubmode === 'topic') {
          endpoint = `/api/authors/topic?q=\${encodeURIComponent(q)}`;
        } else if (authorSubmode === 'sim') {
          endpoint = `/api/authors/similar?q=\${encodeURIComponent(q)}`;
        }
        
        try {
          const res = await fetch(endpoint);
          const data = await res.json();
          renderAuthors(data);
        } catch (e) {
          grid.innerHTML = '<div class="empty-state">Error al consultar autores.</div>';
        }
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
      const count = data.total_hits || (data.similar_authors ? data.similar_authors.length : 0);
      document.getElementById('results-count').textContent = `\${count} investigadores / colaboradores encontrados`;
      document.getElementById('results-time').textContent = `\${data.time_ms} ms`;
      
      const grid = document.getElementById('results-grid');
      const list = data.authors || data.similar_authors || [];
      if (!list || list.length === 0) {
        grid.innerHTML = '<div class="empty-state">No se encontraron investigadores que coincidan con la consulta.</div>';
        return;
      }
      
      grid.innerHTML = list.map(a => `
        <div class="result-card">
          <div class="card-top">
            <span class="card-repo">\${a.role || 'Autor'}</span>
            <span class="card-date">\${a.doc_count || 1} publicaciones</span>
          </div>
          <div class="card-title">\${a.name}</div>
          <div class="card-author">🏛️ Repositorios: \${(a.repos || []).join(', ') || 'N/A'}</div>
          <div class="card-snippet">👥 Coautores: \${(a.coauthors || []).join(' ; ') || 'N/A'}</div>
          \${a.keywords && a.keywords.length ? `
            <div class="card-tags">
              \${a.keywords.slice(0, 6).map(k => `<span class="tag-badge">\${k}</span>`).join('')}
            </div>
          ` : ''}
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
            <span class="card-date">Cita #\${r.ref_id}</span>
          </div>
          <div style="font-size: 1rem; color: #f1f5f9; margin-bottom: 0.5rem; font-family: 'Fira Code', monospace; line-height: 1.4;">
            \${r.raw_text}
          </div>
          <div class="card-author">📄 Citado en obra: <em>\${r.doc_title}</em></div>
          \${r.cited_authors && r.cited_authors.length ? `
            <div class="card-tags">
              \${r.cited_authors.map(ca => `<span class="tag-badge" style="background:rgba(16, 185, 129, 0.15); color:#10b981;">👤 \${ca}</span>`).join('')}
            </div>
          ` : ''}
        </div>
      `).join('');
    }
    
    function renderResults(data) {
      const wikiContainer = document.getElementById('wiki-container');
      wikiContainer.innerHTML = '';
      if (data.wiki_concept) {
        const w = data.wiki_concept;
        wikiContainer.innerHTML = `
          <div class="wiki-card">
            \${w.thumbnail ? `<img src="\${w.thumbnail}" class="wiki-thumb" alt="\${w.title}">` : ''}
            <div>
              <div class="wiki-title">📖 \${w.title} <span class="wiki-badge">\${w.lang}</span></div>
              <div class="wiki-extract">\${w.extract}</div>
              <div style="margin-top:0.4rem;">
                <a href="\${w.url}" target="_blank" style="color:#a5b4fc; font-size:0.8rem; text-decoration:none;">Leer más en Wikipedia &rarr;</a>
              </div>
            </div>
          </div>
        `;
      }
      
      const header = document.getElementById('results-header');
      header.style.display = 'flex';
      document.getElementById('results-count').textContent = `\${data.total_hits} documentos encontrados`;
      document.getElementById('results-time').textContent = `\${data.time_ms} ms`;
      
      const grid = document.getElementById('results-grid');
      if (!data.hits || data.hits.length === 0) {
        grid.innerHTML = '<div class="empty-state">No se encontraron documentos.</div>';
        return;
      }
      
      grid.innerHTML = data.hits.map(h => `
        <div class="result-card">
          <div class="card-top">
            <div>
              <span class="card-repo">\${h.repo}</span>
              <span class="card-type">\${h.type || 'Documento'}</span>
            </div>
            <span class="card-date">\${h.date || ''} | Score: \${h.score.toFixed(1)}</span>
          </div>
          <div class="card-title">\${h.title}</div>
          <div class="card-author">👤 \${h.creator || 'Autor no especificado'}</div>
          <div class="card-snippet">\${h.snippet}</div>
          <div class="card-tags">
            \${(h.keywords || []).map(k => `<span class="tag-badge">\${k}</span>`).join('')}
          </div>
          <div class="card-footer">
            <div>
              \${h.has_fulltext ? `<button class="btn-action" onclick="searchInside(\${h.doc_idx})">🔍 Buscar en párrafos</button>` : ''}
              \${h.reference_count > 0 ? `<button class="btn-action-sec" onclick="showRefs(\${h.doc_idx})">📚 Referencias (\${h.reference_count})</button>` : ''}
            </div>
            \${h.file ? `<a href="/file?path=\${encodeURIComponent(h.file)}" target="_blank" class="btn-file">📄 Ver PDF</a>` : ''}
          </div>
          <div id="in-depth-\${h.doc_idx}" class="in-depth-box">
            <div class="in-depth-header">Búsqueda profunda en párrafos del documento:</div>
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
    
    /* Info & Analytics Loader */
    async function loadInfoView(repo) {
      const container = document.getElementById('info-content');
      container.innerHTML = '<div class="empty-state">Calculando métricas del repositorio...</div>';
      
      const url = repo ? `/api/info?repo=\${encodeURIComponent(repo)}` : '/api/info';
      try {
        const res = await fetch(url);
        const data = await res.json();
        
        container.innerHTML = `
          <div class="dashboard-grid">
            <div class="metric-card">
              <div class="metric-title">Publicaciones Indexadas</div>
              <div class="metric-value">\${data.total_docs.toLocaleString()}</div>
              <div class="metric-sub">Rango: \${data.year_range.min_year || 'N/A'} — \${data.year_range.max_year || 'N/A'}</div>
            </div>
            <div class="metric-card">
              <div class="metric-title">Archivos PDFs</div>
              <div class="metric-value" style="color:var(--green);">\${data.total_files.toLocaleString()}</div>
              <div class="metric-sub">\${((data.total_files/data.total_docs)*100).toFixed(1)}% de cobertura</div>
            </div>
            <div class="metric-card">
              <div class="metric-title">Texto Completo Extraído</div>
              <div class="metric-value" style="color:var(--amber);">\${data.total_fulltext.toLocaleString()}</div>
              <div class="metric-sub">\${((data.total_fulltext/data.total_docs)*100).toFixed(1)}% de manuscritos</div>
            </div>
            <div class="metric-card">
              <div class="metric-title">Citas Bibliográficas</div>
              <div class="metric-value" style="color:var(--purple);">\${data.total_references.toLocaleString()}</div>
              <div class="metric-sub">\${(data.total_references/data.total_docs).toFixed(1)} citas por documento</div>
            </div>
          </div>
          
          <div style="display:grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 1.5rem;">
            <div class="table-container">
              <div class="table-header">📚 Tipos de Publicación</div>
              <table class="data-table">
                <thead><tr><th>Tipo</th><th>Total</th></tr></thead>
                <tbody>
                  \${(data.publication_types || []).map(pt => `
                    <tr><td>\${pt.type}</td><td><strong>\${pt.count.toLocaleString()}</strong></td></tr>
                  `).join('')}
                </tbody>
              </table>
            </div>
            
            <div class="table-container">
              <div class="table-header">🏷️ Disciplinas y Áreas de Conocimiento</div>
              <table class="data-table">
                <thead><tr><th>Disciplina</th><th>Obras</th></tr></thead>
                <tbody>
                  \${(data.top_disciplines || []).slice(0, 10).map(td => `
                    <tr><td>\${td.discipline}</td><td><strong>\${td.count.toLocaleString()}</strong></td></tr>
                  `).join('')}
                </tbody>
              </table>
            </div>
          </div>
          
          <div class="table-container" style="margin-top:1.5rem;">
            <div class="table-header">👤 Investigadores y Asesores Principales</div>
            <table class="data-table">
              <thead><tr><th>Investigador</th><th>Rol</th><th>Repositorio</th><th>Publicaciones</th></tr></thead>
              <tbody>
                \${(data.top_researchers || []).slice(0, 15).map(r => `
                  <tr>
                    <td><strong>\${r.name}</strong></td>
                    <td><span class="card-repo" style="font-size:0.7rem;">\${r.role}</span></td>
                    <td>\${r.repo}</td>
                    <td><strong>\${r.count}</strong></td>
                  </tr>
                `).join('')}
              </tbody>
            </table>
          </div>
        `;
      } catch (e) {
        container.innerHTML = '<div class="empty-state">Error al cargar estadísticas.</div>';
      }
    }
    
    /* Web Shell Execution with Command History */
    const termInput = document.getElementById('term-input');
    const termOutput = document.getElementById('term-output');
    
    let shellHistory = [];
    try {
      shellHistory = JSON.parse(localStorage.getItem('reposmx_shell_history') || '[]');
    } catch (e) {
      shellHistory = [];
    }
    let historyCursor = -1;
    let tempCurrentInput = '';
    
    termInput.addEventListener('keydown', async (e) => {
      if (e.key === 'ArrowUp') {
        e.preventDefault();
        if (shellHistory.length === 0) return;
        if (historyCursor === -1) {
          tempCurrentInput = termInput.value;
        }
        if (historyCursor < shellHistory.length - 1) {
          historyCursor++;
          termInput.value = shellHistory[shellHistory.length - 1 - historyCursor];
        }
      } else if (e.key === 'ArrowDown') {
        e.preventDefault();
        if (historyCursor > 0) {
          historyCursor--;
          termInput.value = shellHistory[shellHistory.length - 1 - historyCursor];
        } else if (historyCursor === 0) {
          historyCursor = -1;
          termInput.value = tempCurrentInput;
        }
      } else if (e.key === 'Enter') {
        const cmd = termInput.value.trim();
        if (!cmd) return;
        
        // Push to persistent history
        if (shellHistory.length === 0 || shellHistory[shellHistory.length - 1] !== cmd) {
          shellHistory.push(cmd);
          if (shellHistory.length > 200) shellHistory.shift();
          try {
            localStorage.setItem('reposmx_shell_history', JSON.stringify(shellHistory));
          } catch (e) {}
        }
        historyCursor = -1;
        tempCurrentInput = '';
        
        termOutput.textContent += `\\nreposmx> \${cmd}\\n`;
        termInput.value = '';
        termOutput.scrollTop = termOutput.scrollHeight;
        
        if (cmd === '/clear' || cmd === 'clear') {
          termOutput.textContent = '';
          return;
        }
        
        try {
          const res = await fetch(`/api/cli/execute?cmd=\${encodeURIComponent(cmd)}`);
          const data = await res.json();
          termOutput.textContent += (data.output || '') + '\\n';
          termOutput.scrollTop = termOutput.scrollHeight;
        } catch (err) {
          termOutput.textContent += `[Error de conexión con el servidor]\\n`;
        }
      }
    });
    
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

Starts the HTTP server and web interface (Read-Only analytical client).
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
    
    HTTP.register!(router, "GET", "/api/authors/topic", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        top = tryparse(Int, get(params, "top", "10"))
        top = top === nothing ? 10 : top
        
        res = search_authors_by_topic(engine, q; top)
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(res))
    end)
    
    HTTP.register!(router, "GET", "/api/authors/similar", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        q = get(params, "q", "")
        top = tryparse(Int, get(params, "top", "10"))
        top = top === nothing ? 10 : top
        
        res = find_similar_authors_by_references(engine, q; top)
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
    
    # Web Shell / Terminal Command Executor (Read-Only)
    HTTP.register!(router, "GET", "/api/cli/execute", function(req)
        uri = URI(req.target)
        params = queryparams(uri)
        raw_cmd = strip(get(params, "cmd", ""))
        
        if isempty(raw_cmd)
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(Dict("output" => "")))
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
                               "  • Rango temporal:       $(get(get(st, "year_range", Dict()), "min_year", "N/A")) — $(get(get(st, "year_range", Dict()), "max_year", "N/A"))",
                               "=======================================================",
                               "\n📚 TIPOS DE PUBLICACIÓN:"]
                for pt in get(st, "publication_types", [])
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
            res = search_authors_by_topic(engine, q; top=10)
            lines = String["Top autores en el tema: \"$q\" ($(get(res, "total_hits", 0)) hits en $(get(res, "time_ms", 0.0)) ms):"]
            for (i, a) in enumerate(get(res, "authors", []))
                push!(lines, "[$i] $(a["name"]) - $(a["doc_count"]) docs ($(join(a["repos"], ", "))) [Score: $(a["score"])]")
            end
            join(lines, "\n")
        elseif startswith(raw_cmd, "/sim-authors")
            q = strip(replace(raw_cmd, r"^/sim-authors\s*" => ""))
            res = find_similar_authors_by_references(engine, q; top=10)
            lines = String["Autores con acoplamiento bibliográfico a \"$q\":"]
            for (i, a) in enumerate(get(res, "similar_authors", []))
                push!(lines, "[$i] $(a["name"]) - $(a["doc_count"]) docs ($(join(a["repos"], ", "))) [Score: $(a["similarity_score"])]")
            end
            join(lines, "\n")
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
            "Acervo total: $(st["total_repos"]) repositorios, $(st["total_records"]) registros."
        else
            # Default BM25 Search
            res = query_index(engine, raw_cmd; top=5, include_wiki=false)
            lines = String["Resultados para \"$raw_cmd\" ($(get(res, "total_hits", 0)) hits en $(get(res, "time_ms", 0.0)) ms):"]
            for (i, h) in enumerate(get(res, "hits", []))
                push!(lines, "[$i] $(get(h, "title", ""))\n    🏛️ $(get(h, "repo", "")) | 👤 $(get(h, "creator", "")) | Score: $(round(get(h, "score", 0.0), digits=2))")
            end
            join(lines, "\n")
        end
        
        return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], JSON.json(Dict("output" => output_str)))
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
