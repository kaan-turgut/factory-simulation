extends RefCounted
## Read-only time accounting per work center, for bottleneck analysis.
## Samples the line's own status readouts; never writes simulation state.

const BUCKETS := ["working", "setup", "starved", "blocked", "handling", "no_work"]

var totals := {}      # center id -> {bucket: seconds}
var statuses := {}    # center id -> {raw status text: seconds}
var observed := 0.0


func reset() -> void:
	totals.clear()
	statuses.clear()
	observed = 0.0


static func bucket(status: String, has_order: bool) -> String:
	if status in ["Running", "Cooking", "Mixing", "Cooling", "Packaging", "Preparing"]:
		return "working"
	if status.begins_with("Setup"):
		return "setup"
	if status in ["Blocked", "Ready", "Waiting for output cart"]:
		return "blocked"
	if status in ["Loading", "Unloading"]:
		return "handling"
	if status == "Idle" and not has_order:
		return "no_work"
	# Starved, waiting for input, waiting for a batch, or idle while an order is assigned.
	return "starved"


func sample(line, seconds: float) -> void:
	observed += seconds
	for center in line.erp.catalog.work_centers.values():
		var equipment := StringName(center.equipment)
		var has_order: bool = not line.order_at(equipment).is_empty()
		var status: String = line.work_center_status(equipment)
		var id: String = center.id
		if not totals.has(id):
			totals[id] = {}
			for name in BUCKETS:
				totals[id][name] = 0.0
			statuses[id] = {}
		var key := bucket(status, has_order)
		totals[id][key] += seconds
		statuses[id][status] = float(statuses[id].get(status, 0.0)) + seconds


func report(id: String) -> Dictionary:
	var row: Dictionary = totals.get(id, {})
	var shares := {}
	for name in BUCKETS:
		shares[name] = snappedf(float(row.get(name, 0.0)) / observed, 0.001) if observed > 0.0 else 0.0
	return {"seconds": row.duplicate(), "share": shares, "status_seconds": statuses.get(id, {}).duplicate()}
