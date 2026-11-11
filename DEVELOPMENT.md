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

## Persistence

Native save version 6 stores the planning catalog, planned orders and their numbering, schedule, BOM and routing snapshots, open reservations, movement IDs, pegging, progress, and the active stock dock assignment, standards, cleaning rules, operating factors, and in-flight cell state. Loading restores them without replaying events. Earlier active combined orders can drain their WIP. Their waiting combined orders retain their original snapshots and reservations until cancellation. The legacy execution mode remains available to the regression fixtures.

## Validation

Use `tests/detailed_scheduling_test.gd` for the milk-wafer demand through shipment scenario, concurrent work centers, finite windows, in-flight save/load, MRP conversion, and Gantt input. The commands in README run the existing routing, transaction, layout and physical simulation regressions. See PERFORMANCE.md for measurements.

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
