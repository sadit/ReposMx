// El mapa de las meta-disciplinas del sitio (mapa.qmd): el grafo de mapa/grafo.json (copia de metadisciplinas/
// grafo.json, sitio/genera.py) con una simulación de fuerzas de D3, dibujado en canvas. Es el de web/estaticos/
// mapa.js, sin la búsqueda (el sitio no liga al demo); los colores salen del tema de Quarto.
(() => {
  const raiz = document.getElementById('mapa-sitio');
  const canvas = document.getElementById('mapa');
  if (!raiz || !canvas || !window.d3) return;
  const panel = document.getElementById('mapa-panel');
  const punta = document.getElementById('mapa-punta');
  const filtro = document.getElementById('mapa-filtro');
  const ctx = canvas.getContext('2d');
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ESC[c]);
  const miles = n => Number(n).toLocaleString('es-MX');
  const sinAcentos = x => (x || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const color = (v, d) => getComputedStyle(document.body).getPropertyValue(v).trim() || d;

  let nodos = [], enlaces = [], vecinos = new Map(), elegido = null, encima = null, resaltados = null;
  let t = d3.zoomIdentity, ancho = 0, alto = 0;

  function mide() {
    const r = canvas.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    ancho = r.width; alto = r.height;
    canvas.width = Math.round(ancho * dpr); canvas.height = Math.round(alto * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function dibuja() {
    const cLiga = color('--bs-link-color', '#1f6ea8'), cAcento = color('--bs-danger', '#cb4b16');
    const cTexto = color('--bs-emphasis-color', '#073642'), cTenue = color('--bs-secondary-color', '#657b83');
    const cBorde = color('--bs-border-color', '#e4dcc4'), cFondo = color('--bs-body-bg', '#fdf6e3');
    ctx.save();
    ctx.clearRect(0, 0, ancho, alto);
    ctx.translate(t.x, t.y); ctx.scale(t.k, t.k);
    const activo = elegido || encima;
    const cerca = activo ? vecinos.get(activo.id) : null;
    for (const e of enlaces) {
      const toca = activo && (e.source === activo || e.target === activo);
      ctx.strokeStyle = toca ? cAcento : cBorde;
      ctx.globalAlpha = toca ? 0.9 : (activo || resaltados ? 0.15 : 0.6);
      ctx.lineWidth = (toca ? 2 : 1) / t.k;
      ctx.beginPath(); ctx.moveTo(e.source.x, e.source.y); ctx.lineTo(e.target.x, e.target.y); ctx.stroke();
    }
    for (const n of nodos) {
      const atenua = (activo && n !== activo && !(cerca && cerca.has(n.id))) || (resaltados && !resaltados.has(n.id));
      ctx.globalAlpha = atenua ? 0.25 : 1;
      ctx.fillStyle = n === elegido ? cAcento : cLiga;
      ctx.beginPath(); ctx.arc(n.x, n.y, n.r, 0, 2 * Math.PI); ctx.fill();
      ctx.strokeStyle = cFondo; ctx.lineWidth = 1.5 / t.k; ctx.stroke();
    }
    ctx.globalAlpha = 1;
    ctx.font = `${12 / t.k}px system-ui, sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    for (const n of nodos) {
      const muestra = n === activo || (cerca && cerca.has(n.id)) || (resaltados && resaltados.has(n.id)) ||
        (!activo && !resaltados && n.r * t.k > 14);
      if (!muestra) continue;
      ctx.lineWidth = 3 / t.k; ctx.strokeStyle = cFondo; ctx.fillStyle = n === activo ? cTexto : cTenue;
      ctx.strokeText(n.nombre, n.x, n.y + n.r + 2 / t.k); ctx.fillText(n.nombre, n.x, n.y + n.r + 2 / t.k);
    }
    ctx.restore();
  }

  function bajo(ev) {
    const r = canvas.getBoundingClientRect();
    const [x, y] = t.invert([ev.clientX - r.left, ev.clientY - r.top]);
    let mejor = null, d = Infinity;
    for (const n of nodos) {
      const dd = Math.hypot(n.x - x, n.y - y);
      if (dd < Math.max(n.r, 6 / t.k) && dd < d) { mejor = n; d = dd; }
    }
    return mejor;
  }

  function muestraPanel(n) {
    if (!n) { panel.innerHTML = '<p class="nota">Elige una meta-disciplina en el mapa.</p>'; return; }
    const vs = [...(vecinos.get(n.id) || [])].map(id => nodos.find(x => x.id === id)).filter(Boolean)
      .sort((a, b) => b.documentos - a.documentos);
    panel.innerHTML = `
      <h3 style="margin-top:0">${esc(n.nombre)}</h3>
      ${n.nombre_en ? `<p class="nota">${esc(n.nombre_en)}</p>` : ''}
      <p>${esc(n.descripcion)}</p>
      <p class="nota">${miles(n.documentos)} documentos</p>
      <p>${n.palabras.map(p => `<span class="etiqueta">${esc(p)}</span>`).join(' ')}</p>
      ${vs.length ? `<h4>Vecinas</h4><ul>${vs.map(v => `<li><a href="#" data-vecina="${esc(v.id)}">${esc(v.nombre)}</a> <span class="nota">${miles(v.documentos)}</span></li>`).join('')}</ul>` : ''}`;
    panel.querySelectorAll('[data-vecina]').forEach(a => a.addEventListener('click', ev => {
      ev.preventDefault(); elige(nodos.find(x => x.id === a.dataset.vecina), true);
    }));
  }

  function elige(n, centra) {
    elegido = n; muestraPanel(n);
    if (n && centra) d3.select(canvas).transition().duration(600)
      .call(zoom.transform, d3.zoomIdentity.translate(ancho / 2, alto / 2).scale(Math.max(t.k, 1.2)).translate(-n.x, -n.y));
    dibuja();
  }

  const zoom = d3.zoom().scaleExtent([0.2, 8]).on('zoom', ev => { t = ev.transform; dibuja(); });

  fetch('mapa/grafo.json').then(r => r.json()).then(g => {
    const maxd = d3.max(g.nodos, n => n.documentos) || 1;
    nodos = g.nodos.map(n => ({ ...n, r: 4 + 22 * Math.sqrt(n.documentos / maxd) }));
    const porId = new Map(nodos.map(n => [n.id, n]));
    enlaces = g.enlaces.filter(e => porId.has(e.source) && porId.has(e.target)).map(e => ({ ...e }));
    for (const e of enlaces) {
      for (const [a, b] of [[e.source, e.target], [e.target, e.source]]) {
        if (!vecinos.has(a)) vecinos.set(a, new Set());
        vecinos.get(a).add(b);
      }
    }
    mide();
    d3.forceSimulation(nodos)
      .force('link', d3.forceLink(enlaces).id(n => n.id).distance(e => 40 + 160 * (1 - e.similitud)).strength(e => 0.2 + 0.8 * Math.min(1, e.jaccard * 20)))
      .force('charge', d3.forceManyBody().strength(-90))
      .force('collide', d3.forceCollide(n => n.r + 3))
      .force('x', d3.forceX(0).strength(0.04)).force('y', d3.forceY(0).strength(0.04))
      .on('tick', dibuja);
    t = d3.zoomIdentity.translate(ancho / 2, alto / 2).scale(0.8);
    d3.select(canvas).call(zoom).call(zoom.transform, t);
  }).catch(() => { panel.innerHTML = '<p>No se pudo cargar el mapa.</p>'; });

  canvas.addEventListener('mousemove', ev => {
    const n = bajo(ev);
    if (n !== encima) { encima = n; canvas.style.cursor = n ? 'pointer' : 'grab'; dibuja(); }
    if (n) {
      const r = canvas.getBoundingClientRect();
      punta.textContent = `${n.nombre} · ${miles(n.documentos)}`;
      punta.style.left = `${ev.clientX - r.left + 12}px`; punta.style.top = `${ev.clientY - r.top + 12}px`;
      punta.style.display = 'block';
    } else punta.style.display = 'none';
  });
  canvas.addEventListener('mouseleave', () => { encima = null; punta.style.display = 'none'; dibuja(); });
  canvas.addEventListener('click', ev => elige(bajo(ev), false));
  filtro?.addEventListener('input', () => {
    const q = sinAcentos(filtro.value.trim());
    resaltados = q ? new Set(nodos.filter(n => sinAcentos([n.nombre, n.nombre_en, ...n.palabras].join(' ')).includes(q)).map(n => n.id)) : null;
    dibuja();
  });
  window.addEventListener('resize', () => { mide(); dibuja(); });
  // el interruptor claro/oscuro de Quarto cambia los colores
  new MutationObserver(dibuja).observe(document.body, { attributes: true, attributeFilter: ['class'] });
})();
