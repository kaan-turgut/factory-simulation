extends RefCounted
## A task owner with timed work and distance-based travel. Positions are simulation data.

enum State { IDLE, WALKING, CARRYING, PUSHING, LOADING, UNLOADING, DRIVING, MOVING_PALLET_JACK }

const TITLES := ["Idle", "Walking", "Carrying sack", "Pushing cart", "Loading", "Unloading", "Driving", "Moving pallet jack"]

var id: StringName
var title: String
var position: Vector3
var previous_position: Vector3
var heading := PI
var state: State = State.IDLE
var task := ""
var destination := ""
var remaining := 0.0
var cargo_kg := 0.0
var reserved_kg := 0.0
var _route: Array[Vector3] = []


func _init(key: StringName, display_name: String, at: Vector3) -> void:
	id = key
	title = display_name
	position = at
	previous_position = at


func travel(path: Array[Vector3], motion: State, job_name: String, target: String) -> void:
	_route = path.duplicate()
	remaining = 0.0
	state = motion
	task = job_name
	destination = target


func work(seconds: float, action: State) -> void:
	remaining = seconds
	state = action


## Speed of a freight lift cage, in metres per second.
const LIFT_SPEED := 0.7

## Load-based slowdown. The configured crew speeds are normal unladen walking (about 5 km/h).
## Carrying, pushing and pulling slow a person down by the mass they move. Typical figures:
## a 25 kg sack in both arms about 1.1 m/s, a loaded cart about 1 m/s, a loaded pallet jack
## about 0.85 m/s.
const SACK_DRAG := 0.008        # share of walking speed lost per kg carried in both arms
const CART_DRAG := 0.003        # per kg of cart plus load pushed on its wheels
const CART_EMPTY_KG := 40.0     # a wafer tray cart without stock
const JACK_DRAG := 0.0008       # per kg of pallet jack plus load; a loaded pallet jack rolls easily
const JACK_EMPTY_KG := 60.0
const MIN_LOADED_PACE := 0.55
const MIN_JACK_PACE := 0.6


## Share of normal walking speed while carrying `kilograms` in both arms.
static func carry_pace(kilograms: float) -> float:
	return clampf(1.0 - SACK_DRAG * kilograms, MIN_LOADED_PACE, 1.0)


## Share of normal walking speed while pushing a cart holding `load_kg` of stock.
static func cart_pace(load_kg: float) -> float:
	return clampf(1.0 - CART_DRAG * (CART_EMPTY_KG + load_kg), MIN_LOADED_PACE, 1.0)


## Share of normal walking speed while pulling a pallet jack carrying `load_kg`.
static func jack_pace(load_kg: float) -> float:
	return clampf(1.0 - JACK_DRAG * (JACK_EMPTY_KG + load_kg), MIN_JACK_PACE, 1.0)


func advance(seconds: float, speed: float) -> void:
	previous_position = position
	remaining = maxf(0.0, remaining - seconds)
	var distance := speed * seconds
	while not _route.is_empty():
		var offset := _route[0] - position
		var length := offset.length()
		var vertical := Vector2(offset.x, offset.z).length() < 0.00001 and absf(offset.y) > 0.00001
		if not vertical and length > 0.00001:
			heading = atan2(offset.x, offset.z)
		# A lift rides at its own speed: the same walking budget covers less height.
		var cost := length * speed / LIFT_SPEED if vertical else length
		if cost > distance:
			position += offset * (distance / cost)
			return
		distance -= cost
		position = _route.pop_front()


func finished() -> bool:
	return _route.is_empty() and remaining == 0.0


func idle() -> void:
	state = State.IDLE
	task = ""
	destination = ""


func state_title() -> String:
	return TITLES[state]
