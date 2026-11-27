// El grafo de las meta-disciplinas en canvas, compartido por el mapa (mapa.js) y el selector de la entrada
// (selector.js). Nodos: meta-disciplinas (área ~ documentos), con el color falso de su centro proyectado a tres
// dimensiones (RGB) y sembrados en el plano de las dos primeras componentes (`color` y `plano` de grafo.json,
// experiments/rag_web/colorea_metadisciplinas.py), de modo que el mapa se ve como un gradiente. Aristas: las que se
// parecen (centros cercanos) o comparten documentos. Rueda para acercar, arrastre para moverse; el tamaño del lienzo
// se sigue con ResizeObserver (el selector se pliega y se despliega). Los colores del tema se leen de estilo.css.
//
//   const m = mapaMetas(canvas, { grafo, punta, alElegir(n), alPasar(n) })
//   m.elige(id | nodo | null, centra)   m.resalta(texto)   m.nodo(id)   m.vecinas(id)
window.mapaMetas = function (canvas, { grafo, punta = null, alElegir = null, detalle = false } = {}) {
  const ctx = canvas.getContext('2d');
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ESC[c]);
  const miles = n => Number(n).toLocaleString('es-MX');
  const tema = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim() || '#888';
  const sinAcentos = window.sinAcentos || (x => (x || '').toLowerCase());
  const R = 320;                    // radio del plano en coordenadas del grafo

  const maxd = Math.max(1, ...grafo.nodos.map(n => n.documentos));
  const nodos = grafo.nodos.map(n => {
    const [px, py] = Array.isArray(n.plano) ? n.plano : [0, 0];
    return { ...n, r: 4 + 22 * Math.sqrt(n.documentos / maxd), px: px * R, py: py * R, x: px * R, y: py * R };
  });
  const porId = new Map(nodos.map(n => [n.id, n]));
  const enlaces = grafo.enlaces.filter(e => porId.has(e.source) && porId.has(e.target)).map(e => ({ ...e }));
  const vecinos = new Map(nodos.map(n => [n.id, new Set()]));
  for (const e of enlaces) { vecinos.get(e.source).add(e.target); vecinos.get(e.target).add(e.source); }

  let elegido = null, encima = null, resaltados = null, t = d3.zoomIdentity, ancho = 0, alto = 0, centrado = false;

  function encuadre() {
    const k = Math.min(ancho, alto) / (2 * R + 360);
    return d3.zoomIdentity.translate(ancho / 2, alto / 2).scale(Math.max(0.2, k));
  }

  function mide() {
    const r = canvas.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    ancho = r.width; alto = r.height;
    if (!ancho || !alto) return;
    canvas.width = Math.round(ancho * dpr); canvas.height = Math.round(alto * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (!centrado) { centrado = true; d3.select(canvas).call(zoom.transform, encuadre()); }
    dibuja();
  }

  function dibuja() {
    if (!ancho || !alto) return;
    const cBorde = tema('--t-borde'), cLiga = tema('--t-liga'), cAcento = tema('--t-acento');
    const cTexto = tema('--t-fuerte'), cTenue = tema('--t-tenue'), cFondo = tema('--t-superficie');
    ctx.save();
    ctx.clearRect(0, 0, ancho, alto);
    ctx.translate(t.x, t.y); ctx.scale(t.k, t.k);
    const activo = encima || elegido;
    const cerca = activo ? vecinos.get(activo.id) : null;
    for (const e of enlaces) {
      const toca = activo && (e.source === activo || e.target === activo);
      ctx.strokeStyle = toca ? cAcento : cBorde;
      ctx.globalAlpha = toca ? 0.9 : (activo || resaltados ? 0.12 : 0.45);
      ctx.lineWidth = (toca ? 2 : 1) / t.k;
      ctx.beginPath(); ctx.moveTo(e.source.x, e.source.y); ctx.lineTo(e.target.x, e.target.y); ctx.stroke();
    }
    for (const n of nodos) {
      const atenua = (activo && n !== activo && !(cerca && cerca.has(n.id))) || (resaltados && !resaltados.has(n.id));
      ctx.globalAlpha = atenua ? 0.22 : 1;
      ctx.fillStyle = n.color || cLiga;
      ctx.beginPath(); ctx.arc(n.x, n.y, n.r, 0, 2 * Math.PI); ctx.fill();
      ctx.strokeStyle = cFondo; ctx.lineWidth = 1.5 / t.k; ctx.stroke();
      if (n === elegido) {
        ctx.strokeStyle = cTexto; ctx.lineWidth = 3 / t.k;
        ctx.beginPath(); ctx.arc(n.x, n.y, n.r + 4 / t.k, 0, 2 * Math.PI); ctx.stroke();
      }
    }
    // nombres: los grandes, el activo y sus vecinas, y los resaltados; en tamaño constante en pantalla
    ctx.globalAlpha = 1;
    ctx.font = `${12 / t.k}px system-ui, sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    // sin encimarse: primero los obligados (activo, elegido), luego por tamaño; se salta el que choca
    const puestos = [], h = 14 / t.k;
    const obligado = n => n === activo || n === elegido;
    const candidatos = nodos.filter(n => obligado(n) || (cerca && cerca.has(n.id)) || (resaltados && resaltados.has(n.id)) ||
      (!activo && !resaltados && n.r * t.k > 9));
    candidatos.sort((a, b) => (obligado(b) - obligado(a)) || (b.r - a.r));
    for (const n of candidatos) {
      const w = ctx.measureText(n.nombre).width, x0 = n.x - w / 2, y0 = n.y + n.r + 3 / t.k;
      if (!obligado(n) && puestos.some(c => x0 < c.x1 && c.x0 < x0 + w && y0 < c.y1 && c.y0 < y0 + h)) continue;
      puestos.push({ x0, x1: x0 + w, y0, y1: y0 + h });
      ctx.lineWidth = 3 / t.k; ctx.strokeStyle = cFondo; ctx.fillStyle = obligado(n) ? cTexto : cTenue;
      ctx.strokeText(n.nombre, n.x, y0); ctx.fillText(n.nombre, n.x, y0);
    }
    ctx.restore();
  }

  // el nodo bajo el puntero, en coordenadas del grafo
  function bajo(ev) {
    const r = canvas.getBoundingClientRect();
    const [x, y] = t.invert([ev.clientX - r.left, ev.clientY - r.top]);
    let mejor = null, d = Infinity;
    for (const n of nodos) {
      const dd = Math.hypot(n.x - x, n.y - y);
      if (dd < Math.max(n.r, 7 / t.k) && dd < d) { mejor = n; d = dd; }
    }
    return mejor;
  }

  function nodo(x) { return x == null ? null : typeof x === 'string' ? porId.get(x) || null : x; }

  function elige(x, centra) {
    elegido = nodo(x);
    if (elegido && centra && ancho) {
      d3.select(canvas).transition().duration(600)
        .call(zoom.transform, d3.zoomIdentity.translate(ancho / 2, alto / 2).scale(Math.max(t.k, 1.2)).translate(-elegido.x, -elegido.y));
    }
    dibuja();
  }

  function resalta(texto) {
    const q = sinAcentos((texto || '').trim());
    resaltados = q ? new Set(nodos.filter(n => sinAcentos([n.nombre, n.nombre_en, ...(n.palabras || [])].join(' ')).includes(q)).map(n => n.id)) : null;
    dibuja();
  }

  const zoom = d3.zoom().scaleExtent([0.15, 8]).on('zoom', ev => { t = ev.transform; dibuja(); });
  d3.select(canvas).call(zoom).on('dblclick.zoom', null);

  // la simulación parte del plano y se queda cerca de él: el color y la posición cuentan la misma historia
  d3.forceSimulation(nodos)
    .force('link', d3.forceLink(enlaces).id(n => n.id).distance(e => 30 + 120 * (1 - e.similitud)).strength(e => 0.05 + 0.25 * Math.min(1, e.jaccard * 20)))
    .force('charge', d3.forceManyBody().strength(-40))
    .force('collide', d3.forceCollide(n => n.r + 3))
    .force('x', d3.forceX(n => n.px).strength(0.18)).force('y', d3.forceY(n => n.py).strength(0.18))
    .on('tick', dibuja);

  canvas.addEventListener('mousemove', ev => {
    const n = bajo(ev);
    if (n !== encima) { encima = n; canvas.style.cursor = n ? 'pointer' : 'grab'; dibuja(); }
    if (!punta) return;
    if (n) {
      const r = canvas.getBoundingClientRect();
      punta.innerHTML = `<strong>${esc(n.nombre)}</strong> · ${miles(n.documentos)} documentos` +
        (detalle && n.palabras ? `<br><span style="opacity:.8">${esc(n.palabras.slice(0, 6).join(' · '))}</span>` : '');
      const x = ev.clientX - r.left + 14, y = ev.clientY - r.top + 14;
      punta.style.left = `${Math.min(x, ancho - 260)}px`; punta.style.top = `${y}px`;
      punta.classList.remove('hidden');
    } else punta.classList.add('hidden');
  });
  canvas.addEventListener('mouseleave', () => { encima = null; punta?.classList.add('hidden'); dibuja(); });
  canvas.addEventListener('click', ev => { const n = bajo(ev); if (alElegir) alElegir(n); });
  new ResizeObserver(mide).observe(canvas);
  // el tema cambia los colores: se vuelve a dibujar
  new MutationObserver(dibuja).observe(document.documentElement, { attributes: true, attributeFilter: ['data-tema'] });
  mide();

  return { elige, resalta, nodo, vecinas: id => [...(vecinos.get(id) || [])].map(v => porId.get(v)), nodos, esc, miles };
};
