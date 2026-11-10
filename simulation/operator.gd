extends RefCounted
## A task owner with timed work and distance-based travel. Positions are simulation data.

enum State { IDLE, WALKING, CARRYING, PUSHING, LOADING, UNLOADING, DRIVING }

const TITLES := ["Idle", "Walking", "Carrying sack", "Pushing cart", "Loading", "Unloading", "Driving"]

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


func advance(seconds: float, speed: float) -> void:
	previous_position = position
	remaining = maxf(0.0, remaining - seconds)
	var distance := speed * seconds
	while not _route.is_empty():
		var offset := _route[0] - position
		var length := offset.length()
		if length > 0.00001:
			heading = atan2(offset.x, offset.z)
		if length > distance:
			position += offset * (distance / length)
			return
		distance -= length
		position = _route.pop_front()


func finished() -> bool:
	return _route.is_empty() and remaining == 0.0


func idle() -> void:
	state = State.IDLE
	task = ""
	destination = ""


func state_title() -> String:
	return TITLES[state]
