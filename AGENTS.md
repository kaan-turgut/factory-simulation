# Factory Simulator — Agent Instructions

## Project Overview
An interactive 3D manufacturing simulation built with Godot 4.7.2 and GDScript.

The goal is to combine realistic industrial production behavior with an accessible management-game experience inspired by The Sims and Age of Empires.

## Development Principles
- Prioritize simulation correctness, usability, and modularity.
- Use built-in Godot functionality wherever practical.
- Keep simulation logic independent of rendering, animation, and UI.
- Implement reusable machines, buffers, and storage components.
- Avoid unnecessary external dependencies.
- Maintain a clean, understandable 3D environment.
- Design for future expansion without overengineering the initial implementation.

## Simulation Requirements
- Use deterministic simulation time, independent of frame rate.
- Use product, operation, and work center standards for planning and execution. Keep native units for rate standards and use kg for physical food mass.
- Enforce inventory capacity constraints and material conservation.
- Model starvation, blocking, and downstream constraints.
- Ensure simulation speed multipliers affect simulated time rather than configured machine rates.
- Keep visualization synchronized with authoritative simulation state.
- Never use animations or physics collisions to calculate production quantities.

## Godot Conventions
- Use Godot 4.7.2-compatible GDScript.
- Prefer reusable scenes and modular scripts.
- Use typed GDScript where practical.
- Keep scene references and signal connections maintainable.
- Use primitive 3D geometry until more detailed assets become necessary.
- Support smooth, Sims-style camera navigation and object selection.

## Testing and Validation
- Validate new GDScript and scenes whenever practical.
- Run automated simulation tests when modifying production logic.
- Check edge cases involving empty buffers, full warehouses, zero production rates, and changing parameters.
- Confirm that the project launches from its configured main scene.
- Do not claim interactive or graphical testing was completed unless it was actually performed.
- Document any testing limitations.

## Agent Autonomy
- Make implementation and architectural decisions independently.
- Do not request approval for routine coding, refactoring, scene organization, UI layout, or data structures.
- Fix discovered bugs and validation errors proactively.
- Do not remove working features unnecessarily.
- Favor delivering functional implementations over extensive planning.
- Briefly summarize implemented changes, tests performed, and remaining limitations after each task.

## Documentation
- Keep README.md updated with installation, launch, and controls.
- Document important architectural decisions when necessary.
- Keep instructions understandable for a user without game-development experience.

## ERP Consistency
- Raw and received semi-finished stock and reservations belong to the ERP ledger. Derive in-process WIP and finished goods from physical buffers, carts, and tagged pallets.
- Freeze the executable recipe and product specification on each order. Route consumption and receipts through fixed-step production events.
- Keep planning proposals separate from executable orders and keep posted movements append-only.
- Run the ERP integration and scene tests when changing transaction logic, snapshots, or the terminal.

## Detailed Scheduling
- Each manufactured stage requires its own scheduled and released order. A demand, proposal, scheduled receipt, or pegging link cannot start equipment or satisfy a physical release check.
- Stage overlap is the one exception, and only for stages with a `start_kg` in `scheduling.json`: a stage may release once that first lot of each manufactured input is physically in stock and the rest is covered by stock plus the unreceived output of released or running upstream orders, net of every claim. Purchased inputs always need their full quantity in stock. An upstream order that others count on cannot be cancelled.
- Reserve only immediate BOM components, atomically. Post issues and receipts when simulated work or transport actually occurs.
- Keep planned intervals separate from actual times. Freeze the executable route, production standard, setup rules, and BOM on release. Check both calendar and finite resource availability for schedule edits.
- Keep the Gantt a readout and editor of authoritative orders. Run the detailed scheduling test for changes to planning, routing, WIP handoffs, or ERP persistence.

## External Master Data
- Keep demonstration definitions in `master_data/` and validate references, machine capabilities, and physical ports before starting a simulation run.
- Preserve released routing and BOM snapshots. Keep work-center commitments and cart ownership tied to production order IDs.
- Run the alternative routing integration test when changing dispatch, transport, eligibility, or save migration. Run the production standards suite for changes to rate models, expanded cells, or their save data.

## Layout Editing
- Validate the entire proposed plan before confirming moves, including linked equipment, clearances, and all logistics approaches.
- Apply edits only while production and transport are idle. Resolve future tasks against the current ports and keep order and work center IDs stable.
- Keep standalone layout files limited to placements. Run the layout editor test when changing drag input, layout validation, persistence, or navigation after a move.
