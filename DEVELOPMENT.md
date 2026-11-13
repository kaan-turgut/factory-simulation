# Production planning and execution

`erp/scheduling.gd` resolves the stage and its eligible work centers from `master_data/scheduling.json`, then calculates a finite planned interval. `erp/operations.gd` owns order state, immediate-component availability, reservations, and the stock ledger. `erp/stage_mrp.gd` explodes requirements by BOM level and dates, nets scheduled supply and firmed planned orders, sizes lots, raises exception messages, and converts planned orders. `ui/scheduling_board.gd` draws the visible time and resource ranges and delegates changes to the scheduling model.

Release freezes a one-operation routing and immediate BOM. The fixed-step line locks the work center once the planned start has arrived and records actual start when processing first takes place. A shared staging crew coordinates dough preparation and extruder feeding. Raw, baked, and coated quantities stay with the producing order through carts and station WIP. The stock dock posts receipts before that material becomes available to another order. The same dock issues reserved stock to a downstream order's cart. Packing finishes when its final pallet reaches a warehouse slot.

## Dates and limits

- Dates and calendar intervals use simulated seconds. Each configured daily interval is available for new starts and finite planned slots. An already committed operation can overrun an interval and records the delay. The example calendars are 24/7.
- Oven estimates count all batches, including the last partial batch. Handling and setup allowances reserve time conservatively. Shared workers, aisle use, stock dock time, and warehouse space can delay actual execution.
- Pegging connects immediate component supply to downstream requirements. Material at a common location is fungible by material code after receipt. Pegging does not grant exclusive access to stock. A release reserves available physical stock.
- One line shares a timed shuttle, the cart aisle and the stock dock. The scheduler reserves machine time. Actual worker, cart, forklift and warehouse availability is resolved by the simulation. Production standard yield can post scrap. The demo recipes use full yield.
- Finished quantities are entered in boxes. Storage and inventory movements use base units, including kilograms for all food materials. The order also reports released quantity, produced and received mass, and unproduced mass.

## MRP planning objects

Planned orders are documents in the ERP book, separate from executable orders. MRP regenerates unfirmed planned orders on every run (regenerative planning) and reuses a number while the same planning key still needs supply. The key is the type, the requirement document and the material. A firmed planned order is never changed by MRP. Its output counts as unpegged supply and its components are exploded as dependent requirements. Changing a planned order's quantity or date firms it.

Lot sizing runs while a material is netted. A period lot (`PB`) stays open for its period and grows when later requirements in that window are short. Fixed lots (`FX`) create as many fixed-size lots as needed. Minimum, rounding and maximum apply to the other procedures. Make lots are scheduled backward from their availability date once the material is fully netted, so a combined lot explodes its components once. Safety time moves that date earlier. Finished goods stay lot-for-lot because demand coverage counts each linked order against a single demand.

Exceptions are computed during netting. Movable receipts are created orders, released orders, open POs and firmed planned orders. Each receipt records its earliest on-time use for the postpone message (30-minute tolerance). Unused or partly used receipts get cancel or excess messages. Released and created orders with pegs are checked against their parent's planned start.

MRP still assumes unlimited capacity. Conversion schedules each order in the first free finite slot, which can be later than the backward-scheduled date. The resulting gaps show as exceptions on the next run.

## Raw-material warehouse capacity

RM-WH capacity is counted in pallet positions (`storage_capacity.json`, 90 by default). `catalog.positions(code, qty)` rounds each racked material up to whole pallets using its `pallet_qty`; tank, pallet-store and shelf materials need none. `operations.raw_room(code)` is the quantity that still fits, counting the material's own part-full pallet. Only PO receipts and returns from the mezzanine are limited. Stock adjustments record what is physically there and may exceed capacity.

A due PO puts away what fits once per simulated second. The remainder stays on the PO as `at_dock`, `dock_seconds` counts the wait, and the PO stays `Partial` until the rest fits. MRP walks the dated rows of racked materials from current RM-WH stock, minus reservations not yet covered by staged stock, and raises `storage_full` on the first receipt that would exceed capacity. It also raises `at_dock` for waiting deliveries.

The capacity comes from a full-rate day. Equal boxes per SKU within each family run at the family's pooled bottleneck: the cooling tunnel for wafers, about 2,670 boxes a day, and gum conditioning, about 4,040 boxes a day. Exploded to purchased materials and rounded to whole pallets per material, that needs about 82 positions. Opening stock uses 69.

## Stage overlap

`scheduling.json` carries `overlap` (`enabled`, `first_lot_kg`) and a `start_kg` on each stage that can start on part of a manufactured input. `Scheduling.overlaps(catalog, stage, input)` is true when overlap is on, the stage has a start quantity and the input is made in house. Purchased inputs and extrusion, which shares its crew with batter prep, keep the full-availability rule.

`ERP.shortages(order)` is the release rule. An overlapping input needs `start_quantity` in stock (`component_available`) and an outlook of at least the full need, where `outlook = accessible stock - all reservations + pending_output`, and `pending_output` is the unreceived target of released and running orders of that material. Release then reserves the full quantity, so reservations may exceed stock until the upstream stage delivers, and records `order.incoming`. Stage execution already read live stock, so a released stage simply waits for input carts. `transition` refuses to cancel a released upstream order while reservations exceed stock plus other pending output.

