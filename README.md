# Chocolate Works

A playable 3D chocolate wafer factory built with **Godot 4.7.2** and GDScript. Run a shift, follow carts and workers around the hall, and change settings to see where the line backs up.

## Open and play

1. Install and open the standard edition of [Godot 4.7.2](https://godotengine.org/download/archive/4.7.2-stable/).
2. In Godot's Project Manager, choose **Import**, select this folder's `project.godot`, then choose **Import & Edit**.
3. Press **F5** or click **Run Project** in the upper-right corner of the editor. The factory opens paused.
4. Choose **20×** and open **ERP** in the bottom-right corner, or press **E**. Production starts with demand and a released order.
5. In **Material Requirements Planning**, click **Create demand**. The default is 13 dark-wafer shipping boxes due in 10 simulated minutes. Run MRP, enable **Proposals only**, and select and convert the **Planned production** row. Then convert the dark-coating **Purchase proposal**. You can see its due time in **Procurement**.
6. Click **Play shift** and let the purchase arrive. In **Production Orders**, select the order and click **Release**. The line starts at its planned start time when eligible. Close ERP to watch the shuttle, workers, oven, and forklift deliver the order. Select a colored pallet to see its SKU and order.
7. Select the FG warehouse or its dashboard card. **Dispatch one** or **Dispatch all** frees physical storage slots. Use **Save** in ChocoERP before stopping the game from the editor.

The game defaults to a 30 FPS rendering cap and redraws the view as needed. The simulation runs on fixed quarter-second ticks.

## Controls

| Input | Action |
| --- | --- |
| Left click on a station, worker, cart, palletizing bay, or forklift | Open its inspector |
| Left click a dashboard card | Inspect that station |
| Mouse wheel | Zoom |
| Right mouse drag | Orbit around the factory |
| Middle mouse drag | Pan |
| WASD or arrow keys | Move across the hall |
| Home view button or Home key | Restore the starting camera |
| Space | Play or pause |
| ERP laptop or E | Open ChocoERP |
| Esc while ERP is open | Return to the factory |
| Grid button or G | Show or hide the 1 m grid |
| Build Mode or B | Pause and open or close the layout editor |
| Left drag in Build Mode | Move equipment and release to place |
| R / Shift+R in Build Mode | Rotate clockwise / counterclockwise by 90° |
| Cmd+Z / Cmd+Shift+Z | Undo / redo a layout change on macOS. Use Ctrl on other systems. |
| Esc or × | Cancel placement or close the inspector |

Use an inspector slider, or type a number and press **Enter**. **Reset** pauses an ERP shift and applies crew and cart pool changes between orders. Documents and inventory are preserved. Product packaging comes from the order's frozen specification. The optional sandbox scene mode retains the original reset behavior.

## Using the factory grid

Hover over the floor or mezzanine to read the cell's X and Z coordinates and elevation. Select an object to see its occupied area. For fixed equipment, the solid outline marks the footprint and the dashed outline marks any additional operating clearance.

### Build Mode

1. Click **Build Mode** or press **B**. This pauses the shift and shows the grid, occupied footprints, and reserved aisles.
2. Select and drag a station. Release on a green preview to place it. A red preview explains what blocks placement. You can also click **Move** and then click a destination. **R** rotates clockwise, **Shift+R** rotates counterclockwise, and **Esc** cancels the preview.
3. Use **Undo** or **Redo** to revisit the last 32 confirmed edits. Click **Save Layout** to reuse the arrangement. **Load Layout** reads that file, and **Default** restores the master-data positions.
4. Exit with **B**, then press **Play** to resume.

The editor waits for active production and transport jobs to finish. An occupied finished-goods warehouse can move after dispatch. The extruder moves with the elevated hopper under the fixed mezzanine. Packaging, Packaging WIP, and palletizing move together to retain their connections. The raw warehouse, mezzanine structure, and parking bays are fixed.

Equipment can move along both floor axes. Workers, carts, and the supply shuttle can take short detours from their main aisles to reach docks. On the default floor plan, move **Coater 02** to **X 35, Z 24** to place it directly behind **Coater 01**.

**Save Layout** writes only IDs, grid cells, and orientations to `user://factory_layout.json`. On macOS this is `~/Library/Application Support/Godot/app_userdata/Chocolate Works/factory_layout.json`. A new shift uses the saved layout if it validates. An existing shift keeps its own placements unless there is a newer saved layout and the shift is safe to edit. Otherwise **Load Layout** can apply it once the shift is idle. The ERP **Save** button also includes the current placements in the operational save.

### Defining a floor plan

The origin is the building's front-left interior corner. Grid X increases to the right, grid Z increases toward the rear, and Y is elevation. Each cell is 1 × 1 m. The default grid is 88 × 32. Both ovens and both coaters sit on the production side of the cart aisle. Change `size` in the layout file or set the **Building Cells** override on the **Factory** scene root. Leave the override at zero to use the file. The supplied equipment plan requires at least 88 × 25 cells.

The definitions live in `master_data/factory_layout.json`. The example below has a 4 × 2 cell footprint, a height of 2.2 m, and a 90° orientation. Its rotated footprint occupies X cells 20–21 and Z cells 14–17.

```json
{
  "id": "Example", "kind": "machine",
  "cell": [20, 14], "size": [4, 2], "height": 2.2,
  "elevation": 0, "turns": 1, "clearance": [1, 2, 1, 0],
  "ports": { "outlet": [2, 1, 0] }, "movable": true
}
```

The example illustrates layout syntax. Actual work centers need an implemented machine and the ports required by their operation.

The clearance values are left, front, right, and rear in the object's unrotated orientation. Port offsets use local meters from the footprint center, with positive Z toward the rear. Both clearances and ports rotate with the object. To specify an elevated object, use the platform's elevation, such as `3.5`, and keep its footprint and clearance within the deck.

For conversion, `layout.grid.to_world(Vector2(20.5, 14.5))` returns the center of cell `(20, 14)` on the ground floor. `layout.grid.cell_at(world_position)` maps a world position back to its cell. Internally, rearward grid Z maps to negative Godot world Z. Workers and vehicles use continuous meter coordinates between connection points.

## ChocoERP

- **Materials and BOMs.** Five finished products ship with fictional demonstration recipes. The material master distinguishes kilograms from eaches, consumer packs from shipping boxes, and boxes from pallets. Master edits and hierarchical BOM edits affect new orders. Created orders retain their validated recipe and packaging snapshot. BOM explosion applies component scrap and rejects cycles. Executable recipes use the supplied mass-conserving wafer routing.
- **Orders and setup.** Release reserves all required external materials. Orders run by priority and planned start. Orders can overlap on separate ovens and coaters. The extruder finishes feeding one order before feeding the next, and packaging handles one SKU at a time. Each coater remembers its own last coating. Setup defaults for future releases are editable in **Production Orders**. The last oven batch and shipping pallet may be partial. Pending orders can cancel, and completed orders can close.
- **Purchasing and planning.** MRP uses unreserved stock, timed PO receipts, lot-for-lot proposals, supplier minimums, and safety stock. It flags a scheduled receipt that will arrive late and allocates it before suggesting more purchases. Make proposals create pending production orders. Buy proposals create timed purchases. Time and lead values are simulated.
- **Inventory and movements.** The raw warehouse owns raw balances. A timed supply shuttle carries stock to the mezzanine freight-lift point, both coaters, and the packing intake. Workers feed the mezzanine's ingredients into the line. WIP and FG stock reports read the physical buffers and pallets. The journal groups continuous flow postings into 15-second windows and records discrete receipts and dispatches individually.
- **Save and load.** The terminal saves one versioned local slot in Godot's user data directory. It restores paused, with stock, order and PO state, route progress, the movement journal, and station placements. Closing the game window saves automatically. Use the terminal's **Save** button before stopping an editor run.

## Alternative routings

Open **Production Versions** in ChocoERP and search for a SKU. **Routing Master** shows the operations in order. **Work Center Master** shows each station’s technical settings, supported coatings, and current commitment.

In **Production Orders**, select a version in the **Create order** form. The preview shows the station sequence, BOM, parameters, and possible conflicts. **Select version** changes a created order. **Show route** draws that order’s assigned route in the factory. Choose the same order again to clear its highlight.

| Routing | Batch oven | Coating |
| --- | --- | --- |
| WAFER-01 | Oven 01 | Coater 01 |
| WAFER-02 | Oven 02 | Coater 02 |
| WAFER-03 | Oven 01 | Coater 02 |
| WAFER-04 | Oven 02 | Coater 01 |

Coater 02 supports milk, dark, and white coatings. All four routes share the extruder, packer, crew, carts, forklift, and finished-goods warehouse. The scheduler commits the oven and coater pair to an order through warehouse delivery and cart cleanup. Disjoint pairs can overlap after the extruder finishes feeding the older order. Shared work and the order’s own bounded stock buffers can delay delivery beyond the processing estimate.

## Editing master data

- `materials.json`, `products.json`, and `boms.json` define the material IDs, product specs, opening balances, and multilevel recipes. Carton mass and pallet mass derive from product specs.
- `routings.json` lists operation numbers and work center references. `work_centers.json` holds equipment IDs, eligibility, availability, and technical settings. `production_versions.json` ties each SKU to a BOM version and routing version with lot and date limits. Dates are simulated seconds from shift start. A zero `valid_to` means open-ended.
- `factory_layout.json` contains positions, footprints, ports, and the packaging WIP receiving bay. `storage_locations.json`, `suppliers.json`, and `simulation_defaults.json` contain locations, supplier offers, and operating defaults.

Keep existing identifiers stable. To add an alternative, add a routing using supported operations and existing centers. Add a production version with the matching routing and BOM version numbers. Restart after editing. A validation error reports the offending file and, where available, the record and field.

Saved shifts preserve their active catalog and layout along with frozen orders. Older saves open in the enlarged hall. Cart and vehicle jobs are replanned from safe positions, and any coated stock left on the former conveyors is recovered into the same order’s coater outfeed. Phase 3 saves keep their original Oven 01 and Coater 01 assignments. Start a fresh shift to use edited files while keeping the saved shift available. From the project directory, run:

```sh
godot --path . -- --fresh-shift
```

This starts from the current JSON and disables automatic save on close for that session. ChocoERP’s **Save** button writes to the same slot. Exported builds can load a complete editable `master_data` folder beside the executable or macOS app bundle. Include `master_data/*.json` in Godot’s export filters to ship the built-in files.

## How the factory works

| Stage | What happens |
| --- | --- |
| Ingredients and extrusion | Two mezzanine workers reserve hopper room, collect staged recipe ingredients as sacks, unload, and walk back. The extruder uses hopper stock and fills the cart at its output. A full cart waits for a worker and a free oven berth. |
| Raw carts and oven | Floor workers push carts along the marked aisle. The selected oven starts at batch capacity or when the final partial batch is ready. It uses the released order’s frozen cooking time. Excess raw wafers stay on their cart for a later batch. |
| Cooked carts and coating | A worker unloads the oven into a cooked tray. If the cart is smaller than the batch, another trip is required. At coating, a cart can unload as much as fits and wait with the remainder. Empty carts return for reuse. |
| Coated wafer delivery | Floor workers load purple tray carts at the coaters and push them to the **Packaging WIP** bay in front of the packer. Carts wait or unload partially when the bay is full. The shared bay holds stock for the order currently assigned to packaging. |
| Packaging and pallets | The packer draws from the WIP bay. A box appears once its configured mass is reached, then the carton conveyor carries output to the palletizing bays. A box or pallet already started retains its original target after an edit. |
| Forklift and warehouse | The forklift reserves an open storage slot before leaving for a full pallet. It takes time to drive, pick up, and unload. Warehouse capacity controls how many of the marked slots can be used. Warehouse and palletizing space eventually limit upstream production. |

The default floor crew has two workers, two raw carts, and two cooked carts. Raw carts hold 50 kg and cooked carts hold 45 kg. Oven 01 starts at 75 kg and 36 seconds per batch. Oven 02 starts at 60 kg and 42 seconds per batch. The warehouse starts with space for four pallets. Carton and pallet sizes vary by SKU. Two coated carts start at 24 kg each, and Packaging WIP starts at 60 kg. Select **Packaging WIP** to change capacity, inspect its receiving dock, or open the **PACK-WIP** inventory in ChocoERP.

Rates are in kilograms per simulated hour. The engine advances in fixed quarter-second ticks, including travel and handling. Ingredient supply comes from opening stock and purchasing. Baking preserves mass and coating adds the actual chocolate consumed. The mass ledger includes material in sacks being carried, every buffer and cart, the oven, partial cartons, pallets on the floor and forklift, and dispatched stock.

Capacity reductions must cover current stock and any incoming reservations. An oven batch's capacity is locked through cooking and unloading. Movement speeds can change during a shift. Technical settings on an idle work center apply to future releases. Released orders keep the parameters they reserved. The forklift uses marked waypoints, and cart moves reserve the shared aisle one at a time. People use fixed pedestrian approaches and can pass one another.

## Project structure

| Path | Responsibility |
| --- | --- |
| `scenes/factory.tscn`, `scenes/factory.gd` | F5 entry point and coordination |
| `layout/` | Meter grid, station definitions, connection points, and placement validation |
| `simulation/` | Clock, physical buffers, worker and forklift tasks |
| `erp/` | Catalog, validation, reservations, inventory ledger, orders, MRP, and snapshots |
| `master_data/` | Editable JSON master definitions and initial floor plan |
| `world/` | Primitive models, motion interpolation, camera, and picking |
| `ui/` | ChocoERP, overview, transport controls, and context-sensitive inspector |
| `tests/` | Simulation scenarios and scene interaction checks |

## Validate the project

Run these commands from the project folder with the Godot executable on your PATH.

```sh
godot --headless --path . --editor --import
godot --headless --path . --script res://tests/factory_grid_test.gd
godot --headless --path . --script res://tests/production_line_test.gd
godot --headless --path . --script res://tests/factory_scene_test.gd
godot --headless --path . --script res://tests/erp_integration_test.gd
godot --headless --path . --script res://tests/erp_scene_test.gd
godot --headless --path . --script res://tests/routing_integration_test.gd
godot --headless --path . --script res://tests/layout_editor_test.gd
```

On macOS, if Godot is installed in Applications, replace `godot` with `/Applications/Godot.app/Contents/MacOS/Godot`.
