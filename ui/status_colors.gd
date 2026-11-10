extends RefCounted

const Machine = preload("res://simulation/machine.gd")

const RUNNING := Color("#71ebbe")
const BLOCKED := Color("#ffc367")
const STARVED := Color("#ffa59c")
const IDLE := Color("#a0b3c5")
const SFG := Color("#65d9d8")
const FG := Color("#f2bf71")


static func color(state: Machine.State) -> Color:
	match state:
		Machine.State.RUNNING:
			return RUNNING
		Machine.State.BLOCKED:
			return BLOCKED
		Machine.State.STARVED:
			return STARVED
		Machine.State.SETUP:
			return Color("#b3a5ff")
		_:
			return IDLE


static func title(state: Machine.State) -> String:
	match state:
		Machine.State.RUNNING:
			return "Running"
		Machine.State.BLOCKED:
			return "Blocked"
		Machine.State.STARVED:
			return "Starved"
		Machine.State.SETUP:
			return "Setup"
		_:
			return "Idle"
