"""Colores falsos y plano de las meta-disciplinas, para el mapa (indicación del usuario, 2026-11-27).

Proyecta los centros de las meta-disciplinas (metadisciplinas/centros.f32, Float32 de 1,024 × K por columnas, en el
orden de `orden_centros` de oficial.json) a sus tres primeras componentes principales. Cada componente, recortada a
sus percentiles 2 y 98 y llevada a [0, 1], es un canal: (R, G, B). Así las meta-disciplinas que se parecen tienen
colores parecidos y el mapa se ve como un gradiente. Las dos primeras componentes, en [-1, 1], son además el `plano`
de cada nodo: el mapa siembra ahí la simulación de fuerzas y la jala suavemente hacia él, de modo que el color y la
posición cuentan la misma historia.

Escribe `color` ("#rrggbb") y `plano` ([x, y]) en cada nodo de metadisciplinas/grafo.json (el resto no cambia).
Los canales van de 45 a 215 para que ningún color se pierda en el fondo claro ni en el oscuro.

Uso: python3 experiments/rag_web/colorea_metadisciplinas.py [metadisciplinas]
"""
import json
import sys
from pathlib import Path

import numpy as np

DIR = Path(sys.argv[1] if len(sys.argv) > 1 else "metadisciplinas")
LO, HI = 45, 215

oficial = json.loads((DIR / "oficial.json").read_text())
orden = oficial["orden_centros"]
C = np.fromfile(DIR / "centros.f32", dtype=np.float32).reshape(len(orden), -1).astype(np.float64)   # K × 1024
C /= np.linalg.norm(C, axis=1, keepdims=True)
X = C - C.mean(axis=0)
U, S, _ = np.linalg.svd(X, full_matrices=False)
P = U[:, :3] * S[:3]                          # K × 3
var = (S ** 2) / (S ** 2).sum()


def escala(v):
    a, b = np.percentile(v, [2, 98])
    return np.clip((v - a) / (b - a), 0, 1)


V = np.stack([escala(P[:, j]) for j in range(3)], axis=1)
rgb = np.rint(LO + (HI - LO) * V).astype(int)
plano = 2 * V[:, :2] - 1

por_clave = {c: i for i, c in enumerate(orden)}
grafo = json.loads((DIR / "grafo.json").read_text())
for n in grafo["nodos"]:
    i = por_clave[n["id"]]
    n["color"] = "#{:02x}{:02x}{:02x}".format(*rgb[i])
    n["plano"] = [round(float(plano[i, 0]), 4), round(float(plano[i, 1]), 4)]
(DIR / "grafo.json").write_text(json.dumps(grafo, ensure_ascii=False, indent=1) + "\n")
print(f"{len(grafo['nodos'])} nodos coloreados; varianza de las 3 componentes: "
      + ", ".join(f"{x:.3f}" for x in var[:3]))
