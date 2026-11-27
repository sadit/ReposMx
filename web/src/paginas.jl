# La cara HTML: páginas y fragmentos para htmx. Todo se arma en el servidor; el navegador sólo carga htmx,
# Alpine.js, la hoja de estilo (Tailwind, generada con web/estilo.sh a partir de las clases de este archivo) y
# redaccion.js, que escucha el flujo de la respuesta redactada. Las ligas llevan el prefijo del servicio: el demo
# vive bajo una ruta de una dirección compartida con otros demos (el portero).
#
# Tres pestañas, una por colección: documentos (una conversación con respuesta redactada, como en AmbientalWeb;
# también dentro de la producción de un autor), autores y referencias (listas).
#
# Los colores son tokens (bg-fondo, text-tenue, ...) que define estilo.css para cada tema: Solarized claro y
# oscuro, pizarra y clásico, para probarlos y decidir (indicación del usuario, 2026-11-26). Sin elección, el tema
# sigue al sistema (Solarized claro u oscuro); la elección se recuerda en el navegador.

const TITULO = "ReposMx"
const TEMAS = ["" => "Automático", "sol-claro" => "Solarized claro", "sol-oscuro" => "Solarized oscuro",
               "pizarra" => "Pizarra", "clasico" => "Clásico"]

function esc(s::AbstractString)
    io = IOBuffer()
    for c in s
        c == '&' ? print(io, "&amp;") : c == '<' ? print(io, "&lt;") : c == '>' ? print(io, "&gt;") :
        c == '"' ? print(io, "&quot;") : c == '\'' ? print(io, "&#39;") : print(io, c)
    end
    String(take!(io))
end

miles(n::Integer) = replace(string(n), r"(?<=\d)(?=(\d{3})+$)" => ",")
estatico(s, archivo) = string(s.prefijo, "/estaticos/", archivo, "?v=", get(s.versiones, archivo, "0"))
liga_segura(u) = startswith(u, "https://") || startswith(u, "http://")
qs(ps...) = join(("$k=$(URIs.escapeuri(string(v)))" for (k, v) in ps if !isempty(string(v))), "&amp;")

const NOMBRE_MODO = Dict(:densa => "Por significado", :bm25 => "Por palabras")
const AYUDA_MODO = Dict(
    :densa => "Compara el significado de la pregunta con la ficha y con el inicio y el final del texto de cada documento (vectores de Qwen3-Embedding).",
    :bm25 => "Busca las palabras de la consulta en la ficha de cada documento: título, resumen y palabras clave (BM25).")

const CLASE_LIGA = "text-liga underline decoration-dotted underline-offset-4 hover:text-acento"
const CLASE_CAMPO = "w-full rounded-lg border border-borde bg-superficie px-4 py-3 text-base text-fuerte shadow-sm placeholder:text-tenue focus:border-liga focus:outline-none focus:ring-2 focus:ring-liga/30"
const CLASE_BOTON = "shrink-0 rounded-lg bg-boton px-5 py-3 font-medium text-sobre-boton shadow-sm hover:opacity-90 focus:outline-none focus:ring-2 focus:ring-liga/50 disabled:cursor-not-allowed disabled:opacity-50"
const CLASE_CHIP = "rounded-full bg-realce px-2 py-0.5 font-medium text-liga ring-1 ring-inset ring-liga/20"

function barra(s, actual::Symbol)
    pestaña(clave, texto, ruta) = clave == actual ?
        """<a href="$(s.prefijo)$ruta" aria-current="page" class="rounded bg-sobre-barra/15 px-2 py-1 font-medium text-sobre-barra">$texto</a>""" :
        """<a href="$(s.prefijo)$ruta" class="rounded px-2 py-1 text-sobre-barra/75 hover:text-sobre-barra">$texto</a>"""
    opciones = join(("""<option value="$k">$(esc(n))</option>""" for (k, n) in TEMAS), "")
    """
    <nav aria-label="Colecciones" class="bg-barra text-sobre-barra">
      <div class="mx-auto flex max-w-5xl flex-wrap items-center gap-x-1 gap-y-1 px-4 py-2.5 text-sm">
        <a href="$(s.prefijo)/" class="mr-4 py-1 font-mono text-lg font-semibold tracking-tight text-sobre-barra">$TITULO</a>
        $(pestaña(:documentos, "Documentos", "/"))
        $(pestaña(:autores, "Autores", "/autores"))
        $(pestaña(:referencias, "Referencias", "/referencias"))
        $(tiene_metas(s.acervo) ? pestaña(:mapa, "Mapa", "/mapa") : "")
        <label class="ml-auto inline-flex items-center gap-2 text-xs text-sobre-barra/75" x-data="tema()">
          <span>Tema</span>
          <select x-model="valor" @change="cambia()" class="rounded border border-sobre-barra/30 bg-barra px-1.5 py-1 text-xs text-sobre-barra">$opciones</select>
        </label>
      </div>
    </nav>
    """
end

aviso(msg) = """<p role="alert" class="rounded-lg border border-aviso-borde bg-aviso-fondo px-4 py-3 text-sm text-aviso-texto">$(esc(msg))</p>"""

function selector_repo(s, repo::AbstractString)
    ops = join(("""<option value="$r"$(r == repo ? " selected" : "")>$r</option>""" for r in s.acervo.repos), "")
    """
    <label class="inline-flex items-center gap-2">
      <span class="text-tenue">Repositorio</span>
      <select name="repo" class="rounded border border-borde bg-superficie px-2 py-1 text-sm text-fuerte"><option value="">todos ($(length(s.acervo.repos)))</option>$ops</select>
    </label>
    """
end

sin_acentos(x) = lowercase(Unicode.normalize(String(x); stripmark=true))

