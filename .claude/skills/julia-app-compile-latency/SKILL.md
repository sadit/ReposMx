---
name: julia-app-compile-latency
description: Diagnóstico y arreglo de arranque lento en CLIs/apps de Julia (julia -m Module, Pkg.Apps, @main) — separar los tres costos (precompilación de paquetes en cada arranque, carga de paquetes, compilación de métodos), compilación anticipada de ramas nunca ejecutadas, deserialización genérica (JLD2), manifiestos de app que quedan obsoletos con dependencias dev, y las herramientas (--trace-compile + --trace-compile-timing, Base.invokelatest, despacho por Dict, PrecompileTools, juliac/--trim) para diagnosticarlo y evitarlo. Úsala para cualquier app/CLI de Julia con arranque lento, no solo este repo.
---

# Latencia de arranque en apps/CLIs de Julia

Destilado de dos casos reales medidos: `reposmx --help` tardaba ~40s en imprimir texto estático
(compilación anticipada), y `textsearch --help` tardaba ~31s (precompilación de paquetes fallida
en cada invocación). **Son causas distintas con el mismo síntoma**, y confundirlas hace perder
horas — por eso §0 va antes que nada.

## Estado verificado

Medido el **2026-09-09** con **Julia 1.12.7** (juliaup), shims de `Pkg.Apps` versión 1.3:

| medición | resultado |
|---|---|
| piso absoluto: `julia --startup-file=no -e ''` | **0.18s** |
| `reposmx --help` (con `invokelatest`, §3) | **3.3s**, reproducible en frío y en tibio |
| `textsearch --help` (manifiesto de app obsoleto, §6) | **31-34s**, reproducible, y termina en error |

El caso histórico de ReposMx (40s → 3.9s) se midió en una versión anterior de Julia; los 3.3s de
hoy confirman que el arreglo sigue en pie tras subir a 1.12.

---

## 0. Primero separa los tres costos: no todos son "compilación"

Un arranque lento de un CLI de Julia puede venir de tres lugares completamente distintos. **Antes
de instrumentar nada, averigua en cuál estás** — la herramienta y el arreglo son distintos en cada
uno.

| # | costo | cómo se ve | herramienta |
|---|---|---|---|
| 1 | **Precompilación de paquetes al arrancar** | el stderr empieza con `Precompiling packages...`; puede tardar decenas de segundos y **repetirse en cada invocación** si falla | mirar el stderr sin redirigir; §6 |
| 2 | **Carga de paquetes** (`using X`) | tiempo constante, mismo en todas las invocaciones, incompresible sin cambiar dependencias | `@time using X`; §5 opción 3 |
| 3 | **Compilación de métodos en ejecución** | el trabajo trivial (`--help`) tarda tanto como el trabajo real | `--trace-compile` + `--trace-compile-timing`; §1-§4 |

Empieza siempre estableciendo **el piso**: `time julia --startup-file=no -e ''` (aquí: 0.18s). Todo
lo que esté por encima de eso hay que explicarlo con uno de los tres.

**Corre el CLI una vez sin redirigir stderr.** Suena obvio y es justo lo que se salta uno cuando
mide con `time cmd > /dev/null 2>&1`: si el problema es (1), el mensaje `Precompiling packages...`
lo dice literalmente, y ninguna cantidad de `--trace-compile` lo va a mostrar como tiempo de
compilación — la precompilación ocurre en un **proceso hijo aparte**.

## 1. El hecho central del costo (3): un método se compila entero

Julia compila un **método completo** la primera vez que ese método se ejecuta — el cuerpo entero,
no solo la rama que corre en esa llamada particular. Si tienes:

```julia
function main_cli(args)
    cmd = args[1]
    if cmd == "serve"
        start_server(...)      # toca HTTP.jl entero
    elseif cmd == "build"
        build_search_index(...) # toca tu pipeline de indexado entero
    elseif cmd == "search"
        SearchEngine(...)       # toca tu backend de búsqueda entero
    # ... 12 ramas más
    end
end
```

la primera vez que `main_cli` se compila (que en un proceso de Julia nuevo es **siempre**, nada de
esto se cachea entre invocaciones a menos que hagas algo al respecto — ver §5), el compilador
infiere y genera código para las ~15 ramas, no solo la que se va a ejecutar. Un CLI que solo hace
`reposmx --help` paga el costo completo de compilar `start_server`, `build_search_index`,
`SearchEngine`, etc., aunque el flujo de ejecución real nunca los toque.

Esto es distinto de "cargar paquetes es lento" (costo 2) — es un costo aparte, que ocurre después
de que los paquetes ya cargaron, la primera vez que tu propio código de despacho se ejecuta.

