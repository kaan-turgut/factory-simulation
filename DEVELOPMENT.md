# Production planning and execution

`erp/scheduling.gd` resolves the stage and its eligible work centers from `master_data/scheduling.json`, then calculates a finite planned interval. `erp/operations.gd` owns order state, immediate-component availability, reservations, and the stock ledger. `erp/stage_mrp.gd` explodes requirements by BOM level and dates, nets scheduled supply, and converts selected proposals. `ui/scheduling_board.gd` draws the visible time and resource ranges and delegates changes to the scheduling model.

Release freezes a one-operation routing and immediate BOM. The fixed-step line locks the work center once the planned start has arrived and records actual start when processing first takes place. A shared staging crew coordinates dough preparation and extruder feeding. Raw, baked, and coated quantities stay with the producing order through carts and station WIP. The stock dock posts receipts before that material becomes available to another order. The same dock issues reserved stock to a downstream order's cart. Packing finishes when its final pallet reaches a warehouse slot.

## Dates and limits

- Dates and calendar intervals use simulated seconds. Each configured daily interval is available for new starts and finite planned slots. An already committed operation can overrun an interval and records the delay. The example calendars are 24/7.
- Oven estimates count all batches, including the last partial batch. Handling and setup allowances reserve time conservatively. Shared workers, aisle use, stock dock time, and warehouse space can delay actual execution.
- Pegging connects immediate component supply to downstream requirements. Material at a common location is fungible by material code after receipt. Pegging does not grant exclusive access to stock. A release reserves available physical stock.
- One line shares a timed shuttle, the cart aisle and the stock dock. The scheduler reserves machine time. Actual worker, cart, forklift and warehouse availability is resolved by the simulation. Food loss and rework are outside the demonstration recipe.
- Finished quantities are entered in boxes. Storage and inventory movements use base units, including kilograms for all food materials. The order also reports released quantity, produced and received mass, and unproduced mass.

## Persistence

Native save version 5 stores the planning catalog, schedule, BOM and routing snapshots, open reservations, movement IDs, pegging, progress, and the active stock dock assignment. Loading restores them without replaying events. Earlier active combined orders can drain their WIP. Their waiting combined orders retain their original snapshots and reservations until cancellation. The legacy execution mode remains available to the regression fixtures.

## Validation

Use `tests/detailed_scheduling_test.gd` for the milk-wafer demand through shipment scenario, concurrent work centers, finite windows, in-flight save/load, MRP conversion, and Gantt input. The commands in README run the existing routing, transaction, layout and physical simulation regressions. See PERFORMANCE.md for measurements.
