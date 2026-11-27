# Vocabulario de palabras clave para las meta-disciplinas (2026-11-26): limpia las palabras clave de los
# documentos de texto del corpus y mide cuánto queda. Reglas:
#  - fuera los nombres CTI (son la clasificación declarada, que no se usa para aprender) y las rutas CTI escritas
#    como texto ("5 ciencias sociales", "humanidades y ... pedagogia"): toda palabra que contenga un nombre CTI
#    de campo o área completo;
#  - fuera las que traen caracteres de reemplazo (acentos rotos: "M�xico") en vez de adivinar la letra;
#  - forma normal: minúsculas, sin acentos, sin puntuación, espacios simples (une "Maíz" y "maiz");
#  - se quedan las que aparecen en al menos MIN_DOCS documentos y MIN_REPOS repositorios (tumba los nombres de
#    edificios y campus de un solo repositorio).
# Uso (desde la raíz): python3 experiments/rag_web/vocabulario_palabras_clave.py
import json, glob, collections, unicodedata, re, sys
MIN_DOCS, MIN_REPOS = 5, 2
NO = {"Carta o documento de archivo", "Imagen, mapa, audio o video", "Evento", "Conjunto de datos"}

def norm(k):
    k = unicodedata.normalize("NFKD", k.lower())
    k = "".join(c for c in k if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", " ", k)).strip()

cti_all, cti_big = set(), set()
for lvl in ("areacono", "campocono", "disciplinacono", "subdisciplinacono"):
    for r in json.load(open(f"data/catalogs/cti_{lvl}.json")):
        n = norm(r["descripcion"]); cti_all.add(n)
        if lvl in ("areacono", "campocono"): cti_big.add(n)

razones = collections.Counter(); df = collections.Counter(); repos = collections.defaultdict(set)
docs_kw = {}
ROTA = re.compile(r"\w\?\w")
pendientes = collections.defaultdict(list)    # palabra con "?" -> documentos (se reparan al final)
for f in sorted(glob.glob("data/repos/*/corpus.jsonl")):
    repo = f.split("/")[2]
    for line in open(f, encoding="utf-8"):
        d = json.loads(line)
        if d.get("type") in NO: continue
        kws = set()
        for k in d.get("keywords") or []:
            if "�" in k: razones["acentos rotos"] += 1; continue
            if ROTA.search(k):           # "M?xico": el "?" pasa a "_", que norm conserva, y se repara al final
                pendientes[norm(k.replace("?", "_"))].append(f"{repo}:{d['id']}"); continue
            n = norm(k)
            if len(n) < 3 or n.isdigit(): razones["muy corta o número"] += 1; continue
            if n in cti_all or any(c in n for c in cti_big if len(c) > 8): razones["nombre o ruta CTI"] += 1; continue
            kws.add(n)
        if kws:
            docs_kw[f"{repo}:{d['id']}"] = kws
            for n in kws: df[n] += 1; repos[n].add(repo)
# los acentos rotos: el "_" (el "?" original) vale por una letra
porlargo = collections.defaultdict(list)
for n in df: porlargo[len(n)].append(n)
reparadas = 0
for rota, docs in pendientes.items():
    pat = re.compile("^" + re.escape(rota).replace("_", ".") + "$")
    cand = [n for n in porlargo[len(rota)] if pat.match(n)]
    if len(cand) == 1:
        reparadas += 1
        for key in docs:
            docs_kw.setdefault(key, set()).add(cand[0]); df[cand[0]] += 1; repos[cand[0]].add(key.split(":")[0])
    else:
        razones["acentos rotos sin reparar"] += len(docs)
voc = {n for n in df if df[n] >= MIN_DOCS and len(repos[n]) >= MIN_REPOS}
razones["poco frecuente o de un solo repositorio"] = sum(1 for n in df if n not in voc)
cubiertos = sum(1 for kws in docs_kw.values() if kws & voc)
por_doc = sorted(len(kws & voc) for kws in docs_kw.values() if kws & voc)
print(f"documentos con palabras clave tras limpiar: {len(docs_kw)}; con alguna del vocabulario: {cubiertos}")
print(f"vocabulario: {len(voc)} de {len(df)} palabras distintas (≥{MIN_DOCS} documentos y ≥{MIN_REPOS} repositorios)")
print(f"palabras del vocabulario por documento: mediana {por_doc[len(por_doc)//2]}, p90 {por_doc[int(.9*len(por_doc))]}")
print(f"acentos rotos reparados: {reparadas} palabras de {len(pendientes)}")
print("descartes:", dict(razones))
print("más frecuentes:", [n for n, _ in sorted(((n, df[n]) for n in voc), key=lambda x: -x[1])[:40]])
json.dump(sorted(voc), open("data/index/dense/vocabulario_palabras_clave.json", "w"), ensure_ascii=False)
