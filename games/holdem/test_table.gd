extends Node
## Self-check for games/holdem/table.gd state logic. Needs autoloads, so it runs as a scene:
## Godot.exe --headless --path . res://games/holdem/test_table.tscn

var failures := 0


func _seat(no: int, user: int, status := "ACTIVE") -> Dictionary:
	return {"seatNo": float(no), "userId": float(user), "stack": 1000.0, "status": status,
		"presence": "CONNECTED", "totalContributed": 0.0, "leaveReserved": false}


func _view(seq: int, seats: Array, extra := {}) -> Dictionary:
	var v := {"seq": float(seq), "seats": seats, "board": [], "handInProgress": false,
		"toActSeatNo": null, "buttonSeatNo": 1.0, "street": "FLOP", "result": null,
		"revealedHands": [], "nextHandInMs": null, "turnRemainingMs": null}
	v.merge(extra, true)
	return v


func _ready() -> void:
	Api.user_id = 7
	var script := preload("res://games/holdem/table.gd")
	script.table_id = 1
	script.auto_join = false
	var table: Control = load("res://games/holdem/table.tscn").instantiate()
	add_child(table)
	Stomp.disconnect_ws() # 실서버 메시지가 주입한 뷰와 섞이지 않게 소켓을 끊는다
	await get_tree().process_frame

	# 1. seq ordering
	table._handle_public(_view(5, [_seat(1, 7)], {"board": ["As", "Kd", "2c"]}))
	table._handle_public(_view(4, [_seat(1, 7)], {"board": ["As", "Kd", "2c", "3h"]}))
	check(table.public_view.board.size() == 3 and int(table.public_view.seq) == 5, "older seq is ignored")

	# 2. board rendering
	var shown := 0
	for r in table.board_card_rects:
		if r.visible:
			shown += 1
	check(shown == 3, "3 board cards visible (got %d)" % shown)

	# 3. action bar: shown on my turn, hidden during all-in runout (toActSeatNo null)
	table._handle_public(_view(6, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0, "board": ["As", "Kd", "2c"]}))
	table.my_available_actions = {"canCheck": true, "callAmount": 0.0, "minRaiseTo": null}
	table._update_action_bar()
	check(table.action_bar.visible, "action bar visible on my turn")
	var qs: Dictionary = table.qa_state()
	check(qs.to_act_seat == 1 and qs.hand_in_progress and qs.board.size() == 3 and qs.seats.size() == 2 and qs.available_actions == ["CHECK", "FOLD"], "qa_state 기본 필드")
	var names_ok := true
	for i in 9:
		names_ok = names_ok and table.seat_nodes[i].name == "Seat%d" % (i + 1)
	check(names_ok, "seat nodes named Seat1..Seat9")
	check(qs.seats[0].nickname != "" and qs.seats[1].nickname == table.seat_nodes[1].name_label.text, "qa_state nickname falls back to displayed name")
	table._handle_public(_view(7, [_seat(1, 7, "ALL_IN"), _seat(2, 8, "ALL_IN")],
		{"handInProgress": true, "board": ["As", "Kd", "2c"]}))
	check(not table.action_bar.visible, "action bar hidden when nobody to act")

	# 4. revealedHands
	table._handle_public(_view(8, [_seat(1, 7, "ALL_IN"), _seat(2, 8, "ALL_IN")],
		{"handInProgress": true, "revealedHands": [{"seatNo": 2.0, "holeCards": ["As", "Kd"]}]}))
	check(table._find_revealed_hand(2) != null, "revealed hand found for seat 2")
	check(table._find_revealed_hand(1) == null, "no revealed hand for seat 1")

	# 5. result matches userId
	var result := {"payouts": [{"seatNo": 2.0, "userId": 8.0, "amount": 500.0}],
		"shownHands": [{"seatNo": 2.0, "userId": 8.0, "holeCards": ["As", "Kd"], "category": "PAIR"}]}
	table.nickname_cache[8] = "qauser8" # 네트워크 없이 닉네임을 정해 둔다
	table._handle_public(_view(9, [_seat(1, 7), _seat(2, 8)], {"result": result}))
	check(table._payout_for(2) == 500, "payout for seat 2 held by same user")
	check(table.board_label.text == "qauser8 +500", "board_label shows winner nickname: '%s'" % table.board_label.text)
	table._handle_public(_view(10, [_seat(1, 7), _seat(2, 9)], {"result": result}))
	check(table._payout_for(2) == 0, "payout ignored when seat taken by another user")
	check(table.board_label.text == "", "board_label empty when winner left: '%s'" % table.board_label.text)
	check(table._find_shown_hand(2) == null, "shown hand ignored when seat taken by another user")

	# 6. join queue
	table.waiting = true
	table._handle_join_queue({"tableId": 1.0, "type": "SEATED"})
	check(not table.waiting and table.got_seated, "SEATED clears waiting, sets got_seated")

	var retried_before: bool = table.dropped_retried
	table.dropped_retried = true
	table._handle_join_queue({"tableId": 1.0, "type": "SEATED"})
	check(not table.dropped_retried, "SEATED resets dropped_retried")
	table.dropped_retried = retried_before

	var err_was: bool = table.error_label.visible
	table.error_label.show()
	table.retry_notice_shown = true
	table._handle_join_queue({"tableId": 1.0, "type": "SEATED"})
	check(not table.error_label.visible, "SEATED hides retry notice")
	table.error_label.visible = err_was

	# 6b. 재연결 스냅샷(POSITION)을 받으면 rejoin_pending 해제, 재시도 안내가 아니면 SEATED 가 오류 문구를 숨기지 않는다
	table.rejoin_pending = true
	table.error_label.show()
	table.retry_notice_shown = true
	table._handle_join_queue({"tableId": 1.0, "type": "POSITION", "position": 2.0})
	check(not table.rejoin_pending, "POSITION clears rejoin_pending")
	check(not table.error_label.visible, "POSITION hides retry notice")
	table.error_label.visible = err_was
	table.retry_notice_shown = false
	table.error_label.show()
	table._handle_join_queue({"tableId": 1.0, "type": "SEATED"})
	check(table.error_label.visible, "SEATED keeps non-retry error")
	table.error_label.visible = err_was

	# 7. ACCESS_DENIED 후 테이블이 연 새 소켓은 재연결 대상이어야 한다(의도적 종료 플래그가 덮이면 안 됨)
	Stomp._handle_packet("ERROR\nerrorCode:ACCESS_DENIED\n\n")
	check(not Stomp._intentional_close, "ACCESS_DENIED 뒤 새 소켓은 재연결 대상")
	Stomp.disconnect_ws()

	# 8. 레이즈 기본값: 새 턴에서만 최소값으로, 같은 턴 갱신은 사용자 조정 유지, 플랍 무베팅은 "베팅"
	var seats := [_seat(1, 7), _seat(2, 8)]
	table._handle_public(_view(11, seats, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	table.my_available_actions = {"canCheck": false, "callAmount": 200.0, "minRaiseTo": 400.0, "maxRaiseTo": 1000.0}
	table._update_action_bar()
	check(int(table.raise_slider.value) == 400 and table.raise_button.text == "레이즈 400", "preflop raise default: '%s'" % table.raise_button.text)
	table.raise_slider.value = 700
	table._handle_public(_view(12, seats, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	check(int(table.raise_slider.value) == 700, "same turn keeps slider (got %d)" % int(table.raise_slider.value))
	table.my_available_actions = {"canCheck": true, "callAmount": 0.0, "minRaiseTo": 400.0, "maxRaiseTo": 1000.0}
	table._update_action_bar()
	check(table.raise_button.text.begins_with("레이즈"), "preflop BB option stays 레이즈: '%s'" % table.raise_button.text)
	var flop_actions := {"seq": 1.0, "holeCards": [], "leaveReservation": null, "availableActions": {"canCheck": true, "callAmount": 0.0, "minRaiseTo": 200.0, "maxRaiseTo": 1000.0}}
	# (a) 공개 뷰가 먼저(낡은 프리플롭 액션이 남아 있음), 그 뒤 개인 뷰
	table._handle_public(_view(13, seats, {"handInProgress": true, "toActSeatNo": 1.0, "street": "FLOP"}))
	table._handle_private(flop_actions)
	check(int(table.raise_slider.value) == 200 and table.raise_button.text == "베팅 200", "flop bet default, public first: '%s'" % table.raise_button.text)
	# (b) 다음 스트리트(턴)에서 개인 뷰가 먼저, 그 뒤 공개 뷰
	table.raise_slider.value = 600
	flop_actions.seq = 2.0
	table._handle_private(flop_actions)
	table._handle_public(_view(14, seats, {"handInProgress": true, "toActSeatNo": 1.0, "street": "TURN"}))
	check(table.action_bar.visible and int(table.raise_slider.value) == 200 and table.raise_button.text == "베팅 200", "turn bet default, private first: '%s'" % table.raise_button.text)

	# 8b. 레이즈는 100 단위 — 새 턴마다 최소값이 선택되고, 최대(올인)도 그대로 선택된다
	for mm in [[400, 63800], [300, 20500], [200, 200]]:
		table.my_available_actions = {"canCheck": false, "callAmount": 200.0, "minRaiseTo": float(mm[0]), "maxRaiseTo": float(mm[1])}
		table._update_action_bar()
		check(int(table.raise_slider.value) == mm[0], "raise min %d selected (got %d)" % [mm[0], int(table.raise_slider.value)])
		table.raise_spin.value = mm[1]
		check(int(table.raise_slider.value) == mm[1], "raise max %d exact (got %d)" % [mm[1], int(table.raise_slider.value)])

	# 9. 턴 타이머: turnRemainingMs 로 매 뷰마다 재동기화, null 이면 숨김
	var seat1: Control = table.seat_nodes[0]
	var turn_extra := {"handInProgress": true, "toActSeatNo": 1.0, "street": "RIVER"}
	table._handle_public(_view(15, seats, turn_extra.merged({"turnRemainingMs": 31000.0, "turnTimeoutMs": 40000.0})))
	table._update_turn_timer()
	check(absf(seat1.timer_left - 31.0) < 0.5, "turn timer from turnRemainingMs: %.2f" % seat1.timer_left)
	table._handle_public(_view(16, seats, turn_extra.merged({"turnRemainingMs": 20000.0, "turnTimeoutMs": 40000.0})))
	table._update_turn_timer()
	check(absf(seat1.timer_left - 20.0) < 0.5, "same-turn view re-syncs timer: %.2f" % seat1.timer_left)
	check(absf(seat1.timer_total - 40.0) < 0.01, "turn timer total from turnTimeoutMs")
	table._handle_public(_view(161, seats, turn_extra.merged({"turnRemainingMs": 20000.0, "turnTimeoutMs": null})))
	table._update_turn_timer()
	check(seat1.timer_left < 0.0, "null turnTimeoutMs hides timer")
	table._handle_public(_view(17, seats, turn_extra.merged({"turnRemainingMs": null})))
	table._update_turn_timer()
	check(seat1.timer_left < 0.0, "null turnRemainingMs hides timer")

	# 10. 방 생성 중(table_id 0): join-queue 이벤트는 버리지 않고 모아 둔다
	script.table_id = 0
	table._handle_join_queue({"tableId": 5.0, "type": "SEATED"})
	check(table.pending_join_queue.size() == 1 and table.pending_join_queue[0].type == "SEATED", "join-queue buffered while table_id is 0")
	script.table_id = 1
	table.pending_join_queue = []

	# 11. 이 테이블의 join-queue 이벤트를 받으면 join_event_seen 이 선다
	var seen_before: bool = table.join_event_seen
	table.join_event_seen = false
	table._handle_join_queue({"tableId": 1.0, "type": "SEATED"})
	check(table.join_event_seen, "join_event_seen set by own-table join-queue event")
	table.join_event_seen = seen_before

	# 12. DROPPED 재시도 대기(retry_pending) 동안 참가 버튼을 숨긴다
	table.waiting = false
	table.retry_pending = false
	table.public_view = _view(20, [_seat(2, 8)])
	table._update_buttons()
	check(table.join_button.visible, "join button visible when not seated and no retry pending")
	table.retry_pending = true
	table._update_buttons()
	check(not table.join_button.visible, "join button hidden while retry_pending")
	table.retry_pending = false

	# 13. 재참가가 ALREADY_SEATED 를 받아도 이미 앉았으면 대기로 되돌리지 않는다
	table.waiting = false
	table.public_view = _view(21, [_seat(1, 7)])
	table.waiting = false
	table._apply_already_seated()
	check(not table.waiting, "ALREADY_SEATED while seated keeps waiting false")
	table.public_view = _view(22, [_seat(2, 8)])
	table._apply_already_seated()
	check(table.waiting, "ALREADY_SEATED while not seated sets waiting")
	table.waiting = false

	# 14. 늦은 buy-in 응답은 팝업 세대가 바뀌거나 닫히면 버린다
	var bi := {"ok": true, "data": {"minBuyIn": 4000.0, "maxBuyIn": 20000.0, "maxStack": 20000.0, "walletBalance": 100000.0, "obligationExpiresAt": null}}
	table.sit_popup_gen = 5
	table.sit_popup.show()
	table.sit_popup_ok.disabled = true
	table._apply_sit_buy_in(4, bi)
	check(table.sit_popup_ok.disabled, "stale-generation buy-in response ignored")
	table.sit_popup.hide()
	table._apply_sit_buy_in(5, bi)
	check(table.sit_popup_ok.disabled, "buy-in response ignored when popup hidden")
	table.sit_popup.show()
	table._apply_sit_buy_in(5, bi)
	check(not table.sit_popup_ok.disabled and table.sit_popup_spin.visible, "current buy-in response applied")
	check(int(table.sit_popup_spin.min_value) == 4000 and int(table.sit_popup_spin.max_value) == 20000 and int(table.sit_popup_spin.value) == 20000, "spin range 4000~20000, default max")
	# 지갑이 상한보다 적으면 100 단위로 내림한 지갑이 상한·기본값
	bi.data.walletBalance = 7350.0
	table._apply_sit_buy_in(5, bi)
	check(int(table.sit_popup_spin.max_value) == 7300 and int(table.sit_popup_spin.value) == 7300, "spin max capped to wallet floor: %d" % int(table.sit_popup_spin.max_value))
	# 지갑 < 최소 + 의무: 확인 막힘, 잔액 부족 + 시각 안내
	bi.data.walletBalance = 3000.0
	bi.data.obligationExpiresAt = "2026-01-01T10:00:00Z"
	table._apply_sit_buy_in(5, bi)
	check(table.sit_popup_ok.disabled and not table.sit_popup_spin.visible, "wallet below min blocks OK")
	check(ErrorText.of("INSUFFICIENT_BALANCE") in table.sit_popup_error.text and "이후에 앉을 수" in table.sit_popup_error.text, "blocked notice with obligation time: '%s'" % table.sit_popup_error.text)
	bi.data.obligationExpiresAt = null
	table._apply_sit_buy_in(5, bi)
	check(table.sit_popup_error.text == ErrorText.of("INSUFFICIENT_BALANCE"), "blocked without obligation: plain text")
	table._apply_sit_buy_in(5, {"ok": false, "error": "TEMPORARILY_UNAVAILABLE"})
	check(table.sit_popup_error.visible and table.sit_popup_ok.disabled, "buy-in GET failure shown")
	table.sit_popup.hide()
	# 입장 선택 패널이 바이인을 넘기면 착석 팝업 없이 바로 참가 요청(last_* 로 재시도에 같은 값을 쓴다)
	script.auto_join = true
	script.auto_join_buy_in = 5000
	script.auto_join_post_blind = true
	table.waiting = false
	table.public_view = _view(30, [_seat(2, 8)])
	table._on_stomp_connected()
	check(not table.sit_popup.visible and table.last_buy_in == 5000 and table.last_post_blind and script.auto_join_buy_in == 0, "auto_join with buy-in sends join without SitPopup")
	script.auto_join = false
	table.waiting = false

	# 14a. 패 보여 주기: 폴드 승자(결과 있음·shownHands 비음·내 지급액·핸드 없음)만. category null 도 그려진다
	var fold_result := {"payouts": [{"seatNo": 1.0, "userId": 7.0, "amount": 500.0}], "shownHands": []}
	table.show_pending = false
	table._handle_public(_view(100, [_seat(1, 7), _seat(2, 8)], {"result": fold_result}))
	check(table.show_hand_button.visible and not table.show_hand_button.disabled, "show button visible for fold winner")
	table.show_pending = true
	table._update_buttons()
	check(table.show_hand_button.disabled, "show button disabled in flight")
	table.show_pending = false
	# 예약 나가기로 자리가 빈 폴드 승자도 userId 로 보인다
	table._handle_public(_view(100, [_seat(2, 8)], {"result": fold_result}))
	check(table.show_hand_button.visible, "show button visible for fold winner no longer seated")
	table._handle_public(_view(100, [_seat(2, 8)], {"result": fold_result, "handInProgress": true}))
	check(not table.show_hand_button.visible, "show button hidden during hand when unseated")
	var other_result := {"payouts": [{"seatNo": 2.0, "userId": 8.0, "amount": 500.0}], "shownHands": []}
	table._handle_public(_view(100, [_seat(2, 8)], {"result": other_result}))
	check(not table.show_hand_button.visible, "show button hidden for other user's payout")
	table._handle_public(_view(101, [_seat(1, 7), _seat(2, 8)], {"result": fold_result, "handInProgress": true}))
	check(not table.show_hand_button.visible, "show button hidden while hand in progress")
	table._handle_public(_view(102, [_seat(1, 7), _seat(2, 8)], {"result": {"payouts": [{"seatNo": 2.0, "userId": 8.0, "amount": 500.0}], "shownHands": []}}))
	check(not table.show_hand_button.visible, "show button hidden for non-winner")
	var showdown := {"payouts": [{"seatNo": 1.0, "userId": 7.0, "amount": 500.0}],
		"shownHands": [{"seatNo": 1.0, "userId": 7.0, "holeCards": ["As", "Kd"], "category": "PAIR"}]}
	table._handle_public(_view(103, [_seat(1, 7), _seat(2, 8)], {"result": showdown}))
	check(not table.show_hand_button.visible, "show button hidden for showdown / already shown")
	var null_cat := {"payouts": showdown.payouts, "shownHands": [{"seatNo": 1.0, "userId": 7.0, "holeCards": ["As", "Kd"], "category": null}]}
	table._handle_public(_view(105, [_seat(1, 7), _seat(2, 8)], {"result": null_cat}))
	check(not table.show_hand_button.visible and table._find_shown_hand(1) != null, "null category shown hand renders")
	# 앞면 카드(공개 패)·내 큰 카드가 있는 좌석은 행동 글자를 숨기고, 뒷면 카드 좌석은 보인다
	var fx_seats := [_seat(1, 7), _seat(2, 8)]
	fx_seats[0]["lastAction"] = "CHECK"
	fx_seats[1]["lastAction"] = "CHECK"
	var showdown2 := {"payouts": showdown.payouts, "shownHands": [{"seatNo": 2.0, "userId": 8.0, "holeCards": ["Qh", "Jh"], "category": "PAIR"}]}
	table._handle_public(_view(105.5, fx_seats, {"result": showdown2}))
	check(not table.seat_nodes[1].badge_action.visible and not table.seat_nodes[0].badge_action.visible, "result: 공개 패·내 좌석의 행동 글자 숨김")
	table._handle_public(_view(105.6, fx_seats, {"handInProgress": true, "toActSeatNo": 1.0}))
	check(table.seat_nodes[1].badge_action.visible, "핸드 중 뒷면 카드 좌석은 행동 글자 보임")
	table._handle_public(_view(105.7, fx_seats, {"result": showdown2}))
	check(table.banner_bg.visible and table.banner_bg.size.x > 0.0, "결과 배너 뒤판이 보임")
	table._handle_public(_view(106, [_seat(1, 7)]))
	# SHOW_NOT_ALLOWED 로 거부되면 그 판 동안 다른 뷰가 와도 숨기고, 새 판의 폴드 승리에서는 다시 보인다
	table._handle_public(_view(107, [_seat(1, 7), _seat(2, 8)], {"result": fold_result}))
	table.show_denied_hand = table.hand_counter
	table._handle_public(_view(108, [_seat(1, 7), _seat(2, 8)], {"result": fold_result}))
	check(not table.show_hand_button.visible, "show button stays hidden after denial in the same hand")
	table._handle_public(_view(109, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0}))
	table._handle_public(_view(110, [_seat(1, 7), _seat(2, 8)], {"result": fold_result}))
	check(table.show_hand_button.visible, "show button returns for the next fold-won hand")
	table._handle_public(_view(111, [_seat(1, 7)]))

	# 14b. 칩 추가 버튼: 앉아 있고, 핸드 중이 아니고, 스택 < 최대일 때만 활성
	var my_seat := _seat(1, 7)
	table.waiting = false
	table.add_chips_pending = false
	table._handle_public(_view(2000, [my_seat]))
	check(table.add_chips_button.visible and not table.add_chips_button.disabled, "add chips enabled between hands")
	table._handle_public(_view(2001, [my_seat], {"handInProgress": true}))
	check(table.add_chips_button.disabled, "add chips disabled during hand")
	table._handle_public(_view(2002, [my_seat], {"nextHandInMs": 3000.0}))
	check(not table.add_chips_button.disabled, "add chips enabled during countdown")
	my_seat.stack = 20000.0
	table._handle_public(_view(2003, [my_seat]))
	check(table.add_chips_button.disabled, "add chips disabled at max stack")
	my_seat.stack = 1000.0
	table._handle_public(_view(2004, [_seat(2, 8)]))
	check(not table.add_chips_button.visible, "add chips hidden when not seated")
	table._handle_public(_view(2005, [my_seat]))
	table.add_chips_pending = true
	table._update_buttons()
	check(table.add_chips_button.disabled, "add chips disabled while request pending")
	table.add_chips_pending = false

	# 14b2. 관전 → 착석: 1번 좌석 패널이 일반에서 큰 내 패널로 바뀐다(데스크톱만 크기가 있다)
	table._handle_public(_view(2006, [_seat(1, 100), _seat(2, 8)]))
	check(not table.seat_nodes[0].hero_slot and not table.my_cards_box.visible, "spectator: seat 1 normal panel")
	table._handle_public(_view(2007, [my_seat, _seat(2, 8)]))
	check(table.seat_nodes[0].hero_slot == table.desktop, "seated at seat 1: hero panel (desktop)")
	table._handle_public(_view(2008, [_seat(1, 100), _seat(2, 8)]))
	check(not table.seat_nodes[0].hero_slot, "unseated: back to normal panel")
	table._handle_public(_view(2009, [my_seat]))

	# 14c. 나가기 예약: 핸드 중에도 일어서기가 켜져 있고(예약 문구), 예약되면 취소 버튼으로 바뀐다
	table._handle_public(_view(2010, [my_seat], {"handInProgress": true}))
	check(table.stand_button.visible and not table.stand_button.disabled, "stand enabled during hand")
	check(table.stand_button.text == "핸드 후 관전" and table.leave_room_button.visible and table.leave_room_button.text == "핸드 후 방 나가기" and not table.cancel_leave_button.visible, "two buttons during hand, cancel hidden")
	var reserved_seat := _seat(1, 7)
	reserved_seat["leaveReserved"] = true
	table._handle_public(_view(2011, [reserved_seat, _seat(2, 8)], {"handInProgress": true}))
	check(not table.stand_button.visible and table.cancel_leave_button.visible, "reserved: stand hidden, cancel visible")
	var other_reserved := _seat(2, 8)
	other_reserved["leaveReserved"] = true
	table._handle_public(_view(2012, [my_seat, other_reserved], {"handInProgress": true}))
	check(table.stand_button.visible and not table.cancel_leave_button.visible, "other seat reserved leaves my buttons alone")
	table._handle_public(_view(2013, [my_seat]))
	check(table.stand_button.text == "일어서기" and table.leave_room_button.text == "방 나가기" and table.leave_room_button.visible, "stand/leave texts between hands")
	# 14d. 방 나가기 의도: 202 → 예약 뷰에서 취소 문구·내 배지가 의도를 따르고, 취소하면 의도가 꺼진다
	table._handle_public(_view(2014, [my_seat], {"handInProgress": true}))
	table._apply_stand_result({"ok": true, "status": 202}, true)
	check(table.leave_room_after_stand, "202 with leave_room sets intent")
	table._handle_public(_view(2015, [reserved_seat, _seat(2, 8)], {"handInProgress": true}))
	check(table.cancel_leave_button.text == "나가기 예약됨 · 취소" and not table.leave_room_button.visible, "cancel text for leave-room intent")
	check(table.seat_nodes[0].badge_leave.visible and table.seat_nodes[0].badge_leave.text == "나가기 예약", "my badge: 나가기 예약")
	table.leave_room_after_stand = false
	table._handle_public(_view(2016, [reserved_seat, other_reserved], {"handInProgress": true}))
	check(table.cancel_leave_button.text == "관전 예약됨 · 취소" and table.seat_nodes[0].badge_leave.text == "관전 예약", "spectate intent texts")
	check(table.seat_nodes[1].badge_leave.visible and table.seat_nodes[1].badge_leave.text == "일어서기 예약", "other badge neutral")
	table.leave_room_after_stand = true
	table.public_view = _view(2017, [reserved_seat])
	check(not table._should_leave_room(), "still seated: stay")
	table.public_view = _view(2018, [_seat(2, 8)])
	check(table._should_leave_room(), "unseated with intent: return to list")
	table.leave_room_after_stand = false
	check(not table._should_leave_room(), "unseated without intent: stay as spectator")
	table.leave_room_after_stand = true
	table._apply_cancel_result({"ok": true, "status": 204})
	check(not table.leave_room_after_stand, "cancel success clears intent")
	# 14e. 개인 뷰 leaveReservation: 메모리 없이도 복원, null 은 해제
	table.leave_room_after_stand = false
	table._handle_private({"seq": 900000.0, "holeCards": [], "leaveReservation": "LEAVE"})
	check(table.leave_room_after_stand, "private leaveReservation LEAVE restores intent")
	table._handle_private({"seq": 900002.0, "holeCards": [], "leaveReservation": "SPECTATE"})
	check(not table.leave_room_after_stand, "private SPECTATE -> not leaving")
	table.leave_room_after_stand = true
	table._handle_private({"seq": 900003.0, "holeCards": [], "leaveReservation": null})
	check(not table.leave_room_after_stand, "private null clears intent")
	table._apply_stand_result({"ok": true, "status": 202}, false)
	check(not table.leave_room_after_stand, "202 SPECTATE resend switches kind")
	table.last_private_seq = -1
	table._handle_public(_view(2019, [my_seat]))
	# 열기 응답: 추가 가능 최대 = min(maxStack - stack, 지갑) 내림
	table._apply_add_chips_open(table.add_chips_gen, {"ok": true, "data": {"maxStack": 20000.0, "walletBalance": 50000.0}})
	check(table.add_chips_box.visible and int(table.add_chips_spin.max_value) == 19000 and int(table.add_chips_spin.value) == 19000, "add chips max by stack: %d" % int(table.add_chips_spin.max_value))
	table._apply_add_chips_open(table.add_chips_gen, {"ok": true, "data": {"maxStack": 20000.0, "walletBalance": 2550.0}})
	check(int(table.add_chips_spin.max_value) == 2500, "add chips max by wallet floor: %d" % int(table.add_chips_spin.max_value))
	table._apply_add_chips_open(table.add_chips_gen, {"ok": true, "data": {"maxStack": 20000.0, "walletBalance": 50.0}})
	check(not table.add_chips_box.visible and table.error_label.text == ErrorText.of("INSUFFICIENT_BALANCE"), "add chips: wallet below one unit -> notice")
	table._handle_public(_view(2006, [_seat(1, 7)]))
	table._update_buttons()

	# 연결이 끊기면 개인 구독을 지우고, 재연결 뒤 앉은 공개 뷰로 다시 구독한다
	table._handle_public(_view(1000, [_seat(1, 7)]))
	var sub_id: String = table.private_sub_id
	check(table.private_subscribed and Stomp._subs.has(sub_id), "앉으면 개인 구독")
	table._on_stomp_closed()
	check(not table.private_subscribed and not Stomp._subs.has(sub_id), "연결이 끊기면 개인 구독을 지운다")
	table.last_public_seq = -1 # 재연결 뒤 seq 리셋
	table._handle_public(_view(1, [_seat(1, 7)]))
	check(table.private_subscribed and Stomp._subs.has(table.private_sub_id), "재연결 뒤 앉은 뷰에서 다시 구독")

	# 정산 때 일어선 폴드 승자(빈 자리)의 결과는 그대로 보이고, 새로 앉은 다른 사람은 물려받지 못한다
	table.last_public_seq = -1
	var left_result := {"payouts": [{"seatNo": 2.0, "userId": 99.0, "amount": 300.0}],
		"shownHands": [{"seatNo": 2.0, "userId": 99.0, "holeCards": ["As", "Kd"], "category": null}]}
	table.nickname_cache[99] = "winner99" # 네트워크 없이 닉네임을 정해 둔다
	table._handle_public(_view(200, [_seat(1, 7)], {"result": left_result}))
	check(table.board_label.text == "winner99 +300", "빈 자리 승자 닉네임·지급액 표시: '%s'" % table.board_label.text)
	check(table._find_shown_hand(2) != null, "빈 자리 승자 패 찾음")
	check(table.seat_nodes[1].shown_codes.size() == 2, "빈 자리에 보여 준 패 카드 그림")
	table._handle_public(_view(201, [_seat(1, 7), _seat(2, 77)], {"result": left_result}))
	check(table._find_shown_hand(2) == null and not ("winner99" in table.board_label.text), "다른 사람이 앉으면 결과를 물려받지 않음")

	# 연출: 첫 뷰(재연결 뒤 포함)는 연출 없이 그리고, 새 판·플랍은 고스트를 만들되 상태는 즉시 반영한다. 다음 뷰가 오면 실제 노드는 최종값
	for c in table.motion.get_children():
		c.free()
	table.motion.kill_real()
	var duo := [_seat(1, 7), _seat(2, 8)]
	table.have_view = false
	table._handle_public(_view(300, duo, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	check(table.motion.get_child_count() == 0 and table.have_view, "첫 뷰는 연출(고스트) 없음")
	table._handle_public(_view(301, duo))
	table._handle_public(_view(302, duo, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	check(table.motion.get_child_count() > 0, "새 판은 딜 고스트를 만든다")
	check(table.seat_nodes[1].shown_codes == ["back", "back"] and int(table.public_view.seq) == 302, "연출 중에도 상태는 즉시 반영")
	check(table.seat_nodes[1].card_rects[0].modulate.a == 0.0, "고스트가 닿기 전 실제 카드는 숨김")
	table._handle_public(_view(303, duo, {"handInProgress": true, "toActSeatNo": 2.0, "street": "FLOP", "board": ["As", "Kd", "2c"]}))
	check(table.board_card_rects[0].scale.x < 0.01 and int(table.public_view.seq) == 303, "플랍 카드는 뒤집기 시작 상태, 상태는 즉시 반영")
	table._handle_public(_view(304, duo, {"handInProgress": true, "toActSeatNo": 1.0, "street": "FLOP", "board": ["As", "Kd", "2c"]}))
	check(table.board_card_rects[0].scale.x < 0.01, "같은 판의 뷰는 도는 appear 연출을 끊지 않는다")
	table.motion.kill_real()
	var settled := true
	for r: Control in table.board_card_rects + table.my_card_rects + [table.seat_nodes[1].card_rects[0], table.seat_nodes[1].card_rects[1]]:
		settled = settled and r.scale == Vector2.ONE and r.modulate.a == 1.0
	check(settled, "연출을 끝내면 보드·카드 노드는 scale 1 / alpha 1")
	table._handle_public(_view(305, duo))
	table._handle_public(_view(306, duo, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	check(table.seat_nodes[1].card_rects[0].modulate.a == 0.0, "새 판 딜 중 카드는 숨김")
	table.have_view = false
	table._handle_public(_view(307, duo, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	settled = true
	for r: Control in table.board_card_rects + table.my_card_rects + [table.seat_nodes[1].card_rects[0], table.seat_nodes[1].card_rects[1]]:
		settled = settled and r.scale == Vector2.ONE and r.modulate.a == 1.0
	check(settled, "첫 뷰(재연결)는 도는 연출을 끊고 노드를 scale 1 / alpha 1 로 맞춘다")

	# 방 이름·사이드 팟 문구
	table._handle_public(_view(390, duo, {"handInProgress": true, "toActSeatNo": 1.0, "street": "TURN", "pot": 1300.0, "tableName": "친구들 방", "pots": [{"amount": 900.0, "eligibleSeatNos": [1.0, 2.0]}, {"amount": 400.0, "eligibleSeatNos": [1.0]}]}))
	check(table.name_label.text == "· 친구들 방" and table.qa_state().table_name == "친구들 방", "방 이름 표시·qa_state table_name")
	check(table.qa_state().pot_labels == ["메인 900", "사이드 1 400"] and table.pots_label.visible and table.pots_label.text.contains("사이드 1 400"), "사이드 팟 2개 문구")
	table._handle_public(_view(391, duo, {"handInProgress": true, "toActSeatNo": 1.0, "street": "TURN", "tableName": "친구들 방", "pots": []}))
	check(not table.pots_label.visible and table.qa_state().pot_labels.is_empty(), "팟 0개면 사이드 팟 줄 없음")

	# 마지막 행동 배지: lastAction 이 있으면 정산 뒤(handInProgress=false)에도 남고, null 이면 숨는다
	var acted := [_seat(1, 7), _seat(2, 8), _seat(3, 9, "ALL_IN")]
	acted[0]["lastAction"] = "RAISE_TO"
	acted[1]["lastAction"] = "FOLD"
	acted[2]["lastAction"] = "CALL"
	table.have_view = false
	table._handle_public(_view(400, acted, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	var sn: Array = table.seat_nodes
	check(sn[0].badge_action.visible and sn[0].badge_action.text == "레이즈" and sn[1].badge_action.text == "폴드" and sn[2].badge_action.text == "콜" and sn[2].badge_all_in.visible, "행동 배지 문구")
	check(table.qa_state().seats[0].last_action == "레이즈", "qa_state last_action")
	table._handle_public(_view(401, acted, {"handInProgress": false}))
	check(sn[0].badge_action.visible and sn[0].badge_action.text == "레이즈" and sn[1].badge_action.text == "폴드", "정산 뒤에도 lastAction 이 있으면 행동 배지 유지")
	var cleared := [_seat(1, 7), _seat(2, 8), _seat(3, 9, "ALL_IN")]
	table._handle_public(_view(402, cleared, {"handInProgress": true, "toActSeatNo": 1.0, "street": "PREFLOP"}))
	check(not sn[0].badge_action.visible and not sn[1].badge_action.visible and not sn[2].badge_action.visible, "lastAction null 이면 행동 배지 숨김")

	# 핸드 기록 좌석 문구
	var hh := preload("res://games/holdem/hand_history.gd")
	check(hh.player_text({"seatNo": 3.0, "userId": 7.0, "startingStack": 5000.0, "endingStack": 6200.0}, 3, 7, false) == "좌석 3 (D) 나  +1,200", "핸드 기록: 내 좌석·버튼·이익")
	check(hh.player_text({"seatNo": 2.0, "userId": 8.0, "startingStack": 5000.0, "endingStack": 4500.0}, 3, 7, false) == "좌석 2  -500", "핸드 기록: 타인·손실")
	check(hh.player_text({"seatNo": 1.0, "userId": 8.0, "startingStack": 5000.0, "endingStack": 5000.0}, 3, 7, false) == "좌석 1  0", "핸드 기록: 0")
	check(hh.player_text({"seatNo": 2.0, "userId": 8.0, "startingStack": 5000.0, "endingStack": 5100.0}, 3, -1, true) == "좌석 2 회원 #8  +100", "핸드 기록: 관리자 회원 번호")
	check(hh.player_text({"seatNo": 3.0, "userId": 7.0, "startingStack": 5000.0, "endingStack": 6200.0}, 3, 7, false, "qauser1") == "좌석 3 (D) qauser1 (나)  +1,200", "핸드 기록: 내 좌석·버튼·닉네임")
	check(hh.player_text({"seatNo": 2.0, "userId": 8.0, "startingStack": 5000.0, "endingStack": 4500.0}, 3, 7, false, "qauser2") == "좌석 2 qauser2  -500", "핸드 기록: 타인·닉네임·손실")
	check(hh.player_text({"seatNo": 2.0, "userId": 8.0, "startingStack": 5000.0, "endingStack": 5100.0}, 3, -1, true, "qauser2") == "좌석 2 qauser2 (회원 #8)  +100", "핸드 기록: 관리자 닉네임")

	# 3b. 블라인드 마커 — 핸드 중에만, 해당 좌석 곁(캡슐 중심에서 가까운 곳)에
	var bl := {"handInProgress": true, "buttonSeatNo": 1.0, "smallBlindSeatNo": 1.0, "bigBlindSeatNo": 2.0}
	table._handle_public(_view(3000, [_seat(1, 7), _seat(2, 8)], bl))
	var near_ok := true
	for pair: Array in [[table.sb_marker, 1], [table.bb_marker, 2]]:
		var bsn: Control = table.seat_nodes[pair[1] - 1]
		near_ok = near_ok and pair[0].visible and (pair[0].position + pair[0].size / 2.0).distance_to(bsn.position + bsn.size / 2.0) < 160.0
	check(near_ok, "SB·BB 마커가 핸드 중 해당 좌석 곁에 보인다")
	check(not Rect2(table.dealer_marker.position, table.dealer_marker.size).intersects(Rect2(table.sb_marker.position, table.sb_marker.size)), "헤즈업 D·SB 마커가 겹치지 않는다")
	var qb: Dictionary = table.qa_state()
	check(qb.sb_seat_no == 1 and qb.bb_seat_no == 2, "qa_state sb_seat_no·bb_seat_no")
	table._handle_public(_view(3001, [_seat(1, 7), _seat(2, 8)], bl.merged({"handInProgress": false}, true)))
	qb = table.qa_state()
	check(not table.sb_marker.visible and not table.bb_marker.visible and qb.sb_seat_no == -1 and qb.bb_seat_no == -1, "핸드 밖에서는 SB·BB 마커 숨김")

	# currentHand → 족보 문구
	table._handle_public(_view(3100, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0, "board": ["As", "Kd", "2c"]}))
	table._handle_private({"seq": 910000.0, "holeCards": ["As", "Ah"], "currentHand": {"category": "PAIR", "tiebreakers": [14.0]}})
	var hr: Label = table.seat_nodes[0].hand_rank
	check(table.my_hand_text == "A 원페어" and table.qa_state().my_hand_text == "A 원페어", "개인 뷰 currentHand 가 문구로 저장된다")
	check(hr.visible and hr.text == "A 원페어" or not table.desktop, "내 패널 HandRank 에 문구(데스크톱)")
	check(table.hand_text_pill.visible == table.compact and (not table.compact or table.hand_text_pill.text == "A 원페어"), "폰 족보 알약은 폰에서만 보인다")
	table._handle_private({"seq": 910001.0, "holeCards": ["As", "Ah"], "currentHand": null})
	check(table.my_hand_text == "" and not hr.visible and not table.hand_text_pill.visible, "currentHand null 이면 문구·라벨 숨김")
	table._handle_private({"seq": 910002.0, "holeCards": ["As", "Ah"], "currentHand": {"category": "FLUSH", "tiebreakers": [14.0, 9.0]}})
	table._drop_private()
	check(table.my_hand_text == "", "개인 뷰를 버리면 문구도 지운다")

	if table.desktop: # 바탕은 행동 패널 아래, 내 큰 카드는 좌석 패널 위(거꾸로면 흐려 보인다)
		check(table.action_bg.get_index() < table.bottom_region.get_index() and table.my_cards_box.get_index() > table.seat_nodes[8].get_index(), "데스크톱 그리기 순서: 행동 바탕 < 행동 패널, 좌석 < 내 카드")

	# 폴드 확인·± 스텝: 공짜 체크 가능이면 첫 누름은 보내지 않고, 두 번째가 보낸다
	table._handle_public(_view(3300, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0, "board": ["As", "Kd", "2c"]}))
	table._handle_private({"seq": 920100.0, "holeCards": ["As", "Ah"], "availableActions": {"canCheck": true, "callAmount": 0.0, "minRaiseTo": 200.0, "maxRaiseTo": 1000.0}})
	table.action_pending = false
	table.fold_button.pressed.emit()
	check(not table.action_pending and table.fold_button.text == "정말 폴드?", "폴드 확인: canCheck 면 첫 누름은 보내지 않고 문구가 바뀐다")
	table.fold_button.pressed.emit()
	check(table.action_pending and table.fold_button.text == "폴드", "폴드 확인: 두 번째 누름은 보낸다")
	table.action_pending = false
	table._handle_private({"seq": 920101.0, "holeCards": ["As", "Ah"], "availableActions": {"canCheck": false, "callAmount": 200.0, "minRaiseTo": 400.0, "maxRaiseTo": 1000.0}})
	table.fold_button.pressed.emit()
	check(table.action_pending, "폴드 확인: canCheck 가 아니면 바로 보낸다")
	table.action_pending = false
	table._update_action_bar()
	table.raise_slider.value = 400
	table.plus_button.pressed.emit()
	check(int(table.raise_slider.value) == 500 and int(table.raise_spin.value) == 500, "+ 버튼은 100 올린다")
	table.minus_button.pressed.emit()
	table.minus_button.pressed.emit()
	table.minus_button.pressed.emit()
	check(int(table.raise_slider.value) == 400, "− 버튼은 최소 레이즈 밑으로 내려가지 않는다")
	table.raise_slider.value = 950
	table.plus_button.pressed.emit()
	table.plus_button.pressed.emit()
	check(int(table.raise_slider.value) == 1000, "+ 버튼은 최대 레이즈를 넘지 않는다")

	# 효과음: 음소거 토글과 내 차례 마지막 5초 비프
	check(not table.settings_popup.visible, "설정 팝업은 처음엔 닫혀 있다")
	table.settings_button.pressed.emit()
	check(table.settings_popup.visible and table.sfx_toggle.button_pressed and table.voice_toggle.button_pressed, "설정 버튼은 팝업을 열고 둘 다 켜져 있다")
	table.sfx_toggle.button_pressed = false
	check(not table.sfx.sfx_on and table.sfx.voice_on, "효과음 토글은 효과음만 끈다")
	table.voice_toggle.button_pressed = false
	check(not table.sfx.voice_on, "딜러 음성 토글은 음성을 끈다")
	var cfg := ConfigFile.new()
	check(cfg.load("user://holdem_settings.cfg") == OK and not bool(cfg.get_value("sound", "sfx_on")) and not bool(cfg.get_value("sound", "voice_on")), "두 설정은 파일에 저장된다")
	var reloaded: Node = table.Sfx.new()
	table.add_child(reloaded)
	check(not reloaded.sfx_on and not reloaded.voice_on, "저장한 설정을 다시 읽는다")
	reloaded.queue_free()
	table.settings_close.pressed.emit()
	check(not table.settings_popup.visible, "닫기 버튼은 팝업을 닫는다")
	table.settings_button.pressed.emit()
	var click := InputEventMouseButton.new()
	click.pressed = true
	table.settings_backdrop.gui_input.emit(click)
	check(not table.settings_popup.visible, "배경을 누르면 팝업이 닫힌다")
	table.sfx.set_sfx_on(true)
	table.sfx.played.clear()
	table.sfx.play("voice_call")
	table.sfx.play("call")
	check(table.sfx.played == ["call"], "음성만 끄면 음성은 안 나고 효과음은 난다")
	table.sfx.set_sfx_on(false)
	table.sfx.set_voice_on(true)
	table.sfx.played.clear()
	table.sfx.play("voice_call")
	table.sfx.play("beep")
	check(table.sfx.played == ["voice_call"], "효과음만 끄면 음성만 난다")
	cfg.clear()
	cfg.set_value("sound", "muted", true)
	cfg.save("user://holdem_settings.cfg")
	var migrated: Node = table.Sfx.new()
	table.add_child(migrated)
	check(not migrated.sfx_on and not migrated.voice_on, "옛 muted=true 는 둘 다 끈다")
	migrated.queue_free()
	cfg.set_value("sound", "muted", false)
	cfg.save("user://holdem_settings.cfg")
	var migrated2: Node = table.Sfx.new()
	table.add_child(migrated2)
	check(migrated2.sfx_on and migrated2.voice_on, "옛 muted=false 는 둘 다 켠다")
	migrated2.queue_free()
	table.sfx.set_sfx_on(true) # 설정 파일을 기본값으로 되돌린다
	table.sfx.set_voice_on(true)
	table.sfx.played.clear()
	table.last_beep_sec = -1
	for left in [6.0, 5.0, 4.6, 4.0, 3.5, 3.0, 2.0, 1.0, 0.5, 0.0]:
		table._beep_tick(left, true)
	check(table.sfx.played == ["beep", "beep", "beep", "beep", "beep"], "내 차례 5..1초에 한 번씩 비프(5·4·3·2·1)")
	table.sfx.played.clear()
	table._beep_tick(3.0, false)
	table._beep_tick(-1.0, true)
	check(table.sfx.played.is_empty(), "남의 차례·타이머 없음은 비프 없음")

	# 내 차례 알림: 시작할 때 한 번만, 관전 중엔 없음
	table._handle_public(_view(4000, [_seat(2, 8)], {"handInProgress": true, "toActSeatNo": 2.0}))
	table.sfx.played.clear()
	table._handle_public(_view(4001, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 2.0}))
	check(not table.sfx.played.has("turn"), "남의 차례에는 내 차례 소리 없음")
	table._handle_public(_view(4002, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0}))
	check(table.sfx.played.count("turn") == 1, "내 차례가 시작되면 소리 한 번")
	table._handle_public(_view(4003, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0, "board": ["As", "Kd", "2c"]}))
	check(table.sfx.played.count("turn") == 1, "같은 차례의 뷰 갱신은 다시 울리지 않음")
	table._handle_public(_view(4004, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 2.0}))
	table._handle_public(_view(4005, [_seat(1, 7), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0}))
	check(table.sfx.played.count("turn") == 2, "차례가 다시 오면 다시 울림")
	table.sfx.played.clear()
	table._handle_public(_view(4006, [_seat(1, 100), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0}))
	table._handle_public(_view(4007, [_seat(1, 100), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 2.0}))
	table._handle_public(_view(4008, [_seat(1, 100), _seat(2, 8)], {"handInProgress": true, "toActSeatNo": 1.0}))
	check(not table.sfx.played.has("turn"), "관전 중에는 내 차례 소리 없음")

	# 빈 자리 클릭: 관전 중이면 참가 팝업, 앉아 있으면 아무 일 없음
	var empty_click := InputEventMouseButton.new()
	empty_click.button_index = MOUSE_BUTTON_LEFT
	empty_click.pressed = true
	table.stomp_connected = true
	table.waiting = false
	table._handle_public(_view(4010, [_seat(2, 8)])) # 나는 관전
	var empty_seat: Control = table.seat_nodes[2]
	check(empty_seat.empty and empty_seat.clickable and empty_seat.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND, "관전 중 빈 자리는 눌러지고 손가락 커서")
	check(not table.seat_nodes[1].clickable, "채워진 자리는 눌리지 않음")
	table.sit_popup.hide()
	empty_seat._gui_input(empty_click)
	check(table.sit_popup.visible, "관전 중 빈 자리 클릭 = 참가 팝업")
	table.sit_popup.hide()
	table.sit_popup_gen += 1 # 진행 중 buy-in 응답은 버린다
	table.waiting = true
	table._update_buttons()
	check(not empty_seat.clickable, "대기열 중에는 빈 자리를 누를 수 없음")
	table.waiting = false
	table._handle_public(_view(4011, [_seat(1, 7), _seat(2, 8)])) # 나는 착석
	var empty_seat2: Control = table.seat_nodes[2]
	check(empty_seat2.empty and not empty_seat2.clickable and empty_seat2.mouse_filter == Control.MOUSE_FILTER_IGNORE, "착석 중 빈 자리는 눌리지 않음")
	empty_seat2._gui_input(empty_click)
	check(not table.sit_popup.visible, "착석 중 빈 자리 클릭은 아무 일 없음")

	get_tree().quit(1 if failures else 0)


func check(cond: bool, label: String) -> void:
	if cond:
		print("ok: ", label)
	else:
		failures += 1
		print("FAIL: ", label)
