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
- Everything in `world/` is visual only and must never write simulation state.

## Things to know
- `simulation/production_line.gd` (~1,800 lines) mixes three execution modes (legacy sandbox, combined routes, explicit stages) kept for save compatibility and regressions. Change it carefully.
- The simulation is fully deterministic: no breakdowns, random cycle times or supplier variability yet. The owner plans to use it for experiments, so any randomness should be seeded and optional.
- Demo timings are much faster than real life (short bakes, 60–90 s supplier lead times).
- About 22 existing GDScript warnings (variable shadowing, unused parameters) come from ERP/UI scripts and predate the visual work.
- Commit a checkpoint before large changes.
