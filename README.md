# Chocolate Works

A playable 3D chocolate wafer factory built with **Godot 4.7.2** and GDScript. Run a shift, follow carts and workers around the hall, and change settings to see where the line backs up.

## Open and play

1. Install and open the standard edition of [Godot 4.7.2](https://godotengine.org/download/archive/4.7.2-stable/).
2. In Godot's Project Manager, choose **Import**, select this folder's `project.godot`, then choose **Import & Edit**.
3. Press **F5** or click **Run Project** in the upper-right corner of the editor. The factory opens paused.
4. Choose **20×** and open **ERP** in the bottom-right corner, or press **E**. In **Material Requirements Planning**, choose **Create demand**. For a first run, use **FG-1001**, **10 shipping boxes**, and a due time **40 simulated minutes** ahead.
5. Run MRP and enable **Proposals only**. Select each **Production proposal** and choose **Convert proposal**. Accept or edit its quantity, version, and start. This puts a planned order on **Detailed Scheduling**. Return to MRP for the next proposal. If ingredients are short, convert the relevant purchase proposal and wait for the receipt in **Procurement**.
6. Release orders as their components arrive. The sequence is **DOUGH-01** → **RAW-01** → **BAKED-01** → **COATED-1001** → **FG-1001**. Release dough first and click **Play shift**. Once dough has been received at the deck, release raw wafers. Continue with the other orders as their input stock arrives. A released order waits for its scheduled start. To automate release, turn on **Auto Release** in the ChocoERP header and play the shift.
7. Close ERP to follow the crew and carts. A forklift receipt puts the finished pallets in the warehouse. Select a pallet to see its SKU and order. **Dispatch one** and **Dispatch all** free warehouse slots. Use **Save** in ChocoERP before stopping a run from the editor.

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

The editor waits for active production and transport jobs to finish. An occupied finished-goods warehouse can move after dispatch. The extruder moves with the elevated hopper under the fixed mezzanine. Packaging, Packaging WIP, and palletizing move together to retain their connections. The raw and wafer stock warehouses, mezzanine structure, and parking bays are fixed.

Equipment can move along both floor axes. Workers, carts, and the supply shuttle can take short detours from their main aisles to reach docks. On the default floor plan, move **Coater 02** to **X 35, Z 24** to place it directly behind **Coater 01**.

**Save Layout** writes only IDs, grid cells, and orientations to `user://factory_layout.json`. On macOS this is `~/Library/Application Support/Godot/app_userdata/Chocolate Works/factory_layout.json`. A new shift uses the saved layout if it validates. An existing shift keeps its own placements unless there is a newer saved layout and the shift is safe to edit. Otherwise **Load Layout** can apply it once the shift is idle. The ERP **Save** button also includes the current placements in the operational save.

### Defining a floor plan

The origin is the building's front-left interior corner. Grid X increases to the right, grid Z increases toward the rear, and Y is elevation. Each cell is 1 × 1 m. The default grid is 88 × 32. Both ovens and both coaters sit on the production side of the cart aisle. Change `size` in the layout file or set the **Building Cells** override on the **Factory** scene root. Leave the override at zero to use the file. The supplied equipment plan requires at least 88 × 29 cells.

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

- **Materials and BOMs.** Five finished products ship with fictional demonstration recipes. The material master distinguishes kilograms from eaches, consumer packs from shipping boxes, and boxes from pallets. Hierarchical BOM edits affect future planning. Executable stage BOMs must fit the physical process and preserve food mass.
- **Production Orders.** Select a manufactured material, quantity, work center, and simulated start. Use kilograms for dough and wafer stock, and shipping boxes for finished goods. **Check stock** lists immediate component shortages. **Component inventory** opens the relevant stock report. **Peg supply** links an upstream order to a downstream BOM requirement. **Supply orders** opens the linked documents. Release checks physical stock and freezes the route, BOM, and technical parameters. Released orders can be cancelled before commitment. Completed orders can close.
- **MRP.** Planning nets unreserved stock, purchase receipts, and scheduled stage output. It creates dated proposals for missing material at each BOM level, applies supplier minimums and safety stock, and flags late receipts and proposal dates. A converted make proposal is a planned order. Convert or release proposals explicitly. Scheduled receipts and pegging appear in planning while physical receipts determine release eligibility.
- **Inventory.** The timed shuttle carries purchased supplies from **RM-WH**. Prepared dough is received into **SFG-DECK**. Workers move raw, baked, and coated wafers through **SFG-WH** by cart. The inventory report also shows controlled **WIP**, the packaging bay, and **FG-WH**. Goods movements link stock issues and receipts to their orders.
- **Save and load.** ChocoERP saves the active catalog, schedules, release snapshots, actual progress, stock, reservations, pegging, in-flight logistics, purchases, and journal. Loads open paused. Closing the game window saves automatically. Use the terminal's **Save** before stopping an editor run.

**Auto Release** is off by default and saved with the shift. When it is on, the running shift releases planned orders once their immediate BOM components are physically available and unreserved. Eligible orders are considered by scheduled start, then priority. MRP proposals must still be converted into orders, and a released order waits for its scheduled start.

### Detailed Scheduling

- Each row represents a work center from the master data. The timeline uses simulated factory days. Choose the scale, scroll, or click **Jump to now**. The horizontal scrollbar or **Shift + mouse wheel** moves through time. Use the vertical scrollbar or regular wheel to move through machines.
- Filter by material or order, work center, status, and day or day range. Select a bar for the order summary, or double-click it for the order details. The thin strip under a bar shows actual start and progress. The red line shows current simulation time. A selected order draws dependency lines to visible pegged orders.
- Drag a planned bar horizontally to set its start. Drag it to another eligible row to select that machine. Green previews can be placed. Red previews show a calendar, capacity, or eligibility conflict. Released assignments stay frozen.
- A new order is scheduled in the first slot that fits on the selected center. Rescheduling an existing order requires an open interval. Estimates include machine rates, oven batch cycles, a handling allowance, and setup allowance. Actual progress also depends on the shuttle, crew, carts, and forklift. **Reports and Analytics** includes a schedule-adherence view with scheduled workload, actual times, wait times, and late orders.

### Alternatives and shared resources

Choose Oven 01 or Oven 02 for baking. Choose an eligible coater for a coated wafer material. Coater 02 supports milk, dark, and white. The prep station and extruder share the staging crew. The two ovens and the two coaters can work on separate orders concurrently, with each order retaining its own carts and buffers. One stock dock and the main cart aisle are shared.

**Routing Master** lists stage assignments alongside the WAFER-01 through WAFER-04 templates. Current orders execute a single stage with a selected work center and frozen parameters. **Production Versions** lists SFG alternatives alongside the existing finished-SKU versions. Finished-goods production uses the packaging operation and version's lot and date limits. **Show route** highlights the selected order’s assigned equipment.

## Editing master data

- `materials.json`, `products.json`, and `boms.json` define the material IDs, product specs, opening balances, and multilevel recipes. Carton mass and pallet mass derive from product specs. The finished BOMs use a 5 kg base with one carton, one label, and one-eighth of a pallet.
- `routings.json` lists operation numbers and work center references. `work_centers.json` holds equipment IDs, eligibility, availability, and technical settings. `production_versions.json` ties each SKU to a BOM version and routing version with lot and date limits. Dates are simulated seconds from shift start. A zero `valid_to` means open-ended.
- `scheduling.json` defines stage-to-material and work-center eligibility, handling estimates, and simulated daily availability intervals. The shipped calendar is 24/7.
- `factory_layout.json` contains positions, footprints, ports, and the packaging WIP receiving bay. `storage_locations.json`, `suppliers.json`, and `simulation_defaults.json` contain locations, supplier offers, and operating defaults.

Keep existing identifiers stable. To add an alternative, add a routing using supported operations and existing centers. Add a production version with the matching routing and BOM version numbers. Restart after editing. A validation error reports the offending file and, where available, the record and field.

Saved shifts preserve their active catalog and layout along with frozen orders. On first load, older shifts update the original demo packaging sizes and BOMs while keeping custom sizes, frozen orders, and physical stock. Re-select the production version on an older draft order to use the new quantities. Older saves open in the enlarged hall. Cart and vehicle jobs are replanned from safe positions, and any coated stock left on the former conveyors is recovered into the same order’s coater outfeed. Orders already in progress from an earlier combined-route save can finish on their original assignments. Older created or released combined-route orders are held with their reservations and can be cancelled before re-planning as individual stages. Start a fresh shift to use edited files while keeping the saved shift available. From the project directory, run:

```sh
godot --path . -- --fresh-shift
```

This starts from the current JSON and disables automatic save on close for that session. ChocoERP’s **Save** button writes to the same slot. Exported builds can load a complete editable `master_data` folder beside the executable or macOS app bundle. Include `master_data/*.json` in Godot’s export filters to ship the built-in files.

## How the factory works

| Stage | What happens |
| --- | --- |
| Dough preparation | The supply shuttle replenishes recipe ingredients. Two mezzanine workers collect sacks and deposit the prepared blend into stock at the deck. |
| Raw wafer extrusion | The platform crew feeds reserved dough into the hopper. The extruder fills raw carts up to the order target. Floor workers carry them to the wafer stock dock for receipt. |
| Baking | Workers load reserved raw wafers at the stock dock and push the carts to the assigned oven. Full batches and the final partial batch use the frozen cooking duration. A cooked cart returns the output to stock. |
| Coating | Workers deliver baked wafers from the stock dock to the selected coater. The shuttle delivers coating ingredients. Workers collect the coated wafers in purple tray carts for receipt back into stock. |
| Packaging and pallets | Workers deliver reserved coated stock to **Packaging WIP**. The packer forms boxes and palletizes them. A final partial pallet may be sealed and dispatched to the warehouse. |
| Forklift and warehouse | The forklift reserves an open storage slot, drives to the pallet, picks it up, and unloads. The warehouse receipt completes the finished order. Full storage delays the order and may block packaging. |

The default floor crew has two workers, two raw carts, and two cooked carts. Raw carts hold 50 kg and cooked carts hold 45 kg. Oven 01 starts at 75 kg and 36 seconds per batch. Oven 02 starts at 60 kg and 42 seconds per batch. The warehouse starts with space for four pallets. All five wafer flavors use 100 g consumer packs, 50 packs per 5 kg shipping box, and eight boxes per 40 kg full pallet. Two coated carts start at 24 kg each, and Packaging WIP starts at 60 kg. Select **Packaging WIP** to change capacity, inspect its receiving dock, or open the **PACK-WIP** inventory in ChocoERP.

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
godot --headless --path . --editor --import --quit
godot --headless --path . --script res://tests/factory_grid_test.gd
godot --headless --path . --script res://tests/production_line_test.gd
godot --headless --path . --script res://tests/factory_scene_test.gd
godot --headless --path . --script res://tests/erp_integration_test.gd
godot --headless --path . --script res://tests/erp_scene_test.gd
godot --headless --path . --script res://tests/routing_integration_test.gd
godot --headless --path . --script res://tests/layout_editor_test.gd
godot --headless --path . --script res://tests/detailed_scheduling_test.gd
```

On macOS, if Godot is installed in Applications, replace `godot` with `/Applications/Godot.app/Contents/MacOS/Godot`.
