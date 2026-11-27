# Cuenta los registros del corpus por tipo de documento, a partir de todos los dc:type de cada registro (el
# campo `type` del corpus los reduce a seis valores y la mitad cae en "Documento Académico"). Las reglas van en
# orden de prioridad sobre los dc:type juntos. Uso: python3 experiments/rag_web/tipos_documento.py (desde la raíz).
import json, glob, re, collections, unicodedata, html, sys
TYPE = re.compile(r"<dc:type[^>]*>(.*?)</dc:type>", re.S)
def sin(s):
    s = unicodedata.normalize("NFKD", html.unescape(s).lower())
    return "".join(c for c in s if not unicodedata.combining(c)).strip()
# reglas en orden de prioridad, sobre todos los dc:type del registro juntos
REGLAS = [
    ("Tesis de doctorado", r"doctoralthesis|doctor"),
    ("Tesis de maestría", r"masterthesis|maestr|master"),
    ("Tesis de licenciatura", r"bachelorthesis|licenci|bachelor|tesina"),
    ("Tesis de especialidad", r"especialidad|specialization"),
    ("Tesis (sin nivel)", r"thesis|tesis|dissertation|trabajo de grado"),
    ("Artículo", r"\barticle\b|articulo|journal"),
    ("Capítulo de libro", r"bookpart|capitulo|chapter"),
    ("Libro", r"\bbook\b|libro|monograf"),
    ("Ponencia o memoria", r"conferen|ponencia|congres|proceeding|memoria|lecture"),
    ("Reporte técnico o informe", r"report|informe|technicaldocumentation"),
    ("Preprint o documento de trabajo", r"preprint|workingpaper|documento de trabajo"),
    ("Reseña", r"review|resena"),
    ("Conjunto de datos", r"dataset|conjunto de datos"),
    ("Patente", r"patent"),
    ("Material didáctico o de divulgación", r"learningobject|didact|divulgac|educativ"),
    ("Imagen, mapa, audio o video", r"image|imagen|mapa|\bmap\b|audio|video|sound|fotogra|cartogra"),
    ("Software", r"software"),
    ("Carta o documento de archivo", r"\bcarta|correspond|manuscrito|expediente|documento de archivo|archival"),
    ("Evento", r"\bevent\b|evento"),
    ("Texto sin especificar", r"^(texto|text|info:eu-repo/semantics/other|other|otro)( \| .*)?$|\btexto\b"),
]
cuenta = collections.Counter(); repos = collections.defaultdict(set); ejemplos = collections.defaultdict(collections.Counter)
ft = collections.Counter(); porrepo = collections.defaultdict(collections.Counter)
for f in sorted(glob.glob("data/repos/*/metadata.jsonl")):
    repo = f.split("/")[2]
    conft = set()
    try:
        for l in open(f.replace("metadata.jsonl", "corpus.jsonl"), encoding="utf-8"):
            d = json.loads(l)
            if d.get("has_fulltext"): conft.add(d.get("id"))
    except FileNotFoundError: pass
    for l in open(f, encoding="utf-8", errors="replace"):
        try: d = json.loads(l)
        except Exception: continue
        ts = [sin(t) for t in TYPE.findall(d.get("xml") or "")]
        junto = " | ".join(ts)
        cat = next((n for n, p in REGLAS if re.search(p, junto)), "Otro" if ts else "Sin tipo")
        cuenta[cat] += 1; repos[cat].add(repo); porrepo[cat][repo] += 1
        if d.get("id") in conft: ft[cat] += 1
        if cat in ("Otro",) or True:
            for t in ts:
                if "info:eu-repo/semantics/" in t and t.split("/")[-1] in ("publishedversion","acceptedversion","submittedversion","draft","updatedversion"): continue
                ejemplos[cat][t[:50]] += 1
tot = sum(cuenta.values())
print("| Tipo | Registros | % | Con texto completo | Repositorios | Valores de `dc:type` más comunes |\n|---|---:|---:|---:|---:|---|")
for n, c in cuenta.most_common():
    ej = "; ".join(f"{k or '(vacío)'} ({v:,})" for k, v in ejemplos[n].most_common(3))
    print(f"| {n} | {c:,} | {100*c/tot:.1f} | {ft[n]:,} | {len(repos[n])} | {ej} |")
for n in ("Otro", "Sin tipo", "Carta o documento de archivo", "Evento", "Texto sin especificar", "Imagen, mapa, audio o video", "Conjunto de datos"):
    print("#", n, porrepo[n].most_common(5), ejemplos[n].most_common(6) if n == "Otro" else "")
print(f"| **Total** | **{tot:,}** | 100 | **{sum(ft.values()):,}** | | |")
