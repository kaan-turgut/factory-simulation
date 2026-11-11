extends RefCounted
## Newline-delimited JSON over TCP on 127.0.0.1, shared by the headless server and the live game.
##
## Each client sends one request at a time and waits for its reply. A live time command replies
## later: the link keeps that client until the API reports the command finished.

const API = preload("res://agent/agent_api.gd")
const MAX_LINE_BYTES := 1 << 20

var api: API
## When false, "shutdown" is refused, so an agent cannot close the player's game.
var allow_shutdown := true
var shutdown_requested := false
var port := 0
var _server := TCPServer.new()
var _clients: Array[StreamPeerTCP] = []
var _buffers: Array[PackedByteArray] = []
var _waiting: StreamPeerTCP


func _init(agent_api: API) -> void:
	api = agent_api


func listen(requested_port: int) -> String:
	if _server.listen(requested_port, "127.0.0.1") != OK:
		return "Cannot listen on port %d." % requested_port
	port = requested_port
	return ""


func stop() -> void:
	for client in _clients:
		client.disconnect_from_host()
	_clients.clear()
	_buffers.clear()
	_server.stop()


## Accept connections and answer complete requests. Returns true when data arrived.
func poll() -> bool:
	var busy := false
	while _server.is_connection_available():
		_clients.append(_server.take_connection())
		_buffers.append(PackedByteArray())
	for i in range(_clients.size() - 1, -1, -1):
		var client := _clients[i]
		client.poll()
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			if client == _waiting:
				_waiting = null
			_clients.remove_at(i)
			_buffers.remove_at(i)
			continue
		var count := client.get_available_bytes()
		if count <= 0:
			continue
		busy = true
		var chunk: Array = client.get_partial_data(count)
		if chunk[0] != OK:
			continue
		_buffers[i].append_array(chunk[1])
		if _buffers[i].size() > MAX_LINE_BYTES:
			_send(client, {"ok": false, "error": "Request too large."})
			_buffers[i].clear()
			continue
		while true:
			var newline := _buffers[i].find(10)
			if newline < 0:
				break
			var text := _buffers[i].slice(0, newline).get_string_from_utf8().strip_edges()
			_buffers[i] = _buffers[i].slice(newline + 1)
			if not text.is_empty():
				_answer(client, text)
			if shutdown_requested:
				return true
	return busy


## Live mode: report played simulation time and deliver a finished time command.
func tick(seconds: float) -> void:
	var reply := api.live_step(seconds)
	if not reply.is_empty() and _waiting != null:
		_send(_waiting, reply)
		_waiting = null


func _answer(client: StreamPeerTCP, text: String) -> void:
	var request: Variant = JSON.parse_string(text)
	if not request is Dictionary:
		_send(client, {"ok": false, "error": "Send one JSON object per line."})
		return
	if request.get("cmd") == "shutdown":
		if allow_shutdown:
			_send(client, {"ok": true, "stopping": true})
			shutdown_requested = true
		else:
			_send(client, {"ok": false, "error": "The live game stays open. Close it from its window."})
		return
	var response := api.handle(request)
	if response.get("pending", false):
		_waiting = client
		return
	_send(client, response)


func _send(client: StreamPeerTCP, response: Dictionary) -> void:
	client.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())
