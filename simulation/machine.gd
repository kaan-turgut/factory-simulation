extends RefCounted
## Rate settings and measured production for one machine.

enum State { IDLE, RUNNING, BLOCKED, STARVED, SETUP }

var configured_rate: float
var actual_rate: float = 0.0
var state: State = State.IDLE
var total_output: float = 0.0


func _init(initial_rate: float) -> void:
	configured_rate = initial_rate


func record(output: float, hours: float, new_state: State) -> void:
	total_output += output
	actual_rate = output / hours
	state = new_state


func idle() -> void:
	actual_rate = 0.0
	state = State.IDLE


func reset() -> void:
	idle()
	total_output = 0.0
