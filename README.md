# Chocolate Works

A playable 3D chocolate wafer factory built with **Godot 4.7.2** and GDScript. Run a shift, follow carts and workers around the hall, and change settings to see where the line backs up.

## Open and play

1. Install and open the standard edition of [Godot 4.7.2](https://godotengine.org/download/archive/4.7.2-stable/).
2. In Godot's Project Manager, choose **Import**, select this folder's `project.godot`, then choose **Import & Edit**.
3. Press **F5** or click **Run Project** in the upper-right corner of the editor. The factory opens paused.
4. Choose **20×** and open **ERP** in the bottom-right corner, or press **E**. In **Material Requirements Planning**, choose **Create demand**. For a first run, use **FG-1001**, **10 shipping boxes**, and a due time **one simulated hour** ahead.
5. Run MRP and enable **Proposals only**. Select each **Production proposal** and choose **Convert proposal**. Accept or edit its quantity, version, and start. This puts a planned order on **Detailed Scheduling**. Return to MRP for the next proposal. If ingredients are short, convert the relevant purchase proposal and wait for the receipt in **Procurement**.
6. Release orders as their components arrive. The sequence is **DOUGH-01** → **RAW-01** → **BAKED-01** → **COATED-1001** → **COOLED-1001** → **FG-1001**. Release dough first and click **Play shift**. Once dough has been received at the deck, release raw wafers. Continue with the other orders as their input stock arrives. A released order waits for its scheduled start. To automate release, turn on **Auto Release** in the ChocoERP header and play the shift.
7. Close ERP to follow the crew and carts. A forklift receipt puts the finished pallets in the warehouse. Select a pallet to see its SKU and order. **Dispatch one** and **Dispatch all** free warehouse slots. Use **Save** in ChocoERP before stopping a run from the editor.

The game defaults to a 30 FPS rendering cap and redraws the view as needed. The simulation runs on fixed quarter-second ticks.

Zoom in on the cream spreader, wafer cutter, cooling tunnel, and packaging lines to see their rollers, cutting head, fans, and sealing equipment move during production. The raw-material room is in the rear-left corner and measures 31 × 35 m. The finished-goods room is in the rear-right corner and measures 32 × 35 m. Both have 6 m racks and a front shutter that opens for approaching traffic. A dedicated material handler uses a manual pallet jack to bring supplies from the raw-material room to the stations. Ingredient sacks and packaging cartons appear on the jack while their shipment is in transit. The forklift follows the marked right-hand lane to one of 24 ground-level pallet positions. Capacity is fixed by the rack layout, and the upper tiers are visual.

## Controls

| Input | Action |
| --- | --- |
| Left click on a station, worker, cart, palletizing bay, or forklift | Open its inspector |
| Left click a dashboard card | Inspect that station |
| **Z** / **X** keys or **+** / **−** buttons next to **Home view** | Zoom in or out |
| Trackpad pinch or mouse wheel | Zoom over the factory view |
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

Use an inspector slider, or type a number and press **Enter**. The factory starts with four floor workers. Older shifts using the original two-worker setting gain two workers when loaded. **Reset** pauses an ERP shift and applies crew and cart pool changes between orders. Documents and inventory are preserved. Product packaging comes from the order's frozen specification. The optional sandbox scene mode retains the original reset behavior.

## Using the factory grid

Hover over the floor or mezzanine to read the cell's X and Z coordinates and elevation. Select an object to see its occupied area. For fixed equipment, the solid outline marks the footprint and the dashed outline marks any additional operating clearance.

### Build Mode

1. Click **Build Mode** or press **B**. This pauses the shift and shows the grid, occupied footprints, and reserved aisles.
2. Select and drag a station. Release on a green preview to place it. A red preview explains what blocks placement. You can also click **Move** and then click a destination. **R** rotates clockwise, **Shift+R** rotates counterclockwise, and **Esc** cancels the preview.
3. Use **Undo** or **Redo** to revisit the last 32 confirmed edits. Click **Save Layout** to reuse the arrangement. **Load Layout** reads that file, and **Default** restores the master-data positions.
4. Exit with **B**, then press **Play** to resume.

The editor waits for active production and transport jobs to finish. An occupied finished-goods warehouse can move after dispatch. The extruder moves with the elevated hopper under the fixed mezzanine. Packaging, Packaging WIP, and palletizing move together to retain their connections. The raw and wafer stock warehouses, mezzanine structure, and parking bays are fixed.

Equipment can move along both floor axes. Workers, tray carts, and the material handler can take short detours from their main aisles to reach docks. On the default floor plan, move **Coater 02** to **X 35, Z 24** to place it directly behind **Coater 01**.

**Save Layout** writes only IDs, grid cells, and orientations to `user://factory_layout.json`. On macOS this is `~/Library/Application Support/Godot/app_userdata/Chocolate Works/factory_layout.json`. A new shift uses the saved layout if it validates. An existing shift keeps its own placements unless there is a newer saved layout and the shift is safe to edit. Otherwise **Load Layout** can apply it once the shift is idle. The ERP **Save** button also includes the current placements in the operational save.

### Defining a floor plan

The origin is the building's front-left interior corner. Grid X increases to the right, grid Z increases toward the rear, and Y is elevation. Each cell is 1 × 1 m. The default factory is 120 m wide by 100 m deep. Both ovens and both coaters sit on the production side of the cart aisle. Change `size` in the layout file or set the **Building Cells** override on the **Factory** scene root. Leave the override at zero to use the file. The warehouse anchors follow the rear wall when a building size override is used, and the layout validator checks the resulting transport routes.

Older shifts load into the rear-warehouse plan when the rooms and routes fit alongside their saved equipment. Existing pallets keep their slot numbers and the material handler and forklift resume their tasks against the new docks. A customized layout that conflicts with the new rooms keeps its previous layout.

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

- **Materials and BOMs.** Seventeen finished products ship with fictional demonstration recipes across classic coated wafers, filled wafers and chewing gum. The material master distinguishes kilograms from eaches, consumer packs from shipping boxes, and boxes from pallets. Hierarchical BOM edits affect future planning. Executable stage BOMs must fit the physical process and preserve food mass.
- **Production Orders.** Select a manufactured material, quantity, work center, and simulated start. Use kilograms for dough and wafer stock, and shipping boxes for finished goods. **Check stock** lists immediate component shortages. **Component inventory** opens the relevant stock report. **Peg supply** links an upstream order to a downstream BOM requirement. **Supply orders** opens the linked documents. Release checks physical stock and freezes the route, BOM, and technical parameters. Released orders can be cancelled before commitment. Completed orders can close.
- **MRP.** Planning nets unreserved stock, purchase receipts, scheduled stage output and firmed planned orders level by level. It creates numbered planned orders (**PLO-…**) for manufactured material and purchase requisitions for bought material, then flags exceptions. See *MRP workspace* below.
- **Inventory.** The material handler brings purchased supplies by pallet jack from **RM-WH**. Prepared dough is received into **SFG-DECK**. Workers move wafers and cream through **SFG-WH** by cart. The inventory report also shows controlled **WIP**, the packaging bay, and **FG-WH**. Goods movements link stock issues and receipts to their orders.
- **Save and load.** ChocoERP saves the active catalog, schedules, release snapshots, actual progress, stock, reservations, pegging, in-flight logistics, purchases, and journal. Loads open paused. Closing the game window saves automatically. Use the terminal's **Save** before stopping an editor run.

**Auto Release** is off by default and saved with the shift. When it is on, the running shift releases planned orders once their immediate BOM components are physically available and unreserved. Eligible orders are considered by scheduled start, then priority. MRP proposals must still be converted into orders, and a released order waits for its scheduled start.

### MRP workspace

The MRP page works like SAP's coverage monitor and stock/requirements list.

- **Coverage list.** One line per planned material, worst exception first: lot size, safety stock, available stock, the date from which stock and firm receipts no longer cover requirements, planned orders, and the top exception. **Exceptions only** filters it. Double-click a material, or select it and click **Stock/Requirements list**.
- **Stock/requirements list.** Dated MRP elements for one material with the running available quantity: `Stock`, `IndReq` (customer demand), `DepReq` (component need of a parent order), `PrdOrd`, `POitem`, `PlOrd.` (planned order), `PurRqs` (purchase requisition). An asterisk (`PlOrd.*`, `PurRqs*`) marks a firmed order.
- **Planned orders persist.** Each MRP run regenerates unfirmed planned orders and keeps their numbers while the same requirement still needs them. **Firm / unfirm** fixes an order so MRP no longer changes it; it then counts as fixed supply. **Change planned order** edits quantity and start and firms the order. **Convert proposal** turns one into a production order or purchase order. **Convert all shown** converts everything visible, parents first, so pegging links automatically.
- **Lot sizing and safety time** come from the material master (**Edit material**): `EX` lot-for-lot, `FX` fixed lot, `PB` period lot that combines requirements within a period, plus minimum, maximum and rounding values. Safety time makes supply available that much earlier than the requirement. Finished goods stay lot-for-lot because each finished order is linked to one demand. The demo combines batter, extrusion and baking needs over four simulated hours and buys flour in 25 kg steps, at least 100 kg.
- **Exception messages.** *Start date in the past* (with the earliest realistic availability), *bring forward* for receipts or linked orders that finish after they are needed, *postpone* for receipts more than 30 minutes earlier than needed, *cancel* or *excess* for unneeded supply, *finishes after the pegged order starts* for supply moved too late, *below safety stock*, and *no source*. Red is urgent, amber is a warning.

MRP plans with unlimited capacity, as SAP MRP does. Converting a planned order schedules it on real machine capacity, which can move it later. Run MRP again after converting to see the resulting exceptions.

### Detailed Scheduling

- Each row represents a work center from the master data. Swipe with two fingers over the chart to move left or right through time and up or down through work centers. You can also use the scrollbars, **Shift + mouse wheel** for time, or the regular wheel for work centers. Choose a time scale or click **Jump to now** to reorient the timeline.
- Filter by material or order, work center, status, and day or day range. Select a bar for the order summary, or double-click it for the order details. The thin strip under a bar shows actual start and progress. The red line shows current simulation time. A selected order draws dependency lines to visible pegged orders.
- Drag a planned bar horizontally to set its start. Drag it to another eligible row to select that machine. Green previews can be placed. Red previews show a calendar, capacity, or eligibility conflict. Released assignments stay frozen.
- A new order is scheduled in the first slot that fits on the selected center. Rescheduling an existing order requires an open interval. Estimates use the selected product/resource standard, handling allowances, and the setup required by the preceding scheduled material. Moving a draft between eligible resources recalculates its duration. Actual progress also depends on the material handler, floor crew, carts, and forklift. **Reports and Analytics** includes a schedule-adherence view with scheduled workload, actual times, wait times, and late orders.

### Alternatives and shared resources

Choose Oven 01 or Oven 02 for baking. Choose an eligible coater and packaging line for the material. Coater 02 supports milk, dark, and white. The prep station and extruder share the staging crew. The two ovens and the two coaters can work on separate orders concurrently, with each order retaining its own carts and buffers. One stock dock and the main cart aisle are shared.

**Routing Master** lists stage assignments alongside the WAFER-01 through WAFER-04 templates used by legacy combined-route shifts. Current orders execute a single stage with a selected work center and frozen parameters. Finished goods have a separate production version for each eligible packaging line. **Show route** highlights the selected order’s assigned equipment.

## Filled-wafer production

In **Material Requirements Planning**, choose **Load filled-wafer example** to add 48 cartons of milk chocolate vanilla cream, 60 cartons of uncoated vanilla, and 120 cartons of dark chocolate hazelnut cream. The demand dates put hazelnut last on shared equipment. For a shorter run, create demand for four cartons of **FG-2001** instead. Run MRP, convert the production and purchase proposals, then release the planned orders as stock becomes available. **Auto Release** handles those releases while the shift runs. Dispatch pallets as warehouse space fills.

| Product | Additional processing | Packaging |
| --- | --- | --- |
| FG-2001 Milk Chocolate Vanilla Cream Wafer | Vanilla cream, sandwiching, cutting, milk coating, cooling | Line 01 or 02 |
| FG-2002 Dark Chocolate Hazelnut Cream Wafer | Hazelnut cream, sandwiching, cutting, dark coating, cooling | Line 01 or 02 |
| FG-2003 White Chocolate Cocoa Cream Wafer | Cocoa cream, sandwiching, cutting, white coating, cooling | Line 01 or 02 |
| FG-2004 Vanilla Cream Wafer — Uncoated | Vanilla cream, sandwiching, cutting | Line 01 or 02 |
| FG-2005 Mini Hazelnut Wafer Bites | Hazelnut cream, sandwiching, mini cutting | Line 02 |

Cream has its own mixer order and stock receipt. Sandwiching reserves both baked wafers and the recipe's exact cream. Coated wafers, including the original five flavors, need an independent cooling order before packaging. Uncoated products reserve cut wafer stock. The new machines are selectable and movable in Build Mode.

The modeled cutter makes 20 g fingers and 5 g mini bites. Filled wafers use four coated fingers or five uncoated fingers per 100 g pack. A 50 g mini pouch holds ten bites. ERP tracks retail film in wrapper equivalents and consumes it with each completed shipping carton.

## Chewing gum production

The gum hall behind the wafer lines has nine machines: a Z-blade **Gum Mixer**, a **Gum Sheeter** (pre-extruder, sizing rollers, dusting and scoring), a **Fruit Gum Former** (rope sizer and rotary fruit die), a **Gum Conditioning** tunnel, three rotating **Coating Pans**, a **Wallet Packer** and a **Bottle Filler**. Kids' fruit gum is packed in 50 g pouches on Packaging Line 02. In **Material Requirements Planning**, the example loader also adds three gum demands.

| Product | Gum mass | Shape and shell | Packaging |
| --- | --- | --- | --- |
| FG-3001 Fresh Spearmint Sugar-Free Gum | Gum base, maltitol, glycerin, spearmint aroma | Pellets, maltitol shell | Wallet, 10 pellets (Wallet Packer) |
| FG-3002 Intense Peppermint Sugar-Free Gum | Gum base, maltitol, glycerin, peppermint aroma | Pellets, maltitol shell | Wallet (Wallet Packer) |
| FG-3003 Xylitol Peppermint Gum | Gum base, xylitol, glycerin, peppermint aroma | Pellets, xylitol shell | 60 g bottle (Bottle Filler) |
| FG-3004 Xylitol Watermelon Gum | Gum base, xylitol, glycerin, watermelon aroma | Pellets, pink xylitol shell | 60 g bottle (Bottle Filler) |
| FG-3005 Fruity Friends Strawberry Gum | Gum base, sugar, sorbitol, glucose syrup, strawberry aroma, red colour | Strawberry shapes, red sugar shell | Kids pouch (Line 02) |
| FG-3006 Fruity Friends Orange Gum | As above with orange aroma and colour | Orange shapes, orange sugar shell | Kids pouch (Line 02) |
| FG-3007 Fruity Friends Green Apple Gum | As above with apple aroma and green colour | Apple shapes, green sugar shell | Kids pouch (Line 02) |

Each product has five independent stage orders: **mass** (Gum Mixer batch from staged ingredients), **cores** (Sheeter or Fruit Former), **conditioning** (residence in the tunnel), **coating** (a pan batch that charges conditioned centres from a cart plus syrup and polishing wax from the syrup station between the pans) and **packing**. Any of the three pans can coat any product. Switching a pan or a stage from sugar to sugar-free products adds a cleaning changeover.

Purchased gum inputs are gum base, maltitol, xylitol, sorbitol, glucose syrup, glycerin, six aromas, three natural colours, three coating syrups, carnauba wax, wallet blisters, bottles, kids pouches, cartons and labels. Demonstration timings are short: a 5-minute mix, a 4-minute conditioning residence and a 7-minute pan batch.

### Production standards

Open **Production Standards** to compare work centers by product, material, operation, or family. **Detailed Scheduling** and order details show the selected standard, planned setup and duration, and actual progress. The machine inspector lets you set **Operating Rate Factor** from 50% to 120%. It affects execution while the planned duration uses the standard. Effective rates respect work center design limits.

| Model | Processing time before setup and transfer allowance |
| --- | --- |
| Continuous | Kilograms divided by the standard kg/hour, or pieces divided by pieces/hour using the material's kg per piece |
| Packaging | Cartons divided by cartons/hour. Physical flow uses cartons/hour × kg per carton |
| Batch | Number of batches × (cycle + loading + unloading). Batch count uses input mass and standard batch capacity. Lots must meet the minimum batch |
| Cooling | Quantity divided by the lower of standard throughput and capacity-derived throughput, plus minimum residence time |

The fictional cleaning rules add setup between materials. A hazelnut-to-plain transition can require extra cleaning on a shared work center.

In a fresh staged shift, ovens use about two minutes per batch and receive 1 kg of baked wafer for every 2 kg of wet sheets. The journal records the difference as evaporated water under yield loss. The cooling tunnel holds coated wafers for 7½ minutes. Baking estimates include a cart-handling allowance per batch. Batter prep and extrusion include handling time proportional to the order size. These allowances describe the default layout and crew. Queues, a changed layout, and dispatch delays affect actual completion.

## Editing master data

- `materials.json`, `products.json`, and `boms.json` define the material IDs, product specs, opening balances, and multilevel recipes. An optional `planning` object on a material sets MRP lot sizing and safety time: `lot_size` (`EX`, `FX` or `PB`), `fixed_lot`, `period_seconds`, `min_lot`, `max_lot`, `rounding` and `safety_time` (simulated seconds). Carton mass and pallet mass derive from product specs. Each finished BOM uses one carton as its base and includes retail film, one carton and label, and the pallet allocation. Packaging with `packaging_role` set to `retail_wrap` uses one unit per consumer pack.
- `routings.json` lists operation numbers and work center references. `work_centers.json` holds equipment IDs, capabilities, availability, and design limits. `production_versions.json` ties each SKU to a BOM version and routing version with lot and date limits. Dates are simulated seconds from shift start. A zero `valid_to` means open-ended.
- `production_standards.json` holds native rates, batch parameters, residence limits, and yield by material, operation, and work center. Optional routing or production version references narrow applicability. `changeovers.json` defines cleaning and setup. `planning_examples.json` contains the example demand.
- `scheduling.json` defines stage-to-material and work-center eligibility, handling estimates, and simulated daily availability intervals. The shipped calendar is 24/7.
- `factory_layout.json` contains positions, footprints, ports, and the packaging WIP receiving bay. `storage_locations.json`, `suppliers.json`, and `simulation_defaults.json` contain locations, supplier offers, and operating defaults.

Keep existing identifiers stable. To add an alternative, add a routing using supported operations and existing centers. Add a production version with the matching routing and BOM version numbers. Use **Reload Standards** to read edited rate and cleaning files into a shift. Start a fresh shift for changes to other master-data files. Released orders keep their snapshots. A validation error reports the offending file and, where available, the record and field.

Saved shifts preserve their active catalog and layout along with frozen orders. On first load, older shifts update the original demo packaging sizes and BOMs while keeping custom sizes, frozen orders, and physical stock. Re-select the production version on an older draft order to use the current rates and BOM. Older saves open in the enlarged hall, with the warehouse shifted outward to clear the new docks. Cart and vehicle jobs are replanned from safe positions, and any coated stock left on the former conveyors is recovered into the same order’s coater outfeed. Orders already in progress from an earlier combined-route save can finish on their original assignments. Older created or released combined-route orders are held with their reservations and can be cancelled before re-planning as individual stages. Start a fresh shift to use edited files while keeping the saved shift available. From the project directory, run:

```sh
godot --path . -- --fresh-shift
```

This starts from the current JSON and disables automatic save on close for that session. ChocoERP’s **Save** button writes to the same slot. Exported builds can load a complete editable `master_data` folder beside the executable or macOS app bundle. Include `master_data/*.json` in Godot’s export filters to ship the built-in files.

## Factory layout

The standard layout groups the hall into departments that face the cart aisle, with the product flow running left to right:

- **Front row:** ingredient deck and extruder, the two ovens, the two coaters, then Packaging Line 01 with its carton conveyor and palletizing bays.
- **Second row:** the filled-wafer cells (cream mixer, spreader, cutter, cooling tunnel) end at the semi-finished stock hub. Packaging Line 02, the wallet packer and the bottle filler follow, then the gum line (mixer, sheeter, fruit former, conditioning).
- **Third row:** the three coating pans sit behind the gum line, centred on the gaps between its machines.
- **Behind the rows:** a raw-material kitting area, the production office and QC lab, the canteen with changing room and hand-wash point, and outbound marshalling lanes in front of the finished-goods store. The maintenance workshop (a walled room with a roller door) and the empty-pallet store with forklift charging stand against the rear wall.

Green walkways link the areas. Yellow lines mark each machine's operating clearance, and boards above the rows name each department. Compressed air, cooling water and insulated hot-water pipes run on wall brackets with branch drops to valve stations. Loose cartons, opened, torn, crushed or broken down, lie around the packing and storage areas. Workers and vehicles keep their own routes; the markings and furniture are visual only and are left out wherever they would sit on a route or a machine.

A saved shift keeps its own floor plan. To switch it to the standard layout, finish or pause production so no order is running, open **Build Mode** and choose **Default**. The move is validated first and can be undone.

## How the factory works

| Stage | What happens |
| --- | --- |
| Dough preparation | The material handler replenishes recipe ingredients by pallet jack. Two mezzanine workers collect sacks and deposit the prepared blend into stock at the deck. |
| Raw wafer extrusion | The platform crew feeds reserved dough into the hopper. The extruder fills raw carts up to the order target. Floor workers carry them to the wafer stock dock for receipt. |
| Baking | Workers load reserved raw wafers at the stock dock and push the carts to the assigned oven. Full batches and the final partial batch use the frozen cooking duration. A cooked cart returns the output to stock. |
| Cream mixing | The material handler brings ingredients to the mixer. A floor worker loads each batch, and a worker carts the mixed cream to wafer stock. |
| Sandwiching and cutting | Carts deliver baked wafers and cream separately. The spreader forms blocks, and the cutter makes fingers or bites in separate orders. |
| Coating | Workers deliver baked or cut wafers from the stock dock to the selected coater. The material handler delivers coating ingredients. Workers collect the coated wafers in purple tray carts for receipt back into stock. |
| Cooling | A cart brings coated stock to the tunnel. Its internal capacity, throughput, and residence time determine when cooled wafers can leave. |
| Packaging and pallets | Line 01 receives carts through **Packaging WIP** and feeds palletizing by conveyor. Line 02 sends boxed wafers to the same palletizing area by worker cart. |
| Forklift and warehouse | The forklift reserves an open storage slot, drives to the pallet, picks it up, and unloads. The warehouse receipt completes the finished order. Full storage delays the order and may block packaging. |

The default floor crew has four workers, two raw carts, and two cooked carts. Raw carts hold 50 kg and cooked carts hold 45 kg. Oven 01 starts at 75 kg and 36 seconds per batch. Oven 02 starts at 60 kg and 42 seconds per batch. The five classic wafer flavors use 100 g consumer packs, 50 packs per 5 kg shipping box, and eight boxes per 40 kg full pallet. Two coated carts start at 24 kg each, and Packaging WIP starts at 60 kg. Select **Packaging WIP** to change capacity, inspect its receiving dock, or open the **PACK-WIP** inventory in ChocoERP.

Production rates use kilograms, pieces, or cartons per simulated hour, or timed batch cycles. The engine advances in fixed quarter-second ticks, including travel and handling. Ingredient supply comes from opening stock and purchasing. Coating adds the actual chocolate consumed. Any standard yield loss is recorded as scrap. The mass ledger includes material in sacks being carried, every buffer and cart, the oven, partial cartons, pallets on the floor and forklift, and dispatched stock.

Capacity reductions must cover current stock and any incoming reservations. An oven batch's capacity is locked through cooking and unloading. Movement speeds can change during a shift. Technical settings on an idle work center apply to future releases. Released orders keep the parameters they reserved. The forklift uses marked waypoints, and cart moves reserve the shared aisle one at a time. People use fixed pedestrian approaches and can pass one another.

## AI planning agent (headless)

An AI agent can plan and run the factory without the game window and without clicking through the ERP. It calls the same ERP functions as the terminal buttons, so it plays by the same rules as a human planner.

- `agent/agent_api.gd` turns JSON commands into ERP actions and returns compact observations: status, stock, orders, demands, the schedule, work-center time breakdowns, MRP proposals and a score.
- `agent/work_center_monitor.gd` records how long each work center spends working, in setup, starved, blocked, handling oven loads, or without work. These shares are the main evidence for bottleneck analysis. It only reads simulation state.
- `agent/server.gd` serves those commands as one JSON object per line over TCP on 127.0.0.1.
- `agent/mcp_bridge.py` starts the server and exposes each command as an MCP tool named `factory_<command>`. It needs only Python 3 and has no packages to install.
- `scenarios/*.json` set up a shift: demands, stock adjustments, operating factors (50–120%), MRP `planning` settings per material, auto-release and a horizon. `evaluator_notes` is never returned to the agent, but an agent with file access could read it. For blind tests, keep scenarios with answers outside the agent's reach.

MRP commands mirror the MRP workspace: `run_mrp` returns numbered planned orders, exceptions and coverage, `mrp_material` returns one material's stock/requirements list, and `convert_all`, `firm_planned_order`, `change_planned_order` and `set_planning` act on them.

Time only moves when the agent calls `advance` or `run_until`. `run_until` stops at events such as a completed order, a received purchase or a missed due date. A 12-hour shift simulates in a few seconds. `snapshot` and `restore` keep whole shifts in memory, so an agent can test a change and then rewind. Runs are deterministic.

**With Claude Code.** `.mcp.json` registers the bridge as the `chocolate-works` server. Open Claude Code in this folder, approve the server, and ask, for example: *Load res://scenarios/constrained_shift.json, plan the shift, run it to the horizon, and report the bottlenecks with evidence and recommendations.* Set `GODOT_BIN` if Godot is not in `/Applications`.

**Without MCP.** Start the server and send lines with any language:

```sh
godot --headless --path . --script res://agent/server.gd -- --port 8765 --scenario res://scenarios/filled_wafer_shift.json
```

```json
{"cmd": "run_mrp", "args": {}}
{"cmd": "run_until", "args": {"max_seconds": 3600, "stop_on": ["order_completed"]}}
```

Send `{"cmd": "describe"}` for the full command list and `{"cmd": "shutdown"}` to stop. `python3 agent/mcp_bridge.py --connect 8765` attaches the MCP bridge to a server that is already running.

**Watch the agent live.** Start the game with an agent port and point the bridge at it:

```sh
godot --path . -- --agent-port 8765
```

```sh
python3 agent/mcp_bridge.py --connect 8765
```

In Claude Code, change the `chocolate-works` entry in `.mcp.json` to `"args": ["agent/mcp_bridge.py", "--connect", "8765"]`, start the game first, then start the agent. The agent then plans the shift you are looking at, and the ERP terminal shows its orders as it creates them.

- Time commands play the shift on screen and reply when the simulated time has passed, so they take real time: simulated seconds divided by the speed. The agent can choose 1×, 5×, 20× or the new 60× with `set_speed`. One simulated hour takes a minute at 60×.
- After each time command the game pauses again until the agent's next move. You can pause, play, change speed, move the camera and open ERP at any time. Your own ERP actions change the same shift the agent is running.
- `load_scenario` replaces the shift on screen. `restore` rewinds the view to a snapshot. `run_until` can overshoot its stop by up to one frame of simulated time.
- With an agent port open, closing the window does not autosave, so an agent run never overwrites your saved shift. To keep an agent's shift, the agent can call `save_shift` with a path, or with `replace_game_save` so the game's **Load** button opens it.

Current limits: the agent controls planning, purchasing and release. It cannot edit the layout, crews or master data. The simulation has no breakdowns or random variability yet.

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
| `agent/` | Headless JSON and MCP interface for AI planning agents |
| `scenarios/` | Planning scenarios for agent runs |
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
godot --headless --path . --script res://tests/product_standards_test.gd
godot --headless --path . --script res://tests/agent_api_test.gd
godot --headless --path . --script res://tests/mrp_planning_test.gd
godot --headless --path . --script res://tests/gum_line_test.gd
```

On macOS, if Godot is installed in Applications, replace `godot` with `/Applications/Godot.app/Contents/MacOS/Godot`.
