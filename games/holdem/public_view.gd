extends RefCounted

const Cards := preload("res://games/holdem/cards.gd")
## 공개 뷰(public_view) 순수 조회·계산. 노드·Api·시계에 기대지 않고 전부 인자로 받는다(헤드리스 점검용).


## 좌석 마지막 행동 배지 문구. lastAction 은 이번 판 내내(결과 화면까지) 유지되고 다음 판이 시작되면 null 이다.
static func action_label(seat: Dictionary) -> String:
	match seat.get("lastAction"):
		"FOLD": return "폴드"
		"CHECK": return "체크"
		"CALL": return "콜"
		"RAISE_TO": return "레이즈"
	return ""


## 이번 핸드에 블라인드를 낸 좌석 {"sb","bb"}(없으면 -1). 서버가 정산 뒤에도 방송에 값을 남기므로 핸드 중일 때만 본다.
## 헤즈업이면 sb 가 버튼과 같다. 데드 스몰 블라인드면 sb 만 null
static func blind_seats(view: Dictionary) -> Dictionary:
	var out := {"sb": -1, "bb": -1}
	if view.get("handInProgress", false):
		var sb = view.get("smallBlindSeatNo")
		var bb = view.get("bigBlindSeatNo")
		out.sb = -1 if sb == null else int(sb)
		out.bb = -1 if bb == null else int(bb)
	return out


static func find_seat(view: Dictionary, seat_no: int) -> Variant:
	for seat in view.get("seats", []):
		if seat.seatNo == seat_no:
			return seat
	return null


static func seat_held_by(view: Dictionary, seat_no: int, user_id) -> bool:
	# 결과는 다음 핸드 전까지 남는다 — 그 사이 같은 좌석에 다른 사람이 앉으면 물려받지 못하게 막는다.
	# 좌석이 비었다면 결과 주인이 나간 것(정산 때 나가기 예약 등)이라 결과를 그대로 보인다
	var seat: Variant = find_seat(view, seat_no)
	return user_id != null and (seat == null or int(seat.userId) == int(user_id))


static func find_seat_by_user(view: Dictionary, user_id: int) -> Variant:
	for seat in view.get("seats", []):
		if seat.userId == user_id:
			return seat
	return null


static func to_act_seat_no(view: Dictionary) -> int:
	# 아무도 차례가 아니면 서버가 null 을 보낸다 — get() 기본값은 키가 없을 때만 쓰이고, int(null) 은 오류다
	var to_act = view.get("toActSeatNo")
	return -1 if to_act == null else int(to_act)


static func find_shown_hand(view: Dictionary, seat_no: int) -> Variant:
	var result = view.get("result")
	if result == null:
		return null
	for shown in result.get("shownHands", []):
		if int(shown.seatNo) == seat_no and seat_held_by(view, seat_no, shown.get("userId")):
			return shown
	return null


static func find_revealed_hand(view: Dictionary, seat_no: int) -> Variant:
	for revealed in view.get("revealedHands", []):
		if int(revealed.seatNo) == seat_no:
			return revealed
	return null


static func payout_for(view: Dictionary, seat_no: int) -> int:
	var result = view.get("result")
	if result == null:
		return 0
	for payout in result.get("payouts", []):
		if int(payout.seatNo) == seat_no and seat_held_by(view, seat_no, payout.get("userId")):
			return int(payout.amount)
	return 0


## 폴드로 이긴 사람만, 다음 판 전에 한 번 보여 줄 수 있다. 폴드 종료 = 결과가 있고 shownHands 가 비었다(쇼다운이면 채워진다 — 내가 이미 보여 줬어도 채워져 조건이 꺼진다)
static func can_show_hand(view: Dictionary, user_id: int) -> bool:
	var result = view.get("result")
	if result == null or view.get("handInProgress", false) or not result.get("shownHands", []).is_empty():
		return false
	# 좌석이 아니라 userId 로 찾는다 — 나가기 예약이 정산에서 실행돼 자리가 비어도 다음 판 전까지 보여 줄 수 있다
	for payout in result.get("payouts", []):
		if int(payout.userId) == user_id and int(payout.amount) > 0:
			return true
	return false


## 이 스트리트에 이 좌석이 건 금액. 공개 뷰엔 totalContributed(핸드 누적)만 있어 스트리트 시작 값과의 차로 구한다
static func street_bet(seat: Dictionary, base: Dictionary) -> int:
	return maxi(int(seat.totalContributed) - int(base.get(int(seat.seatNo), 0)), 0)


