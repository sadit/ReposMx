// La página del mapa de las meta-disciplinas (paginas.jl, pagina_mapa): el grafo de /api/metadisciplinas
// dibujado por grafo.js; clic en una para ver en el panel su descripción, sus palabras y sus vecinas, y un buscador
// dentro de ella (la entrada con ?meta=). ?m=M012 en la dirección la elige al cargar.
(() => {
  const raiz = document.getElementById('mapa-raiz');
  const canvas = document.getElementById('mapa');
  if (!raiz || !canvas || !window.d3 || !window.mapaMetas) return;
  const prefijo = raiz.dataset.prefijo || '';
  const panel = document.getElementById('mapa-panel');
  const filtro = document.getElementById('mapa-filtro');
  let m = null;

  function muestraPanel(n) {
    const { esc, miles } = m;
    if (!n) {
      panel.innerHTML = '<p class="text-tenue">Elige una meta-disciplina en el mapa para ver de qué trata, sus vecinas y buscar dentro de ella.</p>';
      return;
    }
    const vs = m.vecinas(n.id).sort((a, b) => b.documentos - a.documentos);
    const punto = c => c ? `<span aria-hidden="true" class="inline-block size-2.5 shrink-0 rounded-full" style="background:${esc(c)}"></span>` : '';
    panel.innerHTML = `
      <h2 class="flex items-center gap-2 text-lg font-semibold leading-snug text-acento">${punto(n.color)}${esc(n.nombre)}</h2>
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
      <ul class="mt-1 space-y-0.5">${vs.map(v => `<li class="flex items-center gap-1.5">${punto(v.color)}<button type="button" data-vecina="${esc(v.id)}" class="text-left text-liga underline decoration-dotted underline-offset-4 hover:text-acento">${esc(v.nombre)}</button>
        <span class="text-xs text-tenue">${miles(v.documentos)}</span></li>`).join('')}</ul>` : ''}`;
    panel.querySelectorAll('[data-vecina]').forEach(b => b.addEventListener('click', () => elige(b.dataset.vecina, true)));
  }

  function elige(x, centra) { m.elige(x, centra); muestraPanel(m.nodo(x)); }

  fetch(prefijo + '/api/metadisciplinas').then(r => r.json()).then(g => {
    m = mapaMetas(canvas, { grafo: g, punta: document.getElementById('mapa-punta'), alElegir: n => elige(n, false) });
    filtro?.addEventListener('input', () => m.resalta(filtro.value));
    const q = new URLSearchParams(location.search).get('m');
    if (q && m.nodo(q)) setTimeout(() => elige(q, true), 1200);
  }).catch(() => { panel.innerHTML = '<p class="text-aviso-texto">No se pudo cargar el mapa.</p>'; });
})();
