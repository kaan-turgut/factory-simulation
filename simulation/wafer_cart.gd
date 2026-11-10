extends RefCounted
## A reusable raw, cooked or coated tray cart with a physical position and one task owner.

const Storage = preload("res://simulation/storage.gd")
enum Site { PARKING, EXTRUDER, OVEN_RAW, OVEN_COOKED, COATER, TRANSIT, COATER_OUT, PACK_WIP }

const SITE_NAMES := ["Cart parking", "Extruder output", "Oven loading", "Oven unloading",
	"Coating intake", "In transit", "Coater outfeed", "Packaging WIP"]

var id: StringName
var raw: bool
var coated: bool
var stock: Storage
var site := Site.PARKING
var home: Vector3
var position: Vector3
var previous_position: Vector3
var heading := PI
var owner: StringName = &""
var order_id := ""


func _init(key: StringName, is_raw: bool, capacity: float, parking: Vector3, is_coated: bool = false) -> void:
	id = key
	raw = is_raw
	coated = is_coated
	stock = Storage.new(capacity)
	home = parking
	position = home
	previous_position = position


func title() -> String:
	var prefix := "Coated" if coated else ("Raw" if raw else "Cooked")
	return "%s cart %s" % [prefix, String(id).right(1)]


func state_title() -> String:
	if site == Site.TRANSIT:
		return "In transport"
	if stock.quantity == 0.0:
		return "Empty"
	return "Full" if stock.free_space() <= 1e-8 else "Filling"
