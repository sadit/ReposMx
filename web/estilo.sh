#!/bin/sh
# Regenera estaticos/estilo.css con el binario independiente de Tailwind (sin Node). Sólo hace falta al
# cambiar clases en src/paginas.jl o los temas de estilo.css; el resultado se guarda en git.
# El binario: https://github.com/tailwindlabs/tailwindcss/releases (tailwindcss-linux-x64) en el PATH.
AQUI="$(cd "$(dirname "$0")" && pwd)"
command -v tailwindcss >/dev/null 2>&1 || { echo "falta tailwindcss en el PATH" >&2; exit 1; }
cd "$AQUI" && exec tailwindcss --input estilo.css --output estaticos/estilo.css --minify
