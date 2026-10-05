extends Node
## STOMP over raw WebSocket. Autoload "Stomp".

signal connected
signal message(destination: String, body: Variant)
signal error(code: String)
signal closed

const AUTH_SUB_ID := "sub-auth" # 공개 replay 목록(_subs)에 넣지 않는 내부 채널 구독 id
const AUTH_DEST := "/user/queue/auth"
const HEART_BEAT_RECV_MS := 10000 # 서버→클라이언트 주기 요청값

var ws := WebSocketPeer.new()
var _connected := false
var _intentional_close := false
var _reconnecting := false
var _last_state := WebSocketPeer.STATE_CLOSED
var _subs := {} # id -> destination
var _sub_counter := 0
var _last_recv_ticks := 0 # 마지막 패킷(하트비트 포함) 수신 시각
var _recv_interval_ms := 0 # 협상된 수신 주기. 0 이면 끊김 감지 안 함

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
			_last_recv_ticks = Time.get_ticks_msec()
			_handle_packet(decode(ws.get_packet()))
	# 패킷을 다 비운 뒤에 검사한다 — 가려진 탭에서 돌아오면 쌓인 패킷이 먼저 시각을 갱신해야 한다
	if _connected and _recv_interval_ms > 0 and Time.get_ticks_msec() - _last_recv_ticks > _recv_interval_ms * 3:
		ws.close() # 죽은 TCP 는 closing handshake 가 오지 않으니 기다리지 않고 닫힌 피어로 바꿔, 다음 프레임에 평소 재연결 경로를 태운다
		ws = WebSocketPeer.new()
	if _rotate_ws != null:
		_process_rotate()


func connect_ws() -> void:
	_cancel_rotate() # 교체 중 새로 연결하면 _finish_rotate 가 새 ws 를 덮어 고아로 만든다
	_intentional_close = false
	_connected = false # 새 소켓은 CONNECTED 전까지 STOMP 연결이 아니다
	ws = WebSocketPeer.new()
	ws.connect_to_url(_ws_url())
	# 즉시 거부되면 첫 poll 이 바로 CLOSED 다 — CLOSED 로 두면 전이가 안 보여 재연결이 영영 멈춘다
	_last_state = WebSocketPeer.STATE_CONNECTING


func _ws_url() -> String:
	var origin: String = get_node("/root/Api").origin()
	return "ws" + origin.trim_prefix("http") + "/ws"


func _subscribe_all(peer: WebSocketPeer) -> void:
	_send_on(peer, build_frame("SUBSCRIBE", {"id": AUTH_SUB_ID, "destination": AUTH_DEST}, ""))
	for id in _subs:
		_send_on(peer, build_frame("SUBSCRIBE", {"id": id, "destination": _subs[id]}, ""))


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


func _cancel_rotate() -> void:
	if _rotate_ws != null: # 교체 중 로그아웃하면 새 소켓이 유령 연결로 남는다
		_rotate_ws.close()
		_rotate_ws = null
	_rotating = false
	_auth_deadline_generation += 1


func disconnect_ws() -> void:
	_intentional_close = true
	_cancel_rotate()
	if _connected:
		_send(build_frame("DISCONNECT", {}, ""))
	ws.close()
	_subs.clear()
	_connected = false


