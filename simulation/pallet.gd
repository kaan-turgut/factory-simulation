extends RefCounted
## Each pallet keeps the box count it was started with and its exact packed mass.

var target_boxes: int
var boxes := 0
var mass := 0.0
var id := ""
var sku := ""
var order_id := ""
var tint := ""
var sealed := false


func _init(target: int) -> void:
	target_boxes = target


func full() -> bool:
	return sealed or boxes >= target_boxes


func add_box(kg: float) -> void:
	boxes += 1
	mass += kg
