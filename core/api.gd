extends Node
## REST client + session state. Autoload "Api".

signal session_expired
signal token_refreshed
signal _refresh_done(ok: bool)

const DEV_ORIGIN := "http://localhost:8080"
const LOGIN_SCENE := "res://auth/login.tscn"
const REFRESH_MARGIN_SEC := 300.0 # exp 몇 초 전에 선제 갱신할지

var access_token := ""
var _dev_cookie := "" # desktop-only dev copy of the refresh_token cookie; web relies on the browser
var user_id := 0
var _refreshing := false
var _resume_tried := false # 자동 로그인은 앱 시작 때 한 번만. 로그아웃·만료 후 로그인 화면에서 헛 refresh 를 보내지 않는다
var _refresh_schedule_generation := 0 # 새 스케줄이 걸리거나 세션이 끊기면 늘려서 옛 타이머를 무효화한다


func origin() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("location.origin"))
	return DEV_ORIGIN


func request(method: int, path: String, body = null) -> Dictionary:
	var sent_token := access_token
	var r := await _do_request(method, path, body)
	if r.status == 401 and path != "/api/auth/login" and path != "/api/auth/refresh":
		if access_token != sent_token or await _refresh():
			r = await _do_request(method, path, body)
	return r


func _do_request(method: int, path: String, body) -> Dictionary:
	var req := HTTPRequest.new()
	req.accept_gzip = not OS.has_feature("web") # 브라우저가 이미 압축을 풀어 주는데 Content-Encoding 헤더가 남아 있어, 켜 두면 이중 해제로 실패한다
	add_child(req)
	var headers := ["Content-Type: application/json"]
	if access_token != "":
		headers.append("Authorization: Bearer " + access_token)
	var is_auth_path := path.begins_with("/api/auth/")
	var is_web := OS.has_feature("web")
	if is_auth_path and not is_web and _dev_cookie != "":
		headers.append("Cookie: refresh_token=" + _dev_cookie)
	var body_str := "" if body == null else JSON.stringify(body)
	var err := req.request(origin() + path, headers, method, body_str)
	if err != OK:
		req.queue_free()
		return {"ok": false, "status": 0, "data": null, "error": "NETWORK_ERROR"}
	var result: Array = await req.request_completed
	req.queue_free()
	var res_result: int = result[0]
	var status: int = result[1]
	var res_headers: PackedStringArray = result[2]
	var res_body: PackedByteArray = result[3]
	if res_result != HTTPRequest.RESULT_SUCCESS:
		push_warning("HTTP %s %s failed: result=%d" % [method, path, res_result])
		return {"ok": false, "status": 0, "data": null, "error": "NETWORK_ERROR"}
	if is_auth_path and not is_web:
		_update_dev_cookie(res_headers)
	var text := res_body.get_string_from_utf8()
	var data = JSON.parse_string(text) if text != "" else null
	var ok := status >= 200 and status < 300
	var error := ""
	if not ok:
		error = data.errorCode if (data is Dictionary and data.has("errorCode")) else "HTTP_%d" % status
	return {"ok": ok, "status": status, "data": data, "error": error}


func _update_dev_cookie(headers: PackedStringArray) -> void:
	var value = cookie_value(headers, "refresh_token")
	if value == null:
		return
	_dev_cookie = value
	var cfg := ConfigFile.new()
	cfg.set_value("session", "dev_cookie", _dev_cookie)
	cfg.save("user://session.cfg")


func _refresh(expire_on_fail := true) -> bool:
	if _refreshing:
		var ok = await _refresh_done
		return ok
	_refreshing = true
	var r := await _do_request(HTTPClient.METHOD_POST, "/api/auth/refresh", null)
	var ok: bool = r.ok
	if ok:
		_apply_tokens(r.data)
	else:
		_clear_session()
	_refreshing = false
	_refresh_done.emit(ok)
	if ok:
		token_refreshed.emit()
	if not ok and expire_on_fail:
		session_expired.emit()
		get_tree().change_scene_to_file(LOGIN_SCENE)
	return ok


func _apply_tokens(data: Dictionary) -> void:
	access_token = data.accessToken
	user_id = jwt_sub(access_token)
	_schedule_refresh()


func _schedule_refresh() -> void:
	_refresh_schedule_generation += 1
	var generation := _refresh_schedule_generation
	var exp: float = jwt_claims(access_token).get("exp", 0)
	var delay: float = max(exp - Time.get_unix_time_from_system() - REFRESH_MARGIN_SEC, 1.0)
	get_tree().create_timer(delay).timeout.connect(_on_refresh_timer.bind(generation))


func _on_refresh_timer(generation: int) -> void:
	if generation == _refresh_schedule_generation:
		await _refresh()


func _clear_session() -> void:
	access_token = ""
	user_id = 0
	_refresh_schedule_generation += 1 # 예약된 선제 갱신 타이머를 무효화한다
	if not OS.has_feature("web"):
		_dev_cookie = ""
		var cfg := ConfigFile.new()
		cfg.set_value("session", "dev_cookie", "")
		cfg.save("user://session.cfg")


func login(username: String, password: String) -> Dictionary:
	var r := await _do_request(HTTPClient.METHOD_POST, "/api/auth/login", {"username": username, "password": password})
	if r.ok:
		_apply_tokens(r.data)
	return r


func signup(username: String, password: String, password_confirm: String, nickname: String) -> Dictionary:
	var body := {"username": username, "password": password, "passwordConfirm": password_confirm, "nickname": nickname}
	return await _do_request(HTTPClient.METHOD_POST, "/api/users", body)


func logout() -> void:
	await request(HTTPClient.METHOD_POST, "/api/auth/logout")
	_clear_session()
	get_node("/root/Stomp").disconnect_ws()


func try_resume() -> bool:
	if _resume_tried:
		return false
	_resume_tried = true
	if not OS.has_feature("web"):
		var cfg := ConfigFile.new()
		if cfg.load("user://session.cfg") != OK:
			return false
		var cookie: String = cfg.get_value("session", "dev_cookie", "")
		if cookie == "":
			return false
		_dev_cookie = cookie
	return await _refresh(false)


static func cookie_value(headers: PackedStringArray, name: String) -> Variant:
	for h in headers:
		var idx := h.find(":")
		if idx < 0:
			continue
		if h.substr(0, idx).strip_edges().to_lower() != "set-cookie":
			continue
		var parts := h.substr(idx + 1).split(";")
		var kv := parts[0].strip_edges().split("=", true, 1)
		if kv.size() != 2 or kv[0].strip_edges() != name:
			continue
		for i in range(1, parts.size()):
			if parts[i].strip_edges().to_lower() == "max-age=0":
				return ""
		return kv[1].strip_edges()
	return null


static func jwt_claims(token: String) -> Dictionary:
	var parts := token.split(".")
	if parts.size() < 2:
		return {}
	var b64 := parts[1].replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var text := Marshalls.base64_to_raw(b64).get_string_from_utf8()
	var data = JSON.parse_string(text)
	return data if data is Dictionary else {}


static func jwt_sub(token: String) -> int:
	var claims := jwt_claims(token)
	if claims.has("sub"):
		return int(claims.sub)
	return 0


static func page_items(data) -> Array:
	if data is Dictionary and data.has("content"):
		return data["content"]
	return []
