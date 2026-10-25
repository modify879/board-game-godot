extends SceneTree
## Self-check for games/holdem/cards.gd static logic. Run with:
## Godot.exe --headless --path . --script res://games/holdem/test_holdem.gd

var failures := 0


func _init() -> void:
	var cards := preload("res://games/holdem/cards.gd")

	# texture_path
	check(cards.texture_path("As") == "res://games/holdem/assets/cards/As.png", "texture_path builds res:// path")
	for code in ["Td", "As", "2c"]:
		var path: String = cards.texture_path(code)
		check(ResourceLoader.exists(path), "texture_path file exists: " + code)

	# category_text / street_text
	check(cards.category_text("FULL_HOUSE") == "풀하우스", "category_text known")
	check(cards.category_text("NOPE") == "NOPE", "category_text unknown fallback")
	check(cards.street_text("RIVER") == "리버", "street_text known")

	# table_name
	var rules := preload("res://games/holdem/rules.gd")
	check(rules.table_name("  ") == "TABLE_NAME_INVALID", "방 이름 공백만 거부")
	check(rules.table_name("a".repeat(31)) == "TABLE_NAME_INVALID", "방 이름 31자 거부")
	check(rules.table_name("a".repeat(30)) == "", "방 이름 30자 통과")
	check(rules.table_name(" a ") == "", "방 이름 trim 후 1자 통과")

	# buy_in / chip_add — 서버 순서: 단위 → 범위 → 지갑
	check(rules.buy_in(4000, 4000, 20000, 100000) == "", "바이인 하한 통과")
	check(rules.buy_in(20000, 4000, 20000, 100000) == "", "바이인 상한 통과")
	check(rules.buy_in(4050, 4000, 20000, 100000) == "CHIPS_NOT_UNIT", "바이인 100 단위 아님")
	check(rules.buy_in(3900, 4000, 20000, 100000) == "BUY_IN_OUT_OF_RANGE", "바이인 하한 미만")
	check(rules.buy_in(20100, 4000, 20000, 100000) == "BUY_IN_OUT_OF_RANGE", "바이인 상한 초과")
	check(rules.buy_in(5000, 4000, 20000, 4900) == "INSUFFICIENT_BALANCE", "바이인이 지갑 초과")
	check(rules.buy_in(3950, 4000, 20000, 100) == "CHIPS_NOT_UNIT", "단위가 범위·지갑보다 먼저")
	check(rules.buy_in(3900, 4000, 20000, 100) == "BUY_IN_OUT_OF_RANGE", "범위가 지갑보다 먼저")
	check(rules.buy_in(5000, 4000, 20000) == "", "지갑을 모르면 지갑 검사 생략")
	check(rules.chip_add(5000, 15000, 20000, 9000) == "", "칩 추가 상한 정확히 통과")
	check(rules.chip_add(5100, 15000, 20000, 9000) == "CHIP_ADD_OUT_OF_RANGE", "칩 추가 스택 상한 초과")
	check(rules.chip_add(0, 1000, 20000, 9000) == "CHIP_ADD_OUT_OF_RANGE", "칩 추가 0 거부")
	check(rules.chip_add(150, 1000, 20000, 9000) == "CHIPS_NOT_UNIT", "칩 추가 단위")
	check(rules.chip_add(2000, 1000, 20000, 1900) == "INSUFFICIENT_BALANCE", "칩 추가가 지갑 초과")
	check(rules.buy_in_blocked_text({"walletBalance": 3900.0, "minBuyIn": 4000.0, "obligationExpiresAt": null}) == ErrorText.of("INSUFFICIENT_BALANCE"), "의무 없이 지갑 부족")
	check("이후에 앉을 수" in rules.buy_in_blocked_text({"walletBalance": 100.0, "minBuyIn": 4000.0, "obligationExpiresAt": "2026-01-01T10:00:00Z"}), "의무 시각 안내")
	check(rules.buy_in_blocked_text({"walletBalance": 4000.0, "minBuyIn": 4000.0, "obligationExpiresAt": null}) == "", "지갑이 충분하면 안내 없음")

	# preset_raise_to: 현재 최고 베팅 + f × (팟 + 콜), 100 단위, [min, max] 로 자름
	check(rules.preset_raise_to(0.5, 200, 600, 200, 400, 5000) == 600, "프리셋 ½ 팟 일반")
	check(rules.preset_raise_to(1.0, 200, 600, 200, 400, 5000) == 1000, "프리셋 팟 일반")
	check(rules.preset_raise_to(0.5, 200, 100, 200, 500, 5000) == 500, "프리셋 하한으로 올림")
	check(rules.preset_raise_to(1.0, 200, 600, 200, 400, 800) == 800, "프리셋 상한(올인)으로 내림")
	check(rules.preset_raise_to(0.5, 0, 650, 0, 200, 5000) == 300, "프리셋 100 단위 내림 (325 -> 300)")
	check(rules.preset_raise_to(0.5, 0, 750, 0, 200, 5000) == 400, "프리셋 100 단위 올림 (375 -> 400)")

	# public_view — 공개 뷰 순수 조회·계산
	var pv := preload("res://games/holdem/public_view.gd")
	var seats := [
		{"seatNo": 1, "userId": 10, "status": "ACTIVE", "totalContributed": 300},
		{"seatNo": 4, "userId": 11, "status": "FOLDED", "totalContributed": 100},
		{"seatNo": 7, "userId": 12, "status": "ALL_IN", "totalContributed": 500},
		{"seatNo": 8, "userId": 13, "status": "SITTING_OUT", "totalContributed": 0},
	]
	var view := {"seats": seats, "buttonSeatNo": 4, "street": "FLOP", "handInProgress": false}
	check(pv.find_seat(view, 7).userId == 12 and pv.find_seat(view, 2) == null, "find_seat 찾기·없음")
	check(pv.find_seat_by_user(view, 11).seatNo == 4 and pv.find_seat_by_user(view, 99) == null, "find_seat_by_user 찾기·없음")
	check(pv.seat_held_by(view, 2, 10.0), "seat_held_by 빈 좌석이면 true")
	check(pv.seat_held_by(view, 1, 10.0), "seat_held_by 같은 사용자 true")
	check(not pv.seat_held_by(view, 1, 11.0), "seat_held_by 다른 사용자 false")
	check(not pv.seat_held_by(view, 1, null), "seat_held_by null 사용자 false")
	check(pv.to_act_seat_no({"toActSeatNo": null}) == -1 and pv.to_act_seat_no({}) == -1, "to_act_seat_no null·키 없음 = -1")
	check(pv.to_act_seat_no({"toActSeatNo": 5.0}) == 5, "to_act_seat_no 정수")
	var shown := {"seatNo": 1, "userId": 10}
	var res := {"shownHands": [shown], "payouts": [{"seatNo": 1, "userId": 10, "amount": 700.0}]}
	var rview := {"seats": seats, "result": res}
	check(pv.find_shown_hand(rview, 1) == shown and pv.find_shown_hand(rview, 4) == null, "find_shown_hand 찾기·없음")
	check(pv.payout_for(rview, 1) == 700 and pv.payout_for(rview, 4) == 0, "payout_for 지급액·없음")
	check(pv.find_shown_hand(view, 1) == null and pv.payout_for(view, 1) == 0, "결과 없으면 null·0")
	var taken := {"seats": [{"seatNo": 1, "userId": 99}], "result": res}
	check(pv.find_shown_hand(taken, 1) == null and pv.payout_for(taken, 1) == 0, "다른 사람이 앉으면 shown·payout 무시")
	var emptied := {"seats": [], "result": res}
	check(pv.find_shown_hand(emptied, 1) == shown and pv.payout_for(emptied, 1) == 700, "좌석이 비면 shown·payout 유지")
	var revealed := {"seatNo": 7, "cards": ["As", "Kd"]}
	check(pv.find_revealed_hand({"revealedHands": [revealed]}, 7) == revealed and pv.find_revealed_hand({"revealedHands": [revealed]}, 1) == null and pv.find_revealed_hand({}, 7) == null, "find_revealed_hand")
	var fold_win := {"handInProgress": false, "result": {"shownHands": [], "payouts": [{"seatNo": 1, "userId": 10, "amount": 300.0}]}}
	check(pv.can_show_hand(fold_win, 10), "can_show_hand 폴드 승리 true")
	check(not pv.can_show_hand(fold_win, 11), "can_show_hand 다른 사용자 false")
	var showdown: Dictionary = fold_win.duplicate(true)
	showdown.result.shownHands = [shown]
	check(not pv.can_show_hand(showdown, 10), "can_show_hand 쇼다운 false")
	var live: Dictionary = fold_win.duplicate(true)
	live.handInProgress = true
	check(not pv.can_show_hand(live, 10), "can_show_hand 핸드 중 false")
	var zero: Dictionary = fold_win.duplicate(true)
	zero.result.payouts[0].amount = 0
	check(not pv.can_show_hand(zero, 10) and not pv.can_show_hand({}, 10), "can_show_hand 지급 0·결과 없음 false")
	check(pv.street_base({"street": "PREFLOP", "seats": seats}).is_empty(), "street_base 프리플랍은 비어 있음")
	var base: Dictionary = pv.street_base(view)
	check(base == {1: 300, 4: 100, 7: 500, 8: 0}, "street_base 플랍은 totalContributed")
	check(pv.street_bet({"seatNo": 1, "totalContributed": 450}, base) == 150, "street_bet 차이")
	check(pv.street_bet({"seatNo": 1, "totalContributed": 200}, base) == 0, "street_bet 0 으로 자름")
	check(pv.street_bet({"seatNo": 2, "totalContributed": 200}, base) == 200, "street_bet base 없으면 전액")
	var bet_view := {"seats": [{"seatNo": 1, "totalContributed": 450}, {"seatNo": 7, "totalContributed": 800}]}
	check(pv.current_max_bet(bet_view, base) == 300 and pv.current_max_bet({}, {}) == 0, "current_max_bet")
	var al := func(extra: Dictionary) -> String: return pv.action_label({"status": "ACTIVE"}.merged(extra, true))
	check(al.call({"lastAction": "FOLD"}) == "폴드" and al.call({"lastAction": "CHECK"}) == "체크", "action_label 폴드·체크")
	check(al.call({"lastAction": "CALL"}) == "콜" and al.call({"lastAction": "RAISE_TO"}) == "레이즈", "action_label 콜·레이즈")
	check(al.call({"status": "ALL_IN", "lastAction": "CALL"}) == "콜" and al.call({"status": "ALL_IN"}) == "", "action_label 올인 좌석도 lastAction 만 본다")
	check(al.call({}) == "" and al.call({"lastAction": null}) == "" and al.call({"lastAction": "X"}) == "", "action_label 없음·null·모르는 값은 빈 문자열")
	check(pv.deal_order(view) == [7, 1], "deal_order 버튼 왼쪽부터, ACTIVE·ALL_IN 만")
	check(pv.deal_order({"buttonSeatNo": 7, "seats": seats}) == [1, 7], "deal_order 버튼 바뀌면 회전")

	var bs := {"handInProgress": true, "smallBlindSeatNo": 2.0, "bigBlindSeatNo": 3.0}
	check(pv.blind_seats(bs) == {"sb": 2, "bb": 3}, "blind_seats 보통")
	check(pv.blind_seats({"handInProgress": true, "buttonSeatNo": 4.0, "smallBlindSeatNo": 4.0, "bigBlindSeatNo": 7.0}) == {"sb": 4, "bb": 7}, "blind_seats 헤즈업은 SB 가 버튼 좌석")
	check(pv.blind_seats({"handInProgress": true, "smallBlindSeatNo": null, "bigBlindSeatNo": 3.0}) == {"sb": -1, "bb": 3}, "blind_seats 데드 SB 는 sb 만 -1")
	check(pv.blind_seats(bs.merged({"handInProgress": false}, true)) == {"sb": -1, "bb": -1}, "blind_seats 핸드 밖은 -1")
	check(pv.blind_seats({"handInProgress": true}) == {"sb": -1, "bb": -1} and pv.blind_seats({}) == {"sb": -1, "bb": -1}, "blind_seats 필드 없음은 -1")

	quit(1 if failures else 0)


func check(cond: bool, name: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: ", name)
	else:
		print("ok: ", name)
