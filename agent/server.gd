extends SceneTree
## Headless agent server. Newline-delimited JSON over TCP on 127.0.0.1.
##
##   godot --headless --path . --script res://agent/server.gd -- --port 8765 [--scenario res://scenarios/x.json]
##
## Request:  {"cmd": "status", "args": {}}
## Response: {"ok": true, "now": 0.0, ...}
## The extra command "shutdown" stops the server.

const API = preload("res://agent/agent_api.gd")
const MAX_LINE_BYTES := 1 << 20

var api: API
var server := TCPServer.new()
var clients: Array[StreamPeerTCP] = []
var buffers: Array[PackedByteArray] = []


func _initialize() -> void:
	var port := 8765
	var scenario := ""
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif args[i] == "--scenario" and i + 1 < args.size():
			scenario = args[i + 1]
	api = API.new()
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
	if server.listen(port, "127.0.0.1") != OK:
		printerr("AGENT_SERVER_ERROR cannot listen on port %d" % port)
		quit(1)
		return
	print("AGENT_SERVER_READY %d" % port)


func _process(_delta: float) -> bool:
	var busy := false
	while server.is_connection_available():
		clients.append(server.take_connection())
		buffers.append(PackedByteArray())
	for i in range(clients.size() - 1, -1, -1):
		var client := clients[i]
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.remove_at(i)
			buffers.remove_at(i)
			continue
		var count := client.get_available_bytes()
		if count <= 0:
			continue
		busy = true
		var chunk: Array = client.get_partial_data(count)
		if chunk[0] != OK:
			continue
		buffers[i].append_array(chunk[1])
		if buffers[i].size() > MAX_LINE_BYTES:
			_send(client, {"ok": false, "error": "Request too large."})
			buffers[i].clear()
			continue
		while true:
			var newline := buffers[i].find(10)
			if newline < 0:
				break
			var text := buffers[i].slice(0, newline).get_string_from_utf8().strip_edges()
			buffers[i] = buffers[i].slice(newline + 1)
			if text.is_empty():
				continue
			if not _answer(client, text):
				return true
	if not busy:
		OS.delay_msec(10) # Keep the idle server cool.
	return false


func _answer(client: StreamPeerTCP, text: String) -> bool:
	var request: Variant = JSON.parse_string(text)
	if not request is Dictionary:
		_send(client, {"ok": false, "error": "Send one JSON object per line."})
		return true
	if request.get("cmd") == "shutdown":
		_send(client, {"ok": true, "stopping": true})
		quit(0)
		return false
	_send(client, api.handle(request))
	return true


func _send(client: StreamPeerTCP, response: Dictionary) -> void:
	client.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())
