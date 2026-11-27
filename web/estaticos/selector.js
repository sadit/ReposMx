// El mapa de la entrada (paginas.jl, vista_entrada) como selector de meta-disciplina: clic en una la elige
// (evento «meta-elegida», que recibe el componente de la página y pliega el mapa). Al preguntar o listar, el mapa
// se pliega (evento «mapa-pliega») para dejar el ancho a los resultados; «quitar» la deja sin elegir
// (evento «meta-quitada»). El dibujo es el de grafo.js.
(() => {
  const raiz = document.getElementById('selector-mapa');
  const canvas = document.getElementById('selector-lienzo');
  if (!raiz || !canvas || !window.d3 || !window.mapaMetas) return;
  const prefijo = raiz.dataset.prefijo || '';
  const filtro = document.getElementById('selector-filtro');
  const avisa = (nombre, detail) => window.dispatchEvent(new CustomEvent(nombre, { detail }));

  document.body.addEventListener('htmx:beforeRequest', () => avisa('mapa-pliega'));

  fetch(prefijo + '/api/metadisciplinas').then(r => r.json()).then(g => {
    const m = mapaMetas(canvas, {
      grafo: g, punta: document.getElementById('selector-punta'), detalle: true,
      alElegir: n => {
        if (!n) return;
        m.elige(n, false);
        avisa('meta-elegida', { id: n.id, nombre: n.nombre, color: n.color || '' });
      },
    });
    if (raiz.dataset.meta) m.elige(raiz.dataset.meta, false);
    filtro?.addEventListener('input', () => m.resalta(filtro.value));
    window.addEventListener('meta-quitada', () => m.elige(null));
  }).catch(() => { canvas.insertAdjacentHTML('afterend', '<p class="mt-2 text-sm text-aviso-texto">No se pudo cargar el mapa.</p>'); });
})();
