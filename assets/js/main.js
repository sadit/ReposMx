/* ReposMx — estado global, tabs, tema, fetch con cancelación de carreras, sync de URL */

let currentMode = 'docs';
let authorSubmode = 'name';
let currentOffset = 0;
let lastHasMore = false;
const PAGE_SIZE = 10;

/* ---------- Fetch helper: cancela la petición anterior de la misma "key" y
   descarta respuestas obsoletas (evita que una búsqueda lenta vieja sobrescriba
   una búsqueda más nueva). ---------- */
const API = (function () {
  const controllers = {};
  const seq = {};

  async function get(key, url) {
    if (controllers[key]) controllers[key].abort();
    const ctrl = new AbortController();
    controllers[key] = ctrl;
    const mySeq = (seq[key] = (seq[key] || 0) + 1);

    try {
      const res = await fetch(url, { signal: ctrl.signal });
      const data = await res.json();
      if (seq[key] !== mySeq) return null; // respuesta obsoleta, ignorar
      return data;
    } catch (e) {
      if (e.name === 'AbortError') return null;
      console.error(e);
      return null;
    }
  }

  return { get };
})();

function debounce(fn, wait) {
  let t = null;
  return function (...args) {
    clearTimeout(t);
    t = setTimeout(() => fn.apply(this, args), wait);
  };
}

/* ---------- Tema claro/oscuro ---------- */
function initTheme() {
  const btn = document.getElementById('theme-toggle');
  btn.addEventListener('click', () => {
    const cur = document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light';
    const next = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('reposmx_theme', next); } catch (e) {}
  });
}

/* ---------- Skeleton de carga ---------- */
function showSkeleton(container, n = 3) {
  let html = '';
  for (let i = 0; i < n; i++) {
    html += `
      <div class="skeleton-card">
        <div class="skeleton-line w-40"></div>
        <div class="skeleton-line w-90"></div>
        <div class="skeleton-line w-70"></div>
      </div>`;
  }
  container.innerHTML = html;
}

/* ---------- Paginación ---------- */
function renderPagination(hasMore, onChange) {
  const pag = document.getElementById('pagination');
  const prevBtn = document.getElementById('prev-page-btn');
  const nextBtn = document.getElementById('next-page-btn');
  const label = document.getElementById('page-label');

  pag.style.display = 'flex';
  const page = Math.floor(currentOffset / PAGE_SIZE) + 1;
  label.textContent = `Página ${page}`;
  prevBtn.disabled = currentOffset <= 0;
  nextBtn.disabled = !hasMore;

  prevBtn.onclick = () => {
    currentOffset = Math.max(0, currentOffset - PAGE_SIZE);
    onChange();
  };
  nextBtn.onclick = () => {
    currentOffset = currentOffset + PAGE_SIZE;
    onChange();
  };
}

function hidePagination() {
  document.getElementById('pagination').style.display = 'none';
}

/* ---------- URL deep-linking ---------- */
function getURLState() {
  const p = new URLSearchParams(location.search);
  return {
    tab: p.get('tab') || 'docs',
    q: p.get('q') || '',
    repo: p.get('repo') || '',
    type: p.get('type') || '',
    year_min: p.get('year_min') || '',
    year_max: p.get('year_max') || '',
    offset: parseInt(p.get('offset') || '0', 10) || 0,
    submode: p.get('submode') || 'name'
  };
}

function syncURLState() {
  const p = new URLSearchParams();
  p.set('tab', currentMode);
  const q = document.getElementById('query-input').value.trim();
  if (q) p.set('q', q);

  if (currentMode === 'docs') {
    const repo = document.getElementById('repo-select').value;
    const type = document.getElementById('type-select').value;
    const ymin = document.getElementById('year-min-input').value;
    const ymax = document.getElementById('year-max-input').value;
    if (repo) p.set('repo', repo);
    if (type) p.set('type', type);
    if (ymin) p.set('year_min', ymin);
    if (ymax) p.set('year_max', ymax);
  }
  if (currentMode === 'authors') p.set('submode', authorSubmode);
  if (currentOffset) p.set('offset', String(currentOffset));

  const qs = p.toString();
  history.replaceState(null, '', qs ? ('?' + qs) : location.pathname);
}

/* ---------- Tabs ---------- */
function switchMode(mode, opts = {}) {
  currentMode = mode;
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === mode));

  document.getElementById('search-section').style.display = (mode === 'info' || mode === 'shell') ? 'none' : 'block';
  document.getElementById('info-section').style.display = mode === 'info' ? 'block' : 'none';
  document.getElementById('shell-section').style.display = mode === 'shell' ? 'block' : 'none';

  document.getElementById('author-subfilters').style.display = mode === 'authors' ? 'flex' : 'none';
  document.getElementById('type-select').style.display = mode === 'docs' ? 'block' : 'none';
  document.getElementById('year-filter').style.display = mode === 'docs' ? 'flex' : 'none';

  if (!opts.skipReset) currentOffset = 0;

  if (mode === 'docs') {
    document.getElementById('query-input').placeholder = 'Buscar por tema, conceptos, palabras clave (ej. redes neuronales, optimización)...';
    if (!opts.skipSearch) doSearch();
  } else if (mode === 'authors') {
    updateAuthorPlaceholder();
    if (!opts.skipSearch) doSearch();
  } else if (mode === 'refs') {
    document.getElementById('query-input').placeholder = 'Buscar en referencias citadas (ej. Knuth, Deep Learning, Goodfellow, IEEE)...';
    if (!opts.skipSearch) doSearch();
  } else if (mode === 'info') {
    loadInfoView(document.getElementById('info-repo-select').value);
  } else if (mode === 'shell') {
    document.getElementById('term-input').focus();
  }
  syncURLState();
}

