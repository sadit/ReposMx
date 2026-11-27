#!/usr/bin/env bash
# Los datos de la codificación densa en Google Drive (rclone, remoto gdrive:), como en el RAG ambiental
# (~/Projects/Legistlan/RAG-Medio-Ambiente/drive.sh). En Drive: My Drive/DATA/ReposMx/dense/
# (en Colab, con Drive montado: /content/drive/MyDrive/DATA/ReposMx/dense).
#
#   colab/drive.sh subir      textos, validación y resumen de la exportación -> Drive
#   colab/drive.sh vectores   los vectores ya bajados -> Drive
#   colab/drive.sh bajar      los vectores que haya en Drive -> local (los que falten)
#   colab/drive.sh espejo     `vectores` cada 5 min mientras corre colab/orquesta.sh, y una vez al final
#   colab/drive.sh metas      las meta-disciplinas oficiales (metadisciplinas/) y su asignación -> Drive
#   colab/drive.sh estado     qué hay en Drive
#
# Nunca borra: `rclone copy` copia lo nuevo o cambiado y deja lo demás. Variable: REMOTO
# (por omisión gdrive:DATA/ReposMx/dense).
set -euo pipefail
cd "$(dirname "$0")/.."
D=data/index/dense
REMOTO="${REMOTO:-gdrive:DATA/ReposMx/dense}"
RC=(rclone copy --transfers 4 --stats-one-line --stats 60s -v)
case "${1:-}" in
  subir)    "${RC[@]}" "$D/textos" "$REMOTO/textos"
            "${RC[@]}" --include "validacion.jsonl" --include "resumen.json" --max-depth 1 "$D" "$REMOTO" ;;
  vectores) "${RC[@]}" --include "*.f16" "$D/vectores" "$REMOTO/vectores" ;;
  bajar)    mkdir -p "$D/vectores"; "${RC[@]}" --ignore-existing --include "*.f16" "$REMOTO/vectores" "$D/vectores" ;;
  espejo)   while pgrep -f colab/orquesta.sh >/dev/null; do "$0" vectores 2>&1 | tail -1; sleep 300; done
            "$0" vectores 2>&1 | tail -1; echo "$(date '+%F %T') espejo terminado: $(rclone lsf "$REMOTO/vectores" | grep -c '\.f16$') lotes en Drive" ;;
  metas)    "${RC[@]}" metadisciplinas "${REMOTO%/dense}/metadisciplinas"
            "${RC[@]}" --include "metadisciplinas_documentos.jsonl" --max-depth 1 "$D" "${REMOTO%/dense}/metadisciplinas" ;;
  estado)   for d in textos vectores; do echo "$d: $(rclone lsf "$REMOTO/$d" 2>/dev/null | wc -l) archivos"; done
            rclone lsf --max-depth 1 "$REMOTO" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
