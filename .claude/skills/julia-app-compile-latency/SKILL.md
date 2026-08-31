---
name: julia-app-compile-latency
description: Diagnóstico y arreglo de arranque lento en CLIs/apps de Julia (julia -m Module, Pkg.Apps, @main) causado por compilación anticipada de código nunca ejecutado — despachadores con muchas ramas, deserialización genérica (JLD2), y las herramientas (--trace-compile-timing, Base.invokelatest, PrecompileTools, PackageCompiler) para diagnosticarlo y evitarlo. Úsala para cualquier app/CLI de Julia con arranque lento, no solo este repo.
---

# Latencia de compilación en apps/CLIs de Julia

Destilado de un caso real: `reposmx --help` tardaba ~40s en imprimir texto estático. No era
carga de paquetes ni I/O — era compilación, casi toda concentrada en un solo sitio. Esta guía es
para diagnosticar y arreglar ese tipo de problema en cualquier CLI o app de Julia.

## 1. El hecho central que hay que internalizar

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

Esto es distinto de "cargar paquetes es lento" (`using X`) — es un costo aparte, que ocurre
después de que los paquetes ya cargaron, la primera vez que tu propio código de despacho se
ejecuta.

## 2. Diagnóstico: no adivines, mide con `--trace-compile-timing`

```bash
julia --project=. --trace-compile-timing -m TuApp algunsubcomando 2> trace.log
```

Cada línea es una especialización compilada con su tiempo:

```
#=    7.9 ms =# precompile(Tuple{EzXML.var"##parse_options#7", ...})
...
#= 37040.3 ms =# precompile(Tuple{typeof(ReposMx.main), Array{String, 1}})
```

Caso real: 218 especializaciones compiladas, 217 de ellas sumaban menos de 1s combinadas, y
**una sola** (`ReposMx.main`, el despachador de subcomandos) se llevó 37.0 de los ~40s totales.
Eso te dice exactamente dónde mirar — no hace falta perfilar nada más fino que esto para
localizar el culpable en la mayoría de los casos.

Diagnóstico secundario, si quieres ver qué se compila sin el timing (más ruidoso, útil para
confirmar QUÉ paquetes/símbolos entran en juego, no solo cuánto tardan):

```bash
julia --project=. --trace-compile=stderr -m TuApp algunsubcomando 2> trace.log
```

Verificación rápida y barata antes de instrumentar nada: comparar el tiempo de invocar la función
"hoja" directamente (`julia -e 'using TuApp; TuApp.algo_barato()'`) contra invocar el CLI completo
con el mismo trabajo real (`julia -m TuApp algunsubcomando`). Si la primera es rápida y la segunda
no, el costo está en el despachador, no en la función que realmente hace el trabajo — así fue como
se confirmó este caso antes de instrumentar con `--trace-compile-timing`.

## 3. El arreglo de bajo esfuerzo: `Base.invokelatest`

```julia
Base.invokelatest(f, args...; kwargs...)
```

en vez de la llamada estática `f(args...; kwargs...)`. Esto llama a `f` en la última "edad del
mundo" (world age) de la tabla de métodos, en vez de resolverla/inferirla estáticamente en el
sitio de la llamada — rompe la cascada de inferencia que hace que compilar el despachador
arrastre transitivamente la compilación de cada rama. El costo de compilación de cada rama se
sigue pagando, pero **solo si esa rama se ejecuta**, y en el momento en que se ejecuta, no cuando
se compila el despachador.

```julia
if cmd == "serve"
    Base.invokelatest(start_server; port, host)
elseif cmd == "build"
    Base.invokelatest(build_search_index; repos=target_repos)
elseif cmd == "search"
    Base.invokelatest(search_cli, q; top)
end
```

Resultado medido en el caso real: `reposmx --help` con caché tibia, 40s → 3.9s (quedando
básicamente en el piso de `using ReposMx`).

**Qué NO arregla esto por sí solo:** simplemente partir el despachador en funciones más chicas
(`cmd_serve()`, `cmd_build()`, ...) sin `invokelatest` NO ayuda — si esas funciones se siguen
llamando de forma estática desde el despachador, Julia igual las infiere transitivamente al
compilar el despachador. Lo que rompe la cascada es la llamada dinámica (`invokelatest`, o
equivalentemente invocar a través de un valor `::Function` genérico como en un
`Dict{String,Function}`), no la separación en sí.

**Costo de `invokelatest`:** overhead de despacho dinámico en cada llamada — insignificante para
un punto de entrada de CLI que se llama una vez por proceso. No usarlo en un hot loop interno
donde se llama miles de veces por segundo.

## 4. Otra fuente del mismo síntoma: deserialización genérica

