# Chocolate Works — notes for Claude

Read `AGENTS.md` first: it holds the project rules (deterministic fixed-step simulation, ERP ledger consistency, layout validation, which test suite to run for which change). `README.md` covers controls and master data, `DEVELOPMENT.md` the planning/execution design, `PERFORMANCE.md` the measured budgets.

## Running and testing
- Godot 4.7.2, Compatibility renderer, 30 FPS cap. On this Mac Godot is at `/Applications/Godot.app/Contents/MacOS/Godot`.
- The headless test commands are listed in README ("Validate the project"). Run the relevant suites after touching simulation, ERP, layout or scheduling code.
- Visual changes can't be checked headless: run the project and look at it. Say plainly what was and wasn't seen.

## Visual layer (added Nov 2026)
- `world/industrial_models.gd`: detailed batch ovens and chocolate enrobers (Oven/Oven02, Coater/Coater02). Built from primitive meshes; PBR textures (brushed steel, paint, ribbed cladding, wire belt, vents, hazard stripes) are generated in code at startup, because downloads are not available and to keep the project asset-free. Static parts are merged per material via `Primitives.batch_static`; fine details skip shadows and stop drawing beyond 48 m.
- Enrober motion (belt texture scroll, sprocket, coated pieces, chocolate curtain) is driven by the coater's `total_output`, not by real time, so it follows the simulation. The curtain takes the order's `coating_color`.
- `world/hall_models.gd`: hall lighting and exponential haze, 9 m clad walls, open truss roof with high-bay lamps, additive floor light pools (no real lights), concrete floor material. Sims-style cutaway: walls facing the camera switch to shadows-only, and roof bays between the camera and its focus point are hidden. Driven by `Floor.update_view(camera)` from `scenes/factory.gd` `_process`; it no-ops when the camera hasn't moved.
- Performance rule from the owner: performance comes first, and the machine must not run hot. Prefer emissive materials and merged meshes over real lights, transparency and per-frame updates.
- `world/industrial_models.gd` is also the shared model kit: public helpers (`box`, `cylinder`, `pipe`, `leg`, `handrail`, `caster`, `drive_motor`, `stack_light`, `finish`, …) and materials (`stainless`, `polished`, `grating`, `rubber`, `paint(color)`, …). Build new equipment with it and call `finish(root)` so static parts merge per material.
- `world/line_models.gd`: extruder, ingredient hopper, cream mixer, roller conveyors, palletizing table, wire and long-span shelving. `world/processing_models.gd`: spreader, cutter, cooling tunnel and flow wrappers on a shared stainless conveyor with a scrolling belt. Their pivot names (`MeteringRoller`, `CuttingHead`, `CoolingFan`, `SealingJaw`, `FeedReel`) are checked by `tests/product_standards_test.gd`.
- Workers, carts and the forklift (`world/logistics_view.gd`), pallets/cartons/sacks/wafers (`world/stock_models.gd`, generated wood, cardboard, woven and waffle textures) and the warehouse racking (`world/warehouse_view.gd`) were rebuilt in Nov 2026. Each worker pivot (body, legs, arms) is merged per material.
- Everything in `world/` is visual only and must never write simulation state.

## Agent interface (added Nov 2026)
- `agent/` exposes the ERP and simulation to AI planning agents: `agent_api.gd` (JSON commands), `work_center_monitor.gd` (read-only state-time buckets), `server.gd` (TCP, newline JSON) and `mcp_bridge.py` (stdlib-only MCP stdio bridge, registered in `.mcp.json`). Scenarios live in `scenarios/`.
- Agent actions must go through the same ERP functions as the UI. Never give the agent a shortcut that bypasses release checks, reservations or the ledger.
- Command argument specs follow `"[optional ]<string|number|int|bool|array>[: note]"`. The bridge builds MCP schemas from them.
- Run `tests/agent_api_test.gd` after changing anything in `agent/`, ERP command signatures, MRP output, or order/demand fields.

## MRP (phase 1, Nov 2026)
- `erp/stage_mrp.gd` holds explicit-stage MRP: lot sizing (EX/FX/PB, min/max/rounding), safety time, exception messages and the coverage summary. Planned orders persist in `book.planned_orders` (`PLO-…`, `planned_sequence`); unfirmed ones are regenerated each run and keep their number by planning key, firmed ones are fixed supply. `erp/mrp.gd` adds `find`, `convert_all`, `firm` and `change`. The legacy combined-route path in `mrp.gd` is unchanged.
- Material settings: optional `planning` object in `materials.json`, read through `catalog.planning(code)`, validated by `catalog.set_planning`. Finished goods must stay lot-for-lot (demand linking assumes one order per demand).
- Run `tests/mrp_planning_test.gd` after touching MRP, planned orders or material planning settings.
- Known gap (phase 2): MRP plans with unlimited capacity while conversion schedules finitely, so converted orders can land later than MRP assumed. Exceptions report it; nothing levels it yet.

## Things to know
- `simulation/production_line.gd` (~1,800 lines) mixes three execution modes (legacy sandbox, combined routes, explicit stages) kept for save compatibility and regressions. Change it carefully.
- The simulation is fully deterministic: no breakdowns, random cycle times or supplier variability yet. The owner plans to use it for experiments, so any randomness should be seeded and optional.
- Demo timings are much faster than real life (short bakes, 60–90 s supplier lead times).
- About 22 existing GDScript warnings (variable shadowing, unused parameters) come from ERP/UI scripts and predate the visual work.
- Commit a checkpoint before large changes.
