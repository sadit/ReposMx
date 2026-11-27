#!/usr/bin/env bash
# Orquesta la codificación en Colab de la exportación densa (data/index/dense, docs/plan-rag-web.md sección 4)
# con la GPU que haya, y suma una mejor cuando aparece, sin parar ni repetir lo que ya corre (indicación del
# usuario, 2026-11-26: tomar hasta una T4 si no hay otra y revisar cada hora si hay mejores recursos).
#
#   colab/orquesta.sh            todo: consigue sesión, sube, codifica, baja; al terminar cierra las sesiones
#
# - Preferencia: A100, G4, L4, T4. La primera sesión recorre los lotes del primero al último (ORDEN=asc).
# - Cada hora, si hay una sola sesión y no es A100, intenta una mejor; si la consigue, le sube los lotes que
#   faltan, del último al primero, y la lanza con ORDEN=desc: las dos avanzan desde puntas opuestas.
# - Cada minuto baja de cada sesión los vectores terminados y deja en las demás la marca hechos/<lote>, que el
#   codificador respeta (colab/codifica_colab.py). A lo más se repite el lote en el que se encuentran.
# - El codificador corre dentro del kernel (`colab exec -f ... --timeout 0`, en segundo plano aquí), como en el
#   RAG ambiental: así el kernel está ocupado y Colab no recupera la sesión. Lanzado desprendido del kernel
#   (nohup), Colab cerró dos sesiones a los 15-30 min sin aviso (2026-11-26): las subidas de archivos no cuentan
#   como actividad. Escribe /content/reposmx/latido cada 30 s; se vigila por la API de archivos. Sin latido nuevo
#   en 10 min: si la sesión ya no existe se quita; si existe, se reinicia el kernel y se relanza (dos veces a
#   lo más; luego se cierra). Sin sesiones se pide otra. Una traza de error en la bitácora para todo.
# - La bitácora del codificador (la salida del exec) queda en data/index/dense/codifica-<sesión>.log.
# - Se puede relanzar: adopta las sesiones reposmx-* que existan, no vuelve a subir lo que ya está en la
#   máquina y no relanza un codificador que late. Las sesiones vivas están en data/index/dense/sesiones.txt.
set -uo pipefail
cd "$(dirname "$0")/.."
D=data/index/dense
R=/content/reposmx
SES=$D/sesiones.txt
# el Python del CLI no encuentra los certificados del sistema y el websocket de `colab exec` falla sin esto
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/pki/tls/certs/ca-bundle.crt}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VACIO=$TMP/vacio; : > "$VACIO"
SIN_LATIDO=600

