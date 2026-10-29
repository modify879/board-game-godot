extends Node
## REST client + session state. Autoload "Api".

signal token_refreshed
signal _refresh_done(ok: bool)
signal _js_refresh_done # 탭 간 JS refresh 결과(_js_status·_js_text)
signal _js_ask_done # 다른 탭 토큰 문의 결과(_js_ask_token)

const DEV_ORIGIN := "http://localhost:8080"
const LOGIN_SCENE := "res://auth/login.tscn"
const REFRESH_MARGIN_SEC := 300.0 # exp 몇 초 전에 선제 갱신할지
const REQUEST_TIMEOUT_SEC := 15.0 # 응답 없는 연결이 영영 안 끝나면 _refreshing 이 묶여 이후 갱신·401 재시도가 전부 멈춘다 — 타임아웃은 status 0 일시 장애로 처리된다
const UNAVAILABLE_RETRY_SEC := [1.0, 2.0] # 서버가 롤백을 보장해 POST 도 다시 보내도 안전하다
const REFRESH_RETRY_MS := 5000 # 네트워크·5xx 로 갱신이 실패했을 때 재시도 간격

# 탭 간 토큰 공유(Web 전용). 숨은 탭은 Godot 루프가 멈추므로 임계 구역·응답은 JS 쪽에서 끝낸다.
# ponytail: 전파 도착과 락 넘겨받기의 순서가 보장되지 않아 드물게 한 번 더 갱신될 수 있다(sent_token 비교와 전파로 한 번 만에 수렴). 업그레이드: localStorage 세대 카운터
const AUTH_JS := """
(function () {
	if (window.__auth) return;
	const A = window.__auth = {token: "", gen: 0, pending: null, ch: new BroadcastChannel("auth")};
	const take = (t) => { A.token = t; A.gen++; };
	A.share = (t) => { take(t); A.ch.postMessage({type: "token", token: t}); };
	A.refresh = (cb) => {
		const start = A.gen;
		navigator.locks.request("auth-refresh", async () => {
			if (A.gen !== start && A.token) { cb(200, JSON.stringify({accessToken: A.token})); return; }
			try {
				const r = await fetch("/api/auth/refresh", {method: "POST", credentials: "same-origin", signal: AbortSignal.timeout(15000)});
				const text = await r.text();
				if (r.ok) { try { const t = JSON.parse(text).accessToken; if (t) A.share(t); } catch (e) {} }
				cb(r.status, text);
			} catch (e) { cb(0, ""); }
		});
	};
	A.ask = (cb) => {
		const done = (t) => { clearTimeout(tm); A.pending = null; cb(t); };
		const tm = setTimeout(() => done(""), 300);
		A.pending = done;
		A.ch.postMessage({type: "ask"});
	};
	A.logout = () => { A.token = ""; A.ch.postMessage({type: "logout"}); };
	A.ch.onmessage = (e) => {
		const m = e.data || {};
		if (m.type === "token" && m.token) {
			const changed = m.token !== A.token;
			if (changed) take(m.token);
			if (A.pending) A.pending(m.token);
			else if (changed && A.onToken) A.onToken(m.token);
		} else if (m.type === "ask" && A.token) {
			A.ch.postMessage({type: "token", token: A.token});
		} else if (m.type === "logout") {
			A.token = "";
			if (A.onLogout) A.onLogout();
		}
	};
})();
"""

var access_token := ""
var _dev_cookie := "" # desktop-only dev copy of the refresh_token cookie; web relies on the browser
var user_id := 0
var _refreshing := false
var _resume_tried := false # 자동 로그인은 앱 시작 때 한 번만. 로그아웃·만료 후 로그인 화면에서 헛 refresh 를 보내지 않는다
var _refresh_due_ticks := -1 # 선제 갱신 시각(Time.get_ticks_msec 기준). -1 이면 예약 없음
var _auth_js # JavaScriptObject(window.__auth). Web 에서만
var _js_callbacks: Array = [] # create_callback 결과를 잡아 두지 않으면 해제된다
var _js_status := 0
var _js_text := ""
var _js_ask_token := ""