Planning mirrors it. A lot that feeds an overlapping consumer starts at `min(due - first_output, consumer finish - duration)`, where `first_output` is the duration of the consumer's start quantity. MRP netting lets a scheduled receipt serve such a need if its first lot is there in time and its last lot is done by the consumer's finish. Output that released orders have already claimed is not offered to other requirements. `Scheduling.supply_late` is the shared check for the MRP exception and the order detail warning.

Saves keep their catalog, so a save without `overlap` keeps the old rule.

## Floor plan and lanes

A layout file defines `size`, `plan` (the plan family), `lanes` and `objects`. The five routing lanes are grid Z values: `cart` and `walk` for the floor crew, `supply` for the material handler, `lift` for the forklift and `rear` for the legacy rear approach. Optional `aisle_end`, `lift_home_x`, `crew_home_x` and `reserved` rectangles place the forklift home, crew home and the cells the editor keeps clear. The Layout class exposes them as `cart_lane`, `walk_lane`, `supply_lane`, `lift_lane` and `rear_lane`. The old constants remain only as defaults for the original plan.

The aisle plan is double-loaded: machines on both sides of one six-metre aisle, north-row machines facing south and south-row machines turned 180° with their input and output docks swapped, so material still flows west to east. Docks and supply stops sit inside the aisle. Each lane runs in the clear strip between the two rows' cart bodies, so cart and walk lanes are one to two metres wide and the supply and forklift lanes use the full aisle. The forklift drives the aisle to the east side, north along the east wall and into the shipping door. The packing block keeps its belt geometry: the palletizer's front edge lines up with the row, with the packer set back four metres. `Platform` carries a `stage` dock for the ingredient stop, where the original plan used a fixed point.

Saves record the plan. A snapshot without `lanes` loads as the original plan (`legacy`), with `factory_layout_legacy.json` as its defaults for appended equipment and the Default button. Saves older than layouts refit into that plan. Layout files made in Build Mode carry a `plan` and only apply to the same plan.

## Persistence

Native save version 6 stores the planning catalog, planned orders and their numbering, schedule, BOM and routing snapshots, open reservations, movement IDs, pegging, progress, and the active stock dock assignment, standards, cleaning rules, operating factors, and in-flight cell state. Loading restores them without replaying events. Earlier active combined orders can drain their WIP. Their waiting combined orders retain their original snapshots and reservations until cancellation. The legacy execution mode remains available to the regression fixtures.

## Validation

Use `tests/detailed_scheduling_test.gd` for the milk-wafer demand through shipment scenario, concurrent work centers, finite windows, in-flight save/load, MRP conversion, and Gantt input. The commands in README run the existing routing, transaction, layout and physical simulation regressions. See PERFORMANCE.md for measurements.

## Chewing gum family

The gum stages are `gum_mix`, `gum_form`, `gum_condition` and `gum_coat`. They run in the same stock-to-stock production cells as the filled-wafer stages. Any work center with an input dock runs as a cell, and `Catalog.PREPARATION_STAGES` and `SINGLE_INPUT_STAGES` hold the recipe rules. A batch cell whose recipe has a semi-finished input (a coating pan) charges itself once its input stock and the staged supplies cover a batch. Cream-style batches still load purchased ingredients by cart.

Supply locations can be shared. `Layout.SHARED_SUPPLY` lets the three pans draw from **GUM-PAN-IN** and both gum packers from **GUM-PACK-IN**. The shuttle delivers to the station named in `SUPPLY_STATIONS`.

Equipment behind other rows reaches the cart aisle through `Layout._grid_approach`, an axis-aligned grid search. It runs only when the direct and single-detour approaches fail, so existing routes stay as they were.

Saves made before a family existed gain its master data on load (`_add_new_master_data`): new rows are added, and capability lists only gain entries. Its new equipment is placed at its default cells, or `Layout.fit_appended` moves the whole new group to the nearest place where the plan validates.

## Product standards and filled wafers

The scheduler resolves a dated standard using material, operation, resource, and optional routing or production-version scope. A more specific scope takes precedence. Standard values and cleaning rules freeze on release. A work center's maximum limits its effective runtime flow. The original combined-line mode remains available to resume legacy orders and run regressions.

The production cell reuses the floor worker queue for mixed-input, cutting, residence, and second-packaging cells. The sandwiching inputs have separate buffers with the configured capacity applied to each. The cream mixer loads from shuttle-delivered station stock. Cooling tracks dated lots in a bounded internal buffer, limits entry and exit throughput, and releases material after its minimum residence. Packaging Line 02 carts whole cartons to the shared palletizing dock. Worker claims carry material identity through pickup, unloading, and save/load.

The planner calculates continuous and packaging duration from the native standard, batch duration from batch count and handling times, and tunnel duration from its throughput bound plus residence. It adds transfer allowance and planned setup. Actual congestion, travel, and operating factors affect completion. A change to the preceding planned order can require reviewing and rescheduling a draft. Machine bookings leave shared workers and carts to the execution queues.

- [x] Inspect existing architecture and create checkpoint 8d02e9b.
- [x] Record baseline tests and headless performance.
- [x] Validate external standards, capabilities, and cleaning rules.
- [x] Use standards in scheduling, release snapshots, operating factors, and ERP.
- [x] Add cream, sandwiching, cutting, cooling, second packer, and the new product family.
- [x] Integrate worker carts, raw supply, pallet logistics, and editable placements.
- [x] Validate multilevel MRP, concurrent execution, residence time, and persistence.
- [x] Run all nine regression suites and record performance comparisons in PERFORMANCE.md.