log() { echo "$(date '+%F %T') $*"; }
rango() { case "$1" in A100) echo 4 ;; G4) echo 3 ;; L4) echo 2 ;; T4) echo 1 ;; *) echo 0 ;; esac; }
TOTAL=$(ls "$D"/textos/textos-*.jsonl | wc -l)
bajados() { ls "$D"/vectores/*.f16 2>/dev/null | wc -l; }
sesiones() { [ -s "$SES" ] && cut -d' ' -f1 "$SES"; }
orden_de() { awk -v s="$1" '$1 == s { print $3 }' "$SES"; }
quita() { awk -v s="$1" '$1 != s' "$SES" > "$SES.tmp"; mv "$SES.tmp" "$SES"; }
touch "$SES"; mkdir -p "$D/vectores"
declare -A LATIDO VISTO FALLOS

# Una sesión con la primera GPU de la lista que se consiga: imprime "nombre gpu".
nueva() {
    for g in "$@"; do
        s=reposmx-$(echo "$g" | tr 'A-Z' 'a-z')
        grep -q "^$s " "$SES" && continue
        if timeout 900 colab new -s "$s" --gpu "$g" </dev/null >/dev/null 2>&1 &&
           colab sessions </dev/null 2>&1 | grep -q "^\[$s\]"; then
            echo "$s $g"; return 0
        fi
        colab stop -s "$s" </dev/null >/dev/null 2>&1      # por si quedó a medias
    done
    return 1
}

remoto() { printf '%s\n' "$2" | timeout 300 colab exec -s "$1" 2>&1; }
marca() { colab upload -s "$1" "$VACIO" "$R/hechos/$2" </dev/null >/dev/null 2>&1; }

latido() {  # el contenido de latido en la sesión $1, o vacío
    rm -f "$TMP/latido"
    colab download -s "$1" "$R/latido" "$TMP/latido" </dev/null >/dev/null 2>&1 && cat "$TMP/latido"
}

declare -A EXEC
lanza() {  # el codificador en el kernel de la sesión $1 con ORDEN=$2; el exec queda en segundo plano aquí
    local s=$1
    [ -n "${EXEC[$s]:-}" ] && kill "${EXEC[$s]}" 2>/dev/null
    colab exec -s "$s" -f colab/codifica_colab.py --env "ORDEN=$2" --timeout 0 </dev/null >> "$D/codifica-$s.log" 2>&1 &
    EXEC[$s]=$!
    sleep 5
    kill -0 "${EXEC[$s]}" 2>/dev/null
}
existe() { colab sessions </dev/null 2>&1 | grep -q "^\[$1\]"; }

# Prepara y lanza la sesión $1 con ORDEN=$2: carpetas, codificador, validación, marcas de lo ya bajado, los
# lotes que faltan (en el orden en que los va a tomar) y SUBIDA_COMPLETA. Con un latido reciente no relanza.
arranca() {
    local s=$1 orden=$2 gpu=$3 ok=""
    for _ in 1 2 3; do
        remoto "$s" 'import os
for d in ("textos", "vectores", "hechos"): os.makedirs(f"/content/reposmx/{d}", exist_ok=True)
print("carpetas listas")' | grep -q '^carpetas listas' && { ok=1; break; }
        timeout 120 colab restart-kernel -s "$s" </dev/null >/dev/null 2>&1      # un exec cortado lo deja ocupado
        sleep 20
    done
    [ -n "$ok" ] || { log "$s: el kernel no contesta; se cierra"; colab stop -s "$s" </dev/null >/dev/null 2>&1; return 1; }
    grep -q "^$s " "$SES" || echo "$s $gpu $orden" >> "$SES"
    touch "$TMP/carpetas-$s"         # el principal ya puede lanzar el codificador: toma los lotes conforme llegan
    colab upload -s "$s" colab/codifica_colab.py "$R/codifica_colab.py" </dev/null >/dev/null 2>&1 &&
    colab upload -s "$s" "$D/validacion.jsonl" "$R/validacion.jsonl" </dev/null >/dev/null 2>&1 ||
        { log "$s: no se pudo subir el codificador o la validación"; return 1; }
    for f in "$D"/vectores/*.f16; do [ -e "$f" ] && marca "$s" "$(basename "$f" .f16)"; done
    local hay; hay=$(colab ls -s "$s" "$R/textos" </dev/null 2>/dev/null)
    local lotes; lotes=$(ls "$D"/textos/textos-*.jsonl | { [ "$orden" = desc ] && sort -r || sort; })
    local n=0
    for f in $lotes; do
        b=$(basename "$f" .jsonl)
        [ -e "$D/vectores/$b.f16" ] && continue
        grep -qx "$b.jsonl" <<<"$hay" && continue
        colab upload -s "$s" "$f" "$R/textos/$b.jsonl" </dev/null >/dev/null 2>&1 && n=$((n + 1)) || log "$s: FALLÓ la subida de $b"
    done
    colab upload -s "$s" "$VACIO" "$R/SUBIDA_COMPLETA" </dev/null >/dev/null 2>&1
    log "$s: $n lotes subidos (los demás ya estaban o ya se bajaron) y SUBIDA_COMPLETA"
    touch "$TMP/listo-$s"            # el proceso principal lanza el codificador (lanza) al ver esto
}

# Baja de cada sesión los lotes terminados que falten aquí y marca cada uno en las demás.
baja() {
    for s in $(sesiones); do
        for b in $(colab ls -s "$s" "$R/vectores" </dev/null 2>/dev/null | grep '^textos-.*\.f16$'); do
            [ -e "$D/vectores/$b" ] && continue
            if colab download -s "$s" "$R/vectores/$b" "$D/vectores/$b.parte" </dev/null >/dev/null 2>&1; then
                mv "$D/vectores/$b.parte" "$D/vectores/$b"
                log "bajado $b de $s ($(bajados)/$TOTAL)"
                for o in $(sesiones); do [ "$o" = "$s" ] || marca "$o" "${b%.f16}"; done
            fi
        done
    done
}

# Lanza el codificador de las sesiones recién preparadas y revisa el latido de cada una.
vigila() {
    local ahora; ahora=$(date +%s)
    for s in $(sesiones); do
        if [ -e "$TMP/carpetas-$s" ] && [ -z "${EXEC[$s]:-}" ]; then
            lanza "$s" "$(orden_de "$s")" && log "$s: codificador lanzado en el kernel, orden $(orden_de "$s")" ||
                log "$s: el exec del codificador terminó de inmediato (ver $D/codifica-$s.log)"
            VISTO[$s]=$ahora; continue
        fi
        [ -z "${EXEC[$s]:-}" ] && continue                         # todavía preparándose
        l=$(latido "$s")
        if [ -n "$l" ] && [ "$l" != "${LATIDO[$s]:-}" ]; then
            LATIDO[$s]=$l; VISTO[$s]=$ahora; FALLOS[$s]=0; continue
        fi
        [ $((ahora - ${VISTO[$s]:-$ahora})) -lt $SIN_LATIDO ] && continue
        if grep -q 'todo codificado' "$D/codifica-$s.log" 2>/dev/null; then
            log "$s terminó su parte; se cierra"
            colab stop -s "$s" </dev/null >/dev/null 2>&1; quita "$s"; continue
        fi
        if grep -q -E 'Traceback|no coinciden' "$D/codifica-$s.log" 2>/dev/null; then
            log "el codificador de $s falló (ver $D/codifica-$s.log): se para todo para revisarlo"
            exit 1
        fi
        if ! existe "$s"; then
            log "$s ya no existe en Colab (la cerró Colab): se quita"
            kill "${EXEC[$s]}" 2>/dev/null; quita "$s"; continue
        fi
        FALLOS[$s]=$(( ${FALLOS[$s]:-0} + 1 ))
        timeout 120 colab restart-kernel -s "$s" </dev/null >/dev/null 2>&1
        if [ "${FALLOS[$s]}" -le 2 ] && lanza "$s" "$(orden_de "$s")"; then
            log "$s sin latido desde hace $(( (ahora - VISTO[$s]) / 60 )) min: kernel reiniciado y codificador relanzado (vez ${FALLOS[$s]})"
            VISTO[$s]=$ahora
        else
            log "$s sin latido y no se pudo relanzar: se cierra"
            kill "${EXEC[$s]}" 2>/dev/null; colab stop -s "$s" </dev/null >/dev/null 2>&1; quita "$s"
        fi
    done
}

mejor_rango() { local m=0; while read -r _ g _; do r=$(rango "$g"); [ "$r" -gt "$m" ] && m=$r; done < "$SES"; echo $m; }

# -- principal
if [ -z "$(sesiones)" ]; then
    # una sesión reposmx-* ya creada (a mano o por una corrida anterior) se adopta en vez de pedir otra
    ex=$(colab sessions </dev/null 2>&1 | sed -n 's/^\[\(reposmx-[a-z0-9]*\)\].*Hardware: \([A-Za-z0-9]*\).*/\1 \2/p' | head -1)
    if [ -n "$ex" ]; then
        read -r s g <<<"$ex"; log "se adopta la sesión $s ($g)"
    else
        read -r s g < <(nueva A100 G4 L4 T4) || { log "no hay GPU en Colab"; exit 1; }
        log "sesión $s con $g"
    fi
    arranca "$s" asc "$g" &
    sleep 60
fi
ultima_mejora=$(date +%s)
while [ "$(bajados)" -lt "$TOTAL" ]; do
    baja
    [ "$(bajados)" -ge "$TOTAL" ] && break
    vigila
    if [ -z "$(sesiones)" ]; then
        log "no queda sesión y faltan $((TOTAL - $(bajados))) lotes: se pide otra"
        if read -r s g < <(nueva A100 G4 L4 T4); then arranca "$s" asc "$g" & sleep 60; else log "no hay GPU; se reintenta en 5 min"; sleep 240; fi
    fi
    ahora=$(date +%s)
    if [ $((ahora - ultima_mejora)) -ge 3600 ]; then
        ultima_mejora=$ahora
        if [ "$(sesiones | wc -l)" -eq 1 ] && [ "$(mejor_rango)" -lt 4 ]; then
            m=$(mejor_rango); mejores=""
            for g in A100 G4 L4; do [ "$(rango $g)" -gt "$m" ] && mejores="$mejores $g"; done
            log "buscando una GPU mejor:$mejores"
            if read -r s2 g2 < <(nueva $mejores); then
                log "sesión $s2 con $g2: se suma desde la otra punta"
                arranca "$s2" desc "$g2" &            # la bajada sigue mientras se sube
            else
                log "no hubo GPU mejor; se vuelve a probar en una hora"
            fi
        fi
    fi
    sleep 60
done
for p in "${EXEC[@]}"; do kill "$p" 2>/dev/null; done
log "todo bajado: $(bajados) de $TOTAL lotes; se cierran las sesiones"
for s in $(sesiones); do colab stop -s "$s" </dev/null >/dev/null 2>&1 && log "cerrada $s"; done
: > "$SES"
