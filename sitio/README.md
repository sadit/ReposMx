# sitio/

Sitio del proyecto (Quarto, tipo *website*) para GitHub Pages: `https://sadit.github.io/ReposMx/`.

| Página | Archivo |
|---|---|
| Inicio | `index.qmd` |
| Datos (fuentes, tipos, CTI, repositorios) | `datos.qmd` + `_tablas/tipos.md`, `_tablas/repositorios.md` |
| Cómo se hizo (tubería, mediciones, lo que no sirvió) | `metodo.qmd` + `_tablas/metadisciplinas.md` |
| Relación con el Repositorio Nacional | `repositorio-nacional.qmd` |
| Mapa de meta-disciplinas | `mapa.qmd` + `mapa/visor.js` (D3 sobre canvas) + `mapa/grafo.json` |

```sh
python3 sitio/genera.py      # tablas y cifras del corpus, y el grafo (sólo si cambian los datos); van en git
quarto preview sitio         # para verlo mientras se edita
sitio/publica.sh             # arma y sube a la rama gh-pages
```

El sitio no liga al demo (el demo sí liga al sitio, `SITIO` en `web/src/paginas.jl`).
Colores: Solarized claro y oscuro (`sitio.scss`, `sitio-oscuro.scss`), como el demo.
