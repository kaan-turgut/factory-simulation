# Chocolate Works scalability profile

**CPU-side 3D rendering was the first limit.** The 64-machine test held 30 FPS. The 128-machine stress test dropped to 15.7 FPS, with a median 50.3 ms spent in the CPU renderer against a 33.3 ms frame budget.

## Controlled runs

Godot 4.7.2 Compatibility on a Mac with an Apple M4 Pro and macOS 26.6.2. Render runs used the existing 30 FPS cap, 1280 × 800, 2× MSAA, one shared light, and one dashboard with its warehouse inspector open. After 45 warm-up frames, each run measured 150 frames with identical simulated input at 20×. The camera fit all copies in view. Each copy used the existing production line, six workers, eight carts, and one forklift. The copies shared a rendered world and ran independent jobs and inventories.

Headless timings cover 7,200 aggregate ticks per size across three runs. Each tick advanced every copy by 0.25 simulated seconds. The measured windows included production, transport, and periodic dispatch. The default-sized crew and cart pool also measured 0.010 / 0.016 ms per tick at p50 / p95.

| Lines | Machines / workers / forklifts | Simulation step p50 / p95, ms | CPU rendering p50 / p95, ms | Median visible-pass draws | Rendered FPS |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4 / 6 / 1 | 0.011 / 0.016 | 5.26 / 9.06 | 998 | 30.0 |
| 4 | 16 / 24 / 4 | 0.046 / 0.067 | 8.32 / 8.80 | 2,189 | 30.0 |
| 8 | 32 / 48 / 8 | 0.094 / 0.133 | 13.73 / 14.76 | 4,377 | 30.0 |
| 16 | 64 / 96 / 16 | 0.188 / 0.263 | 24.42 / 25.95 | 8,753 | 30.0 |
| 32 | 128 / 192 / 32 | 0.393 / 0.557 | 50.26 / 59.04 | 17,505 | 15.7 |

## What accounts for the time

