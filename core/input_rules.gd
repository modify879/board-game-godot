class_name InputRules
## 입력 사전 검사(사용성용). 최종 판단은 서버가 한다 — 여기서 통과해도 서버가 거부할 수 있고 그 errorCode 는 그대로 보인다.
## 서버 규칙이 바뀌면 함께 고친다. 함수는 문제가 없으면 "", 있으면 errorCode 를 돌려준다.
## 서버 경로는 서버 저장소 src/main/kotlin/com/jsm/boardgame/ 기준. 로그인은 서버가 형식 오류도 LOGIN_FAILED 로 감추므로 검사하지 않는다.

const MIN_MONEY := 1000 # 충전·환전 최소 금액
const MONEY_UNIT := 100


## 서버 검사 순서(confirm → username → nickname → password)대로 첫 오류. SignUpRequest.kt:13-14
static func signup(username: String, nickname: String, password: String, confirm: String) -> String:
	if password != confirm:
		return "PASSWORD_CONFIRM_MISMATCH"
	var e := _username(username)
	if e == "":
		e = _nickname(nickname)
	if e == "":
		e = _password(password)
	return e


## trim → lowercase → ^[a-z][a-z0-9_]{3,19}$. user/domain/model/Username.kt:9,12-13
static func _username(username: String) -> String:
	var re := RegEx.create_from_string("^[a-z][a-z0-9_]{3,19}$")
	return "" if re.search(username.strip_edges().to_lower()) else "USERNAME_FORMAT"


## 모든 공백 → ' ' → trim → 연속 공백 1칸. BLANK → FORBIDDEN(Cc·Cf) → LENGTH(코드포인트 2~12). user/domain/model/Nickname.kt:13-51
## 서버는 먼저 NFC 정규화하지만 Godot 에 없어 생략한다(조합형 한글 입력은 길이가 서버와 다를 수 있다).
## 공백·Cf 는 Unicode 전체가 아닌 주요 범위만 옮겼다.
static func _nickname(nickname: String) -> String:
	var ws := RegEx.create_from_string("[\\s\\x{1C}-\\x{1F}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}]")
	var n := ws.sub(nickname, " ", true).strip_edges()
	n = RegEx.create_from_string(" {2,}").sub(n, " ", true)
	if n == "":
		return "NICKNAME_BLANK"
	for i in n.length():
		var c := n.unicode_at(i)
		if c < 0x20 or (c >= 0x7F and c <= 0x9F) or c == 0xAD or (c >= 0x600 and c <= 0x605) or c == 0x61C \
				or c == 0x6DD or c == 0x70F or c == 0x180E or (c >= 0x200B and c <= 0x200F) \
				or (c >= 0x202A and c <= 0x202E) or (c >= 0x2060 and c <= 0x2064) \
				or (c >= 0x2066 and c <= 0x206F) or c == 0xFEFF or (c >= 0xFFF9 and c <= 0xFFFB):
			return "NICKNAME_FORBIDDEN_CHARACTER"
	if n.length() < 2 or n.length() > 12:
		return "NICKNAME_LENGTH"
	return ""


## trim 안 함. 코드포인트 8 미만 / UTF-8 72바이트 초과. user/domain/model/RawPassword.kt:12-31
static func _password(password: String) -> String:
	if password.length() < 8:
		return "PASSWORD_TOO_SHORT"
	if password.to_utf8_buffer().size() > 72:
		return "PASSWORD_TOO_LONG"
	return ""


## 충전 요청 금액: 1000 이상, 100 단위. wallet/domain/model/DepositRequest.kt:89,92, Money.kt:6
static func deposit_amount(amount: int) -> String:
	return "" if amount >= MIN_MONEY and amount % MONEY_UNIT == 0 else "DEPOSIT_AMOUNT_INVALID"


## 환전 요청 금액: 1000 이상, 100 단위. wallet/domain/model/WithdrawalRequest.kt:82,85, Money.kt:6
static func withdrawal_amount(amount: int) -> String:
	return "" if amount >= MIN_MONEY and amount % MONEY_UNIT == 0 else "WITHDRAWAL_AMOUNT_INVALID"


## 세 필드 trim, 계좌번호는 '-'·' ' 제거. 빈 값 / 번호 숫자 8~20자 아님 / 은행명·예금주 1~50자 아님. wallet/domain/model/BankAccount.kt:24-46
static func bank_account(bank: String, number: String, holder: String) -> String:
	var b := bank.strip_edges()
	var h := holder.strip_edges()
	var n := number.strip_edges().replace("-", "").replace(" ", "")
	if b == "" or h == "" or b.length() > 50 or h.length() > 50:
		return "BANK_ACCOUNT_INVALID"
	if not RegEx.create_from_string("^[0-9]{8,20}$").search(n):
		return "BANK_ACCOUNT_INVALID"
	return ""


## 관리자 승인액(지정할 때만): 0 초과, 100 단위. wallet/domain/model/DepositRequest.kt:45-52
static func credited_amount(amount: int) -> String:
	return "" if amount > 0 and amount % MONEY_UNIT == 0 else "DEPOSIT_AMOUNT_INVALID"


## 관리자 조정: 0 아님·100 단위, 사유 trim 후 비어 있지 않음. wallet/domain/model/Adjustment.kt:23,29-31
static func adjust(amount: int, reason: String) -> String:
	if amount == 0 or amount % MONEY_UNIT != 0:
		return "ADJUSTMENT_AMOUNT_INVALID"
	if reason.strip_edges() == "":
		return "ADJUSTMENT_REASON_BLANK"
	return ""


## 반려 사유: 비어 있지 않음. wallet/domain/model/DepositRequest.kt:60-64, WithdrawalRequest.kt:51-55
static func reject_reason(reason: String) -> String:
	return "" if reason.strip_edges() != "" else "REJECTION_REASON_BLANK"