func _ready() -> void:
	Screen.setup(get_window()) # 화면 크기에 맞춘 배율(core/ui/screen.gd)
	QaBridge.setup(get_tree()) # QA 전용 window.godotQa(core/qa_bridge.gd). 조건이 안 맞으면 아무것도 하지 않는다
	FocusVisible.setup(get_tree()) # 마우스·터치 뒤 포커스 링 숨김·손바닥 커서·터치 hover 제거(core/ui/focus_visible.gd)
	EnvBadge.setup(self) # 서버 환경이 qa 면 "QA 서버" 배지(core/ui/env_badge.gd)
	if OS.has_feature("web"):
		_setup_tab_share()


func _setup_tab_share() -> void:
	JavaScriptBridge.eval(AUTH_JS, true)
	_auth_js = JavaScriptBridge.get_interface("window").__auth
	# JS 가 인자를 Array 하나로 넘긴다. 결과는 멤버에 두고 인자 없는 시그널로 깨운다
	var handlers := {
		"_cb_refresh": _on_js_refresh, "_cb_ask": _on_js_ask,
		"onToken": _on_peer_token, "onLogout": _on_peer_logout,
	}
	for key in handlers:
		var cb := JavaScriptBridge.create_callback(handlers[key])
		_js_callbacks.append(cb)
		_auth_js[key] = cb


func origin() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("location.origin"))
	return DEV_ORIGIN


func request(method: int, path: String, body = null, extra_headers: Array = []) -> Dictionary:
	var r := await _request_once(method, path, body, extra_headers)
	for delay in UNAVAILABLE_RETRY_SEC:
		if not retries_unavailable(r):
			break
		await get_tree().create_timer(delay).timeout
		r = await _request_once(method, path, body, extra_headers)
	return r


func _request_once(method: int, path: String, body, extra_headers: Array) -> Dictionary:
	var sent_token := access_token
	var r := await _do_request(method, path, body, extra_headers)
	if r.status == 401 and sends_bearer(path):
		if access_token != sent_token or await _refresh():
			r = await _do_request(method, path, body, extra_headers)
	return r


func _do_request(method: int, path: String, body, extra_headers: Array = []) -> Dictionary:
	var req := HTTPRequest.new()
	req.accept_gzip = not OS.has_feature("web") # 브라우저가 이미 압축을 풀어 주는데 Content-Encoding 헤더가 남아 있어, 켜 두면 이중 해제로 실패한다
	req.timeout = REQUEST_TIMEOUT_SEC
	add_child(req)
	var headers := ["Content-Type: application/json"]
	headers.append_array(extra_headers)
	if access_token != "" and sends_bearer(path):
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
		var cookie = cookie_value(res_headers, "refresh_token")
		if cookie != null:
			_save_dev_cookie(cookie)
	var text := res_body.get_string_from_utf8()
	var data = JSON.parse_string(text) if text != "" else null
	var ok := status >= 200 and status < 300
	var error := ""
	if not ok:
		error = data.errorCode if (data is Dictionary and data.has("errorCode")) else "HTTP_%d" % status
	return {"ok": ok, "status": status, "data": data, "error": error}


func _save_dev_cookie(value: String) -> void:
	_dev_cookie = value
	var cfg := ConfigFile.new()
	cfg.set_value("session", "dev_cookie", value)
	cfg.save("user://session.cfg")


static func new_idempotency_key() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


static func refresh_failure_is_final(status: int) -> bool:
	# 4xx 만 세션 종료다(408·429 제외). 네트워크 오류(0)·5xx·408·429 는 일시 장애라 로그아웃시키지 않는다
	return status >= 400 and status < 500 and status != 408 and status != 429


static func retries_unavailable(r: Dictionary) -> bool:
	# errorCode 가 없는 게이트웨이 503(HTTP_503)은 롤백 보장이 없어 다시 보내지 않는다
	# IDEMPOTENCY_KEY_CONFLICT 는 같은 키로 다시 보내면 원래 결과를 받는다
	return r.error == "TEMPORARILY_UNAVAILABLE" or r.error == "IDEMPOTENCY_KEY_CONFLICT"


