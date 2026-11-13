# Credits and licences

Everything in the project is original except the third-party assets listed here.
Each one is free to use, including commercially, and each is recorded with its source.

## Workers: Quaternius (CC0 1.0, public domain)

| Asset | Author | Source | Licence | Used as |
| --- | --- | --- | --- | --- |
| Universal Base Characters (Standard) | Quaternius | https://quaternius.itch.io/universal-base-characters | CC0 1.0 | Body, head, eyes and eyebrows of the workers |
| Universal Animation Library (Standard) | Quaternius | https://quaternius.itch.io/universal-animation-library | CC0 1.0 | Idle, walk, push, pick-up and interact clips |

Downloaded on 2026-11-14 from the free tier of each itch.io listing. CC0 needs no credit; it is given here as thanks and for traceability. The licence texts that came with the packs are in `assets/characters/`.

### What was changed

`assets/characters/worker_*.glb` are derived from those packs by `tools/blender/build_worker.py` (Blender 5.3):
- the body was reduced from about 12,500 to about 3,000 triangles, then cut along clean planes (about 5,700 triangles in total);
- boots, trousers, shirt, gloves and a hi-vis vest with reflective bands were painted onto the body and pushed slightly off the skin, so the clothes read as baggy workwear; a bump cap was added (original geometry);
- to keep animation cheap, the 30 finger bones were folded into the hands (65 bones became 23), and the body, cap and eyes were merged into one mesh with one texture atlas (skin, eyes and flat colour swatches at 1,024 px). The eyebrows were dropped. The vest and cap form a second surface that the game recolours for each role;
- the library clips were attached to the same skeleton; `Carry_Loop`, `Carry_Idle_Loop` and `Cart_Push_Loop` were authored by replacing the arm tracks of `Walk_Loop` and `Idle_Loop` with a two-armed hold at the chest, or on a cart or pallet-jack handle.

To rebuild, download both packs, then:

```sh
UBC="<path>/Universal Base Characters[Standard]" \
UAL="<path>/Universal Animation Library[Standard]/Unreal-Godot/UAL1_Standard.glb" \
OUT=/tmp GENDER=male SKIN="" OUTFILE=assets/characters/worker_male_dark.glb \
/Applications/Blender.app/Contents/MacOS/Blender -b --python tools/blender/build_worker.py
```

`GENDER` is `male` or `female`; `SKIN` is `Dark`, `Light` (male: `Ligh`, as the pack names it) or empty for the pack's default.

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