function setAuthorSubmode(sub, opts = {}) {
  authorSubmode = sub;
  document.getElementById('btn-auth-name').classList.toggle('active', sub === 'name');
  document.getElementById('btn-auth-topic').classList.toggle('active', sub === 'topic');
  document.getElementById('btn-auth-sim').classList.toggle('active', sub === 'sim');
  document.getElementById('btn-auth-network').classList.toggle('active', sub === 'network');
  updateAuthorPlaceholder();
  currentOffset = 0;
  if (!opts.skipSearch) doSearch();
  syncURLState();
}

function updateAuthorPlaceholder() {
  const input = document.getElementById('query-input');
  if (authorSubmode === 'name') {
    input.placeholder = 'Buscar investigador o colaborador por nombre (ej. Eric Tellez, Samaniego)...';
  } else if (authorSubmode === 'topic') {
    input.placeholder = 'Rankear autores por campo del conocimiento / tema (ej. visión por computadora, bioinformática)...';
  } else if (authorSubmode === 'sim') {
    input.placeholder = 'Recomendar investigadores afines por acoplamiento bibliográfico (ej. Flores, Gonzalez)...';
  } else if (authorSubmode === 'network') {
    input.placeholder = 'Nombre del investigador para ver su red de coautoría y citas...';
  }
}

/* ---------- Stats badge + selects de repositorio ---------- */
async function loadStats() {
  const data = await API.get('stats', '/api/stats');
  if (!data) return;
  const summary = data.summary || {};
  document.getElementById('stats-badge').textContent =
    `${summary.total_repos || 0} repositorios | ${(summary.total_records || 0).toLocaleString()} registros`;

  const sel = document.getElementById('repo-select');
  const infoSel = document.getElementById('info-repo-select');
  (data.repos || []).forEach(r => {
    const opt = document.createElement('option');
    opt.value = r.repo;
    opt.textContent = `${r.repo} (${(r.total_records || 0).toLocaleString()})`;
    sel.appendChild(opt);
    infoSel.appendChild(opt.cloneNode(true));
  });
}

/* ---------- Bootstrap ---------- */
document.addEventListener('DOMContentLoaded', () => {
  initTheme();

  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => switchMode(btn.dataset.tab));
  });
  document.querySelectorAll('#author-subfilters .sub-filter-btn').forEach(btn => {
    btn.addEventListener('click', () => setAuthorSubmode(btn.dataset.submode));
  });

  const debouncedSearch = debounce(() => {
    const q = document.getElementById('query-input').value.trim();
    if (q.length >= 2) { currentOffset = 0; doSearch(); }
  }, 350);

  document.getElementById('search-btn').addEventListener('click', () => { currentOffset = 0; doSearch(); });
  document.getElementById('query-input').addEventListener('keydown', e => {
    if (e.key === 'Enter') { currentOffset = 0; doSearch(); }
  });
  document.getElementById('query-input').addEventListener('input', debouncedSearch);
  document.getElementById('type-select').addEventListener('change', () => { currentOffset = 0; doSearch(); });
  document.getElementById('repo-select').addEventListener('change', () => { currentOffset = 0; doSearch(); });
  document.getElementById('year-min-input').addEventListener('change', () => { currentOffset = 0; doSearch(); });
  document.getElementById('year-max-input').addEventListener('change', () => { currentOffset = 0; doSearch(); });

  document.getElementById('info-repo-select').addEventListener('change', () => loadInfoView(document.getElementById('info-repo-select').value));
  document.getElementById('info-refresh-btn').addEventListener('click', () => loadInfoView(document.getElementById('info-repo-select').value));

  loadStats();

  // Restaurar estado desde la URL (deep-linking)
  const st = getURLState();
  document.getElementById('query-input').value = st.q;
  document.getElementById('repo-select').value = st.repo;
  document.getElementById('type-select').value = st.type;
  document.getElementById('year-min-input').value = st.year_min;
  document.getElementById('year-max-input').value = st.year_max;
  currentOffset = st.offset;

  if (st.tab === 'authors') {
    switchMode('authors', { skipSearch: true, skipReset: true });
    setAuthorSubmode(st.submode, { skipSearch: true });
  } else {
    switchMode(st.tab || 'docs', { skipSearch: true, skipReset: true });
  }

  const isBrowseTab = st.tab === 'docs' || st.tab === 'authors' || st.tab === 'refs' || !st.tab;
  if (isBrowseTab && st.q) doSearch();
});
