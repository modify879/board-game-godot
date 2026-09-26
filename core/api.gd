extends Node
## REST client + session state. Autoload "Api".

signal session_expired
signal _refresh_done(ok: bool)

const DEV_ORIGIN := "http://localhost:8080"
const LOGIN_SCENE := "res://auth/login.tscn"

var access_token := ""
var _dev_cookie := "" # desktop-only dev copy of the refresh_token cookie; web relies on the browser
var user_id := 0
var _refreshing := false


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
	if not ok and expire_on_fail:
		session_expired.emit()
		get_tree().change_scene_to_file(LOGIN_SCENE)
	return ok


func _apply_tokens(data: Dictionary) -> void:
	access_token = data.accessToken
	user_id = jwt_sub(access_token)


func _clear_session() -> void:
	access_token = ""
	user_id = 0
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


static func jwt_sub(token: String) -> int:
	var parts := token.split(".")
	if parts.size() < 2:
		return 0
	var b64 := parts[1].replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	var text := Marshalls.base64_to_raw(b64).get_string_from_utf8()
	var data = JSON.parse_string(text)
	if data is Dictionary and data.has("sub"):
		return int(data.sub)
	return 0


static func page_items(data) -> Array:
	if data is Dictionary and data.has("_embedded"):
		var embedded: Dictionary = data["_embedded"]
		for key in embedded:
			return embedded[key]
	return []