"""
El selector de meta-disciplina (grupos de palabras clave por significado, nombrados por Qwen): la lista completa y
un filtro en el navegador por nombre o por sus palabras. Se elige una.
"""
function selector_meta(s, meta::AbstractString)
    tiene_metas(s.acervo) || return ""
    elegida = isempty(meta) ? "" : nombre_meta(s.acervo, meta)
    io = IOBuffer()
    print(io, """
    <div x-data="{ q: '', abierto: false, elegida: '$(esc(replace(elegida, "'" => "\\'")))',
                   coincide(el) { const t = sinAcentos(this.q.trim()); return !t || el.dataset.t.includes(t) } }" class="w-full">
      <button type="button" @click="abierto = !abierto; if (abierto) \$nextTick(() => \$refs.filtro.focus())" :aria-expanded="abierto"
              title="Grupos de palabras clave por significado, encontrados en el acervo y nombrados por un modelo de lenguaje. Un documento cae en uno o dos."
              class="inline-flex max-w-full items-center gap-2 rounded border border-borde bg-superficie px-2 py-1 text-left text-sm text-fuerte">
        <span class="text-tenue">Meta-disciplina</span><span class="truncate" x-text="elegida || 'todas'">$(isempty(elegida) ? "todas" : esc(elegida))</span>
        <span aria-hidden="true" class="text-tenue" x-text="abierto ? '▴' : '▾'">▾</span>
      </button>
      <a href="$(s.prefijo)/mapa" class="ml-2 text-xs $CLASE_LIGA">ver el mapa</a>
      <div x-show="abierto" x-cloak class="mt-2 rounded-lg border border-borde bg-superficie p-2">
        <input type="search" x-ref="filtro" x-model="q" placeholder="Filtra por nombre o por palabras: robótica, migración, maíz…" aria-label="Filtrar meta-disciplinas"
               class="w-full rounded border border-borde bg-fondo px-2 py-1 text-sm text-fuerte placeholder:text-tenue">
        <ul class="mt-2 max-h-72 space-y-0.5 overflow-y-auto text-sm">
          <li><label class="flex cursor-pointer items-baseline gap-2 rounded px-1 py-0.5 hover:bg-realce">
            <input type="radio" name="meta" value="" $(isempty(meta) ? "checked" : "") @change="elegida = ''; abierto = false" class="accent-liga">
            <span>todas</span></label></li>
    """)
    for g in s.acervo.metas
        nombre = string(g["nombre"])
        palabras = join(first(String.(g["palabras"]), 6), " · ")
        print(io, """
          <li x-show="coincide(\$el)" data-t="$(esc(sin_acentos(join([nombre, string(get(g, "nombre_en", "")), join(String.(g["palabras"]), " ")], " "))))">
            <label class="flex cursor-pointer items-baseline gap-2 rounded px-1 py-0.5 hover:bg-realce">
              <input type="radio" name="meta" value="$(esc(string(g["clave"])))" $(g["clave"] == meta ? "checked" : "")
                     @change="elegida = '$(esc(replace(nombre, "'" => "\\'")))'; abierto = false" class="accent-liga">
              <span><span class="text-fuerte">$(esc(nombre))</span>
                <span class="block text-xs text-tenue">$(miles(Int(g["documentos"]))) · $(esc(palabras))</span></span>
            </label>
          </li>
        """)
    end
    print(io, "        </ul>\n      </div>\n    </div>\n")
    String(take!(io))
end

"""
El selector de disciplina: se elige una sola, llegando a ella por su área y su campo (el árbol de la CTI). La
lista completa va en la página y un filtro en el navegador (Alpine) la acota por cualquier parte del camino,
sin importar acentos. La clasificación es la que declara cada repositorio (catálogos de SECIHTI).
"""
function selector_cti(s, cti::Union{Nothing,Pair{String,String}})
    isempty(s.acervo.disciplinas) && return ""
    elegida = cti !== nothing && first(cti) == "disciplina" ? last(cti) : ""
    io = IOBuffer()
    print(io, """
    <div x-data="{ q: '', abierto: false, elegida: '$(esc(bonito(elegida)))',
                   coincide(el) { const t = sinAcentos(this.q.trim()); return !t || el.dataset.t.includes(t) } }" class="w-full">
      <button type="button" @click="abierto = !abierto; if (abierto) \$nextTick(() => \$refs.filtro.focus())" :aria-expanded="abierto"
              title="La clasificación CTI (catálogos de SECIHTI) tal como la declara cada repositorio. Sólo una parte de los documentos la trae."
              class="inline-flex max-w-full items-center gap-2 rounded border border-borde bg-superficie px-2 py-1 text-left text-sm text-fuerte">
        <span class="text-tenue">Disciplina</span><span class="truncate" x-text="elegida || 'todas'">$(isempty(elegida) ? "todas" : esc(bonito(elegida)))</span>
        <span aria-hidden="true" class="text-tenue" x-text="abierto ? '▴' : '▾'">▾</span>
      </button>
      <div x-show="abierto" x-cloak class="mt-2 rounded-lg border border-borde bg-superficie p-2">
        <input type="search" x-ref="filtro" x-model="q" placeholder="Filtra por área, campo o disciplina" aria-label="Filtrar disciplinas"
               class="w-full rounded border border-borde bg-fondo px-2 py-1 text-sm text-fuerte placeholder:text-tenue">
        <ul class="mt-2 max-h-72 space-y-0.5 overflow-y-auto text-sm">
          <li><label class="flex cursor-pointer items-baseline gap-2 rounded px-1 py-0.5 hover:bg-realce">
            <input type="radio" name="cti" value="" $(isempty(elegida) ? "checked" : "") @change="elegida = ''; abierto = false" class="accent-liga">
            <span>todas</span></label></li>
    """)
    for d in s.acervo.disciplinas
        camino = join(filter(!isempty, [bonito(d.area), bonito(d.campo)]), " › ")
        print(io, """
          <li x-show="coincide(\$el)" data-t="$(esc(sin_acentos(join([d.area, d.campo, d.nombre], " "))))">
            <label class="flex cursor-pointer items-baseline gap-2 rounded px-1 py-0.5 hover:bg-realce">
              <input type="radio" name="cti" value="$(esc("disciplina:" * d.nombre))" $(d.nombre == elegida ? "checked" : "")
                     @change="elegida = '$(esc(replace(bonito(d.nombre), "'" => "\\'")))'; abierto = false" class="accent-liga">
              <span><span class="text-fuerte">$(esc(bonito(d.nombre)))</span>
                <span class="block text-xs text-tenue">$(esc(camino)) · $(miles(d.items))</span></span>
            </label>
          </li>
        """)
    end
    print(io, """
        </ul>
      </div>
    </div>
    """)
    String(take!(io))
