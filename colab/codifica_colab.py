"""Codifica en Colab los textos de la exportación densa de ReposMx (docs/plan-rag-web.md, sección 4).

Se lanza desde la terminal con colab/codifica_cli.sh (google-colab-cli):
    colab exec -s <sesión> -f colab/codifica_colab.py --timeout 0

Lee /content/reposmx/textos/textos-NNNNN.jsonl ({"sha", "texto"} por renglón) y escribe
/content/reposmx/vectores/textos-NNNNN.f16: los vectores de ese lote en su orden, Float16, 1,024 por texto,
sin normalizar (numpy row-major, N x 1024). Antes de codificar compara con los vectores de
/content/reposmx/validacion.jsonl, hechos en la máquina con Ollama (qwen3-embedding:0.6b-fp16), que es el
codificador de las consultas: si no coinciden (coseno mínimo 0.999), no codifica nada. Es la misma
receta del RAG ambiental (emb/codifica_v2_colab.py): sentence-transformers en fp16, sin el módulo
Normalize, lotes armados por presupuesto de tokens. Da vueltas hasta que existe
/content/reposmx/SUBIDA_COMPLETA y no queda lote por codificar; termina con "todo codificado".

Puede haber más de una sesión a la vez (colab/orquesta.sh: se empieza con la GPU que haya y se suma una mejor
cuando aparece). Para no repetir trabajo: ORDEN=desc recorre los lotes del último al primero (la segunda sesión
va de la otra punta), y un lote con marca en /content/reposmx/hechos/<lote> (la deja el orquestador al bajar
sus vectores de otra sesión) se salta. A lo más se repite el lote en el que se encuentran.
"""
import glob
import json
import os
import threading
import time
import traceback

import numpy as np
import torch
from sentence_transformers import SentenceTransformer

BASE = "/content/reposmx"
MODEL_ID = "Qwen/Qwen3-Embedding-0.6B"
REVISION = "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3"
MAX_LENGTH = 2048          # las partes tienen hasta 2,000 caracteres; una ficha larga se trunca
DIM = 1024
ORDEN = os.environ.get("ORDEN", "asc")

# tokens por lote (estimados): 80,000 en una A100 de 40 GB; proporcional a la memoria en las demás (T4: 16 GB)
MEMORIA = torch.cuda.get_device_properties(0).total_memory / 2**30
PRESUPUESTO = int(min(80000, 2000 * MEMORIA))
print(torch.cuda.get_device_name(0), f"{MEMORIA:.0f} GB, presupuesto {PRESUPUESTO} tokens, orden {ORDEN}", flush=True)
model = SentenceTransformer(MODEL_ID, revision=REVISION, device="cuda", model_kwargs={"torch_dtype": torch.float16},
                            tokenizer_kwargs={"padding_side": "left"})
if type(model[-1]).__name__ == "Normalize":  # se guarda el pooling crudo, como en el RAG ambiental
    model = SentenceTransformer(modules=[model[i] for i in range(len(model) - 1)], device="cuda")
model.max_seq_length = MAX_LENGTH


def lee(ruta):
    with open(ruta, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def codifica(textos):
    global PRESUPUESTO
    largo = [min(MAX_LENGTH, len(t) // 3 + 16) for t in textos]
    orden = sorted(range(len(textos)), key=lambda i: -largo[i])
    out = np.zeros((len(textos), DIM), dtype=np.float16)
    i = 0
    while i < len(orden):
        n = max(1, min(256, PRESUPUESTO // largo[orden[i]]))
        idx = orden[i:i + n]
        try:
            out[idx] = model.encode([textos[j] for j in idx], batch_size=n, normalize_embeddings=False,
                                    convert_to_numpy=True, show_progress_bar=False).astype(np.float16)
        except torch.cuda.OutOfMemoryError:  # no cupo: se baja el presupuesto y se repite el mismo lote
            torch.cuda.empty_cache()
            PRESUPUESTO = max(2048, PRESUPUESTO // 2)
            print(f"  sin memoria: presupuesto {PRESUPUESTO} tokens", flush=True)
            continue
        i += n
    return out


while not os.path.exists(f"{BASE}/validacion.jsonl"):
    time.sleep(5)
time.sleep(5)
v = lee(f"{BASE}/validacion.jsonl")
ref = np.asarray([r["vector"] for r in v], dtype=np.float32)
out = codifica([r["texto"] for r in v]).astype(np.float32)
cos = (ref * out).sum(1) / (np.linalg.norm(ref, axis=1) * np.linalg.norm(out, axis=1))
print(f"validación con {len(v)} textos: coseno mín {cos.min():.5f}, media {cos.mean():.5f}", flush=True)
assert cos.min() > 0.999, "los vectores de Colab no coinciden con los de Ollama"

os.makedirs(f"{BASE}/vectores", exist_ok=True)
t_ini, n_textos, n_lotes = time.time(), 0, 0
EN_CURSO = {"lote": "", "latidos": 0}


def late():  # el orquestador lo lee por la API de archivos (sin el kernel) para saber que esto sigue vivo
    while True:
        EN_CURSO["latidos"] += 1
        with open(f"{BASE}/latido.tmp", "w") as f:
            f.write(f"{EN_CURSO['latidos']} {time.strftime('%H:%M:%S')} {EN_CURSO['lote']} {n_lotes}\n")
        os.replace(f"{BASE}/latido.tmp", f"{BASE}/latido")
        time.sleep(30)


threading.Thread(target=late, daemon=True).start()
while True:
    completa = os.path.exists(f"{BASE}/SUBIDA_COMPLETA")
    hizo = False
    for p in sorted(glob.glob(f"{BASE}/textos/textos-*.jsonl"), reverse=ORDEN == "desc"):
        nombre = os.path.basename(p)[:-len(".jsonl")]
        salida = f"{BASE}/vectores/{nombre}.f16"
        if os.path.exists(salida) or os.path.exists(f"{BASE}/hechos/{nombre}"):  # hecho aquí o en otra sesión
            continue
        if time.time() - os.path.getmtime(p) < 20:  # aún subiendo
            continue
        try:
            textos = [r["texto"] for r in lee(p)]
        except Exception as e:  # archivo a medias: se reintenta en la vuelta siguiente
            print(f"  {nombre}: todavía no se puede leer ({type(e).__name__})", flush=True)
            continue
        t0 = time.time()
        EN_CURSO["lote"] = nombre
        try:
            vecs = codifica(textos)
        except Exception:  # se anota y se sigue con el siguiente; este se reintenta en la vuelta siguiente
            print(f"  {nombre}: falló\n{traceback.format_exc()}", flush=True)
            continue
        vecs.tofile(salida + ".tmp")
        os.replace(salida + ".tmp", salida)
        n_textos += len(textos)
        n_lotes += 1
        hizo = True
        print(f"{nombre}: {len(textos)} textos en {time.time() - t0:.0f} s "
              f"(acumulado {n_textos} textos, {n_lotes} lotes, {(time.time() - t_ini) / 60:.1f} min)", flush=True)
    if completa and not hizo:
        break
    if not hizo:
        time.sleep(15)
print(f"todo codificado: {n_textos} textos en {(time.time() - t_ini) / 60:.1f} min", flush=True)
