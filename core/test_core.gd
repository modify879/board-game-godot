extends SceneTree
## Self-check for core/*.gd static logic. Run with:
## Godot.exe --headless --path . --script res://core/test_core.gd

var failures := 0


func _init() -> void:
	var api := preload("res://core/api.gd")
	var stomp := preload("res://core/stomp.gd")
	var et := preload("res://core/error_text.gd")

	var lab := preload("res://core/ui/rows.gd").label("x", true)
	check(lab.text == "x" and lab.size_flags_horizontal == Control.SIZE_EXPAND_FILL, "Rows.label expand")
	lab.free()

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

	# 헤더 이스케이프 (리터럴의 "\\" 는 백슬래시 한 글자)
	check(stomp.unescape_header("a\\cb") == "a:b", "unescape \\c")
	check(stomp.unescape_header("x\\ny") == "x\ny", "unescape \\n")
	check(stomp.unescape_header("\\\\n") == "\\n" and stomp.unescape_header("\\\\n").length() == 2, "unescape backslash then n, no double decode")
	check(stomp.parse_frame("ERROR\nmessage:a\\cb\n\n").headers.get("message", "") == "a:b", "parse_frame unescapes header value")

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
	check(api.refresh_failure_is_final(408) == false, "refresh 408 은 일시 장애")
	check(api.refresh_failure_is_final(429) == false, "refresh 429 는 일시 장애")

	# retries_unavailable
	check(api.retries_unavailable({"error": "TEMPORARILY_UNAVAILABLE"}) == true, "TEMPORARILY_UNAVAILABLE 은 재시도")
	check(api.retries_unavailable({"error": "IDEMPOTENCY_KEY_CONFLICT"}) == true, "IDEMPOTENCY_KEY_CONFLICT 는 같은 키로 재시도")
	check(api.retries_unavailable({"error": "HTTP_503"}) == false, "게이트웨이 503 은 재시도 안 함")
	check(api.retries_unavailable({"error": "INTERNAL_ERROR"}) == false, "INTERNAL_ERROR 는 재시도 안 함")

	# keeps_idempotency_key
	check(api.keeps_idempotency_key({"status": 0, "error": "NETWORK_ERROR"}) == true, "status 0 은 키 유지")
	check(api.keeps_idempotency_key({"status": 503, "error": "HTTP_503"}) == true, "5xx 는 키 유지")
	check(api.keeps_idempotency_key({"status": 409, "error": "IDEMPOTENCY_KEY_CONFLICT"}) == true, "IDEMPOTENCY_KEY_CONFLICT 는 키 유지")
	check(api.keeps_idempotency_key({"status": 400, "error": "DEPOSIT_AMOUNT_INVALID"}) == false, "400 은 새 키")
	check(api.keeps_idempotency_key({"status": 409, "error": "INSUFFICIENT_BALANCE"}) == false, "409 INSUFFICIENT_BALANCE 는 새 키")

	# receive_interval_ms
	check(stomp.receive_interval_ms("10000,0") == 10000, "heart-beat 10000,0")
	check(stomp.receive_interval_ms("5000,0") == 10000, "heart-beat 5000,0 은 10000 으로 올림")
	check(stomp.receive_interval_ms("20000,0") == 20000, "heart-beat 20000,0")
	check(stomp.receive_interval_ms("0,0") == 0, "heart-beat 0,0 은 비활성")
	check(stomp.receive_interval_ms("") == 0, "heart-beat 없으면 비활성")

	# ErrorText
	check(et.of("LOGIN_FAILED") == "아이디 또는 비밀번호가 올바르지 않습니다", "ErrorText known code")
	check(et.of("NOPE") == "오류가 발생했습니다 (NOPE)", "ErrorText fallback")

	# is_admin_token
	check(api.is_admin_token(role_token('{"sub":"1","role":"ADMIN"}')), "role ADMIN 은 관리자")
	check(not api.is_admin_token(role_token('{"sub":"1","role":"USER"}')), "role USER 는 관리자 아님")
	check(not api.is_admin_token(role_token('{"sub":"1"}')), "role 없으면 관리자 아님")

	# Format
	var fmt := preload("res://core/format.gd")
	check(fmt.comma(0) == "0", "comma 0")
	check(fmt.comma(999) == "999", "comma 999")
	check(fmt.comma(1000) == "1,000", "comma 1000")
	check(fmt.comma(1234567) == "1,234,567", "comma 1234567")
	check(fmt.comma(-12300) == "-12,300", "comma 음수")
	check(fmt.time("2026-10-10T01:02:03.456Z", 540) == "10-10 10:02", "time 소수 초·Z 무시, +9h")
	check(fmt.time("2026-10-10T01:02:03Z", 0) == "10-10 01:02", "time bias 0")
	check(fmt.time("2026-12-31T20:00:00Z", 540) == "01-01 05:00", "time 해 넘김")
	check(fmt.parse_amount("1,000") == 1000, "parse_amount 쉼표")
	check(fmt.parse_amount(" 5000 ") == 5000, "parse_amount 공백")
	check(fmt.parse_amount("1a000") == null, "parse_amount 문자 섞임")
	check(fmt.parse_amount("5000.5") == null, "parse_amount 소수")
	check(fmt.parse_amount("") == null, "parse_amount 빈 값")
	check(fmt.parse_amount("-500") == -500, "parse_amount 음수")
	check(fmt.request_status("PENDING") == "대기", "request_status 알려진 값")
	check(fmt.request_status("NEW") == "NEW", "request_status 모르는 값은 그대로")

	# InputRules
	var ir := preload("res://core/input_rules.gd")
	check(ir.signup("a" + "b".repeat(3), "닉네임", "12345678", "12345678") == "", "아이디 4자 통과")
	check(ir.signup("a" + "b".repeat(19), "닉네임", "12345678", "12345678") == "", "아이디 20자 통과")
	check(ir.signup("abc", "닉네임", "12345678", "12345678") == "USERNAME_FORMAT", "아이디 3자 거부")
	check(ir.signup("a" + "b".repeat(20), "닉네임", "12345678", "12345678") == "USERNAME_FORMAT", "아이디 21자 거부")
	check(ir.signup("1abc", "닉네임", "12345678", "12345678") == "USERNAME_FORMAT", "아이디 숫자 시작 거부")
	check(ir.signup("Abcd", "닉네임", "12345678", "12345678") == "", "아이디 대문자는 lowercase 로 통과")
	check(ir.signup("abcd", "가", "12345678", "12345678") == "NICKNAME_LENGTH", "닉네임 1자 거부")
	check(ir.signup("abcd", "가".repeat(13), "12345678", "12345678") == "NICKNAME_LENGTH", "닉네임 13자 거부")
	check(ir.signup("abcd", "가나", "12345678", "12345678") == "", "닉네임 2자 통과")
	check(ir.signup("abcd", "가".repeat(12), "12345678", "12345678") == "", "닉네임 12자 통과")
	check(ir.signup("abcd", "   ", "12345678", "12345678") == "NICKNAME_BLANK", "닉네임 공백만 BLANK")
	check(ir.signup("abcd", "가\u200B나", "12345678", "12345678") == "NICKNAME_FORBIDDEN_CHARACTER", "닉네임 U+200B 거부")
	check(ir.signup("abcd", "가" + " ".repeat(5) + "나", "12345678", "12345678") == "", "닉네임 내부 공백은 1칸으로 줄어 길이 3")
	check(ir.signup("abcd", "가" + " ".repeat(11) + "나", "12345678", "12345678") == "", "닉네임 내부 연속 공백 축약 후 길이")
	check(ir.signup("abcd", "닉네임", "1234567", "1234567") == "PASSWORD_TOO_SHORT", "비밀번호 7자 거부")
	check(ir.signup("abcd", "닉네임", "12345678", "12345678") == "", "비밀번호 8자 통과")
	var kr25 := "가".repeat(25)
	check(ir.signup("abcd", "닉네임", kr25, kr25) == "PASSWORD_TOO_LONG", "비밀번호 75바이트 거부")
	var b72 := "가".repeat(24)
	check(ir.signup("abcd", "닉네임", b72, b72) == "", "비밀번호 72바이트 통과")
	check(ir.signup("abcd", "닉네임", "x".repeat(73), "x".repeat(73)) == "PASSWORD_TOO_LONG", "비밀번호 73바이트 거부")
	check(ir.signup("abcd", "닉네임", "12345678", "12345679") == "PASSWORD_CONFIRM_MISMATCH", "비밀번호 확인 불일치")
	check(ir.signup("ab", "가", "1", "2") == "PASSWORD_CONFIRM_MISMATCH", "검사 순서: confirm 이 먼저")
	check(ir.deposit_amount(999) == "DEPOSIT_AMOUNT_INVALID", "충전 999 거부")
	check(ir.deposit_amount(1050) == "DEPOSIT_AMOUNT_INVALID", "충전 1050 거부")
	check(ir.deposit_amount(1000) == "", "충전 1000 통과")
	check(ir.withdrawal_amount(999) == "WITHDRAWAL_AMOUNT_INVALID", "환전 999 거부")
	check(ir.withdrawal_amount(1000) == "", "환전 1000 통과")
	check(ir.bank_account("은행", "1234567", "홍길동") == "BANK_ACCOUNT_INVALID", "계좌 7자리 거부")
	check(ir.bank_account("은행", "1".repeat(21), "홍길동") == "BANK_ACCOUNT_INVALID", "계좌 21자리 거부")
	check(ir.bank_account("은행", "123-4567-8", "홍길동") == "", "계좌 123-4567-8 통과")
	check(ir.bank_account("가".repeat(51), "12345678", "홍길동") == "BANK_ACCOUNT_INVALID", "은행명 51자 거부")
	check(ir.bank_account("은행", "12345678", " ") == "BANK_ACCOUNT_INVALID", "예금주 빈 값 거부")
	check(ir.credited_amount(0) == "DEPOSIT_AMOUNT_INVALID", "승인액 0 거부")
	check(ir.credited_amount(1500) == "", "승인액 1500 통과")
	check(ir.adjust(0, "사유") == "ADJUSTMENT_AMOUNT_INVALID", "조정 0 거부")
	check(ir.adjust(150, "사유") == "ADJUSTMENT_AMOUNT_INVALID", "조정 150 거부")
	check(ir.adjust(-100, "사유") == "", "조정 -100 통과")
	check(ir.adjust(100, "  ") == "ADJUSTMENT_REASON_BLANK", "조정 사유 공백 거부")
	check(ir.reject_reason("  ") == "REJECTION_REASON_BLANK", "반려 사유 공백 거부")
	check(ir.reject_reason("x") == "", "반려 사유 통과")

	# Pager
	var pbox := HBoxContainer.new()
	var pprev := Button.new()
	var plabel := Label.new()
	var pnext := Button.new()
	var pg := Pager.new(pbox, pprev, plabel, pnext)
	pg.total = 3
	pg.page = 1
	pg.update()
	check(pbox.visible and plabel.text == "2 / 3" and not pprev.disabled and not pnext.disabled, "Pager update 가운데 페이지")
	pg.page = 2
	pg.update()
	check(pnext.disabled and not pprev.disabled, "Pager update 마지막 페이지는 다음 비활성")
	pg.total = 1
	pg.page = 0
	pg.update()
	check(not pbox.visible, "Pager 1쪽이면 숨김")
	var stale := pg.begin()
	var fresh := pg.begin()
	check(pprev.disabled and pnext.disabled, "Pager begin 은 버튼 잠금")
	var ok_resp := {"ok": true, "data": {"page": {"number": 1, "totalPages": 3}, "content": []}}
	check(not await pg.accept(stale, 0, ok_resp, func(_p: int) -> void: pass), "Pager 낡은 gen 은 false")
	check(await pg.accept(fresh, 1, ok_resp, func(_p: int) -> void: pass) and pg.page == 1 and pg.total == 3, "Pager 정상 응답 반영")
	var called := [-1]
	var over := pg.begin()
	var res: bool = await pg.accept(over, 5, ok_resp, func(p: int) -> void: called[0] = p)
	check(not res and called[0] == 2, "Pager 초과는 마지막 페이지로 reload")
	pbox.free()
	pprev.free()
	plabel.free()
	pnext.free()

	quit(1 if failures else 0)


func role_token(json: String) -> String:
	var b64 := Marshalls.raw_to_base64(json.to_utf8_buffer()).replace("+", "-").replace("/", "_").rstrip("=")
	return "x." + b64 + ".y"


func check(cond: bool, name: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: ", name)
	else:
		print("ok: ", name)