end

function pagina(s, actual::Symbol, titulo::AbstractString, cuerpo::AbstractString; encabezado::AbstractString="",
                scripts::Vector{String}=String[], ancho::String="max-w-3xl")
    """
    <!doctype html>
    <html lang="es">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="referrer" content="no-referrer">
      <meta name="robots" content="noindex">
      <title>$(isempty(titulo) ? "" : esc(first(titulo, 60)) * " · ")$TITULO</title>
      <script>try { const t = localStorage.getItem('tema'); if (t) document.documentElement.dataset.tema = t; } catch (_) {}</script>
      <link rel="stylesheet" href="$(estatico(s, "estilo.css"))">
      <script defer src="$(estatico(s, "htmx.min.js"))"></script>
      <script defer src="$(estatico(s, "redaccion.js"))"></script>
      <script defer src="$(estatico(s, "alpine.min.js"))"></script>
      $(join(("""<script defer src="$(estatico(s, x))"></script>""" for x in scripts), "\n  "))
    </head>
    <body class="min-h-screen bg-fondo text-texto antialiased">
      $(barra(s, actual))
      <div class="mx-auto $ancho px-4 py-8 sm:py-10">
        $encabezado
        $cuerpo
        <footer class="mt-10 border-t border-borde pt-4 text-xs leading-relaxed text-tenue">
          Demo de investigación sobre los repositorios institucionales mexicanos que publican por OAI-PMH. Cada resultado
          lleva a su registro en el repositorio de origen; este sitio no comparte los documentos.$(s.gen === nothing ? "" :
          " La respuesta redactada es texto generado por un modelo y puede estar equivocada; para redactarla, la pregunta y los fragmentos encontrados se envían a un servicio externo.")
          Las conversaciones no se guardan: se pierden al cerrar la página o al reiniciarse el servicio.
        </footer>
      </div>
    </body>
    </html>
    """
end

con_htmx(req::HTTP.Request) = HTTP.header(req.headers, "HX-Request", "") == "true"
const CABECERAS_HTML = ["Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer", "X-Content-Type-Options" => "nosniff"]
fallo_html(msg, status) = Oxygen.html(aviso(msg); status, headers=CABECERAS_HTML)

# ---------------------------------------------------------------------------------------------------------
# Documentos: una conversación

lento(g::Generador) = "Este demo tiene recursos limitados: redacta $(g.a_la_vez == 1 ? "una respuesta" : "$(g.a_la_vez) respuestas") a la vez."

"El renglón donde se escribe la pregunta; se vuelve a mandar con cada paso (cuenta de preguntas, límite)."
function entrada(s, pasos::Int; oob::Bool=false)
    tope = s.convs.max_pasos
    attr = oob ? " hx-swap-oob=\"true\"" : ""
    pasos >= tope && return """
    <div id="entrada"$attr class="rounded-lg border border-borde bg-superficie px-4 py-3 text-sm text-texto">
      Esta conversación llegó al límite de $tope preguntas. <a href="$(s.prefijo)/" class="$CLASE_LIGA">Empezar una conversación nueva</a>
    </div>
    """
    sugerencia = pasos == 0 ? "Escribe una pregunta o un tema, por ejemplo: ¿qué se ha estudiado sobre la calidad del agua en acuíferos?" :
                 "Sigue la conversación: escribe la pregunta completa"
    """
    <div id="entrada"$attr>
      <div class="flex gap-2">
        <label for="q" class="sr-only">Pregunta</label>
        <input id="q" name="q" type="search" required maxlength="$MAX_CONSULTA" autocomplete="off" placeholder="$(esc(sugerencia))" class="$CLASE_CAMPO">
        <button type="submit" :disabled="ocupado" class="$CLASE_BOTON">$(pasos == 0 ? "Preguntar" : "Seguir")</button>
      </div>
      $(pasos == 0 ? "" : """<p class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-tenue">
        <span>Pregunta $(pasos + 1) de $tope. Cada pregunta se busca por separado; para redactar, el modelo también lee las preguntas y respuestas anteriores.</span>
        <span x-show="ocupado" x-cloak>Espera a que termine la respuesta para seguir.</span>
        <a href="$(s.prefijo)/" class="ml-auto $CLASE_LIGA">Conversación nueva</a>
      </p>""")
    </div>
    """
end

oculto(id, valor; oob::Bool=false) = """<input type="hidden" id="$id" name="$id" value="$(esc(valor))"$(oob ? " hx-swap-oob=\"true\"" : "")>"""

