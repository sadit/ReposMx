"""Codifica con Ollama local los lotes de una exportación densa (para probar el pipeline sin Colab).

Escribe <dir>/vectores/textos-NNNNN.f16 igual que colab/codifica_colab.py (Float16, N x 1024, row-major).
Ollama devuelve vectores normalizados; los de Colab no lo están, pero el índice normaliza al construir.
Uso: python3 experiments/rag_web/codifica_ollama.py <dir de la exportación> [url] [modelo] [lotes]
(lotes: cuántos codificar como máximo; todos si no se dice)
"""
import glob, json, os, struct, sys, time, urllib.request

d = sys.argv[1]
url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:11434"
modelo = sys.argv[3] if len(sys.argv) > 3 else "qwen3-embedding:0.6b-fp16"
max_lotes = int(sys.argv[4]) if len(sys.argv) > 4 else 10**9
os.makedirs(f"{d}/vectores", exist_ok=True)
for p in sorted(glob.glob(f"{d}/textos/textos-*.jsonl"))[:max_lotes]:
    out = f"{d}/vectores/" + os.path.basename(p)[:-len(".jsonl")] + ".f16"
    if os.path.exists(out):
        continue
    textos = [json.loads(l)["texto"] for l in open(p, encoding="utf-8") if l.strip()]
    t0, vecs = time.time(), []
    for i in range(0, len(textos), 32):
        cuerpo = json.dumps({"model": modelo, "input": textos[i:i + 32], "truncate": True,
                             "options": {"num_ctx": 4096}}).encode()
        req = urllib.request.Request(url + "/api/embed", cuerpo, {"Content-Type": "application/json"})
        for e in json.load(urllib.request.urlopen(req, timeout=600))["embeddings"]:
            vecs.append(struct.pack(f"<{len(e)}e", *e))
    with open(out + ".tmp", "wb") as f:
        f.write(b"".join(vecs))
    os.replace(out + ".tmp", out)
    print(f"{os.path.basename(out)}: {len(textos)} textos en {time.time() - t0:.0f} s", flush=True)
