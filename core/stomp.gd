extends Node
## STOMP over raw WebSocket. Autoload "Stomp".

signal connected
signal message(destination: String, body: Variant)
signal error(code: String)
signal closed

var ws := WebSocketPeer.new()
var _connected := false
var _intentional_close := false
var _reconnecting := false
var _last_state := WebSocketPeer.STATE_CLOSED
var _subs := {} # id -> destination
var _sub_counter := 0


func _process(_delta: float) -> void:
	var state := ws.get_ready_state()
	if state != WebSocketPeer.STATE_CLOSED:
		ws.poll()
		state = ws.get_ready_state()
	if state != _last_state:
		if state == WebSocketPeer.STATE_OPEN:
			_send_connect()
		elif state == WebSocketPeer.STATE_CLOSED:
			_connected = false
			closed.emit()
			if not _intentional_close:
				_schedule_reconnect()
	_last_state = state
	if state == WebSocketPeer.STATE_OPEN:
		while ws.get_available_packet_count() > 0:
			_handle_packet(decode(ws.get_packet()))


func connect_ws() -> void:
	_intentional_close = false
	ws = WebSocketPeer.new()
	var origin: String = get_node("/root/Api").origin()
	var url: String = "ws" + origin.trim_prefix("http") + "/ws"
	ws.connect_to_url(url)
	_last_state = WebSocketPeer.STATE_CLOSED


func subscribe(destination: String) -> String:
	_sub_counter += 1
	var id := "sub-%d" % _sub_counter
	_subs[id] = destination
	if _connected:
		_send_subscribe(id, destination)
	return id


func unsubscribe(id: String) -> void:
	if not _subs.has(id):
		return
	if _connected:
		_send(build_frame("UNSUBSCRIBE", {"id": id}, ""))
	_subs.erase(id)


func disconnect_ws() -> void:
	_intentional_close = true
	if _connected:
		_send(build_frame("DISCONNECT", {}, ""))
	ws.close()
	_subs.clear()
	_connected = false


func _send_connect() -> void:
	var api := get_node("/root/Api")
	var host: String = api.origin().trim_prefix("https://").trim_prefix("http://")
	var headers := {"accept-version": "1.2", "host": host, "heart-beat": "0,0"}
	if api.access_token != "":
		headers["Authorization"] = "Bearer " + api.access_token
	_send(build_frame("CONNECT", headers, ""))


func _send_subscribe(id: String, destination: String) -> void:
	_send(build_frame("SUBSCRIBE", {"id": id, "destination": destination}, ""))


func _send(frame: String) -> void:
	ws.send(encode(frame), WebSocketPeer.WRITE_MODE_TEXT)


func _handle_packet(text: String) -> void:
	if text.strip_edges() == "":
		return # heartbeat
	var frame := parse_frame(text)
	match frame.command:
		"CONNECTED":
			_connected = true
			connected.emit()
			for id in _subs:
				_send_subscribe(id, _subs[id])
		"MESSAGE":
			var dest: String = frame.headers.get("destination", "")
			message.emit(dest, JSON.parse_string(frame.body))
		"ERROR":
			var code: String = frame.headers.get("errorCode", frame.headers.get("message", "STOMP_ERROR"))
			error.emit(code)
			if code == "AUTHENTICATION_REQUIRED":
				if not await get_node("/root/Api")._refresh():
					_intentional_close = true
			else:
				_intentional_close = true


func _schedule_reconnect() -> void:
	if _reconnecting:
		return
	_reconnecting = true
	# ponytail: fixed 2s interval, switch to exponential backoff if server load becomes an issue
	await get_tree().create_timer(2.0).timeout
	_reconnecting = false
	if not _intentional_close:
		connect_ws()


static func build_frame(command: String, headers: Dictionary, body: String) -> String:
	var lines := [command]
	for key in headers:
		lines.append("%s:%s" % [key, headers[key]])
	return "\n".join(lines) + "\n\n" + body


static func encode(frame: String) -> PackedByteArray:
	var bytes := frame.to_utf8_buffer()
	bytes.append(0)
	return bytes


static func decode(bytes: PackedByteArray) -> String:
	var end := bytes.size()
	while end > 0 and bytes[end - 1] == 0:
		end -= 1
	return bytes.slice(0, end).get_string_from_utf8()


static func parse_frame(text: String) -> Dictionary:
	var t := text.lstrip("\n")
	var parts := t.split("\n\n", true, 1)
	var head_lines := parts[0].split("\n")
	var headers := {}
	for i in range(1, head_lines.size()):
		var line: String = head_lines[i]
		var idx := line.find(":")
		if idx >= 0:
			headers[line.substr(0, idx)] = line.substr(idx + 1)
	return {"command": head_lines[0], "headers": headers, "body": parts[1] if parts.size() > 1 else ""}
