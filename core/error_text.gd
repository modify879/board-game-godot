class_name ErrorText
## Maps server errorCode strings to Korean display text.

const TEXT := {
	"AUTHENTICATION_REQUIRED": "로그인이 필요합니다",
	"ACCESS_DENIED": "권한이 없습니다",
	"NICKNAME_LENGTH": "닉네임은 2~12자여야 합니다",
	"NICKNAME_FORBIDDEN_CHARACTER": "닉네임에 사용할 수 없는 문자가 있습니다",
	"NICKNAME_BLANK": "닉네임을 입력해주세요",
	"USERNAME_FORMAT": "아이디는 영문 소문자로 시작하는 소문자/숫자/_ 4~20자여야 합니다",
	"PASSWORD_TOO_SHORT": "비밀번호는 8자 이상이어야 합니다",
	"PASSWORD_TOO_LONG": "비밀번호가 너무 깁니다",
	"PASSWORD_CONFIRM_MISMATCH": "비밀번호 확인이 일치하지 않습니다",
	"DUPLICATE_USERNAME": "이미 사용 중인 아이디입니다",
	"DUPLICATE_NICKNAME": "이미 사용 중인 닉네임입니다",
	"USER_NOT_FOUND": "사용자를 찾을 수 없습니다",
	"LOGIN_FAILED": "아이디 또는 비밀번호가 올바르지 않습니다",
	"REFRESH_TOKEN_INVALID": "세션이 만료되었습니다. 다시 로그인해주세요",
	"ACCOUNT_LOCKED": "계정이 잠겼습니다",
	"NETWORK_ERROR": "네트워크 오류가 발생했습니다",
	"TABLE_NOT_FOUND": "방을 찾을 수 없습니다",
	"TABLE_NAME_INVALID": "방 이름은 1~30자여야 합니다",
	"ALREADY_SEATED": "이미 착석 중입니다",
	"BUY_IN_OUT_OF_RANGE": "바이인 금액이 허용 범위를 벗어났습니다",
	"INSUFFICIENT_BALANCE": "잔액이 부족합니다",
	"JOIN_REQUEST_NOT_FOUND": "참가 요청을 찾을 수 없습니다",
	"NOT_SEATED": "착석 중이 아닙니다",
	"HAND_IN_PROGRESS": "진행 중인 판이 끝난 뒤에 할 수 있습니다",
	"CHIPS_NOT_UNIT": "칩은 100 단위로 입력해주세요",
	"NOT_CONNECTED": "서버 연결을 확인한 뒤 다시 시도해주세요",
	"TABLE_FULL": "자리가 가득 찼습니다",
	"NOT_YOUR_TURN": "내 차례가 아닙니다",
	"CANNOT_CHECK": "지금은 체크할 수 없습니다",
	"RAISE_TOO_SMALL": "레이즈 금액이 너무 작습니다",
	"RAISE_NOT_ALLOWED": "지금은 레이즈할 수 없습니다",
	"INSUFFICIENT_STACK": "칩이 부족합니다",
	"BETTING_ROUND_CLOSED": "이미 끝난 베팅 라운드입니다",
	"HAND_ALREADY_FINISHED": "이미 끝난 판입니다",
	"HAND_NOT_FOUND": "진행 중인 판이 없습니다",
	"UNKNOWN_ACTION": "알 수 없는 행동입니다",
}


static func of(code: String) -> String:
	return TEXT.get(code, "오류가 발생했습니다 (%s)" % code)