Un problema relacionado pero distinto: la primera llamada a `JLD2.load` (o cualquier librería que
reconstruya tipos genéricos en tiempo de ejecución a partir de metadata serializada) puede costar
varios segundos de compilación **la primera vez en el proceso**, sin importar qué tan chico sea el
archivo — porque compila la maquinaria genérica de reconstrucción de tipos, no porque lea muchos
bytes. Medido: cargar un `.jld2` de 249KB costó 8.44s (98.66% compilación). Reemplazar ese punto
de serialización por algo con forma de dato plano (JSON3, o cualquier formato que solo necesite
tipos concretos conocidos de antemano en vez de reconstruir un grafo de objetos arbitrario) bajó
eso a 0.9s — no por ser más chico el archivo, sino porque el código que hay que compilar para
leerlo es mucho menor y además comparte especializaciones ya calientes de otras partes cercanas
del mismo proceso (ver skill `search-index-engineering` para el caso completo con benchmarks).

Regla práctica: si un solo punto de tu código usa una librería de serialización genérica
(JLD2.jl, Serialization stdlib con tipos complejos, etc.) y todo lo demás usa formatos con forma
de dato plano, ese punto probablemente sea un pico aislado de tiempo de compilación — sospecha de
él primero.

## 5. Por qué esto se paga en *cada* invocación (y qué hacer al respecto)

Un shim generado por `Pkg.Apps.develop`/`Pkg.Apps.add` (el `reposmx` que queda en
`~/.julia/bin/`) **no es un binario precompilado** — es un script que simplemente ejecuta
`julia -m TuApp` cada vez. Revisa el shim generado (`cat ~/.julia/bin/tuapp`) antes de asumir lo
contrario: es fácil pensar que "instalar como Julia App" significa "compilar una vez", y no es
así por defecto. Cada invocación es un proceso de Julia nuevo, y el trabajo de compilación de
`invokelatest` (que se defirió, no se eliminó) se repite en cada una si la rama en cuestión se
ejecuta.

Opciones, de menor a mayor esfuerzo/impacto:

1. **`invokelatest` (§3)** — evita compilar ramas que NO se ejecutan. No reduce el costo de la
   rama que sí se ejecuta.
2. **`PrecompileTools.jl`** (`@compile_workload` dentro del módulo) — ejecuta las rutas de código
   representativas durante la *precompilación del paquete* (una vez, al instalar/actualizar),
   guardando esas especializaciones en la caché de precompilación (`~/.julia/compiled/...`). No
   reduce el trabajo total de compilación, lo mueve de "cada arranque" a "cada instalación". Es el
   siguiente paso natural después de `invokelatest` si el costo de la rama que sí se usa
   habitualmente (p. ej. abrir la shell interactiva) sigue siendo notorio.
3. **Separar módulos/entrypoints por responsabilidad** (un `[apps]` por tarea: TUI, servidor HTTP,
   tareas de construcción/ETL) — reduce el techo de `using TuApp` solo si además el módulo raíz
   carga condicionalmente sus submódulos pesados (extensiones de paquete/weak deps, o paquetes
   separados) en vez de un `include`+`using` incondicional de todo. Separar solo los ejecutables
   sin separar los módulos no cambia nada: `using TuApp` sigue cargando todo sin importar cuál
   `[apps]` lo invoque.
4. **`PackageCompiler.jl` / `juliac --trim`** — compila un binario standalone de verdad, una vez,
   como paso de build/CI. Es la respuesta correcta cuando la latencia de arranque debe ser
   consistentemente baja (servicio interactivo, herramienta que se invoca con mucha frecuencia) y
   ya se agotó el margen de las opciones anteriores. Mayor esfuerzo de infraestructura (pipeline de
   build, artefacto a distribuir) a cambio de arranque cercano a cero.

## 6. Checklist rápido

- ¿Un `reposmx --help`-equivalente (algo trivial) tarda segundos en vez de ser instantáneo tras el
  arranque de Julia? Sospecha de compilación anticipada de ramas no ejecutadas, no de I/O.
- Mide primero con `--trace-compile-timing` — busca la línea que domina, no optimices a ciegas.
- ¿Un despachador con `if/elseif` sobre muchos subcomandos, cada uno tocando un subsistema
  distinto y pesado? Envuelve cada rama en `Base.invokelatest`.
- ¿Un solo punto usa una librería de (de)serialización genérica mientras el resto usa formatos
  planos? Sospecha de él como pico aislado, verifica con el mismo trace.
- ¿El shim que genera `Pkg.Apps` de verdad precompila algo, o solo re-ejecuta `julia -m Módulo`
  cada vez? Revisa el script antes de asumir.
- Si el costo que queda es el de la rama que SÍ se usa siempre (p. ej. abrir el shell interactivo
  por defecto), el siguiente palanca es `PrecompileTools.@compile_workload`, no más
  `invokelatest`.
