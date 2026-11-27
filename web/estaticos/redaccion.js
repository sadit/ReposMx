// La conversación en la página: el redaccion.js de AmbientalWeb, más el selector de tema (`tema`).
//
// 1. `redaccion`: un componente de Alpine por paso. Si la respuesta ya viene en la página (sin dirección),
//    sólo le pone las ligas a las citas; si no, escucha el flujo de /redaccion (eventos enviados por el
//    servidor) y va poniendo el texto. Una sola conexión por respuesta, sin reintentos; si el recuadro se
//    quita o la página se cierra, la conexión se cierra y el servidor cancela la generación. Mientras
//    redacta avisa al formulario (evento «redactando») para que no se mande otra pregunta. Al terminar
//    pueden llegar preguntas para seguir, propuestas por el modelo: cada una es un botón que la pone en el
//    formulario y la manda. Sólo las ofrece la última respuesta.
// 2. Las fuentes de cada pregunta van en un <details>: al llegar un paso nuevo se pliegan las anteriores, y
//    una cita [13] abre las fuentes de su pregunta antes de saltar a su fragmento (#p2f13).
// sin acentos y en minúsculas, para el filtro de disciplinas (paginas.jl, selector_cti)
window.sinAcentos = x => (x || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();

(() => {
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const avisa = ocupado => window.dispatchEvent(new CustomEvent('redactando', { detail: ocupado }));
  const lista = x => (Array.isArray(x) ? x : []).filter(q => typeof q === 'string' && q.trim()).slice(0, 5);

  document.addEventListener('alpine:init', () => {
    // El tema de colores (estilo.css): se guarda en el navegador; vacío sigue al sistema.
    Alpine.data('tema', () => ({
      valor: (() => { try { return localStorage.getItem('tema') || ''; } catch (_) { return ''; } })(),
      cambia() {
        if (this.valor) document.documentElement.dataset.tema = this.valor; else delete document.documentElement.dataset.tema;
        try { this.valor ? localStorage.setItem('tema', this.valor) : localStorage.removeItem('tema'); } catch (_) { /* sin almacenamiento */ }
      },
    }));
    Alpine.data('redaccion', (url, hasta) => ({
      estado: url ? 'espera' : 'lista',     // espera | leyendo | escribiendo | lista | falla
      texto: '',
      aviso: '',
      nota: '',
      otras: 0,
      saturado: 0,          // intento en curso cuando el servicio que redacta contestó que está ocupado
      sugerencias: [],      // preguntas para seguir
      fuente: null,
      init() {
        // los hijos todavía no pasan por Alpine: el texto que puso el servidor sigue ahí
        if (!url) {
          this.texto = this.$el.querySelector('[data-texto]').textContent;
          try { this.sugerencias = lista(JSON.parse(this.$el.dataset.sugerencias || '[]')); } catch (_) { /* sin preguntas */ }
          return;
        }
        this.conecta();
      },
      // Una pregunta propuesta: va al renglón de la pregunta y se manda, salvo que haya otra respuesta en curso.
      pregunta(q) {
        const campo = document.getElementById('q');
        if (!campo) return;             // la conversación llegó a su límite
        campo.value = q;
        const boton = campo.form.querySelector('button[type=submit]');
        if (boton && boton.disabled) { campo.focus(); return; }
        campo.form.requestSubmit(boton || undefined);
      },
      // Lo que se dice mientras espera turno: es un demo, redacta de una en una y va lento.
      get espera() {
        if (this.saturado > 0) return 'El servicio que redacta está ocupado en este momento. Este demo tiene recursos limitados: se vuelve a intentar en unos segundos (intento ' + this.saturado + ' de 3); no hace falta recargar la página.';
        if (!(this.otras > 0)) return 'Preparando la respuesta…';
        return (this.$el.dataset.lento || 'Este demo tiene recursos limitados.') + ' ' +
          (this.otras === 1 ? 'Hay otra respuesta en curso' : `Hay otras ${this.otras} respuestas en curso o en fila`) +
          '; la tuya espera su turno. Espera un poco, no hace falta recargar la página.';
      },
      reintenta() { this.cierra(); this.estado = 'espera'; this.texto = ''; this.aviso = ''; this.otras = 0; this.saturado = 0; this.sugerencias = []; this.conecta(); },
      conecta() {
        avisa(true);
        const f = this.fuente = new EventSource(url);
        f.addEventListener('espera', e => { this.estado = 'espera'; this.otras = Number(JSON.parse(e.data)) || 0; });
        f.addEventListener('leyendo', () => { this.estado = 'leyendo'; this.saturado = 0; });
        f.addEventListener('saturado', e => { this.estado = 'espera'; this.saturado = Number(JSON.parse(e.data)) || 1; });
        f.addEventListener('texto', e => { this.estado = 'escribiendo'; this.texto += JSON.parse(e.data); });
        f.addEventListener('fin', e => {
          const d = JSON.parse(e.data);
          this.cierra(); this.estado = 'lista'; this.nota = d.nota || ''; this.sugerencias = lista(d.sugerencias);
        });
        f.addEventListener('falla', e => { this.cierra(); this.estado = 'falla'; this.aviso = JSON.parse(e.data); });
        f.onerror = () => {
          if (!this.fuente) return;     // ya terminó: es el cierre normal
          this.cierra();                // sin esto EventSource reintenta y se volvería a redactar
          this.estado = 'falla';
          this.aviso = 'Se perdió la conexión mientras se redactaba la respuesta.';
        };
      },
      // El texto escapado, con las citas ligadas a su fragmento. Los fragmentos se numeran de corrido en la
      // conversación y cada tarjeta dice su número (data-cita): [13] va a la tarjeta 13, y [13, 15] a las dos.
      get html() {
        return this.texto.replace(/[&<>"']/g, c => ESC[c]).replace(/\[([^\[\]]{1,60})\]/g, (todo, dentro) =>
          '[' + dentro.replace(/(?<![\d.])\d{1,3}(?![\d.])/g, n => {
            const el = n >= 1 && n <= hasta ? document.querySelector(`[data-cita="${+n}"]`) : null;
            return el ? `<a class="cita" href="#${el.id}">${n}</a>` : n;
          }) + ']');
      },
      cierra() { if (this.fuente) { this.fuente.close(); this.fuente = null; avisa(false); } },
      destroy() { this.cierra(); },
    }));
  });

  // Abre las fuentes plegadas donde está el fragmento al que se va.
  const abre = ancla => {
    if (!/^#p\d+(f\d+)?$/.test(ancla || '')) return;
    const el = document.getElementById(ancla.slice(1));
    const d = el && el.closest('details');
    if (d) d.open = true;
  };
  document.addEventListener('click', e => {
    const a = e.target.closest && e.target.closest('a.cita');
    if (a) abre(a.getAttribute('href'));
  });
  window.addEventListener('hashchange', () => abre(location.hash));
  document.addEventListener('DOMContentLoaded', () => {
    abre(location.hash);
    if (/^#p\d+f\d+$/.test(location.hash)) document.getElementById(location.hash.slice(1))?.scrollIntoView();
  });

  // Llegó un paso nuevo: se pliegan las fuentes de los anteriores, se quitan sus preguntas para seguir y la
  // página baja a la pregunta nueva.
  document.addEventListener('htmx:afterSwap', e => {
    if (!e.detail.target || e.detail.target.id !== 'pasos') return;
    const pasos = document.querySelectorAll('#pasos [data-paso]');
    pasos.forEach((p, i) => {
      if (i === pasos.length - 1) return;
      p.querySelectorAll('details[data-fuentes]').forEach(d => { d.open = false; });
      p.querySelectorAll('[data-sugeridas]').forEach(d => d.remove());      // las preguntas para seguir son de la última respuesta
    });
    if (pasos.length) pasos[pasos.length - 1].scrollIntoView({ behavior: 'smooth', block: 'start' });
  });
})();