## 스트리트 시작 시점의 누적 베팅(좌석 번호 → 금액)
static func street_base(view: Dictionary) -> Dictionary:
	var base := {}
	if view.get("street", "") != "PREFLOP": # 프리플랍은 블라인드부터 베팅이라 0 에서 센다
		for seat in view.get("seats", []):
			base[int(seat.seatNo)] = int(seat.totalContributed)
	return base


static func current_max_bet(view: Dictionary, base: Dictionary) -> int:
	var best := 0
	for seat in view.get("seats", []):
		best = maxi(best, street_bet(seat, base))
	return best


## 딜 순서: 버튼 왼쪽부터 ACTIVE·ALL_IN 좌석 번호
static func deal_order(view: Dictionary) -> Array:
	var dealer := int(view.get("buttonSeatNo", 0))
	var order: Array = []
	for seat in view.get("seats", []):
		if seat.status == "ACTIVE" or seat.status == "ALL_IN":
			order.append(int(seat.seatNo))
	order.sort_custom(func(a: int, b: int) -> bool: return posmod(a - dealer - 1, 9) < posmod(b - dealer - 1, 9))
	return order


## 연속한 공개 뷰 둘의 차이로 효과음 이름 목록을 만든다. prev 가 비면(첫 뷰·재연결 뒤) []. 좌석은 userId 로 맞추고 주인이 바뀐 좌석은 건너뛴다.
## 이름: shuffle·deal(새 판), board, call, raise, allin, check, fold, win
static func sound_events(prev: Dictionary, cur: Dictionary) -> Array:
	var out: Array = []
	if prev.is_empty():
		return out
	if cur.get("handInProgress", false) and not prev.get("handInProgress", false):
		out.append_array(["shuffle", "deal"])
	if cur.get("board", []).size() > prev.get("board", []).size():
		out.append("board")
	for seat in cur.get("seats", []):
		var old: Variant = find_seat(prev, int(seat.seatNo))
		if old == null or int(old.userId) != int(seat.userId):
			continue
		var act = seat.get("lastAction")
		var acted: bool = act != old.get("lastAction")
		if seat.status == "ALL_IN" and old.status != "ALL_IN":
			out.append("allin")
		elif act == "FOLD" and acted or seat.status == "FOLDED" and old.status != "FOLDED":
			out.append("fold")
		elif acted and act == "CHECK":
			out.append("check")
		elif acted and act == "CALL":
			out.append("call")
		elif acted and act == "RAISE_TO":
			out.append("raise")
	if prev.get("result") == null and cur.get("result") != null:
		out.append("win")
	return out


## 칩 금액 단위(큰 것부터). 서버 칩 단위는 100 이라 100 미만 나머지는 버린다
const CHIP_DENOMS := [500000, 100000, 50000, 10000, 5000, 1000, 500, 100]


## 금액을 큰 단위부터 욕심내어 나눈다 → [[단위, 장수], ...](장수 0 은 뺀다). 예: 2800 → [[1000,2],[500,1],[100,3]]
static func chip_breakdown(amount: int) -> Array:
	var out: Array = []
	var left := amount
	for d: int in CHIP_DENOMS:
		var n := left / d
		if n > 0:
			out.append([d, n])
			left -= n * d
	return out


## 핸드 끝 결과 배너 {"title": 큰 글자, "sub": [[좌석, userId, 금액], ...]} — 이길 사람이 없으면 {}. 닉네임은 호출 쪽이 userId 로 찾는다.
## 쇼다운 단독 = 족보, 스플릿(승자 2명 이상) = "스플릿 · 족보"(족보가 다르면 "스플릿"), 패 공개 없이 끝나면 "폴드 승리", 족보를 모르면 "승리"
static func result_banner(view: Dictionary) -> Dictionary:
	var result = view.get("result")
	if result == null:
		return {}
	var sub := []
	for payout in result.get("payouts", []):
		var seat_no := int(payout.seatNo)
		var uid = payout.get("userId")
		if uid == null and find_seat(view, seat_no) != null:
			uid = find_seat(view, seat_no).userId
		if payout.amount > 0 and uid != null and seat_held_by(view, seat_no, uid):
			sub.append([seat_no, int(uid), int(payout.amount)])
	if sub.is_empty():
		return {}
	if result.get("shownHands", []).is_empty():
		return {"title": "폴드 승리", "sub": sub}
	var cats := []
	for w: Array in sub:
		var shown: Variant = find_shown_hand(view, w[0])
		cats.append(shown.get("category") if shown != null else null)
	var cat = cats[0]
	for c in cats:
		if c != cat:
			cat = null
	var text: String = Cards.category_text(cat) if cat is String else ""
	if sub.size() >= 2:
		return {"title": "스플릿 · " + text if text != "" else "스플릿", "sub": sub}
	return {"title": text if text != "" else "승리", "sub": sub}
