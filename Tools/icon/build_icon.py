"""Buduje finalny znak OpenCommander (koncept A: dwa panele) i ikonę aplikacji macOS jako SVG.
Tylko biblioteka standardowa. Użycie: python3 -I build_icon.py"""
import math

def rrect(x, y, w, h, r):
    return (f"M{x+r},{y} H{x+w-r} A{r},{r} 0 0 1 {x+w},{y+r} V{y+h-r} A{r},{r} 0 0 1 {x+w-r},{y+h} "
            f"H{x+r} A{r},{r} 0 0 1 {x},{y+h-r} V{y+r} A{r},{r} 0 0 1 {x+r},{y} Z")

def superellipse(x, y, w, h, n=5, steps=240):
    a, b, cx, cy = w / 2, h / 2, x + w / 2, y + h / 2
    pts = []
    for i in range(steps):
        t = i / steps * 2 * math.pi
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c) ** (2 / n), c), cy + b * math.copysign(abs(s) ** (2 / n), s)))
    return "M" + " L".join(f"{px:.1f},{py:.1f}" for px, py in pts) + " Z"

# --- geometria symbolu (siatka 256) -------------------------------------------------------
FULL = dict(
    left=[rrect(20, 36, 100, 184, 22), rrect(38, 68, 64, 16, 8), rrect(38, 172, 64, 16, 8),
          rrect(30, 104, 80, 48, 16)],                      # lewy: dwa wiersze + pasek zaznaczenia (jasne pole)
    pill=rrect(40, 120, 60, 16, 8),                         # zaznaczony wiersz w polu (akcent)
    right=[rrect(136, 36, 100, 184, 22), rrect(154, 76, 64, 16, 8), rrect(154, 112, 64, 16, 8), rrect(154, 148, 64, 16, 8)],
)
SMALL = dict(                                               # ≤32 px: mniej szczegółów, grubsze elementy
    left=[rrect(18, 34, 104, 188, 26), rrect(36, 66, 68, 30, 12), rrect(36, 116, 68, 30, 12) ],
    pill=rrect(36, 116, 68, 30, 12),
    right=[rrect(134, 34, 104, 188, 26), rrect(152, 66, 68, 30, 12), rrect(152, 116, 68, 30, 12), rrect(152, 166, 68, 30, 12)],
)
# w wersji małej środkowy wiersz lewego panelu jest pełny (akcent) — usuwamy go z otworów
SMALL["left"] = [SMALL["left"][0], SMALL["left"][1], rrect(36, 166, 68, 30, 12)]

def mono_symbol(g, title):
    d = " ".join(g["left"] + [g["pill"]] + g["right"])
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" role="img">\n  <title>{title}</title>\n'
            f'  <path fill="#000" fill-rule="evenodd" d="{d}"/>\n</svg>\n')

open("a-final.svg", "w").write(mono_symbol(FULL, "OpenCommander"))
open("a-small.svg", "w").write(mono_symbol(SMALL, "OpenCommander (małe rozmiary)"))

def icon(g, scale, shadow):
    body = superellipse(100, 100, 824, 824)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img">
  <title>OpenCommander – ikona aplikacji</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5B9BFF"/><stop offset="1" stop-color="#16278A"/>
    </linearGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0.22"/><stop offset="0.45" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <filter id="sh" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="{shadow[0]}" stdDeviation="{shadow[1]}" flood-color="#000" flood-opacity="0.38"/>
    </filter>
  </defs>
  <path d="{body}" fill="url(#bg)" filter="url(#sh)"/>
  <path d="{body}" fill="url(#gloss)"/>
  <g transform="translate(128 128) scale({scale})">
    <path fill="#fff" fill-opacity="0.97" fill-rule="evenodd" d="{' '.join(g['left'])}"/>
    <path fill="#FFB020" d="{g['pill']}"/>
    <path fill="#fff" fill-opacity="0.62" fill-rule="evenodd" d="{' '.join(g['right'])}"/>
  </g>
</svg>
'''
open("icon-1024.svg", "w").write(icon(FULL, 3.0, (14, 14)))
open("icon-small.svg", "w").write(icon(SMALL, 3.1, (8, 8)))
print("ok")
