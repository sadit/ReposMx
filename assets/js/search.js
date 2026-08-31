/* ReposMx — búsqueda de documentos/autores/referencias, renderizado y paginación */

async function doSearch() {
  const q = document.getElementById('query-input').value.trim();
  const grid = document.getElementById('results-grid');
  const networkSection = document.getElementById('network-section');

  // Sub-modo "Red de coautoría / citas": vista completamente distinta (D3), sin paginación.
  if (currentMode === 'authors' && authorSubmode === 'network') {
    grid.style.display = 'none';
    networkSection.style.display = 'block';
    hidePagination();
    document.getElementById('wiki-container').innerHTML = '';
    document.getElementById('results-header').style.display = 'none';
    if (q) await loadNetworkView(q);
    syncURLState();
    return;
  }

  networkSection.style.display = 'none';
  grid.style.display = 'grid';

  if (!q) {
    grid.innerHTML = '<div class="empty-state">Ingresa una consulta para explorar el acervo académico nacional.</div>';
    document.getElementById('results-header').style.display = 'none';
    document.getElementById('wiki-container').innerHTML = '';
    hidePagination();
    return;
  }

  showSkeleton(grid, 3);
  document.getElementById('results-header').style.display = 'none';
  hidePagination();

  if (currentMode === 'authors') {
    let endpoint;
    if (authorSubmode === 'topic') {
      endpoint = `/api/authors/topic?q=${encodeURIComponent(q)}`;
    } else if (authorSubmode === 'sim') {
      endpoint = `/api/authors/similar?q=${encodeURIComponent(q)}`;
    } else {
      endpoint = `/api/authors?q=${encodeURIComponent(q)}&offset=${currentOffset}`;
    }
    const data = await API.get('search', endpoint);
    if (data) renderAuthors(data);
    syncURLState();
    return;
  }

  if (currentMode === 'refs') {
    const repo = document.getElementById('repo-select').value;
    const data = await API.get('search', `/api/references?q=${encodeURIComponent(q)}&repo=${encodeURIComponent(repo)}&offset=${currentOffset}`);
    if (data) renderReferences(data);
    syncURLState();
    return;
  }

  // Documentos
  const repo = document.getElementById('repo-select').value;
  const type = document.getElementById('type-select').value;
  const yearMin = document.getElementById('year-min-input').value;
  const yearMax = document.getElementById('year-max-input').value;
  let url = `/api/search?q=${encodeURIComponent(q)}&repo=${encodeURIComponent(repo)}&doc_type=${encodeURIComponent(type)}&wiki=true&offset=${currentOffset}`;
  if (yearMin) url += `&year_min=${encodeURIComponent(yearMin)}`;
  if (yearMax) url += `&year_max=${encodeURIComponent(yearMax)}`;

  const data = await API.get('search', url);
  if (data) renderResults(data);
  syncURLState();
}

function renderAuthors(data) {
  document.getElementById('wiki-container').innerHTML = '';
  const header = document.getElementById('results-header');
  header.style.display = 'flex';
  const list = data.authors || data.similar_authors || [];
  const count = data.total_hits !== undefined ? data.total_hits : list.length;
  document.getElementById('results-count').textContent = `${count} investigadores / colaboradores encontrados`;
  document.getElementById('results-time').textContent = `${data.time_ms || 0} ms`;

  const grid = document.getElementById('results-grid');
  if (!list || list.length === 0) {
    grid.innerHTML = '<div class="empty-state">No se encontraron investigadores que coincidan con la consulta.</div>';
    hidePagination();
    return;
  }

  grid.innerHTML = list.map(a => `
    <div class="result-card">
      <div class="card-top">
        <span class="card-repo">${a.role || 'Autor'}</span>
        <span class="card-date">${a.doc_count || 1} publicaciones</span>
      </div>
      <div class="card-title">${a.name}</div>
      <div class="card-author">🏛️ Repositorios: ${(a.repos || []).join(', ') || 'N/A'}</div>
      <div class="card-snippet">👥 Coautores: ${(a.coauthors || []).join(' ; ') || 'N/A'}</div>
      ${a.keywords && a.keywords.length ? `
        <div class="card-tags">
          ${a.keywords.slice(0, 6).map(k => `<span class="tag-badge">${k}</span>`).join('')}
        </div>
      ` : ''}
    </div>
  `).join('');

  if (data.has_more !== undefined) renderPagination(!!data.has_more, doSearch);
  else hidePagination();
}

