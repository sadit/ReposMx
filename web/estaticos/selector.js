// El mapa de la entrada (paginas.jl, vista_entrada) como selector de meta-disciplina: clic en una la elige
// (evento «meta-elegida», que recibe el componente de la página y achica el mapa). Al preguntar o listar, el mapa
// se achica (evento «mapa-achica») sin ocultarse, y al llegar los resultados se iluminan las meta-disciplinas en las
// que cayeron sus documentos (`data-metas` del último paso o de la lista). «quitar» deja la meta-disciplina sin
// elegir (evento «meta-quitada»). Debajo del mapa va la ficha de la elegida (descripción, palabras clave y vecinas,
// como en la página del mapa); una vecina se elige con un clic. El dibujo es el de grafo.js.
(() => {
  const raiz = document.getElementById('selector-mapa');
  const canvas = document.getElementById('selector-lienzo');
  if (!raiz || !canvas || !window.d3 || !window.mapaMetas) return;
  const prefijo = raiz.dataset.prefijo || '';
  const filtro = document.getElementById('selector-filtro');
  const leyenda = document.getElementById('selector-leyenda');
  const ficha = document.getElementById('selector-ficha');
  const avisa = (nombre, detail) => window.dispatchEvent(new CustomEvent(nombre, { detail }));
  let m = null;

  document.body.addEventListener('htmx:beforeRequest', () => avisa('mapa-achica'));

  function elige(n) {
    if (!n) return;
    m.elige(n, false);
    muestraFicha(n);
    avisa('meta-elegida', { id: n.id, nombre: n.nombre, color: n.color || '' });
  }

  // la ficha de la meta-disciplina elegida, como el panel de la página del mapa (mapa.js)
  function muestraFicha(n) {
    if (!ficha) return;
    if (!n) { ficha.classList.add('hidden'); ficha.innerHTML = ''; return; }
    const { esc, miles } = m;
    const punto = c => c ? `<span aria-hidden="true" class="inline-block size-2.5 shrink-0 rounded-full" style="background:${esc(c)}"></span>` : '';
    const vs = m.vecinas(n.id).sort((a, b) => b.documentos - a.documentos);
    ficha.innerHTML = `
      <h2 class="flex items-center gap-2 font-semibold leading-snug text-acento">${punto(n.color)}${esc(n.nombre)}</h2>
      ${n.nombre_en ? `<p class="text-xs text-tenue">${esc(n.nombre_en)} · ${miles(n.documentos)} documentos</p>` : `<p class="text-xs text-tenue">${miles(n.documentos)} documentos</p>`}
      ${n.descripcion ? `<p class="mt-2 leading-relaxed text-texto">${esc(n.descripcion)}</p>` : ''}
      <p class="mt-3 flex flex-wrap gap-1 text-xs">${(n.palabras || []).map(p => `<span class="rounded-full bg-realce px-2 py-0.5 text-liga ring-1 ring-inset ring-liga/20">${esc(p)}</span>`).join(' ')}</p>
      ${vs.length ? `<h3 class="mt-3 text-xs font-medium uppercase tracking-wide text-tenue">Vecinas</h3>
      <ul class="mt-1 flex flex-wrap gap-x-4 gap-y-1">${vs.map(v => `<li class="flex items-center gap-1.5">${punto(v.color)}<button type="button" data-vecina="${esc(v.id)}"
        class="text-left text-liga underline decoration-dotted underline-offset-4 hover:text-acento">${esc(v.nombre)}</button></li>`).join('')}</ul>` : ''}`;
    ficha.querySelectorAll('[data-vecina]').forEach(b => b.addEventListener('click', () => elige(m.nodo(b.dataset.vecina))));
    ficha.classList.remove('hidden');
  }

  // ilumina las meta-disciplinas de un elemento con data-metas (un paso o la lista); null apaga
  function ilumina(el, que) {
    if (!m) return;
    let cuentas = null;
    try { cuentas = el ? JSON.parse(el.dataset.metas || '{}') : null; } catch (_) { cuentas = null; }
    m.ilumina(cuentas);
    const n = cuentas ? Object.keys(cuentas).length : 0;
    if (!n) { leyenda.classList.add('hidden'); leyenda.textContent = ''; return; }
    leyenda.innerHTML = `Iluminadas: las ${n === 1 ? 'meta-disciplina' : n + ' meta-disciplinas'} de los documentos ${m.esc(que)}. ` +
      '<button type="button" class="text-liga underline decoration-dotted underline-offset-4 hover:text-acento">Apagar</button>';
    leyenda.querySelector('button').addEventListener('click', () => ilumina(null));
    leyenda.classList.remove('hidden');
  }
  const ultimoPaso = () => { const xs = document.querySelectorAll('#pasos [data-paso][data-metas]'); return xs[xs.length - 1] || null; };
  const deLista = () => document.querySelector('#lista [data-metas]');
  function iluminaInicial() {
    const l = deLista(), p = ultimoPaso();
    if (l) ilumina(l, 'de la lista'); else if (p) ilumina(p, 'de la última pregunta');
  }

  document.body.addEventListener('htmx:afterSwap', ev => {
    const id = ev.detail?.target?.id;
    if (id === 'pasos') ilumina(ultimoPaso(), 'de la última pregunta');
    else if (id === 'lista') ilumina(deLista(), 'de la lista');
  });

  fetch(prefijo + '/api/metadisciplinas').then(r => r.json()).then(g => {
    m = mapaMetas(canvas, {
      grafo: g, punta: document.getElementById('selector-punta'), detalle: true,
      alElegir: elige,
    });
    if (raiz.dataset.meta) { m.elige(raiz.dataset.meta, false); muestraFicha(m.nodo(raiz.dataset.meta)); }
    filtro?.addEventListener('input', () => m.resalta(filtro.value));
    window.addEventListener('meta-quitada', () => { m.elige(null); muestraFicha(null); });
    iluminaInicial();
  }).catch(() => { canvas.insertAdjacentHTML('afterend', '<p class="mt-2 text-sm text-aviso-texto">No se pudo cargar el mapa.</p>'); });
})();
