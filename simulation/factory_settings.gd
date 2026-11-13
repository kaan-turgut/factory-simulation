extends RefCounted
## Setting definitions shared by simulation validation and the station inspector.

const Master = preload("res://erp/master_files.gd")
const TECHNICAL := {
	&"extruder_rate": ["Extruder", "rate"], &"coater_rate": ["Coater", "rate"],
	&"coater_input": ["Coater", "input_kg"], &"batch_capacity": ["Oven", "batch_kg"],
	&"cook_minutes": ["Oven", "cycle_seconds", 60.0], &"packing_rate": ["Packer", "rate"],
	&"batch_capacity_02": ["Oven02", "batch_kg"], &"cook_minutes_02": ["Oven02", "cycle_seconds", 60.0],
	&"coater_rate_02": ["Coater02", "rate"], &"coater_input_02": ["Coater02", "input_kg"]
}

# Label, minimum, maximum, increment.
const SPECS := {
	&"sack_kg": ["Sack weight (kg)", 1.0, 100.0, 0.5],
	&"hopper_capacity": ["Hopper capacity (kg)", 1.0, 500.0, 0.5],
	&"platform_speed": ["Platform crew speed (m/s)", 0.25, 5.0, 0.05],
	&"pickup_time": ["Sack pickup (sim s)", 0.25, 30.0, 0.25],
	&"unload_time": ["Sack unloading (sim s)", 0.25, 30.0, 0.25],
	&"floor_speed": ["Floor crew speed (m/s)", 0.25, 5.0, 0.05],
	&"floor_count": ["Floor crew (applies when idle)", 1.0, 4.0, 1.0],
	&"extruder_rate": ["Extrusion rate (kg/h)", 0.0, 36000.0, 1.0],
	&"raw_capacity": ["Raw cart capacity (kg)", 1.0, 300.0, 0.5],
	&"raw_count": ["Raw carts (applies when idle)", 1.0, 4.0, 1.0],
	&"batch_capacity": ["Batch Capacity (kg)", 1.0, 300.0, 0.5],
	&"cook_minutes": ["Cook Time (sim min)", 0.05, 30.0, 0.05],
	&"batch_capacity_02": ["Batch Capacity (kg)", 1.0, 300.0, 0.5],
	&"cook_minutes_02": ["Cook Time (sim min)", 0.05, 30.0, 0.05],
	&"coater_rate_02": ["Coating Rate (kg/h)", 0.0, 36000.0, 1.0],
	&"coater_input_02": ["Staging Area Capacity (kg)", 1.0, 500.0, 0.5],
	&"cooked_capacity": ["Cooked cart capacity (kg)", 1.0, 300.0, 0.5],
	&"cooked_count": ["Cooked carts (applies when idle)", 1.0, 4.0, 1.0],
	&"coated_cart_capacity": ["Coated cart capacity (kg)", 1.0, 300.0, 0.5],
	&"coated_cart_count": ["Coated carts (applies when idle)", 1.0, 4.0, 1.0],
	&"pack_wip_capacity": ["Packaging WIP capacity (kg)", 1.0, 500.0, 0.5],
	&"coater_rate": ["Coating Rate (kg/h)", 0.0, 36000.0, 1.0],
	&"coater_input": ["Staging Area Capacity (kg)", 1.0, 500.0, 0.5],
	&"packing_rate": ["Packaging rate (kg/h)", 0.0, 36000.0, 1.0],
	&"box_kg": ["Box size (kg)", 1.0, 50.0, 0.25],
	&"pallet_boxes": ["Boxes per pallet", 1.0, 32.0, 1.0],
	&"lift_speed": ["Forklift speed (m/s)", 0.25, 8.0, 0.05]
}


static func load_values(directory: String = "") -> Dictionary:
	var result := Master.read("simulation_defaults", directory)
	if not result.error.is_empty():
		return result
	if not result.data is Dictionary:
		return {"error": "simulation_defaults.json: expected named parameters."}
	var centers := Master.index("work_centers", "id", ["equipment", "technical"], directory)
	if not centers.error.is_empty():
		return centers
	var equipment := {}
	for row in centers.data.values():
		equipment[row.equipment] = row.technical
	var values: Dictionary[StringName, float] = {}
	for key in SPECS:
		var spec: Array = SPECS[key]
		var value: Variant = result.data.get(String(key))
		if TECHNICAL.has(key):
			value = null
			var ref: Array = TECHNICAL[key]
			var technical: Variant = equipment.get(ref[0], {})
			if technical is Dictionary:
				var source: Variant = technical.get("max_rate_kg_h", technical.get(ref[1])) if ref[1] == "rate" else technical.get(ref[1])
				if Master.number(source):
					value = float(source) / (ref[2] if ref.size() == 3 else 1.0)
		var whole: bool = key in [&"floor_count", &"raw_count", &"cooked_count", &"coated_cart_count", &"pallet_boxes"]
		if not Master.number(value, spec[1], spec[2], whole):
			return {"error": "%s.json [%s]: missing or outside permitted range." % [
				"work_centers" if TECHNICAL.has(key) else "simulation_defaults", key]}
		values[key] = float(value)
	return {"error": "", "data": values}


static func defaults() -> Dictionary[StringName, float]:
	var result := load_values()
	var values: Dictionary[StringName, float] = {}
	# Safe construction values allow the scene to display validation errors before running.
	for key in SPECS:
		values[key] = result.get("data", {}).get(key, SPECS[key][1])
	return values