function renderReferences(data) {
  document.getElementById('wiki-container').innerHTML = '';
  const header = document.getElementById('results-header');
  header.style.display = 'flex';
  document.getElementById('results-count').textContent = `${data.total_hits} citas / referencias encontradas`;
  document.getElementById('results-time').textContent = `${data.time_ms} ms`;

  const grid = document.getElementById('results-grid');
  if (!data.references || data.references.length === 0) {
    grid.innerHTML = '<div class="empty-state">No se encontraron referencias que coincidan.</div>';
    hidePagination();
    return;
  }

  grid.innerHTML = data.references.map(r => `
    <div class="result-card">
      <div class="card-top">
        <span class="card-repo">${r.repo}</span>
        <span class="card-date">${r.total_references} referencias en total</span>
      </div>
      <div class="card-title">${r.doc_title}</div>
      <div class="card-author">👤 ${r.creator || 'Autor no especificado'}</div>
      ${(r.sample_references || []).map(sr => `
        <div class="card-snippet" style="margin-top:0.35rem;">— ${sr.text || sr}</div>
      `).join('')}
    </div>
  `).join('');

  if (data.has_more !== undefined) renderPagination(!!data.has_more, doSearch);
  else hidePagination();
}

function renderResults(data) {
  const wikiContainer = document.getElementById('wiki-container');
  wikiContainer.innerHTML = '';
  if (data.wiki_concept) {
    const w = data.wiki_concept;
    wikiContainer.innerHTML = `
      <div class="wiki-card">
        ${w.thumbnail ? `<img src="${w.thumbnail}" class="wiki-thumb" alt="${w.title}">` : ''}
        <div>
          <div class="wiki-title">📖 ${w.title} <span class="wiki-badge">${w.lang}</span></div>
          <div class="wiki-extract">${w.extract}</div>
          <div style="margin-top:0.4rem;">
            <a href="${w.url}" target="_blank" style="color:var(--purple); font-size:0.8rem; text-decoration:none;">Leer más en Wikipedia &rarr;</a>
          </div>
        </div>
      </div>
    `;
  }

  const header = document.getElementById('results-header');
  header.style.display = 'flex';
  document.getElementById('results-count').textContent = `${data.total_hits} documentos encontrados`;
  document.getElementById('results-time').textContent = `${data.time_ms} ms`;

  const grid = document.getElementById('results-grid');
  if (!data.hits || data.hits.length === 0) {
    grid.innerHTML = '<div class="empty-state">No se encontraron documentos.</div>';
    hidePagination();
    return;
  }

  grid.innerHTML = data.hits.map(h => `
    <div class="result-card">
      <div class="card-top">
        <div>
          <span class="card-repo">${h.repo}</span>
          <span class="card-type">${h.type || 'Documento'}</span>
        </div>
        <span class="card-date">${h.date || ''} | Score: ${h.score.toFixed(1)}</span>
      </div>
      <div class="card-title">${h.title}</div>
      <div class="card-author">👤 ${h.creator || 'Autor no especificado'}</div>
      <div class="card-snippet">${h.snippet}</div>
      <div class="card-tags">
        ${(h.keywords || []).map(k => `<span class="tag-badge">${k}</span>`).join('')}
      </div>
      <div class="card-footer">
        <div>
          ${h.has_fulltext ? `<button class="btn-action" onclick="searchInside(${h.doc_idx}, '${h.repo}', '${h.id}')">🔍 Buscar en párrafos</button>` : ''}
          ${h.reference_count > 0 ? `<button class="btn-action-sec" onclick="showRefs(${h.doc_idx}, '${h.repo}', '${h.id}')">📚 Referencias (${h.reference_count})</button>` : ''}
        </div>
        ${h.file ? `<a href="/file?path=${encodeURIComponent(h.file)}" target="_blank" class="btn-file">📄 Ver PDF</a>` : ''}
      </div>
      <div id="in-depth-${h.doc_idx}" class="in-depth-box">
        <div class="in-depth-header">Búsqueda profunda en párrafos del documento:</div>
        <div style="display:flex; gap:0.5rem;">
          <input type="text" id="inside-q-${h.doc_idx}" class="search-input" placeholder="Término o pregunta dentro del documento...">
          <button class="btn-search" onclick="runSearchInside(${h.doc_idx}, '${h.repo}', '${h.id}')">Buscar Párrafos</button>
        </div>
        <div id="inside-res-${h.doc_idx}" style="margin-top:0.75rem;"></div>
      </div>
      <div id="refs-box-${h.doc_idx}" class="in-depth-box">
        <div class="in-depth-header">Referencias Bibliográficas Citadas:</div>
        <div id="refs-res-${h.doc_idx}"></div>
      </div>
    </div>
  `).join('');

  renderPagination(!!data.has_more, doSearch);
}

