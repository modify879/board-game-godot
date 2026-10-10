class_name Format
## 화면 표시용 포매터.

const REQUEST_STATUS := {"PENDING": "대기", "APPROVED": "승인", "REJECTED": "거절", "CANCELED": "취소"} # 충전·환전 요청 상태


## 충전·환전 요청 상태 문구. 모르는 값은 그대로
static func request_status(status: String) -> String:
	return REQUEST_STATUS.get(status, status)


const BALANCE_FAILED := "잔액 확인 실패"


## 잔액 표시 문구
static func balance(n: int) -> String:
	return "잔액 %s" % comma(n)


## 천 단위 쉼표
static func comma(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## 금액 입력 → 정수. int() 가 "1a000" 을 조용히 1 로 바꾸는 변환 오류를 막는 것 — 금액 형식 검사는 InputRules. 못 읽으면 null
static func parse_amount(text: String) -> Variant:
	var t := text.strip_edges().replace(",", "")
	return int(t) if t.is_valid_int() else null


## ISO Instant(UTC) → 로컬 "MM-DD HH:MM". 소수 초·Z 는 앞 19자만 써서 버린다. bias_min 이 null 이면 시스템 시간대
static func time(iso: String, bias_min: Variant = null) -> String:
	var t := int(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))
	t += int(Time.get_time_zone_from_system().bias if bias_min == null else bias_min) * 60
	var d := Time.get_datetime_dict_from_unix_time(t)
	return "%02d-%02d %02d:%02d" % [d.month, d.day, d.hour, d.minute]