function formulario(s, c::Union{Nothing,Conversacion}, autor::Union{Nothing,Autor}; meta_inicial::AbstractString="")
    pasos = c === nothing ? Paso[] : c.pasos
    ultimo = isempty(pasos) ? nothing : last(pasos)
    modo = ultimo === nothing ? first(modos(s.acervo)) : ultimo.modo
    repo = ultimo === nothing ? "" : ultimo.repo
    cti = ultimo === nothing ? nothing : ultimo.cti
    meta = ultimo === nothing ? String(meta_inicial) : ultimo.meta
    io = IOBuffer()
    print(io, """
    <form action="$(s.prefijo)/buscar" method="get" hx-get="$(s.prefijo)/buscar" hx-target="#pasos" hx-swap="beforeend"
          hx-indicator="#espera" hx-disabled-elt="find button[type=submit]"
          x-data="{ ocupado: false }" @redactando.window="ocupado = \$event.detail" class="mt-6 space-y-4">
      $(oculto("conv", c === nothing ? "" : c.id))
      $(oculto("autor", autor === nothing ? "" : autor.id))
      $(entrada(s, length(pasos)))
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm">
        <span class="text-tenue">Cómo</span>
    """)
    for m in modos(s.acervo)
        print(io, """
            <label class="inline-flex cursor-pointer items-center gap-1.5" title="$(esc(AYUDA_MODO[m]))">
              <input type="radio" name="modo" value="$m" $(m == modo ? "checked" : "") class="accent-liga">
              <span>$(NOMBRE_MODO[m])</span>
            </label>
        """)
    end
    autor === nothing && print(io, """<span class="ml-auto flex flex-wrap gap-x-4 gap-y-2">$(selector_repo(s, repo))</span><span class="w-full">$(selector_meta(s, meta))</span><span class="w-full">$(selector_cti(s, cti))</span>""")
    tiene_denso(s.acervo) || print(io, """<span class="w-full text-xs text-tenue">La búsqueda por significado estará disponible cuando termine la codificación de los documentos.</span>""")
    print(io, """
      </div>
    </form>
    """)
    String(take!(io))
end

"Un documento de la pregunta `n`, el número `num` de la conversación: el ancla `p{n}f{num}` es a donde lleva la cita [num]."
function tarjeta(s, r::Resultado, n::Int, num::Int)
    medidas = String[]
    r.similitud === nothing || push!(medidas, "similitud " * string(round(r.similitud; digits=3)))
    r.bm25 === nothing || push!(medidas, "BM25 " * string(round(r.bm25; digits=1)))
    muestra = publico(r) || s.mostrar_texto
    cuerpo = muestra && r.seccion != "ficha" ? r.texto : r.resumen
    largo = length(cuerpo) > 420
    nota = muestra || r.seccion == "ficha" ? "" :
        """<p class="mt-2 text-xs italic text-tenue">Coincide en el $(get(NOMBRE_SECCION, r.seccion, r.seccion)), que el modelo leyó para redactar; el texto completo se consulta en el repositorio.</p>"""
    """
    <li>
      <article id="p$(n)f$num" data-cita="$num" x-data="{ abierto: false }" class="scroll-mt-4 rounded-xl border border-borde bg-superficie p-4 shadow-sm target:ring-2 target:ring-liga">
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-tenue">
          <span class="font-mono">$num</span>
          <span class="$CLASE_CHIP">$(esc(r.repo))</span>
          <span>$(esc(get(NOMBRE_SECCION, r.seccion, r.seccion)))</span>
          <span class="ml-auto font-mono tabular-nums">$(esc(join(medidas, " · ")))</span>
        </div>
        <h3 class="mt-2 font-medium leading-snug text-fuerte">$(esc(isempty(r.titulo) ? r.documento : r.titulo))</h3>
        $(isempty(r.cita) ? "" : "<p class=\"mt-0.5 text-xs text-tenue\">$(esc(r.cita))</p>")
        $(isempty(cuerpo) ? "" : """<p class="$(largo ? "line-clamp-4 " : "")mt-2 whitespace-pre-line text-sm leading-relaxed text-texto" $(largo ? ":class=\"{ 'line-clamp-4': !abierto }\"" : "")>$(esc(cuerpo))</p>""")
        $nota
        <div class="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-sm">
          $(largo ? "<button type=\"button\" @click=\"abierto = !abierto\" class=\"$CLASE_LIGA\" x-text=\"abierto ? 'Ver menos' : 'Ver más'\">Ver más</button>" : "")
          $(liga_segura(r.liga) ? "<a href=\"$(esc(r.liga))\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"text-liga underline underline-offset-4 hover:text-acento\">Ver el registro en el repositorio ↗</a>" : "")
        </div>
      </article>
    </li>
    """
end

