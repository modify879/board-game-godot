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

	# 7. ACCESS_DENIED 후 테이블이 연 새 소켓은 재연결 대상이어야 한다(의도적 종료 플래그가 덮이면 안 됨)
	Stomp._handle_packet("ERROR\nerrorCode:ACCESS_DENIED\n\n")
	check(not Stomp._intentional_close, "ACCESS_DENIED 뒤 새 소켓은 재연결 대상")
	Stomp.disconnect_ws()

	get_tree().quit(1 if failures else 0)


func check(cond: bool, label: String) -> void:
	if cond:
		print("ok: ", label)
	else:
		failures += 1
		print("FAIL: ", label)
