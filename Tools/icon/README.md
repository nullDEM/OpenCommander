# Ikona OpenCommander

Koncept **A — „Dwa panele”**, zaprojektowany z użyciem skilla [logo-design](https://github.com/kaankiziltug/logo-design-skill) (MIT).

- `a-final.svg` — znak (czerń, 256×256), `a-small.svg` — uproszczone cięcie na ≤32 px.
- `icon-1024.svg` / `icon-small.svg` — ikona aplikacji (kwadrat macOS 824/1024, gradient, cień).
- `build_icon.py` — generuje powyższe SVG (tylko biblioteka standardowa): `python3 -I build_icon.py`.

PNG w `OpenCommander/Assets.xcassets/AppIcon.appiconset` powstały przez renderowanie SVG w 1024 px
(Quick Look) i skalowanie w dół filtrem Lanczos; 16 i 32 px pochodzą z wersji uproszczonej.
Kolory: tło `#5B9BFF → #16278A`, panele białe (aktywny 97 %, nieaktywny 62 %), akcent `#FFB020`.