"""
El recuadro de la respuesta del paso `n`. Con `hecha` el texto ya viene en la página y redaccion.js sólo le pone
las ligas a las citas; sin ella, abre el flujo de `/redaccion` y va poniendo el texto.
"""
function recuadro(s, conv::AbstractString, n::Int, base::Int, leidos::Int, hecha::Union{Nothing,Redaccion}; sugerencias=String[])
    de = leidos == 1 ? "el fragmento $(base + 1)" : "los fragmentos $(base + 1) a $(base + leidos)"
    url = hecha === nothing ? "$(s.prefijo)/redaccion?conv=$conv&amp;paso=$n" : ""
    """
    <section x-data="redaccion('$url', $(base + leidos))" data-lento="$(esc(lento(s.gen)))" data-sugerencias="$(esc(JSON.json(sugerencias)))" class="mt-3 rounded-xl border border-liga/30 bg-realce p-4">
      <h3 class="text-xs font-medium uppercase tracking-wide text-acento">Respuesta redactada por un modelo</h3>
      $(hecha !== nothing ? "" : """<p x-show="estado === 'espera'" class="mt-2 text-sm text-tenue" x-text="espera">Preparando la respuesta…</p>
      <p x-show="estado === 'leyendo'" x-cloak class="mt-2 text-sm text-tenue">El modelo está leyendo $de$(n > 1 ? " y la conversación" : "").</p>""")
      <div data-texto x-show="texto" $(hecha === nothing ? "x-cloak " : "")x-html="html" class="mt-2 whitespace-pre-line text-sm leading-relaxed text-fuerte">$(hecha === nothing ? "" : esc(hecha.texto))</div>
      <p x-show="estado === 'falla'" x-cloak class="mt-2 text-sm text-aviso-texto"><span x-text="aviso"></span>
        <button type="button" @click="reintenta()" class="ml-1 underline underline-offset-4">Intentar de nuevo</button></p>
      <div data-sugeridas x-show="sugerencias.length" x-cloak class="mt-4">
        <p class="text-xs font-medium uppercase tracking-wide text-tenue">Para seguir</p>
        <ul class="mt-2 space-y-2">
          <template x-for="q in sugerencias" :key="q">
            <li><button type="button" @click="pregunta(q)" x-text="q" class="rounded-lg border border-liga/30 bg-superficie px-3 py-2 text-left text-sm leading-snug text-liga shadow-sm hover:border-liga hover:text-acento"></button></li>
          </template>
        </ul>
        <p class="mt-2 text-xs leading-relaxed text-tenue">Preguntas propuestas por el modelo a partir de los mismos fragmentos; al elegir una se busca de nuevo.</p>
      </div>
      $(hecha !== nothing ? "" : """<noscript><p class="mt-2 text-sm text-tenue">La respuesta redactada necesita JavaScript; las fuentes de abajo no.</p></noscript>""")
      <p class="mt-3 text-xs leading-relaxed text-tenue">Texto generado por $(esc(s.gen.nombre)) con $de$(n > 1 ? " y las preguntas y respuestas anteriores" : ""); las citas llevan el número del documento en la lista de fuentes. Puede estar equivocado: verifícalo en las fuentes. <span x-show="nota" x-cloak x-text="nota"></span></p>
    </section>
    """
end

"Un paso de la conversación: la pregunta, la respuesta y sus fuentes plegables (abiertas sólo en el último)."
function paso_html(s, conv::AbstractString, n::Int, p::Paso; ultimo::Bool, base::Int)
    io = IOBuffer()
    print(io, """
    <section id="p$n" data-paso class="scroll-mt-4">
      <h2 class="flex items-baseline gap-3 border-b border-borde pb-2">
        <span class="shrink-0 font-mono text-xs font-medium uppercase tracking-wide text-tenue">Pregunta $n</span>
        <span class="text-lg font-medium leading-snug text-fuerte">$(esc(p.consulta))</span>
      </h2>
    """)
    if isempty(p.resultados)
        print(io, "<div class=\"mt-3\">", aviso("No hubo resultados para esa pregunta."), "</div>\n</section>\n")
        return String(take!(io))
    end
    if s.gen !== nothing
        leidos = min(length(p.resultados), s.gen.fragmentos)
        if p.respuesta !== nothing
            print(io, recuadro(s, conv, n, base, p.respuesta.leidos > 0 ? p.respuesta.leidos : leidos, p.respuesta;
                               sugerencias=ultimo && n < s.convs.max_pasos ? p.respuesta.sugerencias : String[]))
        elseif ultimo
            print(io, recuadro(s, conv, n, base, leidos, nothing))
        else
            print(io, """<p class="mt-3 text-sm text-tenue">Esta pregunta quedó sin respuesta redactada.</p>\n""")
        end
    end
    donde = p.autor !== nothing ? " · en la producción de $(esc(p.autor.nombre))" :
            string(isempty(p.meta) ? "" : " · meta-disciplina $(esc(nombre_meta(s.acervo, p.meta)))",
                   p.cti === nothing ? "" : " · $(esc(lowercase(Dict(NIVELES_CTI)[first(p.cti)]))) $(esc(bonito(last(p.cti)))) (declarada)",
                   isempty(p.repo) ? "" : " · en $(esc(p.repo))")
    tiempos = String[]
    haskey(p.ms, "codifica") && push!(tiempos, "codificar $(round(Int, p.ms["codifica"])) ms")
    haskey(p.ms, "busca") && push!(tiempos, "buscar $(round(Int, p.ms["busca"])) ms")
    print(io, """
      <details data-fuentes $(ultimo ? "open" : "") class="group mt-3">
        <summary class="cursor-pointer text-sm text-tenue hover:text-acento">
          <span class="font-medium text-acento">Fuentes de la pregunta $n</span>
          <span class="text-xs"> · $(length(p.resultados)) · $(esc(lowercase(NOMBRE_MODO[p.modo])))$donde$(isempty(tiempos) ? "" : " · " * join(tiempos, ", "))</span>
        </summary>
        <ol class="mt-3 space-y-3">
        $(join((tarjeta(s, x, n, base + i) for (i, x) in enumerate(p.resultados)), "\n"))
        </ol>
      </details>
    </section>
    """)
    String(take!(io))
end

function encabezado_documentos(s, autor::Union{Nothing,Autor})
    a = s.acervo
    total = a.documentos > 0 ? " $(miles(a.documentos)) documentos de $(length(a.repos)) repositorios." : " Documentos de $(length(a.repos)) repositorios."
    produccion = autor === nothing ? "" : """
      <p class="mt-3 rounded-lg border border-liga/30 bg-realce px-4 py-2 text-sm text-texto">Se busca sólo en la producción de
        <span class="font-medium text-acento">$(esc(autor.nombre))</span>: $(miles(length(autor.documentos))) $(length(autor.documentos) == 1 ? "documento" : "documentos").
        <a href="$(s.prefijo)/" class="ml-1 $CLASE_LIGA">Buscar en todo</a></p>"""
    """
    <header class="mb-6">
      <h1 class="text-2xl font-semibold tracking-tight text-acento sm:text-3xl"><a href="$(s.prefijo)/">Documentos</a></h1>
      <p class="mt-2 text-sm leading-relaxed text-texto">Tesis, artículos, libros y reportes de los repositorios institucionales mexicanos.$total$(s.gen === nothing ? "" :
        " Un modelo de lenguaje redacta una respuesta con lo encontrado y cita cada documento; se puede seguir preguntando, hasta $(s.convs.max_pasos) preguntas por conversación.")</p>
      $(s.gen === nothing ? "" : """<p class="mt-2 text-xs leading-relaxed text-tenue">$(lento(s.gen)) Si hay otras personas usándolo, la tuya espera su turno.</p>""")
      $produccion
    </header>
    """
