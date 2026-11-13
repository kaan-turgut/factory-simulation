# Credits and licences

Everything in the project is original except the third-party assets listed here.
Each one is free to use, including commercially, and each is recorded with its source.

## Carton artwork fonts: Google Fonts (SIL Open Font Licence 1.1)

The finished-good carton prints (`assets/cartons/*.png`) were drawn by `tools/cartons/build_cartons.py`. The brands (Crispella, Velvetto, Frostline, Xylo, Fruity Friends), logos and illustrations are original. The lettering uses these fonts, downloaded on 2026-11-14 from https://github.com/google/fonts (`ofl/`). The font files and their licence texts are in `tools/cartons/fonts/`. Only rendered pixels ship in the game; the fonts are not loaded at runtime.

| Font | Designer | Used for |
| --- | --- | --- |
| Pacifico | Vernon Adams | Crispella wordmark |
| Lobster | Pablo Impallari | Velvetto wordmark |
| Bebas Neue | Ryoichi Tsunekawa / Dharma Type | Frostline wordmark |
| Righteous | Astigmatic | Xylo wordmark |
| Fredoka | Milena Brandão | Fruity Friends wordmark |
| Oswald | Vernon Adams | Flavour names, pack counts, codes |

To rebuild the atlases after changing a design or a product's `package_color`: `python3 tools/cartons/build_cartons.py` (needs Pillow). New products need an entry in its `PRODUCTS` table, or the script stops.