function searchInside(docIdx) {
  const box = document.getElementById(`in-depth-${docIdx}`);
  box.style.display = box.style.display === 'block' ? 'none' : 'block';
}

async function showRefs(docIdx, repo, docId) {
  const box = document.getElementById(`refs-box-${docIdx}`);
  box.style.display = box.style.display === 'block' ? 'none' : 'block';
  const container = document.getElementById(`refs-res-${docIdx}`);
  if (box.style.display === 'block' && !container.innerHTML) {
    container.innerHTML = '<div style="color:var(--accent);">Cargando referencias...</div>';
    try {
      const res = await fetch(`/api/document/references?repo=${encodeURIComponent(repo)}&doc_id=${encodeURIComponent(docId)}`);
      const data = await res.json();
      if (!data.references || data.references.length === 0) {
        container.innerHTML = '<div style="color:var(--text-muted);">No se encontraron referencias extraídas para este documento.</div>';
        return;
      }
      container.innerHTML = data.references.map((r, i) => `
        <div class="ref-item">
          <strong>[${i + 1}]</strong> ${r.text}
        </div>
      `).join('');
    } catch (e) {
      container.innerHTML = '<div style="color:#ef4444;">Error al cargar referencias.</div>';
    }
  }
}

async function runSearchInside(docIdx, repo, docId) {
  const q = document.getElementById(`inside-q-${docIdx}`).value.trim();
  const resContainer = document.getElementById(`inside-res-${docIdx}`);
  if (!q) return;

  resContainer.innerHTML = '<div style="color:var(--accent);">Analizando párrafos...</div>';
  try {
    const res = await fetch(`/api/document/paragraphs?repo=${encodeURIComponent(repo)}&doc_id=${encodeURIComponent(docId)}&q=${encodeURIComponent(q)}`);
    const data = await res.json();
    if (data.error) {
      resContainer.innerHTML = `<div style="color:#ef4444;">${data.error}</div>`;
      return;
    }
    resContainer.innerHTML = (data.hits || []).map((h) => `
      <div class="paragraph-item">
        <div style="font-weight:600; color:var(--accent); margin-bottom:0.25rem;">[Párrafo ${h.paragraph_num} - ${h.section} | Score: ${h.score.toFixed(1)}]</div>
        <div>${h.text}</div>
      </div>
    `).join('');
  } catch (e) {
    resContainer.innerHTML = '<div style="color:#ef4444;">Error al buscar párrafos.</div>';
  }
}