end

function vista_documentos(s, c::Union{Nothing,Conversacion}, autor::Union{Nothing,Autor}, avisos::AbstractString=""; meta::AbstractString="")
    pasos = c === nothing ? Paso[] : c.pasos
    conv = c === nothing ? "" : c.id
    titulo = isempty(pasos) ? (autor === nothing ? "" : autor.nombre) : first(pasos).consulta
    cuerpo = """
    <main id="pasos" class="space-y-8">
    $(join((paso_html(s, conv, i, p; ultimo=i == length(pasos), base=antes(c, i)) for (i, p) in enumerate(pasos)), "\n"))
    </main>
    <div id="avisos" class="mt-4">$avisos</div>
    $(formulario(s, c, autor; meta_inicial=meta))
    <p id="espera" class="htmx-indicator mt-4 text-sm text-tenue">Buscando…</p>
    """
    pagina(s, :documentos, titulo, cuerpo; encabezado=encabezado_documentos(s, autor))
end

const SIN_CONVERSACION = "Esa conversación ya no está en la memoria del servidor (se pierden al reiniciarlo o cuando llevan mucho sin usarse)."
otra(s) = """<p role="alert" class="rounded-lg border border-aviso-borde bg-aviso-fondo px-4 py-3 text-sm text-aviso-texto">$(esc(SIN_CONVERSACION)) <a href="$(s.prefijo)/" class="underline underline-offset-4">Empezar una conversación nueva</a></p>"""

"La portada, una conversación viva (`?conv=`) o la portada dentro de la producción de un autor (`?autor=`)."
function pagina_inicio(req::HTTP.Request)
    s = SERVICIO[]
    d = Dict(pares(req))
    c, aviso_, status = nothing, "", 200
    if haskey(d, "conv")
        c = viva(s.convs, d["conv"])
        c === nothing && (aviso_ = otra(s))
    end
    au = c !== nothing && !isempty(c.pasos) ? last(c.pasos).autor : nothing
    if au === nothing && !isempty(get(d, "autor", ""))
        au = autor(s.acervo, d["autor"])
        au === nothing && ((aviso_, status) = (aviso("No se encontró ese autor."), 404))
    end
    meta = String(strip(get(d, "meta", "")))
    haskey(s.acervo.meta_docs, meta) || (meta = "")
    Oxygen.html(vista_documentos(s, c, au, aviso_; meta); status, headers=CABECERAS_HTML)
end

"""
Una pregunta: añade el paso a la conversación (`conv`) o a una nueva. Con htmx devuelve sólo el paso, más lo que
cambia fuera de él; sin htmx manda a la página de la conversación, para que recargarla no repita la pregunta.
"""
function pagina_buscar(req::HTTP.Request)
    s = SERVICIO[]
    htmx = con_htmx(req)
    msg, status = "", 200
    try
        p = peticion(req, s)
        c, n = paso_nuevo!(s, p)             # la redacción no empieza aquí: la pide la página al abrir el flujo
        donde = "$(s.prefijo)/?conv=$(c.id)"
        htmx || return HTTP.Response(303, ["Location" => donde * "#p$n", CABECERAS_HTML...])
        cuerpo = string(paso_html(s, c.id, n, c.pasos[n]; ultimo=true, base=antes(c, n)), entrada(s, n; oob=true), oculto("conv", c.id; oob=true),
                        """<div id="avisos" hx-swap-oob="true" class="mt-4"></div>""")
        return Oxygen.html(cuerpo; headers=[CABECERAS_HTML..., (isempty(p.conv) ? "HX-Push-Url" : "HX-Replace-Url") => donde])
    catch e
        if e isa ErrorPeticion
            msg, status = aviso(e.msg), 400
        elseif e isa ErrorCodificador
            msg, status = aviso("El codificador de consultas no está disponible. Prueba la búsqueda por palabras."), 503
        elseif e isa LimiteDePasos
            msg, status = aviso("Esta conversación llegó al límite de $(e.max) preguntas; empieza una nueva."), 409
        elseif e isa SinConversacion
            msg, status = otra(s), 404
        else
            rethrow()
        end
    end
    # htmx no cambia la página con respuestas 4xx o 5xx: los avisos van con 200 y a su lugar
    htmx ? Oxygen.html(msg; headers=[CABECERAS_HTML..., "HX-Retarget" => "#avisos", "HX-Reswap" => "innerHTML"]) :
           Oxygen.html(vista_documentos(s, nothing, nothing, msg); status, headers=CABECERAS_HTML)
end

# ---------------------------------------------------------------------------------------------------------
# Autores y referencias: un formulario y una lista

function forma_lista(s, ruta, q, repo, ejemplo, boton)
    """
    <form action="$(s.prefijo)$ruta" method="get" class="space-y-3">
      <div class="flex gap-2">
        <label for="q" class="sr-only">Consulta</label>
        <input id="q" name="q" type="search" required maxlength="$MAX_CONSULTA" autocomplete="off" value="$(esc(q))" placeholder="$(esc(ejemplo))" class="$CLASE_CAMPO">
        <button type="submit" class="$CLASE_BOTON">$boton</button>
      </div>
      <div class="text-sm">$(selector_repo(s, repo))</div>
    </form>
    """
end

function lista_de(req, s)
    d = Dict(pares(req))
    q = String(strip(get(d, "q", "")))
    repo = String(strip(get(d, "repo", "")))
    (isempty(repo) || repo in s.acervo.repos) || (repo = "")
    first(q, MAX_CONSULTA), repo