static func keeps_idempotency_key(r: Dictionary) -> bool:
	# 결과를 모르는 실패(status 0·5xx)이거나 같은 키 요청이 아직 처리 중(IDEMPOTENCY_KEY_CONFLICT)이면 같은 키로 다시 보내야 중복이 안 생긴다 — 그 밖의 4xx 는 확정 실패라 새 키를 쓴다
	return r.status == 0 or r.status >= 500 or r.error == "IDEMPOTENCY_KEY_CONFLICT"


static func sends_bearer(path: String) -> bool:
	# 로그인·refresh 는 permitAll 이지만, 서버 토큰 필터는 Bearer 헤더가 있으면 검증한다 — 만료된 토큰이 실리면 refresh 전에 401 이 난다
	return path != "/api/auth/login" and path != "/api/auth/refresh"


func _refresh(expire_on_fail := true) -> bool:
	if _refreshing:
		var ok = await _refresh_done
		return ok
	_refreshing = true
	var is_web := OS.has_feature("web")
	var before := access_token
	var r: Dictionary
	if is_web:
		r = await _web_refresh()
	else:
		r = await _do_request(HTTPClient.METHOD_POST, "/api/auth/refresh", null)
	var ok: bool = r.ok
	var final := false
	if ok:
		_apply_tokens(r.data)
	elif refresh_failure_is_final(r.status):
		final = true
		_clear_session()
		if is_web:
			_auth_js.logout() # 다른 탭도 로그인 화면으로
	elif access_token != "": # 로그아웃 중이던 refresh 가 재시도를 걸면 나중에 로그인 화면을 튕긴다
		_refresh_due_ticks = Time.get_ticks_msec() + REFRESH_RETRY_MS # 일시 장애 — 세션은 두고 곧 재시도
	_refreshing = false
	_refresh_done.emit(ok)
	if ok and access_token != before: # 같은 토큰을 두 번 알리면 Stomp 가 인밴드 갱신을 두 번 보낸다
		token_refreshed.emit()
	if final and expire_on_fail:
		get_tree().change_scene_to_file(LOGIN_SCENE)
	return ok


## 탭 간 락 안에서 JS 가 refresh 한다(다른 탭이 이미 갱신했으면 그 토큰을 돌려준다). 결과 형식은 _do_request 와 같다
func _web_refresh() -> Dictionary:
	_auth_js.refresh(_js_callbacks[0])
	await _js_refresh_done
	var text := _js_text
	var data = JSON.parse_string(text) if text != "" else null
	var ok := _js_status >= 200 and _js_status < 300
	var error := ""
	if not ok:
		error = data.errorCode if (data is Dictionary and data.has("errorCode")) else ("NETWORK_ERROR" if _js_status == 0 else "HTTP_%d" % _js_status)
	return {"ok": ok, "status": _js_status, "data": data, "error": error}


func _on_js_refresh(args: Array) -> void:
	_js_status = int(args[0])
	_js_text = str(args[1])
	_js_refresh_done.emit()


func _on_js_ask(args: Array) -> void:
	_js_ask_token = str(args[0])
	_js_ask_done.emit()


## 다른 탭이 새 토큰을 알렸다
func _on_peer_token(args: Array) -> void:
	var t := str(args[0])
	if access_token == "" or t == access_token:
		return
	var other_user := jwt_sub(t) != user_id
	access_token = t
	user_id = jwt_sub(t)
	_schedule_refresh(null)
	if other_user: # 다른 탭에서 다른 계정으로 로그인했다
		get_node("/root/Stomp").disconnect_ws() # 옛 계정의 소켓을 남기지 않는다
		get_tree().change_scene_to_file("res://lobby/lobby.tscn")
	else:
		token_refreshed.emit() # Stomp 가 인밴드로 연장해 서버의 30초 유예 종료를 피한다


func _on_peer_logout(_args: Array) -> void:
	if access_token == "":
		return
	_clear_session()
	get_node("/root/Stomp").disconnect_ws()
	get_tree().change_scene_to_file(LOGIN_SCENE)


func _apply_tokens(data: Dictionary) -> void:
	access_token = data.accessToken
	user_id = jwt_sub(access_token)
	_schedule_refresh(data.get("accessTokenExpiresInMs"))