**No solo aplica a despachadores de subcomandos.** El mismo patrón muerde en **una closure
capturada dentro de un callback**: en ReposMx, `process_shell_input` (~20 ramas hacia Search.jl /
DB.jl / Wikipedia.jl) vive dentro de `launch_interactive_shell` como el `on_done` que se pasa a
`REPL.LineEdit.Prompt`. Compilar esa closure para *abrir* el shell costaba **22.15s** medidos, sin
que el usuario hubiera tecleado un solo comando. Si tu app tiene un bucle REPL, un router HTTP o
cualquier tabla de handlers dentro de una closure, es el mismo problema con otra cara.

## 2. Diagnóstico: no adivines, mide

### 2.1 `--trace-compile-timing` NO funciona solo

**Corrección respecto a versiones anteriores de esta guía, verificada empíricamente en 1.12.7:**
`--trace-compile-timing` solo agrega los tiempos a una traza que **ya esté encendida**. Pasado
solo, no imprime absolutamente nada (silencio total, que es fácil confundir con "no se compiló
nada"). La invocación correcta lleva las dos banderas:

```bash
julia --project=. --trace-compile=stderr --trace-compile-timing -m TuApp algunsubcomando 2> trace.log
```

Del `julia --help-hidden`: *"--trace-compile-timing: If --trace-compile is enabled show how long
each took to compile in ms"*. En 1.12, además, los métodos **recompilados** (por invalidación)
salen en amarillo o con un comentario al final de la línea — útil para distinguir "esto se compiló"
de "esto se tuvo que volver a compilar porque algo lo invalidó".

Cada línea es una especialización con su tiempo:

```
#=    7.9 ms =# precompile(Tuple{EzXML.var"##parse_options#7", ...})
...
#= 37040.3 ms =# precompile(Tuple{typeof(ReposMx.main), Array{String, 1}})
```

Caso real: 218 especializaciones compiladas, 217 de ellas sumaban menos de 1s combinadas, y
**una sola** (`ReposMx.main`, el despachador de subcomandos) se llevó 37.0 de los ~40s totales.
Eso te dice exactamente dónde mirar — no hace falta perfilar nada más fino en la mayoría de los
casos.

Para ordenar la traza por costo:

```bash
sed 's/^#=\s*\([0-9.]*\) ms =#/\1\t/' trace.log | sort -rn | head -15
sed -n 's/^#=\s*\([0-9.]*\) ms =#.*/\1/p' trace.log | awk '{s+=$1} END {print s" ms en "NR" especializaciones"}'
```

Ese total es la comprobación que cierra el diagnóstico: **si la suma de la traza no explica el
tiempo de pared, el costo no es compilación de métodos** — vuelve a §0 y busca en (1) o (2).

### 2.2 Cómo pasarle banderas de Julia a un app instalado

El shim de `Pkg.Apps` reparte los argumentos con `--`: lo que va **antes** es para Julia, lo que va
**después** es para tu app. Esto es lo que permite trazar un app instalado tal como el usuario lo
ejecuta, sin reconstruir el entorno a mano (que además puede resolver distinto y darte otro
problema):

```bash
textsearch --trace-compile=stderr --trace-compile-timing -- --help 2> trace.log
```

### 2.3 La verificación barata, antes de instrumentar

Comparar el tiempo de invocar la función "hoja" directamente
(`julia -e 'using TuApp; TuApp.algo_barato()'`) contra invocar el CLI completo con el mismo trabajo
real (`julia -m TuApp algunsubcomando`). Si la primera es rápida y la segunda no, el costo está en
el despachador, no en la función que hace el trabajo — así se confirmó el caso de ReposMx antes de
instrumentar nada.

## 3. El arreglo de bajo esfuerzo: romper la cascada de inferencia

Lo que hay que lograr es que la llamada al handler sea **dinámica**, para que compilar el
despachador no arrastre transitivamente la compilación de cada rama. Hay dos formas, y ambas
funcionan por la misma razón.

### 3.1 `Base.invokelatest` por rama

```julia
if cmd == "serve"
    Base.invokelatest(start_server; port, host)
elseif cmd == "build"
    Base.invokelatest(build_search_index; repos=target_repos)
elseif cmd == "search"
    Base.invokelatest(search_cli, q; top)
end
```

Llama a `f` en la última "edad del mundo" (world age) de la tabla de métodos, en vez de
resolverla/inferirla estáticamente en el sitio de la llamada. El costo de compilación de cada rama
se sigue pagando, pero **solo si esa rama se ejecuta**, y en el momento en que se ejecuta.

Resultado medido en ReposMx: `--help` con caché tibia, 40s → 3.9s; re-verificado en Julia 1.12.7,
**3.3s**, contra un piso de 0.18s (el resto es carga de paquetes, costo 2).

### 3.2 Tabla de despacho `Dict{String,Function}`

El patrón que usa hoy el app `textsearch` de TextSearch.jl, y que suele quedar más limpio que
salpicar 15 `invokelatest`:

```julia
const SUBCOMMANDS = Dict(
    "fit" => cmd_fit, "merge" => cmd_merge, "search" => cmd_search, ...
)

function (@main)(args::Vector{String}=ARGS)
    fn = get(SUBCOMMANDS, args[1], nothing)
    fn === nothing && return 1
    result = fn(args[2:end])
    result isa Integer ? result : 0
end
```

**Por qué funciona, y la condición que hay que respetar**: con handlers de tipos distintos, el
`Dict` se promueve a `Dict{String,Function}` — y `Function` es abstracto, así que el compilador no
puede desvirtualizar `fn(...)` y emite una llamada dinámica. Es el mismo efecto que
`invokelatest`. **Si por casualidad todos los valores fueran del mismo tipo concreto, el
tipo del `Dict` se estrecharía y el beneficio podría desaparecer** — si dependes de esto, anótalo
con `const SUBCOMMANDS = Dict{String,Function}(...)` explícito en vez de dejarlo a la inferencia.

### 3.3 Qué NO arregla esto

Partir el despachador en funciones más chicas (`cmd_serve()`, `cmd_build()`, ...) **sin** hacer la
llamada dinámica no ayuda: si se siguen llamando estáticamente, Julia igual las infiere
transitivamente al compilar el despachador. Lo que rompe la cascada es la llamada dinámica, no la
separación en sí.

**Costo:** overhead de despacho dinámico en cada llamada — insignificante para un punto de entrada
que se ejecuta una vez por proceso. No lo uses en un hot loop interno.

**Tensión a tener presente:** esta misma dinamicidad es lo que `juliac --trim` **no puede
analizar** (§5, opción 4). `--trim` incluye solo código *demostrablemente alcanzable* desde los
entrypoints, y una llamada por `invokelatest` o por un `Dict{String,Function}` es precisamente lo
que no se puede demostrar. Si el plan a mediano plazo es compilar un binario recortado, sabe que
estos dos arreglos apuntan en direcciones opuestas y que habrá que reintroducir el despacho
estático (o marcar cada handler como entrypoint) en ese momento.

## 4. Otra fuente del mismo síntoma: deserialización genérica

Un problema relacionado pero distinto: la primera llamada a `JLD2.load` (o cualquier librería que
reconstruya tipos genéricos en tiempo de ejecución a partir de metadata serializada) puede costar
varios segundos de compilación **la primera vez en el proceso**, sin importar qué tan chico sea el
archivo — porque compila la maquinaria genérica de reconstrucción de tipos, no porque lea muchos
bytes. Medido: cargar un `.jld2` de 249KB costó **8.44s (98.66% compilación)**. Reemplazar ese
punto por algo con forma de dato plano (JSON3, o cualquier formato que solo necesite tipos
concretos conocidos de antemano) bajó eso a 0.9s — no por el tamaño del archivo, sino porque el
código a compilar es mucho menor y **además comparte especializaciones ya calientes con otras
partes cercanas del mismo proceso**.

Ese "además" es la parte que se suele pasar por alto y es la que cambia la decisión: el criterio no
es solo bytes y segundos de I/O, es **"¿estoy introduciendo una segunda maquinaria de
deserialización cuyo JIT nadie más amortiza?"**. Si el resto del proceso ya carga JSON3, el
formato marginalmente más eficiente que trae su propia maquinaria puede salir más caro en total.
(Caso completo con benchmarks en el skill `search-index-engineering`, §10.2.)

Regla práctica: si un solo punto de tu código usa una librería de serialización genérica (JLD2.jl,
la stdlib `Serialization` con tipos complejos, etc.) y todo lo demás usa formatos con forma de dato
plano, ese punto probablemente sea un pico aislado de tiempo de compilación — sospecha de él
primero.

## 5. Por qué esto se paga en *cada* invocación (y qué hacer al respecto)

Un shim generado por `Pkg.Apps.develop`/`Pkg.Apps.add` (el que queda en `~/.julia/bin/`) **no es un
binario precompilado** — es un script `/bin/sh` que ejecuta `julia -m TuApp` cada vez. Verificado en
la versión de shim 1.3 (Julia 1.12.7): el script fija `JULIA_DEPOT_PATH` y `JULIA_LOAD_PATH`,
reparte los argumentos alrededor de `--`, y termina en un `exec julia ... -m TuApp "$@"`. **Revísalo
antes de asumir cualquier cosa** (`cat ~/.julia/bin/tuapp`): es fácil pensar que "instalar como
Julia App" significa "compilar una vez", y no es así por defecto.

Esa lectura del shim además te dice dos cosas que vas a necesitar:

- **Qué `Manifest.toml` manda**: el `JULIA_LOAD_PATH` que fija. Puede apuntar al directorio del
  proyecto que desarrollaste (`reposmx` → `~/Projects/Repositorios-Institucionales/`) o al
  subproyecto del app (`textsearch` → `~/Research/TextSearch.jl/apps/textsearch`). Ese es el
  entorno que tiene que estar resuelto — ver §6.
- **Con qué `julia` corre**: el shim clava la ruta absoluta del binario de juliaup vigente al
  instalar. Cambiar de versión con `juliaup` **no** actualiza los shims ya instalados; hay que
  reinstalar el app (o exportar `JULIA_APPS_JULIA_CMD`).

Opciones para bajar lo que queda, de menor a mayor esfuerzo:

1. **Llamada dinámica (§3)** — evita compilar ramas que NO se ejecutan. No reduce el costo de la
   rama que sí se ejecuta.
2. **`PrecompileTools.jl`** (`@compile_workload` dentro del módulo) — ejecuta las rutas
   representativas durante la *precompilación del paquete* (una vez, al instalar/actualizar),
   guardando esas especializaciones en `~/.julia/compiled/`. No reduce el trabajo total de
   compilación: lo mueve de "cada arranque" a "cada instalación". Es el siguiente paso natural
   después de §3 si el costo de la rama que sí se usa siempre (p. ej. abrir el shell interactivo)
   sigue siendo notorio.
3. **Separar módulos/entrypoints por responsabilidad.** El patrón concreto, tal como lo hace
   TextSearch.jl: el CLI vive en un **subproyecto aparte** (`apps/textsearch/`) con su propio
   `Project.toml`, su propio uuid, su propio `[apps.<nombre>]`, y
   `[sources] TextSearch = {path = "../.."}`. Las dependencias que solo el CLI necesita (ArgParse,
   CSV, Parquet2, Tables) quedan fuera de la librería, que nunca las carga. Esto sí baja el techo
   de `using` para quien usa la librería como librería — pero ojo: **no baja el arranque del CLI**,
   que sigue cargando todo. Y agrega un `Manifest.toml` más que mantener resuelto (§6).
   Separar solo los ejecutables sin separar los módulos no cambia nada.
4. **`juliac` / `--trim`** — en Julia 1.12 ya no es hipotético: `juliac` se instala como un app más
   (`~/.julia/bin/juliac`, que corre `-m JuliaC`). Banderas reales:
   `--output-exe <n>` / `--output-lib` / `--output-sysimage` / `--output-o` / `--output-bc`,
   `--project <path>`, `--bundle <dir>` (empaqueta libjulia, stdlibs y artifacts),
   `--trim[=safe|unsafe|unsafe-warn]`, `--compile-ccallable`, `--experimental` (**requerido para
   `--trim`**). Ejemplo de su propia ayuda:

   ```bash
   juliac --output-exe app ./MyApp.jl --bundle build --trim=safe
   ```

   `--trim` construye una sysimage con **solo el código demostrablemente alcanzable desde los
   métodos marcados con `Base.Experimental.entrypoint`** (`@main` cuenta como uno). De ahí la
   tensión de §3.3: todo el despacho dinámico que agregaste para diferir compilación es
   exactamente lo que el análisis de alcanzabilidad no puede seguir. Sigue siendo experimental —
   trátalo como un paso de build/CI a evaluar, no como el default.

## 6. El costo (1): precompilación de paquetes reintentada en cada arranque

Sección nueva, y **el caso más caro que se ha medido en estos repos** — más que el despachador de
40s, y con un arreglo trivial una vez que se sabe qué es.

### 6.1 El síntoma y el diagnóstico

`textsearch --help` tardaba **31-34s**, reproducible, en frío y en tibio. Trazándolo por el shim:

```bash
textsearch --trace-compile=stderr --trace-compile-timing -- --help 2> trace.log
```

la traza sumaba **530 ms en 25 especializaciones**. Es decir: la compilación de métodos explicaba
medio segundo de treinta. **La suma de la traza contra el tiempo de pared es lo que cierra el
diagnóstico** (§2.1). Lo que sí aparecía, sin ser tiempo de compilación:

```
Precompiling packages...
              ✗ SimilaritySearch
              ✗ TextSearch
#= 28.4 ms =# precompile(Tuple{Base.Precompilation.var"##precompilepkgs#9", ...})
```

Julia intentaba **precompilar el entorno del app en cada invocación**, fallaba, y seguía adelante
(o moría). El trabajo real ocurre en un **proceso hijo**, así que no aparece como tiempo de
compilación en ninguna traza — solo como tiempo de pared que nada explica.

### 6.2 La causa raíz: manifiesto de app obsoleto contra una dependencia `dev`

El error de fondo:

```
ERROR: LoadError: ArgumentError: Package SimilaritySearch does not have MultivariateStats
in its dependencies
```

`apps/textsearch/Manifest.toml` tenía registrado `SimilaritySearch` en **versión 1.2.0** con su
lista de dependencias de entonces, apuntando por `path` a un checkout que hoy es **1.4.1** y que
adquirió `MultivariateStats` (para PCA en `src/proj/Projections.jl`). El manifiesto quedó
describiendo un paquete que ya no existe con esa forma.

**Por qué esto es una trampa recurrente y no un accidente**: una dependencia por `path`/`[sources]`
o `Pkg.develop` cambia bajo los pies del manifiesto **sin bump de versión** que dispare una
re-resolución. Un app instalado con `Pkg.Apps` fija su `JULIA_LOAD_PATH` a ese proyecto, así que
el manifiesto obsoleto se usa **en cada invocación desde cualquier directorio**, aunque el
desarrollo diario ocurra en otro entorno que sí está resuelto. Nadie lo nota hasta que el CLI
tarda medio minuto.

### 6.3 Reglas prácticas

- **Corre el CLI una vez sin redirigir stderr** antes de medir nada. `Precompiling packages...` en
  la primera línea es el diagnóstico completo.
- **Si el CLI sale con código distinto de 0, eso es el bug** — no lo trates como un problema de
  latencia. Medir con `> /dev/null 2>&1` esconde exactamente esto.
- **Cada subproyecto de app es un `Manifest.toml` más que mantener resuelto.** Si el proyecto usa
  dependencias `dev`/`[sources]`, `Pkg.resolve()`/`Pkg.instantiate()` en el entorno del app
  después de cada cambio estructural de la dependencia (dep nueva, extensión nueva) — o
  reinstalar el app.
- Cuando una dependencia `dev` gana una dependencia nueva, **todos** los entornos que la consumen
  por `path` quedan obsoletos a la vez, no solo el que estabas usando. Vale la pena enumerarlos.

## 7. Checklist rápido

**Separar el costo (§0)**

1. `time julia --startup-file=no -e ''` — establece el piso (aquí: 0.18s).
2. Corre el CLI **sin redirigir stderr**. ¿Dice `Precompiling packages...`? Entonces es §6, no
   compilación de métodos. ¿Sale con código != 0? Ese es el bug, arréglalo antes de medir latencia.
3. `time` del CLI haciendo algo trivial (`--help`) vs. haciendo el trabajo real. Si son parecidos,
   el costo está en el arranque, no en el trabajo.

**Compilación de métodos (§1-§4)**

4. Traza con **las dos banderas**: `--trace-compile=stderr --trace-compile-timing`. Solas no
   sirven de nada. Para un app instalado: `app <banderas de julia> -- <args del app>`.
5. Suma la traza. **Si no explica el tiempo de pared, no es esto** — vuelve al paso 2.
6. ¿Un despachador con muchas ramas, cada una tocando un subsistema pesado? Llamada dinámica:
   `Base.invokelatest` por rama, o una tabla `Dict{String,Function}` explícitamente tipada (§3).
7. ¿El despachador vive dentro de una **closure** capturada por un callback (bucle REPL, router
   HTTP)? Mismo problema, misma solución (§1).
8. ¿Un solo punto usa (de)serialización genérica mientras el resto usa formatos planos? Sospecha
   de él como pico aislado (§4).

**Lo que queda (§5)**

9. ¿El shim de `Pkg.Apps` de verdad precompila algo, o solo re-ejecuta `julia -m Módulo`? Léelo.
   De paso te dice qué `Manifest.toml` manda y con qué binario de julia corre.
10. Si el costo restante es la rama que SÍ se usa siempre, la siguiente palanca es
    `PrecompileTools.@compile_workload`, no más despacho dinámico.
11. Si vas hacia `juliac --trim`, recuerda que el despacho dinámico de §3 es justo lo que el
    análisis de alcanzabilidad no puede seguir. Decídelo a conciencia, no lo descubras al final.