end

chips(xs; n=8) = join(("""<span class="$CLASE_CHIP">$(esc(string(x)))</span>""" for x in first(xs, n)), " ")

function pagina_autores(req::HTTP.Request)
    s = SERVICIO[]
    q, repo = lista_de(req, s)
    io = IOBuffer()
    print(io, forma_lista(s, "/autores", q, repo, "Nombre de una persona, por ejemplo: Téllez Eric", "Buscar"))
    if !isempty(q)
        autores, ms = Base.acquire(() -> busca_autores(s.acervo, q; repo, k=20), s.cupo)
        print(io, """<p class="mt-6 text-xs text-tenue">$(length(autores)) perfiles · BM25 sobre los nombres · $(round(Int, ms)) ms</p><ol class="mt-3 space-y-3">""")
        isempty(autores) && print(io, "<li>", aviso("No hay perfiles con ese nombre."), "</li>")
        for a in autores
            n = Int(get(a, "doc_count", 0))
            print(io, """
            <li class="rounded-xl border border-borde bg-superficie p-4 shadow-sm">
              <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                <h3 class="font-medium text-fuerte">$(esc(string(a["name"])))</h3>
                <span class="text-xs text-tenue">$(miles(n)) $(n == 1 ? "documento" : "documentos") · $(esc(string(get(a, "role", ""))))</span>
                <span class="ml-auto font-mono text-xs text-tenue">BM25 $(round(a["score"]; digits=1))</span>
              </div>
              <p class="mt-2 flex flex-wrap gap-1 text-xs">$(chips(a["repos"]))</p>
              $(isempty(a["keywords"]) ? "" : """<p class="mt-2 text-xs leading-relaxed text-texto"><span class="text-tenue">Temas:</span> $(esc(join(first(a["keywords"], 10), " · ")))</p>""")
              $(isempty(a["coauthors"]) ? "" : """<p class="mt-1 text-xs leading-relaxed text-texto"><span class="text-tenue">Coautores:</span> $(esc(join(first(a["coauthors"], 8), " · ")))</p>""")
              <p class="mt-3 text-sm"><a href="$(s.prefijo)/?$(qs("autor" => a["consolidated_id"]))" class="$CLASE_LIGA">Buscar en su producción</a></p>
            </li>
            """)
        end
        print(io, "</ol>")
    end
    encabezado = """
    <header class="mb-6">
      <h1 class="text-2xl font-semibold tracking-tight text-acento sm:text-3xl"><a href="$(s.prefijo)/autores">Autores</a></h1>
      <p class="mt-2 text-sm leading-relaxed text-texto">Perfiles de autores y asesores, con las variantes de cada nombre reunidas. Se busca por nombre, sin mezclar con los documentos; desde un perfil se puede preguntar dentro de su producción.</p>
    </header>
    """
    Oxygen.html(pagina(s, :autores, q, String(take!(io)); encabezado); headers=CABECERAS_HTML)
end

function pagina_referencias(req::HTTP.Request)
    s = SERVICIO[]
    q, repo = lista_de(req, s)
    io = IOBuffer()
    print(io, forma_lista(s, "/referencias", q, repo, "Autor, título o tema de una obra citada, por ejemplo: Breiman random forests", "Buscar"))
    if !isempty(q)
        docs, ms = Base.acquire(() -> busca_referencias(s.acervo, q; repo, k=20), s.cupo)
        print(io, """<p class="mt-6 text-xs text-tenue">$(length(docs)) documentos · BM25 sobre su bibliografía · $(round(Int, ms)) ms</p><ol class="mt-3 space-y-3">""")
        isempty(docs) && print(io, "<li>", aviso("Ningún documento cita algo así."), "</li>")
        for d in docs
            print(io, """
            <li class="rounded-xl border border-borde bg-superficie p-4 shadow-sm">
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-tenue">
                <span class="$CLASE_CHIP">$(esc(first(split(d.documento, ':'))))</span>
                <span>$(miles(d.total)) referencias</span>
                <span class="ml-auto font-mono">BM25 $(round(d.bm25; digits=1))</span>
              </div>
              <h3 class="mt-2 font-medium leading-snug text-fuerte">$(esc(isempty(d.titulo) ? d.documento : d.titulo))</h3>
              $(isempty(d.cita) ? "" : "<p class=\"mt-0.5 text-xs text-tenue\">$(esc(d.cita))</p>")
              $(isempty(d.coinciden) ? "" : """<ul class="mt-3 space-y-1.5 border-l-2 border-liga/30 pl-3 text-sm leading-snug text-texto">$(join(("<li>$(esc(first(r, 400)))</li>" for r in d.coinciden), ""))</ul>""")
              $(liga_segura(d.liga) ? """<p class="mt-3 text-sm"><a href="$(esc(d.liga))" target="_blank" rel="noopener noreferrer" class="text-liga underline underline-offset-4 hover:text-acento">Ver el registro en el repositorio ↗</a></p>""" : "")
            </li>
            """)
        end
        print(io, "</ol>")
    end
    encabezado = """
    <header class="mb-6">
      <h1 class="text-2xl font-semibold tracking-tight text-acento sm:text-3xl"><a href="$(s.prefijo)/referencias">Referencias</a></h1>
      <p class="mt-2 text-sm leading-relaxed text-texto">Documentos que citan una obra: se busca en la bibliografía extraída de cada texto completo y se muestran las referencias que coinciden.</p>
    </header>
    """
    Oxygen.html(pagina(s, :referencias, q, String(take!(io)); encabezado); headers=CABECERAS_HTML)
end

# ---------------------------------------------------------------------------------------------------------
# El mapa de las meta-disciplinas: el grafo (estaticos/mapa.js, D3 sobre canvas) para verlas y navegar.

