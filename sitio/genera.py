# Las tablas y cifras del sitio, calculadas del corpus (data/repos/*/corpus.jsonl e info.json) y de las
# meta-disciplinas oficiales (metadisciplinas/). Escribe sitio/_tablas/*.md y cifras.json, y copia el grafo del mapa
# a sitio/mapa/grafo.json. Todo eso va en git: el sitio se arma sin los datos (quarto render sitio).
# Uso (desde la raíz): python3 sitio/genera.py
import json, glob, collections, os, shutil, statistics
NO = {"Carta o documento de archivo", "Imagen, mapa, audio o video", "Evento", "Conjunto de datos"}
miles = lambda n: f"{n:,}"
pct = lambda a, b: f"{100 * a / b:.0f} %" if b else "–"

por_repo = {}
tipos = collections.Counter(); tipos_ft = collections.Counter()
tot = dict(registros=0, resumen=0, texto=0, citas=0, cti=0, disciplina=0, palabras=0, texto_academico=0)
for f in sorted(glob.glob("data/repos/*/corpus.jsonl")):
    repo = f.split("/")[2]
    c = collections.Counter(); pub = collections.Counter()
    for l in open(f, encoding="utf-8"):
        d = json.loads(l)
        t = d.get("type") or "Sin tipo"
        c["registros"] += 1; tipos[t] += 1
        c["resumen"] += bool((d.get("description") or "").strip())
        ft = bool(d.get("has_fulltext")); c["texto"] += ft; tipos_ft[t] += ft
        c["citas"] += int(d.get("reference_count") or len(d.get("references") or []))
        c["cti"] += bool(d.get("areas")); c["disciplina"] += bool(d.get("disciplinas"))
        c["palabras"] += bool(d.get("keywords"))
        c["texto_academico"] += t not in NO
        p = (d.get("publisher") or "").split(";")[0].strip()
        if p: pub[p] += 1
    if not c["registros"]: continue
    info = {}
    try: info = json.load(open(f.replace("corpus.jsonl", "info.json")))
    except Exception: pass
    por_repo[repo] = dict(c, institucion=pub.most_common(1)[0][0] if pub else "", cosecha=str(info.get("last_harvest", ""))[:10])
    for k in tot: tot[k] += c[k]

g = json.load(open("metadisciplinas/oficial.json"))
cifras = dict(tot, repositorios=len(por_repo), metadisciplinas=len(g["grupos"]),
              autores_crudos=447279, autores_consolidados=234624,           # docs/plan-rag-web.md, inventario (RocksDB)
              partes_densas=701588, documentos_densos=329717)               # data/index/dense/proyecto.json
json.dump(cifras, open("sitio/_tablas/cifras.json", "w"), indent=1)

with open("sitio/_tablas/repositorios.md", "w") as io:
    io.write("| Repositorio | Institución (editor más frecuente) | Registros | Con texto completo | Con CTI | Con palabras clave | Última cosecha |\n")
    io.write("|---|---|---:|---:|---:|---:|---|\n")
    for repo, c in sorted(por_repo.items(), key=lambda x: -x[1]["registros"]):
        io.write(f"| `{repo}` | {c['institucion'][:70]} | {miles(c['registros'])} | {miles(c['texto'])} | {pct(c['cti'], c['registros'])} | "
                 f"{pct(c['palabras'], c['registros'])} | {c['cosecha']} |\n")

with open("sitio/_tablas/tipos.md", "w") as io:
    io.write("| Tipo | Registros | % | Con texto completo | En la búsqueda por significado |\n|---|---:|---:|---:|:---:|\n")
    for t, n in tipos.most_common():
        io.write(f"| {t} | {miles(n)} | {100 * n / tot['registros']:.1f} | {miles(tipos_ft[t])} | {'no (sólo metadatos)' if t in NO else 'sí'} |\n")

with open("sitio/_tablas/metadisciplinas.md", "w") as io:
    io.write("| Meta-disciplina | En inglés | Documentos | Palabras más representativas |\n|---|---|---:|---|\n")
    for x in sorted(g["grupos"], key=lambda x: -x["documentos"]):
        io.write(f"| {x['nombre']} | {x.get('nombre_en', '')} | {miles(x['documentos'])} | {' · '.join(x['palabras'][:6])} |\n")

shutil.copy("metadisciplinas/grafo.json", "sitio/mapa/grafo.json")
print(json.dumps(cifras, indent=1))