func _connect_headers() -> Dictionary:
	var api := get_node("/root/Api")
	var host: String = api.origin().trim_prefix("https://").trim_prefix("http://")
	# 서버→클라이언트만 요청한다(클라이언트는 안 보냄). Web 메인 루프는 가려진 탭에서 멈춰 클라이언트 비트가 끊기고,
	# 서버가 연결(과 대기열 자리)을 버리기 때문이다. 브라우저는 WebSocket ping 을 못 쓰므로 이것이 유일한 끊김 감지다
	var headers := {"accept-version": "1.2", "host": host, "heart-beat": "0,%d" % HEART_BEAT_RECV_MS}
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
			_auth_deadline_generation += 1 # 새 연결은 현재 토큰으로 인증됐다 — 옛 소켓에서 건 연장 마감은 무효
			_connected = true
			_recv_interval_ms = receive_interval_ms(frame.headers.get("heart-beat", ""))
			_last_recv_ticks = Time.get_ticks_msec()
			_subscribe_all(ws)
			connected.emit()
		"MESSAGE":
			var dest: String = frame.headers.get("destination", "")
			var parsed = JSON.parse_string(frame.body)
			if dest == AUTH_DEST:
				_handle_auth_reply(parsed)
			else:
				message.emit(dest, parsed)
		"ERROR":
			var code: String = frame.headers.get("errorCode", frame.headers.get("message", "STOMP_ERROR"))
			if code == "AUTHENTICATION_REQUIRED":
				# 여기서 직접 갱신·재연결한다 — error 로 내보내면 복구된 뒤에도 화면에 낡은 문구가 남는다
				if not await get_node("/root/Api")._refresh() and get_node("/root/Api").access_token == "":
					_intentional_close = true # 세션이 사라진 경우만. 일시 장애면 소켓 종료 경로가 재연결한다
			else:
				_intentional_close = true # emit 먼저 하면 핸들러의 connect_ws() 가 푼 플래그를 다시 덮어 새 소켓이 재연결을 안 한다
				error.emit(code)


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
	# 확정 실패면 Api._refresh() 가 이미 로그인 화면으로 보낸다. 일시 장애(세션 유지)면 다시 시도한다.
	var api := get_node("/root/Api")
	if await api._refresh():
		connect_ws()
	elif api.access_token != "":
		_schedule_reconnect()


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
	_rotate_ws.connect_to_url(_ws_url())
	# connect_ws 와 같다 — CLOSED 로 두면 실패한 회전 소켓이 정리되지 않고 _rotating 이 영영 true 다
	_rotate_last_state = WebSocketPeer.STATE_CONNECTING


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
				_finish_rotate(receive_interval_ms(frame.headers.get("heart-beat", "")))
				return


func _finish_rotate(recv_interval_ms: int) -> void:
	_subscribe_all(_rotate_ws)
	var old_ws := ws
	ws = _rotate_ws
	_last_state = WebSocketPeer.STATE_OPEN
	_connected = true
	_recv_interval_ms = recv_interval_ms
	_last_recv_ticks = Time.get_ticks_msec()
	_rotate_ws = null
	_rotating = false
	_auth_deadline_generation += 1 # 교체된 소켓은 새 토큰으로 인증됐다 — 남은 연장 마감이 또 교체하지 않게
	while old_ws.get_available_packet_count() > 0: # 교체 직전에 옛 소켓에 도착한 메시지(대기열 알림 등)를 버리지 않는다
		_handle_packet(decode(old_ws.get_packet()))
	_send_on(old_ws, build_frame("DISCONNECT", {}, ""))
	old_ws.close()
	connected.emit()


static func receive_interval_ms(server_heart_beat: String) -> int:
	# 서버 "sx,sy" 와 우리 cy(HEART_BEAT_RECV_MS) 의 협상값. 0 이면 비활성
	var parts := server_heart_beat.split(",")
	var sx := int(parts[0]) if parts.size() >= 1 else 0
	return maxi(sx, HEART_BEAT_RECV_MS) if sx > 0 else 0


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


static func unescape_header(s: String) -> String:
	# STOMP 1.2 헤더 이스케이프를 왼쪽부터 한 번씩만 푼다 — replace 를 이어 쓰면 "\\\\n" 이 두 번 풀린다
	if not s.contains("\\"):
		return s
	var out := ""
	var i := 0
	while i < s.length():
		var ch := s[i]
		if ch == "\\" and i + 1 < s.length():
			i += 1
			match s[i]:
				"r": out += "\r"
				"n": out += "\n"
				"c": out += ":"
				"\\": out += "\\"
				_: out += ch + s[i]
		else:
			out += ch
		i += 1
	return out


static func parse_frame(text: String) -> Dictionary:
	var t := text.lstrip("\n")
	var parts := t.split("\n\n", true, 1)
	var head_lines := parts[0].split("\n")
	var headers := {}
	for i in range(1, head_lines.size()):
		var line: String = head_lines[i]
		var idx := line.find(":")
		if idx >= 0:
			headers[unescape_header(line.substr(0, idx))] = unescape_header(line.substr(idx + 1))
	return {"command": head_lines[0], "headers": headers, "body": parts[1] if parts.size() > 1 else ""}
