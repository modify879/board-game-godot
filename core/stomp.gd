extends Node
## STOMP over raw WebSocket. Autoload "Stomp".

signal connected
signal message(destination: String, body: Variant)
signal error(code: String)
signal closed

const AUTH_SUB_ID := "sub-auth" # 공개 replay 목록(_subs)에 넣지 않는 내부 채널 구독 id
const AUTH_DEST := "/user/queue/auth"

var ws := WebSocketPeer.new()
var _connected := false
var _intentional_close := false
var _reconnecting := false
var _last_state := WebSocketPeer.STATE_CLOSED
var _subs := {} # id -> destination
var _sub_counter := 0

var _rotate_ws: WebSocketPeer = null
var _rotate_last_state := WebSocketPeer.STATE_CLOSED
var _rotating := false
var _auth_deadline_generation := 0


func _ready() -> void:
	get_node("/root/Api").token_refreshed.connect(_on_token_refreshed)


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
			var reason := ws.get_close_reason()
			var code := ws.get_close_code()
			closed.emit()
			if not _intentional_close:
				if code == 1008 or reason.contains("AUTHENTICATION_REQUIRED"):
					_reauth_reconnect()
				else:
					_schedule_reconnect()
	_last_state = state
	if state == WebSocketPeer.STATE_OPEN:
		while ws.get_available_packet_count() > 0:
			_handle_packet(decode(ws.get_packet()))
	if _rotate_ws != null:
		_process_rotate()


func connect_ws() -> void:
	_intentional_close = false
	ws = WebSocketPeer.new()
	var origin: String = get_node("/root/Api").origin()
	var url: String = "ws" + origin.trim_prefix("http") + "/ws"
	ws.connect_to_url(url)
	_last_state = WebSocketPeer.STATE_CLOSED


func send(destination: String, body: Variant) -> void:
	if not _connected:
		return
	_send(build_frame("SEND", {"destination": destination, "content-type": "application/json"}, JSON.stringify(body)))


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


func _connect_headers() -> Dictionary:
	var api := get_node("/root/Api")
	var host: String = api.origin().trim_prefix("https://").trim_prefix("http://")
	var headers := {"accept-version": "1.2", "host": host, "heart-beat": "0,0"}
	if api.access_token != "":
		headers["Authorization"] = "Bearer " + api.access_token
	return headers


func _send_connect() -> void:
	_send(build_frame("CONNECT", _connect_headers(), ""))


func _send_subscribe(id: String, destination: String) -> void:
	_send(build_frame("SUBSCRIBE", {"id": id, "destination": destination}, ""))


func _send(frame: String) -> void:
	_send_on(ws, frame)


func _send_on(peer: WebSocketPeer, frame: String) -> void:
	peer.send(encode(frame), WebSocketPeer.WRITE_MODE_TEXT)


func _handle_packet(text: String) -> void:
	if text.strip_edges() == "":
		return # heartbeat
	var frame := parse_frame(text)
	match frame.command:
		"CONNECTED":
			_connected = true
			_send_subscribe(AUTH_SUB_ID, AUTH_DEST)
			connected.emit()
			for id in _subs:
				_send_subscribe(id, _subs[id])
		"MESSAGE":
			var dest: String = frame.headers.get("destination", "")
			var parsed = JSON.parse_string(frame.body)
			if dest == AUTH_DEST:
				_handle_auth_reply(parsed)
			else:
				message.emit(dest, parsed)
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


func _reauth_reconnect() -> void:
	# 소켓이 AUTHENTICATION_REQUIRED 로 닫혔다 — REST 로 먼저 갱신한 뒤에만 재연결한다.
	# 실패하면 Api._refresh() 가 이미 로그인 화면으로 보낸다.
	if await get_node("/root/Api")._refresh():
		connect_ws()


# --- 인밴드 토큰 갱신 (make-before-break 소켓 교체) ---

func _on_token_refreshed() -> void:
	if not _connected:
		return
	var api := get_node("/root/Api")
	send("/app/auth/refresh", {"accessToken": api.access_token})
	_auth_deadline_generation += 1
	var generation := _auth_deadline_generation
	get_tree().create_timer(30.0).timeout.connect(_on_auth_deadline.bind(generation))


func _on_auth_deadline(generation: int) -> void:
	if generation == _auth_deadline_generation:
		_rotate()


func _handle_auth_reply(body: Variant) -> void:
	if body is Dictionary and body.get("result") == "OK":
		_auth_deadline_generation += 1 # 마감 타이머 무효화
	else:
		_rotate()


func _rotate() -> void:
	if _rotating or not _connected:
		return
	_rotating = true
	# make-before-break: 새 소켓이 CONNECTED 되고 구독을 옮긴 뒤에야 옛 소켓을 끊는다.
	# 먼저 끊으면 그 사이 대기열에서 빠질 수 있다(다른 세션이 없으면 서버가 큐를 비운다).
	_rotate_ws = WebSocketPeer.new()
	var origin: String = get_node("/root/Api").origin()
	var url: String = "ws" + origin.trim_prefix("http") + "/ws"
	_rotate_ws.connect_to_url(url)
	_rotate_last_state = WebSocketPeer.STATE_CLOSED


func _process_rotate() -> void:
	var state := _rotate_ws.get_ready_state()
	if state != WebSocketPeer.STATE_CLOSED:
		_rotate_ws.poll()
		state = _rotate_ws.get_ready_state()
	if state != _rotate_last_state:
		if state == WebSocketPeer.STATE_OPEN:
			_send_on(_rotate_ws, build_frame("CONNECT", _connect_headers(), ""))
		elif state == WebSocketPeer.STATE_CLOSED:
			# 새 소켓 연결 실패 — 옛 소켓을 그대로 두고 평소 재연결 경로에 맡긴다
			_rotate_ws = null
			_rotating = false
			return
	_rotate_last_state = state
	if state == WebSocketPeer.STATE_OPEN:
		while _rotate_ws.get_available_packet_count() > 0:
			var frame := parse_frame(decode(_rotate_ws.get_packet()))
			if frame.command == "CONNECTED":
				_finish_rotate()
				return


func _finish_rotate() -> void:
	_send_on(_rotate_ws, build_frame("SUBSCRIBE", {"id": AUTH_SUB_ID, "destination": AUTH_DEST}, ""))
	for id in _subs:
		_send_on(_rotate_ws, build_frame("SUBSCRIBE", {"id": id, "destination": _subs[id]}, ""))
	var old_ws := ws
	ws = _rotate_ws
	_last_state = WebSocketPeer.STATE_OPEN
	_connected = true
	_rotate_ws = null
	_rotating = false
	while old_ws.get_available_packet_count() > 0: # 교체 직전에 옛 소켓에 도착한 메시지(대기열 알림 등)를 버리지 않는다
		_handle_packet(decode(old_ws.get_packet()))
	_send_on(old_ws, build_frame("DISCONNECT", {}, ""))
	old_ws.close()
	connected.emit()


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