- **Rendering and GPU.** At 32 lines, disabling 3D drawing restored 30.0 FPS with simulation, world updates, physics, and HUD still running. Rendering at 960 × 600 reached 16.5 FPS. Metal traces measured **1.21, 3.79, and 6.01 ms** of GPU execution per rendered frame at 1, 16, and 32 lines. These are means from the union of Godot's active GPU intervals in separate traced runs. In the 74-frame stress trace window, Godot was GPU-active for 8.6% of elapsed time. The CPU rendering path was the limit at the tested resolution. Godot's Compatibility GPU timer returned zero, so the GPU figures use the independent trace. [Apple Metal System Trace](https://developer.apple.com/metal/tools/)
- **Simulation and navigation.** At 32 lines, simulation took a median 1.06 ms per rendered frame. Advancing 128 walkers along existing waypoints took 0.024 / 0.032 ms per tick at p50 / p95. In one line, increasing the floor crew from 4 to 64 raised the median tick from 0.011 to 0.030 ms. The instrumented floor-worker update averaged 7.0 and 25.6 µs per tick respectively, including about two job-list builds per tick in both cases. The nearest-idle-worker scan can get more expensive when many jobs become eligible together.
- **Physics.** Median values of the engine's published one-second physics maxima ranged from 0.03 to 0.18 ms across the visible runs. At 896 colliders, a separate warm picking test measured 0.95 µs per ray at the median. The current workload uses static picking bodies and timed waypoints. A shared fleet with collision avoidance needs a separate benchmark. [Godot 4.7.2 monitor implementation](https://github.com/godotengine/godot/blob/4.7.2-stable/main/main.cpp#L5029-L5051)
- **Inventory, animation, and UI.** At 32 lines, the median world refresh, animation, and HUD update took 3.01, 1.60, and 0.04 ms respectively. At eight lines, hiding only rendered stock reduced median draw calls from 4,377 to 2,913 and median CPU render time from 13.73 to 10.18 ms. The refresh path still scans pallet slots and rewrites status values each tick-driven frame. Logistics views scan the worker and cart arrays for each matching view. The HUD formats text and reapplies control state each refresh.
- **Grid and placement.** The floor and deck lines share one mesh surface. Building the overlay took a median 0.45 ms with 33 labels at 64 × 26 and 1.21 ms with 305 labels at 512 × 256. At eight lines, toggling the repeated overlays off cut median draws from 4,377 to 3,840. Cursor projection still runs each frame even when the view and pointer are still. Full placement validation is a separate cost. For the same valid move in a 128 × 64 hall, p95 rose from **3.25 ms** to **12.26 ms** with 60 extra off-route obstacles and **21.55 ms** with 120.

## Priorities for expansion

1. **Batch repeated visible stock.** Instance cartons, wafers, and repeated cart parts by mesh and material. Use zone-level batches so areas outside the camera can be culled. Retest the 16- and 32-line cases at the same cap and resolution.
2. **Update views when state changes.** Index actors by ID. Refresh inventory slots, labels, and HUD fields when their values change, and skip idle transforms and unchanged cursor projections. Prioritize the world refresh over the single-dashboard HUD.
3. **Keep planning and live navigation separate.** Use a spatial index to filter obstacle checks as placement grows. The current waypoint mover has room to scale. Benchmark task assignment and aisle contention when adding shared traffic, since today's single-line reservations were exercised independently in each copy.

## Phase 3 regression

The legacy workload was rerun on the same Apple M4 Pro and Godot 4.7.2 Compatibility setup, at 1280 × 800 and the original 30 FPS cap. This isolates regressions in the earlier line and world workload. The separate ERP test below uses the actual Phase 3 scene.

| Lines | Legacy step p95, baseline → Phase 3 (ms) | Legacy CPU rendering p50, baseline → Phase 3 (ms) | Phase 3 FPS |
| ---: | ---: | ---: | ---: |
| 1 | 0.016 → 0.016 | 5.26 → 5.63 | 30.0 |
| 4 | 0.067 → 0.064 | 8.32 → 8.52 | 30.0 |
| 8 | 0.133 → 0.128 | 13.73 → 13.73 | 30.0 |
| 16 | 0.263 → 0.258 | 24.42 → 24.33 | 30.0 |
| 32 | 0.557 → 0.510 | 50.26 → 47.81 | 17.1 |

At 32 lines, median CPU rendering still exceeded the 33.3 ms frame budget and median simulation work was 1.05 ms per rendered frame. The GPU was not independently traced again in this run. The legacy comparison exercises independent lines. The current ERP manages one shared production line.

The active ERP benchmark ran the same released 100-box milk order at 20× in three separate runs, each with 45 warm-up and 150 measured frames. Each ended at 45 cartons packed and four stored pallets, with 1,946 scene nodes. Memory is the median reported by Godot's static-memory monitor.

| Terminal state | FPS | CPU rendering p50 (ms) | Simulation per frame p50 (ms) | Engine-tracked memory p50 (MiB) |
| --- | ---: | ---: | ---: | ---: |
| Closed | 30.0 | 5.17 | 0.282 | 61.83 |
| Dashboard open | 30.0 | 5.41 | 0.262 | 62.42 |
| Closed after eight open/close cycles | 30.0 | 4.95 | 0.266 | 62.43 |

The first open added about 0.59 MiB of engine-tracked memory. After eight cycles the footprint stayed near that level, and the terminal refresh timer was stopped. The dashboard test covers a short interactive session. Large planning datasets, multi-line ERP scheduling, and long-session memory retention need separate benchmarks.

## Phase 4 regression

Godot 4.7.2 Compatibility on the same M4 Pro, at 1280 × 800 and the 30 FPS cap. Each run used 45 warm-up frames and 150 measured frames at 20×. The single-order runs used the Phase 3 100-box milk workload. Each packed 45 boxes and stored four pallets by the end of the sample.

| Phase 4 workload | FPS | CPU rendering p50 (ms) | Simulation per frame p50 (ms) | Engine-tracked memory p50 (MiB) |
| --- | ---: | ---: | ---: | ---: |
| One order, terminal closed | 30.0 | 5.27 | 0.427 | 63.65 |
| One order, dashboard open | 30.0 | 5.67 | 0.412 | 64.25 |
| Two active routes, terminal closed | 30.0 | 6.45 | 0.481 | 63.92 |

Against the Phase 3 closed-terminal run, the matched single-order median increased by 0.10 ms in CPU rendering, 0.145 ms in simulation work per frame, and 1.82 MiB of engine-tracked memory. The parallel run used a later window with two committed routes and ended with 88 cartons packed and eight pallets stored. It exercises contention but uses a different production state from the matched comparison. GPU execution was not traced in these samples.

The headless legacy workload’s p95 tick times at 1, 4, 8, 16, and 32 lines were 0.018, 0.070, 0.144, 0.272, and 0.561 ms. The matching Phase 3 figures were 0.016, 0.064, 0.128, 0.258, and 0.510 ms. The legacy harness uses independent lines and excludes ERP and shared resource scheduling.

## Build Mode

Native Godot 4.7.2 Compatibility on the same M4 Pro at 1280 × 800 and the 30 FPS cap. The factory was paused. Each case sampled 150 frames after 45 warm-up frames. The drag case submitted a distinct snapped Oven 02 position per measured frame. Of those, 43 passed placement validation.

| Mode | Rendered FPS | Factory update p50 / p95 (µs) | Preview p50 / p95 (ms per new cell) |
| --- | ---: | ---: | ---: |
| Pre-editor checkpoint | 30.0 | 69 / 133 | — |
| Editor closed | 30.0 | 63 / 127 | — |
| Build Mode idle after camera settled | No redraws in sample | 46 / 75 | — |
| Placement preview | 30.0 | 6 / 31 | 0.89 / 6.00 |

The factory-update column excludes the separately timed preview. Preview validation runs when the snapped cell or orientation changes and reuses cached results on revisits. A confirmed edit rebuilds the view and collision geometry. This short run measures the existing hall and waypoint routes.