function pagina_mapa(req::HTTP.Request)
    s = SERVICIO[]
    tiene_metas(s.acervo) || return Oxygen.html(pagina(s, :mapa, "Mapa", aviso("Este servidor no tiene meta-disciplinas.")); status=404, headers=CABECERAS_HTML)
    encabezado = """
    <header class="mb-4">
      <h1 class="text-2xl font-semibold tracking-tight text-acento sm:text-3xl">Mapa de meta-disciplinas</h1>
      <p class="mt-2 text-sm leading-relaxed text-texto">Grupos de palabras clave que el acervo usa para lo mismo, en español o en inglés, encontrados
        por el significado de los documentos y nombrados por un modelo de lenguaje. El tamaño es el número de documentos; una línea une a las
        que se parecen o comparten documentos. Rueda para acercar, arrastra para moverte, clic para ver una y buscar dentro de ella.</p>
    </header>
    """
    cuerpo = """
    <div class="lg:grid lg:grid-cols-[minmax(0,1fr)_20rem] lg:gap-6" data-prefijo="$(s.prefijo)" id="mapa-raiz">
      <div class="relative">
        <input type="search" id="mapa-filtro" placeholder="Resalta por nombre o palabra: robótica, agua, poesía…" aria-label="Resaltar meta-disciplinas"
               class="mb-2 $CLASE_CAMPO">
        <canvas id="mapa" class="h-[70vh] w-full rounded-xl border border-borde bg-superficie" aria-label="Grafo de meta-disciplinas"></canvas>
        <p id="mapa-punta" class="pointer-events-none absolute hidden rounded bg-barra px-2 py-1 text-xs text-sobre-barra"></p>
      </div>
      <aside id="mapa-panel" class="mt-4 rounded-xl border border-borde bg-superficie p-4 text-sm lg:mt-0">
        <p class="text-tenue">Elige una meta-disciplina en el mapa para ver de qué trata, sus vecinas y buscar dentro de ella.</p>
      </aside>
    </div>
    <noscript>$(aviso("El mapa necesita JavaScript; las meta-disciplinas también se eligen en Documentos."))</noscript>
    """
    Oxygen.html(pagina(s, :mapa, "Mapa", cuerpo; encabezado, scripts=["d3.min.js", "mapa.js"], ancho="max-w-6xl"); headers=CABECERAS_HTML)
end

# ---------------------------------------------------------------------------------------------------------
# El flujo de la respuesta redactada de un paso (eventos enviados por el servidor), el de AmbientalWeb:
#   espera, leyendo, saturado, texto, fin {nota, citados, sugerencias}, falla; «:» son latidos.

evento(nombre, dato) = string("event: ", nombre, "\ndata: ", JSON.json(dato), "\n\n")

function flujo_redaccion(stream::HTTP.Stream)
    s = SERVICIO[]
    HTTP.setheader(stream, "Content-Type" => "text/event-stream; charset=utf-8")
    HTTP.setheader(stream, "Cache-Control" => "no-store")
    HTTP.setheader(stream, "X-Accel-Buffering" => "no")
    HTTP.startwrite(stream)
    function manda(texto)
        try
            write(stream, texto)
        catch
            throw(ClienteAusente())
        end
        nothing
    end
    t0 = time()
    try
        g = s.gen
        d = Dict(pares(stream.message))
        c = g === nothing ? nothing : viva(s.convs, get(d, "conv", ""))
        n = something(tryparse(Int, get(d, "paso", "")), 0)
        if c === nothing || !(1 <= n <= length(c.pasos)) || isempty(c.pasos[n].resultados)
            manda(evento("falla", "Esta conversación ya no está en la memoria del servidor; empieza una nueva."))
        elseif c.pasos[n].respuesta !== nothing                  # ya estaba redactada (se recargó la página)
            manda(evento("texto", c.pasos[n].respuesta.texto))
            manda(evento("fin", Dict("nota" => "", "citados" => c.pasos[n].respuesta.citados,
                                     "sugerencias" => n < s.convs.max_pasos ? c.pasos[n].respuesta.sugerencias : String[])))
        else
            p = c.pasos[n]
            r = redacta(g, p.consulta, p.resultados; base=antes(c, n), historia=historia(s.convs, c, n),
                        proponer=n < s.convs.max_pasos,
                        al_llegar=x -> manda(evento("texto", x)),
                        al_estado=(e, k) -> manda(e === :latido ? ": latido\n\n" : evento(String(e), k)))
            fija!(s.convs, p, r)
            anota(r, time() - t0, n)
            manda(evento("fin", Dict("nota" => r.de_memoria ? "" : "Redactada en $(round(Int, time() - t0)) s.",
                                     "citados" => r.citados, "sugerencias" => r.sugerencias)))
        end
    catch e
        if e isa ClienteAusente
            bitacora("redacta cancelada: el visitante se fue a los ", round(Int, time() - t0), " s")
        else
            e isa GeneradorOcupado && bitacora("redacta rechazada: la fila está llena (", s.gen.max_fila, ")")
            msg = e isa GeneradorOcupado ? "$(lento(s.gen)) En este momento hay demasiadas en fila. Las fuentes de abajo son el resultado de tu búsqueda; espera un par de minutos y vuelve a intentarlo." :
                  "El modelo que redacta no está disponible en este momento. Las fuentes de abajo son el resultado de tu búsqueda."
            (e isa GeneradorOcupado || e isa ErrorGenerador) || @error "error al redactar" exception = (e, catch_backtrace())
            e isa ErrorGenerador && @warn "generador" motivo = e.msg
            try
                manda(evento("falla", msg))
            catch
            end
        end
    end
    flush(stdout)
    HTTP.Response(200)        # sin cuerpo: Oxygen escribiría «null» al final del flujo si se devuelve `nothing`
end
