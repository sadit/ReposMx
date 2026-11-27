#!/usr/bin/env bash
# Codifica en Colab, desde la terminal (google-colab-cli), los textos que dejó `reposmx export-units` en
# data/index/dense/ (docs/plan-rag-web.md, sección 4). Hace falta una sesión ya creada:
#   colab new -s reposmx --gpu A100            (o G4)
#   colab/codifica_cli.sh valida    hace data/index/dense/validacion.jsonl con Ollama local (una vez)
#   colab/codifica_cli.sh sube      sube la validación y los lotes de textos que falten en la máquina
#   colab/codifica_cli.sh corre     lanza colab/codifica_colab.py (bitácora en data/index/dense/codifica.log)
#   colab/codifica_cli.sh baja      baja los vectores terminados, en vueltas, hasta que la corrida acaba
# `sube` y `baja` no usan el kernel, así que corren a la vez que `corre`. Los cuatro se pueden relanzar.
# Al terminar: colab stop -s reposmx
set -uo pipefail
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/pki/tls/certs/ca-bundle.crt}"   # sin esto falla el websocket de `colab exec`
cd "$(dirname "$0")/.."
S="${SESION:-reposmx}"
D=data/index/dense
R=/content/reposmx
OLLAMA="${OLLAMA_URL:-http://127.0.0.1:11434}"
MODELO="${OLLAMA_MODELO:-qwen3-embedding:0.6b-fp16}"
case "${1:-}" in
  valida)
    # 64 textos del primer lote, codificados como los documentos: sin instrucción.
    python3 - "$D/textos/textos-00001.jsonl" "$D/validacion.jsonl" "$OLLAMA" "$MODELO" <<'EOF'
import json, sys, urllib.request
src, dst, url, modelo = sys.argv[1:]
with open(src, encoding="utf-8") as f:
    rs = [json.loads(l) for _, l in zip(range(4000), f)][::62][:64]
cuerpo = json.dumps({"model": modelo, "input": [r["texto"] for r in rs], "truncate": True,
                     "options": {"num_ctx": 4096}}).encode()
req = urllib.request.Request(url + "/api/embed", cuerpo, {"Content-Type": "application/json"})
E = json.load(urllib.request.urlopen(req, timeout=600))["embeddings"]
with open(dst, "w", encoding="utf-8") as f:
    for r, e in zip(rs, E):
        f.write(json.dumps({"sha": r["sha"], "texto": r["texto"], "vector": e}, ensure_ascii=False) + "\n")
print(f"{len(E)} vectores en {dst}")
EOF
    ;;
  sube)
    [ -s "$D/validacion.jsonl" ] || { echo "falta $D/validacion.jsonl: corre primero '$0 valida'" >&2; exit 1; }
    colab upload -s "$S" "$D/validacion.jsonl" "$R/validacion.jsonl" </dev/null | tail -1
    hay=$(colab ls -s "$S" "$R/textos" </dev/null 2>/dev/null)
    for f in "$D"/textos/textos-*.jsonl; do
      b=$(basename "$f")
      grep -qx "$b" <<<"$hay" && continue
      # se sube con su nombre final; el codificador no toca un archivo con menos de 20 s de escrito y, si
      # aún no se puede leer, lo reintenta en la vuelta siguiente
      colab upload -s "$S" "$f" "$R/textos/$b" </dev/null >/dev/null 2>&1 \
        && echo "$(date +%T) subido $b" || echo "$(date +%T) FALLO $b"
    done
    printf 'ok\n' > "/tmp/SUBIDA_COMPLETA.$$" && colab upload -s "$S" "/tmp/SUBIDA_COMPLETA.$$" "$R/SUBIDA_COMPLETA" </dev/null | tail -1
    rm -f "/tmp/SUBIDA_COMPLETA.$$"
    ;;
  corre)
    colab exec -s "$S" -f colab/codifica_colab.py --timeout 0 </dev/null >> "$D/codifica.log" 2>&1
    ;;
  baja)
    mkdir -p "$D/vectores"
    while true; do
      for b in $(colab ls -s "$S" "$R/vectores" </dev/null 2>/dev/null | grep '^textos-.*\.f16$'); do
        [ -e "$D/vectores/$b" ] && continue
        colab download -s "$S" "$R/vectores/$b" "$D/vectores/$b.parte" </dev/null >/dev/null 2>&1 \
          && mv "$D/vectores/$b.parte" "$D/vectores/$b" && echo "$(date +%T) bajado $b"
      done
      if grep -aq "todo codificado" "$D/codifica.log" 2>/dev/null; then
        [ -n "${ULTIMA:-}" ] && break; ULTIMA=1   # una vuelta más después de terminar, por lo último escrito
      fi
      sleep 60
    done
    echo "$(date +%T) todo bajado: $(ls "$D"/vectores/*.f16 | wc -l) de $(ls "$D"/textos/*.jsonl | wc -l) lotes"
    ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
