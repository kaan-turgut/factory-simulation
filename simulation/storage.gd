extends RefCounted
## One bounded inventory. The owner computes feasible transfers before applying them.

var capacity: float
var quantity: float = 0.0


func _init(initial_capacity: float) -> void:
	capacity = initial_capacity


func free_space() -> float:
	return capacity - quantity


func occupancy() -> float:
	return quantity / capacity if capacity > 0.0 else 0.0


func resize(requested: float) -> bool:
	if requested < quantity:
		return false
	capacity = requested
	return true


func apply_transfer(incoming: float, outgoing: float) -> void:
	# Bounds were checked against the starting inventory. Clamp roundoff at the edges.
	quantity = clampf((quantity - outgoing) + incoming, 0.0, capacity)


func remove(requested: float) -> float:
	var removed := clampf(requested, 0.0, quantity)
	quantity -= removed
	return removed
