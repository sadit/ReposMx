// El mapa de las meta-disciplinas (paginas.jl, pagina_mapa): el grafo de /api/metadisciplinas con una simulación
// de fuerzas de D3, dibujado en canvas. Nodos: meta-disciplinas (área ~ documentos). Aristas: las que se parecen
// (centros cercanos) o comparten documentos. Rueda para acercar, arrastre para moverse, clic para elegir una: el
// panel muestra su descripción, sus palabras y sus vecinas, y un buscador dentro de ella (Documentos con ?meta=).
// Los colores se leen del tema (estilo.css), así que el mapa sigue al selector de tema.
(() => {
  const raiz = document.getElementById('mapa-raiz');
  const canvas = document.getElementById('mapa');
  if (!raiz || !canvas || !window.d3) return;
  const prefijo = raiz.dataset.prefijo || '';
  const panel = document.getElementById('mapa-panel');
  const punta = document.getElementById('mapa-punta');
  const filtro = document.getElementById('mapa-filtro');
  const ctx = canvas.getContext('2d');
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = x => String(x ?? '').replace(/[&<>"']/g, c => ESC[c]);
  const miles = n => Number(n).toLocaleString('es-MX');
  const color = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim() || '#888';

  let nodos = [], enlaces = [], vecinos = new Map(), elegido = null, encima = null, resaltados = null;
  let t = d3.zoomIdentity, ancho = 0, alto = 0;

  function mide() {
    const r = canvas.getBoundingClientRect(), dpr = window.devicePixelRatio || 1;
    ancho = r.width; alto = r.height;
    canvas.width = Math.round(ancho * dpr); canvas.height = Math.round(alto * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function dibuja() {
    const cBorde = color('--t-borde'), cLiga = color('--t-liga'), cAcento = color('--t-acento');
    const cTexto = color('--t-fuerte'), cTenue = color('--t-tenue'), cFondo = color('--t-superficie');
    ctx.save();
    ctx.clearRect(0, 0, ancho, alto);
    ctx.translate(t.x, t.y); ctx.scale(t.k, t.k);
    const activo = elegido || encima;
    const cerca = activo ? vecinos.get(activo.id) : null;
    for (const e of enlaces) {
      const toca = activo && (e.source === activo || e.target === activo);
      ctx.strokeStyle = toca ? cAcento : cBorde;
      ctx.globalAlpha = toca ? 0.9 : (activo || resaltados ? 0.15 : 0.5);
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
    // nombres: los grandes, el activo y sus vecinas, y los resaltados; en tamaño constante en pantalla
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

  // el nodo bajo el puntero, en coordenadas del grafo
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
    if (!n) {
      panel.innerHTML = '<p class="text-tenue">Elige una meta-disciplina en el mapa para ver de qué trata, sus vecinas y buscar dentro de ella.</p>';
      return;
    }
    const vs = [...(vecinos.get(n.id) || [])].map(id => nodos.find(x => x.id === id)).filter(Boolean)
      .sort((a, b) => b.documentos - a.documentos);
    panel.innerHTML = `
      <h2 class="text-lg font-semibold leading-snug text-acento">${esc(n.nombre)}</h2>
      ${n.nombre_en ? `<p class="text-xs text-tenue">${esc(n.nombre_en)}</p>` : ''}
      <p class="mt-2 leading-relaxed text-texto">${esc(n.descripcion)}</p>
      <p class="mt-2 text-xs text-tenue">${miles(n.documentos)} documentos</p>
      <p class="mt-3 flex flex-wrap gap-1 text-xs">${n.palabras.map(p => `<span class="rounded-full bg-realce px-2 py-0.5 text-liga ring-1 ring-inset ring-liga/20">${esc(p)}</span>`).join(' ')}</p>
      <form action="${esc(prefijo)}/buscar" method="get" class="mt-4 space-y-2">
        <input type="hidden" name="meta" value="${esc(n.id)}">
        <input type="search" name="q" required placeholder="Pregunta dentro de esta meta-disciplina" aria-label="Pregunta"
               class="w-full rounded-lg border border-borde bg-fondo px-3 py-2 text-sm text-fuerte placeholder:text-tenue">
        <button type="submit" class="w-full rounded-lg bg-boton px-3 py-2 text-sm font-medium text-sobre-boton hover:opacity-90">Buscar aquí</button>
      </form>
      <a href="${esc(prefijo)}/?meta=${encodeURIComponent(n.id)}" class="mt-2 inline-block text-xs text-liga underline decoration-dotted underline-offset-4">Abrir Documentos con este filtro</a>
      ${vs.length ? `<h3 class="mt-4 text-xs font-medium uppercase tracking-wide text-tenue">Vecinas</h3>
      <ul class="mt-1 space-y-0.5">${vs.map(v => `<li><button type="button" data-vecina="${esc(v.id)}" class="text-left text-liga underline decoration-dotted underline-offset-4 hover:text-acento">${esc(v.nombre)}</button>
        <span class="text-xs text-tenue">${miles(v.documentos)}</span></li>`).join('')}</ul>` : ''}`;
    panel.querySelectorAll('[data-vecina]').forEach(b => b.addEventListener('click', () => elige(nodos.find(x => x.id === b.dataset.vecina), true)));
  }

  function elige(n, centra) {
    elegido = n; muestraPanel(n);
    if (n && centra) {
      d3.select(canvas).transition().duration(600)
        .call(zoom.transform, d3.zoomIdentity.translate(ancho / 2, alto / 2).scale(Math.max(t.k, 1.2)).translate(-n.x, -n.y));
    }
    dibuja();
  }

  const zoom = d3.zoom().scaleExtent([0.2, 8]).on('zoom', ev => { t = ev.transform; dibuja(); });

  fetch(prefijo + '/api/metadisciplinas').then(r => r.json()).then(g => {
    const maxd = d3.max(g.nodos, n => n.documentos) || 1;
    nodos = g.nodos.map(n => ({ ...n, r: 4 + 22 * Math.sqrt(n.documentos / maxd) }));
    const porId = new Map(nodos.map(n => [n.id, n]));
    enlaces = g.enlaces.filter(e => porId.has(e.source) && porId.has(e.target)).map(e => ({ ...e }));
    for (const e of enlaces) {
      if (!vecinos.has(e.source)) vecinos.set(e.source, new Set());
      if (!vecinos.has(e.target)) vecinos.set(e.target, new Set());
      vecinos.get(e.source).add(e.target); vecinos.get(e.target).add(e.source);
    }
    mide();
    const sim = d3.forceSimulation(nodos)
      .force('link', d3.forceLink(enlaces).id(n => n.id).distance(e => 40 + 160 * (1 - e.similitud)).strength(e => 0.2 + 0.8 * Math.min(1, e.jaccard * 20)))
      .force('charge', d3.forceManyBody().strength(-90))
      .force('collide', d3.forceCollide(n => n.r + 3))
      .force('x', d3.forceX(0).strength(0.04)).force('y', d3.forceY(0).strength(0.04))
      .on('tick', dibuja);
    t = d3.zoomIdentity.translate(ancho / 2, alto / 2).scale(0.8);
    d3.select(canvas).call(zoom).call(zoom.transform, t);
    sim.on('end', dibuja);
    // ?m=M012 en la dirección: elige esa al terminar de acomodarse
    const m = new URLSearchParams(location.search).get('m');
    if (m && porId.has(m)) setTimeout(() => elige(porId.get(m), true), 1500);
  }).catch(() => { panel.innerHTML = '<p class="text-aviso-texto">No se pudo cargar el mapa.</p>'; });

  canvas.addEventListener('mousemove', ev => {
    const n = bajo(ev);
    if (n !== encima) { encima = n; canvas.style.cursor = n ? 'pointer' : 'grab'; dibuja(); }
    if (n) {
      const r = canvas.getBoundingClientRect();
      punta.textContent = `${n.nombre} · ${miles(n.documentos)}`;
      punta.style.left = `${ev.clientX - r.left + 12}px`; punta.style.top = `${ev.clientY - r.top + 44}px`;
      punta.classList.remove('hidden');
    } else punta.classList.add('hidden');
  });
  canvas.addEventListener('mouseleave', () => { encima = null; punta.classList.add('hidden'); dibuja(); });
  canvas.addEventListener('click', ev => elige(bajo(ev), false));
  filtro?.addEventListener('input', () => {
    const q = window.sinAcentos ? window.sinAcentos(filtro.value.trim()) : filtro.value.trim().toLowerCase();
    resaltados = q ? new Set(nodos.filter(n => window.sinAcentos([n.nombre, n.nombre_en, ...n.palabras].join(' ')).includes(q)).map(n => n.id)) : null;
    dibuja();
  });
  window.addEventListener('resize', () => { mide(); dibuja(); });
  // el tema cambia los colores: se vuelve a dibujar
  new MutationObserver(dibuja).observe(document.documentElement, { attributes: true, attributeFilter: ['data-tema'] });
})();
