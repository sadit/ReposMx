#!/usr/bin/env bash
# Publica el sitio en GitHub Pages: sadit.github.io/ReposMx/ (el repositorio es público).
#
# Arma el sitio (quarto render) y lo deja en la rama gh-pages del mismo repositorio, con un git worktree en
# .gh-pages/ en la raíz (fuera de git). No va dentro de sitio/: los patrones de `resources` de _quarto.yml
# coinciden a cualquier profundidad y Quarto copiaría el worktree al sitio. Hace commit y lo sube. En la
# configuración de Pages del repositorio, la fuente es la rama gh-pages, carpeta raíz (se configura una vez). Las
# tablas y el grafo salen de sitio/genera.py, que hay que correr antes si cambiaron los datos.
#
# Uso: sitio/publica.sh ["mensaje del commit"]
set -euo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(dirname "$AQUI")"
DESTINO="$RAIZ/.gh-pages"
MENSAJE="${1:-Sitio del $(date +%F)}"

quarto render "$AQUI"
cd "$RAIZ"
if [ ! -d "$DESTINO" ]; then
  git fetch origin gh-pages 2>/dev/null || true
  if git show-ref --verify --quiet refs/remotes/origin/gh-pages; then
    git worktree add "$DESTINO" gh-pages 2>/dev/null || git worktree add -B gh-pages "$DESTINO" origin/gh-pages
  else
    git worktree add --detach "$DESTINO" && git -C "$DESTINO" checkout --orphan gh-pages && git -C "$DESTINO" rm -rfq . || true
  fi
fi
rsync -a --delete --exclude .git "$AQUI/_site/" "$DESTINO/"
touch "$DESTINO/.nojekyll"
git -C "$DESTINO" add -A
if git -C "$DESTINO" diff --cached --quiet; then echo "sin cambios que publicar"; exit 0; fi
git -C "$DESTINO" commit -q -m "$MENSAJE"
git -C "$DESTINO" push -u origin gh-pages
echo "publicado: https://sadit.github.io/ReposMx/"
