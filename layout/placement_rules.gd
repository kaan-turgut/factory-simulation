extends RefCounted
## Reusable footprint, clearance and support checks for a rectangular factory grid.

const Grid = preload("res://layout/factory_grid.gd")
const Placement = preload("res://layout/placement.gd")

static func validate(
	grid: Grid, item: Placement, objects: Dictionary, reserved: Array[Rect2i]
) -> String:
	if item.size.x < 1 or item.size.y < 1 or not is_finite(item.height) \
			or not is_finite(item.elevation) or item.height <= 0.0 or item.elevation < 0.0:
		return "Footprint, height and elevation must be valid."
	if mini(mini(item.clearance.x, item.clearance.y), mini(item.clearance.z, item.clearance.w)) < 0:
		return "Operational clearance cannot be negative."
	if not grid.bounds().encloses(item.required_area()):
		return "Footprint or clearance crosses the interior wall."
	if is_zero_approx(item.elevation):
		for region in reserved:
			if item.footprint().intersects(region):
				return "Footprint blocks a reserved aisle or exit."
	var supported := is_zero_approx(item.elevation) or item.kind == &"platform"
	for other: Placement in objects.values():
		if other.id == item.id:
			continue
		if other.kind == &"platform" and item.kind != &"platform" \
				and is_equal_approx(other.elevation, item.elevation):
			supported = supported or other.footprint().encloses(item.required_area())
			continue
		if item.kind == &"platform" and other.kind != &"platform" \
				and is_equal_approx(other.elevation, item.elevation):
			continue
		if item.elevation >= other.elevation + other.height 				or other.elevation >= item.elevation + item.height:
			continue
		if item.footprint().intersects(other.footprint()):
			return "Footprint overlaps %s." % other.id
		if item.footprint().intersects(other.required_area()) 				or other.footprint().intersects(item.required_area()):
			return "Operational clearance conflicts with %s." % other.id
	return "" if supported else "Elevated footprint requires a supporting platform."
