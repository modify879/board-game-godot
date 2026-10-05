extends SceneTree
## Self-check for core/*.gd static logic. Run with:
## Godot.exe --headless --path . --script res://core/test_core.gd

var failures := 0


func _init() -> void:
	var api := preload("res://core/api.gd")
	var stomp := preload("res://core/stomp.gd")
	var et := preload("res://core/error_text.gd")

	# build/parse round trip
	var frame := stomp.build_frame("SEND", {"destination": "/app/hello", "content-type": "text/plain"}, "hi")
	var parsed := stomp.parse_frame(frame)
	check(parsed.command == "SEND", "build/parse command")
	check(parsed.headers.get("destination", "") == "/app/hello", "build/parse destination header")
	check(parsed.headers.get("content-type", "") == "text/plain", "build/parse content-type header")
	check(parsed.body == "hi", "build/parse body")

	# realistic server MESSAGE frame
	var msg_text := "MESSAGE\ndestination:/topic/tables/1\ncontent-type:application/json\nsubscription:sub-0\nmessage-id:x\n\n{\"a\":1}"
	var msg := stomp.parse_frame(msg_text)
	check(msg.command == "MESSAGE", "message command")
	check(msg.headers.get("destination", "") == "/topic/tables/1", "message destination header")
	check(msg.body == "{\"a\":1}", "message body")
	var msg_body = JSON.parse_string(msg.body)
	check(msg_body is Dictionary and msg_body.get("a") == 1, "message body json parse")

	# NUL-terminated byte encoding
	var encoded_a := stomp.encode("A")
	check(encoded_a.size() == 2 and encoded_a[encoded_a.size() - 1] == 0, "encode appends single NUL byte")
	check(frame.ends_with("hi"), "build_frame result ends with the body, no trailing NUL")
	var korean_frame := stomp.build_frame("SEND", {"destination": "/app/hello"}, "한글")
	check(stomp.decode(stomp.encode(korean_frame)) == korean_frame, "encode/decode round trip with Korean body")

	# heartbeat frame
	var hb := stomp.parse_frame("\n")
	check(hb.command == "", "heartbeat parses to empty command")

	# page_items
	var with_content := {"content": [{"id": 1}, {"id": 2}], "page": {}}
	check(api.page_items(with_content).size() == 2, "page_items with content")
	var no_content := {"page": {}}
	check(api.page_items(no_content).size() == 0, "page_items without content")
	var empty_content := {"content": []}
	check(api.page_items(empty_content).size() == 0, "page_items with empty content")

	# jwt sub decode
	var payload_b64 := Marshalls.raw_to_base64('{"sub":"42"}'.to_utf8_buffer())
	payload_b64 = payload_b64.replace("+", "-").replace("/", "_").rstrip("=")
	var token := "eyJhbGciOiJIUzI1NiJ9." + payload_b64
	check(api.jwt_sub(token) == 42, "jwt_sub decodes sub")

	# jwt_claims decode (exp)
	var claims_payload_b64 := Marshalls.raw_to_base64('{"sub":"7","exp":1700000000}'.to_utf8_buffer())
	claims_payload_b64 = claims_payload_b64.replace("+", "-").replace("/", "_").rstrip("=")
	var claims_token := "eyJhbGciOiJIUzI1NiJ9." + claims_payload_b64
	var claims := api.jwt_claims(claims_token)
	check(int(claims.get("exp", 0)) == 1700000000, "jwt_claims reads exp")
	check(api.jwt_sub(claims_token) == 7, "jwt_sub still works via jwt_claims")
	check(api.jwt_claims("not-a-jwt").is_empty(), "jwt_claims returns empty dict for malformed token")

	# cookie_value
	var ck_normal := PackedStringArray(["Set-Cookie: refresh_token=abc; Path=/api/auth; Max-Age=1209600; HttpOnly; Secure; SameSite=Strict"])
	check(api.cookie_value(ck_normal, "refresh_token") == "abc", "cookie_value normal")
	var ck_maxage0 := PackedStringArray(["Set-Cookie: refresh_token=abc; Path=/api/auth; Max-Age=0; HttpOnly"])
	check(api.cookie_value(ck_maxage0, "refresh_token") == "", "cookie_value Max-Age=0 clears")
	var ck_other := PackedStringArray(["Set-Cookie: other=1"])
	check(api.cookie_value(ck_other, "refresh_token") == null, "cookie_value no matching cookie")
	var ck_lower := PackedStringArray(["set-cookie: refresh_token=xyz; Path=/"])
	check(api.cookie_value(ck_lower, "refresh_token") == "xyz", "cookie_value lowercase header name")

	# sends_bearer
	check(api.sends_bearer("/api/auth/refresh") == false, "refresh 에는 Bearer 를 안 싣는다")
	check(api.sends_bearer("/api/auth/login") == false, "login 에는 Bearer 를 안 싣는다")
	check(api.sends_bearer("/api/auth/logout") == true, "logout 은 Bearer 필요")

	# refresh_failure_is_final
	check(api.refresh_failure_is_final(0) == false, "refresh 네트워크 오류는 일시 장애")
	check(api.refresh_failure_is_final(503) == false, "refresh 5xx 는 일시 장애")
	check(api.refresh_failure_is_final(401) == true, "refresh 401 은 확정 실패")
	check(api.refresh_failure_is_final(400) == true, "refresh 400 은 확정 실패")

	# receive_interval_ms
	check(stomp.receive_interval_ms("10000,0") == 10000, "heart-beat 10000,0")
	check(stomp.receive_interval_ms("5000,0") == 10000, "heart-beat 5000,0 은 10000 으로 올림")
	check(stomp.receive_interval_ms("20000,0") == 20000, "heart-beat 20000,0")
	check(stomp.receive_interval_ms("0,0") == 0, "heart-beat 0,0 은 비활성")
	check(stomp.receive_interval_ms("") == 0, "heart-beat 없으면 비활성")

	# ErrorText
	check(et.of("LOGIN_FAILED") == "아이디 또는 비밀번호가 올바르지 않습니다", "ErrorText known code")
	check(et.of("NOPE") == "오류가 발생했습니다 (NOPE)", "ErrorText fallback")

	quit(1 if failures else 0)


func check(cond: bool, name: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: ", name)
	else:
		print("ok: ", name)