## 선제 갱신까지 ms. 여유가 수명의 절반을 넘지 않게 해, 짧은 토큰이 매초 갱신되지 않게 한다
static func refresh_delay_ms(expires_in_ms: int) -> int:
	return maxi(expires_in_ms - int(minf(REFRESH_MARGIN_SEC * 1000.0, expires_in_ms / 2.0)), 1000)


func _schedule_refresh(expires_in_ms) -> void:
	# 서버가 준 남은 ms 를 단조 시계로 센다 — OS 시계가 어긋나도, 탭이 가려져 루프가 멈췄다 돌아와도 정확하다
	if expires_in_ms == null:
		var exp: float = jwt_claims(access_token).get("exp", 0)
		expires_in_ms = (exp - Time.get_unix_time_from_system()) * 1000.0
	_refresh_due_ticks = Time.get_ticks_msec() + refresh_delay_ms(int(expires_in_ms))


func _process(_delta: float) -> void:
	if _refresh_due_ticks >= 0 and Time.get_ticks_msec() >= _refresh_due_ticks and not _refreshing:
		_refresh_due_ticks = -1
		_refresh()


func _clear_session() -> void:
	access_token = ""
	user_id = 0
	_refresh_due_ticks = -1
	if not OS.has_feature("web"):
		_save_dev_cookie("")


func login(username: String, password: String) -> Dictionary:
	var r := await _do_request(HTTPClient.METHOD_POST, "/api/auth/login", {"username": username, "password": password})
	if r.ok:
		_apply_tokens(r.data)
		if OS.has_feature("web"):
			_auth_js.share(access_token) # Object.set 과 이름이 겹치지 않게 share
	return r


func signup(username: String, password: String, password_confirm: String, nickname: String) -> Dictionary:
	var body := {"username": username, "password": password, "passwordConfirm": password_confirm, "nickname": nickname}
	return await _do_request(HTTPClient.METHOD_POST, "/api/users", body)


func logout() -> void:
	if _refreshing: # 진행 중인 갱신이 로그아웃 뒤에 끝나면 토큰을 되살린다 — 끝난 뒤에 로그아웃한다
		await _refresh_done
	_refresh_due_ticks = -1 # 로그아웃 요청 중에 선제 갱신이 시작돼 세션이 되살아나지 않게
	# 서버가 로그아웃 때 소켓을 1008 로 닫는다 — 먼저 끊어야 재인증 재연결로 오인하지 않고, 살아 있는 세션에 DISCONNECT 를 보낸다
	get_node("/root/Stomp").disconnect_ws()
	await request(HTTPClient.METHOD_POST, "/api/auth/logout")
	_clear_session()
	if OS.has_feature("web"):
		_auth_js.logout()


func try_resume() -> bool:
	if _resume_tried:
		return false
	_resume_tried = true
	if OS.has_feature("web"): # 다른 탭이 세션을 갖고 있으면 refresh 하지 않고 그 토큰을 받는다
		_auth_js.ask(_js_callbacks[1])
		await _js_ask_done
		if _js_ask_token != "":
			_apply_tokens({"accessToken": _js_ask_token})
			return true
	else:
		var cfg := ConfigFile.new()
		if cfg.load("user://session.cfg") != OK:
			return false
		var cookie: String = cfg.get_value("session", "dev_cookie", "")
		if cookie == "":
			return false
		_dev_cookie = cookie
	var ok: bool = await _refresh(false)
	if not ok:
		_refresh_due_ticks = -1 # 로그인 화면에서는 재시도하지 않는다 — 사용자가 직접 로그인한다
	return ok


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


## 로그인 응답에는 role 이 없다 — access 토큰 클레임으로 판단한다(화면 표시용일 뿐, 인가는 서버가 한다)
func is_admin() -> bool:
	return is_admin_token(access_token)


static func is_admin_token(token: String) -> bool:
	return jwt_claims(token).get("role") == "ADMIN"


static func jwt_sub(token: String) -> int:
	var claims := jwt_claims(token)
	if claims.has("sub"):
		return int(claims.sub)
	return 0


static func page_items(data) -> Array:
	if data is Dictionary and data.has("content"):
		return data["content"]
	return []
