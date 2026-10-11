extends RefCounted
## 홀덤 입력 사전 검사(사용성용). 최종 판단은 서버가 한다 — 서버 규칙이 바뀌면 함께 고친다.
## 서버 경로는 서버 저장소 src/main/kotlin/com/jsm/boardgame/ 기준.

## 칩 단위. holdem/domain/model/Chips.kt:10
const CHIP_UNIT := 100
## 빅블라인드. 서버 고정값. holdem/domain/model/HoldemTable.kt:7-8,62-63
const BIG_BLIND := 200
## 기본 바이인 범위 20BB~100BB(재착석 의무가 없을 때). 실제 범위는 buy-in GET 이 준다. holdem/domain/model/HoldemTable.kt:64-65,79,82,257-258
const DEFAULT_MIN_BUY_IN := 20 * BIG_BLIND
const DEFAULT_MAX_BUY_IN := 100 * BIG_BLIND


## 방 이름: trim 후 코드포인트 1~30. 문제가 없으면 "", 있으면 errorCode. holdem/domain/model/HoldemTable.kt:232,240-242
static func table_name(table_name: String) -> String:
	var n := table_name.strip_edges().length()
	return "" if n >= 1 and n <= 30 else "TABLE_NAME_INVALID"


## 바이인: 음수·단위(Chips.of, Chips.kt:51-57) → 범위(SeatRequester.kt:43-47) → 지갑(SeatRequester.kt:48-51) 순. wallet < 0 이면 잔액을 모르는 것이라 건너뛴다
static func buy_in(amount: int, min_buy_in: int, max_buy_in: int, wallet := -1) -> String:
	if amount < 0:
		return "CHIPS_NEGATIVE"
	if amount % CHIP_UNIT != 0:
		return "CHIPS_NOT_UNIT"
	if amount < min_buy_in or amount > max_buy_in:
		return "BUY_IN_OUT_OF_RANGE"
	if wallet >= 0 and wallet < amount:
		return "INSUFFICIENT_BALANCE"
	return ""


## 칩 추가: 음수·단위(AddChipsService.kt:42) → 0 초과·스택 상한(HoldemTable.kt:85-91) → 지갑(AddChipsService.kt:44-46) 순. 핸드 중 거부(HAND_IN_PROGRESS)는 버튼 상태로 막는다
static func chip_add(amount: int, stack: int, max_stack: int, wallet := -1) -> String:
	if amount < 0:
		return "CHIPS_NEGATIVE"
	if amount % CHIP_UNIT != 0:
		return "CHIPS_NOT_UNIT"
	if amount <= 0 or stack + amount > max_stack:
		return "CHIP_ADD_OUT_OF_RANGE"
	if wallet >= 0 and wallet < amount:
		return "INSUFFICIENT_BALANCE"
	return ""


## buy-in GET 응답에서 지갑이 최소 바이인에 못 미칠 때의 안내 문구(재착석 의무가 있으면 풀리는 시각을 덧붙인다). 앉을 수 있으면 ""
static func buy_in_blocked_text(data: Dictionary) -> String:
	if int(data.walletBalance) >= int(data.minBuyIn):
		return ""
	var text := ErrorText.of("INSUFFICIENT_BALANCE")
	if data.get("obligationExpiresAt") != null:
		text += "\n나간 지 30분 이내에는 나간 금액 이상으로 다시 앉아야 합니다. %s 이후에 앉을 수 있습니다" % Format.time(str(data.obligationExpiresAt))
	return text
