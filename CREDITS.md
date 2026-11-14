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

## Safety props and water cooler: Poly Pizza (CC-BY 3.0 and CC0 1.0)

Downloaded on 2026-11-14 from https://poly.pizza. The CC-BY 3.0 models (https://creativecommons.org/licenses/by/3.0/) need this credit; the CC0 ones are credited as thanks.

| Asset | Author | Source | Licence | Used as |
| --- | --- | --- | --- | --- |
| Fire Extinguisher | Jarlan Perez | https://poly.pizza/m/71rR7PaeXNN | CC-BY 3.0 | `assets/props/fire_extinguisher.glb`: fire points and wall safety boards |
| Water Cooler | J-Toastie | https://poly.pizza/m/zWi9p5FSxD | CC-BY 3.0 | `assets/props/water_cooler.glb`: canteen and production hall |
| Fire Exit Sign | J-Toastie | https://poly.pizza/m/gpft2tHZv4 | CC-BY 3.0 | `assets/props/exit_sign.glb`: lit exit signs on the walls |
| Wet Floor Sign | J-Toastie | https://poly.pizza/m/it0AE63TMj | CC-BY 3.0 | `assets/props/wet_floor_sign.glb`: beside hand-wash stations |
| Fire alarm | Poly by Google | https://poly.pizza/m/8C_V3PSD5sw | CC-BY 3.0 | `assets/props/fire_alarm.glb`: manual call points |
| First Aid Kit | Quaternius | https://poly.pizza/m/Hp80p6148W | CC0 1.0 | `assets/props/first_aid_kit.glb`: wall safety boards |
| Traffic Cone | Quaternius | https://poly.pizza/m/lAx8JytxGD | CC0 1.0 | `assets/props/traffic_cone.glb`: forklift charging bay |

### What was changed

`tools/blender/build_safety_props.py` (Blender 5.3) joins each model into one mesh, scales it to real size (extinguisher 0.62 m, water cooler 1.32 m, exit sign 0.42 m wide, call point 0.20 m, first-aid case 0.42 m, wet-floor sign 0.62 m, cone 0.5 m), turns its front to +Z, moves the origin to the base (or the back face for wall items) and shrinks textures to 256 px. Geometry and colours are otherwise as published. To rebuild, download the files above into one folder under the names in the script's `PROPS` table, then:

```sh
SRC=<folder> /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python tools/blender/build_safety_props.py
```

## Factory grounds: vehicles and plants from Poly Pizza (CC0 1.0 and CC-BY 3.0)

Downloaded on 2026-11-14 from https://poly.pizza. The CC-BY 3.0 models need this credit; the CC0 ones are credited as thanks.

| Asset | Author | Source | Licence | Used as |
| --- | --- | --- | --- | --- |
| Car (sedan) | Quaternius | https://poly.pizza/m/Cz6yDaUcM9 | CC0 1.0 | `assets/site/car_sedan.glb` |
| Car (hatchback) | Quaternius | https://poly.pizza/m/unqqkULtRU | CC0 1.0 | `assets/site/car_hatchback.glb` |
| SUV | Quaternius | https://poly.pizza/m/xsMtZhBkxL | CC0 1.0 | `assets/site/car_suv.glb` |
| Sports Car | Quaternius | https://poly.pizza/m/1mkmFkAz5v | CC0 1.0 | `assets/site/car_sports.glb` |
| Pickup Truck | Quaternius | https://poly.pizza/m/qn4grQgHm8 | CC0 1.0 | `assets/site/pickup.glb` |
| Generic Van | PuKkBuMXDD | https://poly.pizza/m/BbRojf2v3H | CC-BY 3.0 | `assets/site/van.glb` |
| Cargo Truck | J-Toastie | https://poly.pizza/m/Fy3WI3uXNQ | CC-BY 3.0 | `assets/site/box_truck.glb`, and its cab as `assets/site/tractor_unit.glb` |
| Trees | Quaternius | https://poly.pizza/m/etFGNvsiFv | CC0 1.0 | `assets/site/tree_oak_a/b/c.glb` |
| Birch Trees | Quaternius | https://poly.pizza/m/R7qMWzb7nk | CC0 1.0 | `assets/site/tree_birch_a/b.glb` |
| Pine | Quaternius | https://poly.pizza/m/79gmlLnweB | CC0 1.0 | `assets/site/tree_pine.glb` |
| Bush | Quaternius | https://poly.pizza/m/ooG6CkLyE8 | CC0 1.0 | `assets/site/bush.glb` |
| Bush with Flowers | Quaternius | https://poly.pizza/m/U1ymDy8tbY | CC0 1.0 | `assets/site/bush_flowers.glb` |
| Flowers | Quaternius | https://poly.pizza/m/NBUxHir6FJ | CC0 1.0 | `assets/site/flowers_a/b.glb` |
| Flower Group | Quaternius | https://poly.pizza/m/hfPzQAedOe | CC0 1.0 | `assets/site/flower_group.glb` |
| Bench | Quaternius | https://poly.pizza/m/jLxjFxFRpw | CC0 1.0 | `assets/site/bench.glb` |
| Street Light | Quaternius | https://poly.pizza/m/nFwrlcLvM5 | CC0 1.0 | `assets/site/street_light.glb` |

### What was changed

`tools/blender/build_site_props.py` (Blender 5.3) joins each model into one mesh, scales it to real size, turns vehicles so their headlights face +Z, moves the origin to the base centre and shrinks textures to 512 px. Each vehicle's body paint is renamed `<name>_paint` so the game can recolour it. The tractor unit is the Cargo Truck's cab and chassis without the box. Trees are thinned (bark decimated, a share of leaf cards removed and the rest enlarged) from 4,500–8,500 to about 1,000–1,900 triangles. The semi-trailers, gatehouse, barriers, fence and markings are original and built in code (`world/grounds_models.gd`). To rebuild, download the files above into one folder named by their Poly Pizza id (for example `Cz6yDaUcM9.glb`), then:

```sh
SRC=<folder> /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python tools/blender/build_site_props.py
```
