extends SceneTree
## Headless agent server. Newline-delimited JSON over TCP on 127.0.0.1.
##
##   godot --headless --path . --script res://agent/server.gd -- --port 8765 [--scenario res://scenarios/x.json]
##
## Request:  {"cmd": "status", "args": {}}
## Response: {"ok": true, "now": 0.0, ...}
## The extra command "shutdown" stops the server. To watch an agent instead, start the game
## with `-- --agent-port 8765`; the same protocol then drives the visible factory.

const API = preload("res://agent/agent_api.gd")
const Link = preload("res://agent/agent_link.gd")

var link: Link


func _initialize() -> void:
	var port := 8765
	var scenario := ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif args[i] == "--scenario" and i + 1 < args.size():
			scenario = args[i + 1]
	var api := API.new()
	if not api.line.validation_error.is_empty():
		printerr("AGENT_SERVER_ERROR " + api.line.validation_error)
		quit(1)
		return
	if not scenario.is_empty():
		var loaded := api.handle({"cmd": "load_scenario", "args": {"path": scenario}})
		if not loaded.ok:
			printerr("AGENT_SERVER_ERROR " + String(loaded.error))
			quit(1)
			return
	link = Link.new(api)
	var error := link.listen(port)
	if not error.is_empty():
		printerr("AGENT_SERVER_ERROR " + error)
		quit(1)
		return
	print("AGENT_SERVER_READY %d" % port)


func _process(_delta: float) -> bool:
	if link == null:
		return false
	var busy := link.poll()
	if link.shutdown_requested:
		link.stop()
		quit(0)
		return true
	if not busy:
		OS.delay_msec(10) # Keep the idle server cool.
	return false
