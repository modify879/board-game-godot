extends Node
## Self-check for games/holdem/table.gd state logic. Needs autoloads, so it runs as a scene:
## Godot.exe --headless --path . res://games/holdem/test_table.tscn

var failures := 0


func _seat(no: int, user: int, status := "ACTIVE") -> Dictionary:
	return {"seatNo": float(no), "userId": float(user), "stack": 1000.0, "status": status,
		"presence": "CONNECTED", "totalContributed": 0.0}


func _view(seq: int, seats: Array, extra := {}) -> Dictionary:
	var v := {"seq": float(seq), "seats": seats, "board": [], "handInProgress": false,
		"toActSeatNo": null, "buttonSeatNo": 1.0, "street": "FLOP", "result": null,
		"revealedHands": [], "nextHandInMs": null}
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
	table._handle_public(_view(9, [_seat(1, 7), _seat(2, 8)], {"result": result}))
	check(table._payout_for(2) == 500, "payout for seat 2 held by same user")
	check("2번" in table.board_label.text, "board_label mentions 2번: '%s'" % table.board_label.text)
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
	var flop_actions := {"seq": 1.0, "holeCards": [], "availableActions": {"canCheck": true, "callAmount": 0.0, "minRaiseTo": 200.0, "maxRaiseTo": 1000.0}}
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

	# 9. 턴 타이머: turnRemainingMs 로 매 뷰마다 재동기화, null 이면 숨김, 키가 없으면(옛 서버) 30초 어림
	var timer_lbl: Label = table.seat_timer_labels[0]
	var turn_extra := {"handInProgress": true, "toActSeatNo": 1.0, "street": "RIVER"}
	table._handle_public(_view(15, seats, turn_extra.merged({"turnRemainingMs": 31000.0})))
	table._update_turn_timer()
	check(timer_lbl.visible and timer_lbl.text == "31초", "turn timer from turnRemainingMs: '%s'" % timer_lbl.text)
	table._handle_public(_view(16, seats, turn_extra.merged({"turnRemainingMs": 20000.0})))
	table._update_turn_timer()
	check(timer_lbl.visible and timer_lbl.text == "20초", "same-turn view re-syncs timer: '%s'" % timer_lbl.text)
	table._handle_public(_view(17, seats, turn_extra.merged({"turnRemainingMs": null})))
	table._update_turn_timer()
	check(not timer_lbl.visible, "null turnRemainingMs hides timer")
	table._handle_public(_view(18, seats, turn_extra.merged({"toActSeatNo": 2.0}, true)))
	table._handle_public(_view(19, seats, turn_extra))
	table._handle_public(_view(20, seats, turn_extra.merged({"street": "TURN"}, true)))
	table._update_turn_timer()
	check(timer_lbl.visible and timer_lbl.text == "30초", "absent turnRemainingMs falls back to 30s: '%s'" % timer_lbl.text)

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
	table._apply_sit_buy_in(5, {"ok": false, "error": "TABLE_NOT_FOUND"})
	check(table.sit_popup_error.visible and table.sit_popup_ok.disabled, "buy-in GET failure shown")
	table.sit_popup.hide()

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

	get_tree().quit(1 if failures else 0)


func check(cond: bool, label: String) -> void:
	if cond:
		print("ok: ", label)
	else:
		failures += 1
		print("FAIL: ", label)
