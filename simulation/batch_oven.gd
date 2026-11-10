extends RefCounted
## A single oven chamber. Time and batch size are fixed once cooking begins.

const Storage = preload("res://simulation/storage.gd")
enum State { IDLE, LOADING, COOKING, READY, UNLOADING }
const TITLES := ["Idle", "Loading", "Cooking", "Ready", "Unloading"]

var stock: Storage
var state: State = State.IDLE
var remaining := 0.0
var batches := 0
var owner: StringName = &""


func _init(capacity: float) -> void:
	stock = Storage.new(capacity)


func advance(seconds: float, next_duration: float) -> void:
	if state == State.COOKING:
		remaining = maxf(0.0, remaining - seconds)
		if remaining <= 1e-8:
			remaining = 0.0
			state = State.READY
			batches += 1
	elif owner == &"" and can_load() and stock.free_space() <= 1e-8:
		start(next_duration)


func start(duration: float) -> void:
	state = State.COOKING
	remaining = duration


func can_load() -> bool:
	return state == State.IDLE or state == State.LOADING


func state_title() -> String:
	return TITLES[state]
