#!/bin/sh
# Levanta el demo web (docs/plan-rag-web.md, fase 2): un proceso de Julia 1.13 con el índice de ReposMx embebido
# y Oxygen, sólo en 127.0.0.1. La búsqueda por significado necesita Ollama con qwen3-embedding:0.6b-fp16 (el
# mismo de AmbientalWeb) y el proyecto denso (reposmx export-units, colab/codifica_cli.sh, build_dense_project).
# Uso: web/sirve.sh [puerto]        (8790; prefijo en REPOSMX_PREFIJO, /reposmx si no se dice)
AQUI="$(cd "$(dirname "$0")" && pwd)"
CANAL="${JULIA_CANAL:-$(juliaup status 2>/dev/null | grep -o '1\.13[^ ]*' | head -1)}"
[ -n "$CANAL" ] || { echo "falta Julia 1.13 (juliaup add 1.13)" >&2; exit 1; }
export REPOSMX_PUERTO="${1:-${REPOSMX_PUERTO:-8790}}"
# El generador por API (compatible con OpenAI): dirección, modelo y llave en un archivo fuera de git, con
# renglones VARIABLE=valor (REPOSMX_GENERADOR_API, REPOSMX_GENERADOR, REPOSMX_GENERADOR_LLAVE, ...). Sin él se
# sirve sólo la búsqueda. Lo que ya venga en el ambiente no se pisa.
GEN="$AQUI/../data/web/generador.env"
if [ -f "$GEN" ]; then
    while IFS='=' read -r k v; do
        case "$k" in
            *[!A-Z0-9_]*) ;;                                  # sólo nombres de variable limpios
            REPOSMX_*) eval "[ -n \"\${$k+x}\" ]" || export "$k=$v" ;;
        esac
    done < "$GEN"
fi
exec julia +"$CANAL" --project="$AQUI" -t "${REPOSMX_HILOS:-16}" -e 'using ReposMxWeb; ReposMxWeb.main()'
