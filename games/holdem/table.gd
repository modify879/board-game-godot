extends Control
## Holdem table: seats, betting round status, private hole cards.

static var table_id := 0
static var auto_join := false # table_list 의 "참가" 가 true 로, "관전"/me-seat 자동입장이 false 로 넘긴다

const Cards := preload("res://games/holdem/cards.gd")

const STATUS_TEXT := {"FOLDED": "폴드", "ALL_IN": "올인"}
const PRESENCE_TEXT := {"DISCONNECTED": "연결 끊김", "SITTING_OUT": "자리 비움"}
const TO_ACT_COLOR := Color(1.0, 0.85, 0.4)
const TURN_SECONDS := 60.0

@onready var back_button: Button = %BackButton
@onready var title_label: Label = %TitleLabel
@onready var status_label: Label = %StatusLabel
@onready var board_box: HBoxContainer = %Board
@onready var board_label: Label = %BoardLabel
@onready var seats_grid: GridContainer = %Seats
@onready var my_cards_box: HBoxContainer = %MyCards
@onready var error_label: Label = %ErrorLabel
@onready var join_button: Button = %JoinButton
@onready var stand_button: Button = %StandButton
@onready var cancel_request_button: Button = %CancelRequestButton
@onready var sit_popup: Control = %SitPopup
@onready var sit_popup_spin: SpinBox = %SitPopupSpin
@onready var sit_popup_post_blind: CheckBox = %PostBlindCheck
@onready var sit_popup_error: Label = %SitPopupError
@onready var sit_popup_ok: Button = %SitPopupOk
@onready var sit_popup_cancel: Button = %SitPopupCancel
@onready var action_bar: HBoxContainer = %ActionBar
@onready var fold_button: Button = %FoldButton
@onready var check_call_button: Button = %CheckCallButton
@onready var raise_box: HBoxContainer = %RaiseBox
@onready var raise_slider: HSlider = %RaiseSlider
@onready var raise_spin: SpinBox = %RaiseSpin
@onready var raise_button: Button = %RaiseButton

var seat_panels: Array = [] # seat_panels[seatNo - 1] -> PanelContainer
var seat_content_boxes: Array = [] # seat_content_boxes[seatNo - 1] -> VBoxContainer, rebuilt on each render
var seat_timer_labels: Array = [] # seat_timer_labels[seatNo - 1] -> Label, ticked every frame (not rebuilt)
var board_card_rects: Array = []
var my_card_rects: Array = []
var public_view: Dictionary = {}
var last_public_seq := -1
var last_private_seq := -1
var next_hand_due_ticks := -1 # nextHandInMs 를 받은 순간 기준의 시작 시각(get_ticks_msec). -1 이면 카운트다운 없음
var private_subscribed := false
var private_sub_id := ""
var nickname_cache := {} # userId -> nickname
var nickname_fetching := {} # userId -> true while request in flight

var stomp_connected := false
var waiting := false
var queue_position := 0
var got_seated := false # SEATED 가 202 응답보다 먼저 올 수 있다 — 공개 뷰가 오기 전이라도 대기 상태로 되돌리지 않는다
var last_buy_in := 0
var last_post_blind := false
var rejoin_pending := false # Stomp closed 될 때 대기 중이었다 — 재연결 후 다시 요청해야 한다

var my_available_actions = null # SeatPrivateView.availableActions (Dictionary) or null
var action_pending := false

# 서버는 턴 마감 시각을 보내지 않는다 — toActSeatNo 가 바뀐 시점부터 60초로 어림한다.
var hand_counter := 0
var last_hand_in_progress := false
var last_turn_key := ""
var turn_started_at := 0.0


func _ready() -> void:
	title_label.text = "#%d" % table_id
	back_button.pressed.connect(_on_back_pressed)
	join_button.pressed.connect(_on_join_pressed)
	stand_button.pressed.connect(_on_stand_pressed)
	cancel_request_button.pressed.connect(_on_cancel_request_pressed)
	sit_popup_ok.pressed.connect(_on_sit_popup_ok)
	sit_popup_cancel.pressed.connect(_on_sit_popup_cancel)
	fold_button.pressed.connect(_on_fold_pressed)
	check_call_button.pressed.connect(_on_check_call_pressed)
	raise_button.pressed.connect(_on_raise_pressed)
	raise_slider.value_changed.connect(_on_raise_slider_changed)
	raise_spin.value_changed.connect(_on_raise_spin_changed)
	board_card_rects = board_box.get_children()
	my_card_rects = my_cards_box.get_children()
	_build_seat_panels()
	Stomp.message.connect(_on_stomp_message)
	Stomp.error.connect(_on_stomp_error)
	Stomp.connected.connect(_on_stomp_connected)
	Stomp.closed.connect(_on_stomp_closed)
	Stomp.subscribe("/topic/tables/%d" % table_id)
	Stomp.subscribe("/user/queue/holdem/join-queue")
	Stomp.connect_ws()


func _exit_tree() -> void:
	Stomp.message.disconnect(_on_stomp_message)
	Stomp.error.disconnect(_on_stomp_error)
	Stomp.connected.disconnect(_on_stomp_connected)
	Stomp.closed.disconnect(_on_stomp_closed)
	Stomp.disconnect_ws()


func _process(_delta: float) -> void:
	if not waiting and not public_view.get("handInProgress", false) and next_hand_due_ticks >= 0:
		_update_status_label()
	_update_turn_timer()


func _build_seat_panels() -> void:
	for seat_no in range(1, 10):
		var panel := PanelContainer.new()
		var outer := VBoxContainer.new()
		panel.add_child(outer)
		var content := VBoxContainer.new()
		outer.add_child(content)
		var timer_label := Label.new()
		timer_label.hide()
		outer.add_child(timer_label)
		seats_grid.add_child(panel)
		seat_panels.append(panel)
		seat_content_boxes.append(content)
		seat_timer_labels.append(timer_label)
	_render_seats()


# --- STOMP ---

func _on_stomp_message(destination: String, body: Variant) -> void:
	if destination == "/topic/tables/%d" % table_id:
		_handle_public(body)
	elif destination == "/user/queue/tables/%d" % table_id:
		_handle_private(body)
	elif destination == "/user/queue/holdem/join-queue":
		_handle_join_queue(body)


func _handle_public(body: Dictionary) -> void:
	if int(body.seq) < last_public_seq:
		return
	last_public_seq = int(body.seq)
	public_view = body
	var in_ms = body.get("nextHandInMs")
	next_hand_due_ticks = -1 if in_ms == null else Time.get_ticks_msec() + int(in_ms)
	if _is_seated():
		waiting = false
	if rejoin_pending:
		rejoin_pending = false
		if not _is_seated():
			_send_join(last_buy_in, last_post_blind)
	_sync_private_subscription()
	_update_turn_key()
	if _to_act_seat_no() != _my_seat_no():
		my_available_actions = null
	_update_status_label()
	_update_board_cards()
	_update_board_label()
	_render_seats()
	_update_buttons()
	_update_action_bar()


func _handle_private(body: Dictionary) -> void:
	if int(body.seq) < last_private_seq:
		return
	last_private_seq = int(body.seq)
	var hole_cards: Array = body.get("holeCards", [])
	_show_cards(my_card_rects, hole_cards)
	my_cards_box.visible = not hole_cards.is_empty()
	my_available_actions = body.get("availableActions")
	_update_action_bar()


func _handle_join_queue(body: Dictionary) -> void:
	if int(body.tableId) != table_id:
		return
	match body.type:
		"POSITION":
			queue_position = int(body.position)
			_update_status_label()
		"SEATED":
			got_seated = true
			waiting = false
			_update_status_label()
			_update_buttons()
		"DROPPED":
			waiting = false
			_show_error(body.errorCode)
			_update_status_label()
			_update_buttons()


func _sync_private_subscription() -> void:
	var seated := _is_seated()
	if seated and not private_subscribed:
		private_sub_id = Stomp.subscribe("/user/queue/tables/%d" % table_id)
		private_subscribed = true
	elif not seated and private_subscribed:
		_drop_private()


func _drop_private() -> void:
	Stomp.unsubscribe(private_sub_id)
	private_subscribed = false
	last_private_seq = -1
	my_cards_box.hide()
	my_available_actions = null


func _show_error(code: String) -> void:
	error_label.text = ErrorText.of(code)
	error_label.show()


func _on_stomp_error(code: String) -> void:
	_show_error(code)
	if code == "ACCESS_DENIED":
		if private_subscribed:
			_drop_private()
		Stomp.connect_ws()


func _on_stomp_connected() -> void:
	stomp_connected = true
	last_public_seq = -1
	last_private_seq = -1
	_update_buttons()
	if auto_join and not waiting and not _is_seated():
		auto_join = false
		_open_sit_popup()


func _on_stomp_closed() -> void:
	stomp_connected = false
	if waiting:
		rejoin_pending = true
		error_label.text = "연결이 끊겨 다시 대기열에 등록합니다"
		error_label.show()
	_update_buttons()


# --- rendering ---

func _is_seated() -> bool:
	return _find_seat_by_user(Api.user_id) != null


func _find_seat(seat_no: int) -> Variant:
	for seat in public_view.get("seats", []):
		if seat.seatNo == seat_no:
			return seat
	return null


func _seat_held_by(seat_no: int, user_id) -> bool:
	# 결과는 다음 핸드 전까지 남는다 — 그 사이 같은 좌석에 다른 사람이 앉을 수 있다
	var seat: Variant = _find_seat(seat_no)
	return seat != null and user_id != null and int(seat.userId) == int(user_id)


func _find_seat_by_user(user_id: int) -> Variant:
	for seat in public_view.get("seats", []):
		if seat.userId == user_id:
			return seat
	return null


func _my_seat_no() -> int:
	var seat: Variant = _find_seat_by_user(Api.user_id)
	return int(seat.seatNo) if seat != null else -1


func _to_act_seat_no() -> int:
	# 아무도 차례가 아니면 서버가 null 을 보낸다 — get() 기본값은 키가 없을 때만 쓰이고, int(null) 은 오류다
	var to_act = public_view.get("toActSeatNo")
	return -1 if to_act == null else int(to_act)


func _find_shown_hand(seat_no: int) -> Variant:
	var result = public_view.get("result")
	if result == null:
		return null
	for shown in result.get("shownHands", []):
		if int(shown.seatNo) == seat_no and _seat_held_by(seat_no, shown.get("userId")):
			return shown
	return null


func _find_revealed_hand(seat_no: int) -> Variant:
	for revealed in public_view.get("revealedHands", []):
		if int(revealed.seatNo) == seat_no:
			return revealed
	return null


func _payout_for(seat_no: int) -> int:
	var result = public_view.get("result")
	if result == null:
		return 0
	for payout in result.get("payouts", []):
		if int(payout.seatNo) == seat_no and _seat_held_by(seat_no, payout.get("userId")):
			return int(payout.amount)
	return 0


func _update_status_label() -> void:
	if waiting:
		status_label.text = "대기 순번 %d" % queue_position
		return
	if public_view.get("handInProgress", false):
		status_label.text = "%s · 팟 %d" % [Cards.street_text(public_view.get("street", "")), int(public_view.get("pot", 0))]
		return
	if next_hand_due_ticks >= 0:
		var remaining := int(ceil((next_hand_due_ticks - Time.get_ticks_msec()) / 1000.0))
		status_label.text = "다음 판 %d초" % max(remaining, 0)
	else:
		status_label.text = "대기 중 (2명 이상 필요)"


func _update_board_cards() -> void:
	var board: Array = public_view.get("board", [])
	_show_cards(board_card_rects, board)


func _show_cards(rects: Array, codes: Array) -> void:
	for i in rects.size():
		var rect: TextureRect = rects[i]
		if i < codes.size():
			rect.texture = load(Cards.texture_path(codes[i]))
			rect.show()
		else:
			rect.hide()


func _update_board_label() -> void:
	var result = public_view.get("result")
	var text := ""
	if result != null:
		var wins := []
		for payout in result.get("payouts", []):
			if payout.amount > 0 and _seat_held_by(int(payout.seatNo), payout.get("userId")):
				wins.append("%d번 +%d" % [int(payout.seatNo), int(payout.amount)])
		if not wins.is_empty():
			text = "승리: " + ", ".join(wins)
	board_label.text = text


func _render_seats() -> void:
	for seat_no in range(1, 10):
		_render_seat_panel(seat_no)


func _add_card_row(vbox: VBoxContainer, codes: Array) -> void:
	var row := HBoxContainer.new()
	for code in codes:
		var rect := TextureRect.new()
		rect.custom_minimum_size = Vector2(42, 57)
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.texture = load(Cards.texture_path(code))
		row.add_child(rect)
	vbox.add_child(row)


func _render_seat_panel(seat_no: int) -> void:
	var panel: PanelContainer = seat_panels[seat_no - 1]
	var vbox: VBoxContainer = seat_content_boxes[seat_no - 1]
	for child in vbox.get_children():
		child.queue_free()
	panel.self_modulate = TO_ACT_COLOR if _to_act_seat_no() == seat_no else Color(1, 1, 1, 1)

	var seat_no_label := Label.new()
	seat_no_label.text = "%d번" % seat_no
	vbox.add_child(seat_no_label)

	var seat: Variant = _find_seat(seat_no)
	if seat == null:
		var empty_label := Label.new()
		empty_label.text = "빈 자리"
		vbox.add_child(empty_label)
		return

	var nickname_label := Label.new()
	var suffix := ""
	if public_view.get("buttonSeatNo", -1) == seat_no:
		suffix += " D"
	var is_me := int(seat.userId) == Api.user_id
	if is_me:
		suffix += " (나)"
	nickname_label.text = _nickname_for(seat.userId) + suffix
	vbox.add_child(nickname_label)

	var stack_label := Label.new()
	stack_label.text = "%d칩" % int(seat.stack)
	vbox.add_child(stack_label)

	var status_text: String = STATUS_TEXT.get(seat.status, "")
	if status_text == "":
		status_text = PRESENCE_TEXT.get(seat.presence, "")
	if status_text != "":
		var status_label_node := Label.new()
		status_label_node.text = status_text
		vbox.add_child(status_label_node)

	var hand_in_progress: bool = public_view.get("handInProgress", false)
	var shown_hand: Variant = _find_shown_hand(seat_no)
	var revealed_hand: Variant = _find_revealed_hand(seat_no)
	if shown_hand != null:
		_add_card_row(vbox, shown_hand.holeCards)
		var category_label := Label.new()
		category_label.text = Cards.category_text(shown_hand.category)
		vbox.add_child(category_label)
	elif revealed_hand != null:
		_add_card_row(vbox, revealed_hand.holeCards)
	elif hand_in_progress and not is_me and (seat.status == "ACTIVE" or seat.status == "ALL_IN"):
		_add_card_row(vbox, ["back", "back"])

	var contributed := int(seat.totalContributed)
	if hand_in_progress and contributed > 0:
		var bet_label := Label.new()
		bet_label.text = "베팅 %d" % contributed
		vbox.add_child(bet_label)

	var payout := _payout_for(seat_no)
	if payout > 0:
		var payout_label := Label.new()
		payout_label.text = "+%d" % payout
		vbox.add_child(payout_label)


func _update_turn_key() -> void:
	var hip: bool = public_view.get("handInProgress", false)
	if hip and not last_hand_in_progress:
		hand_counter += 1
	last_hand_in_progress = hip
	var to_act := _to_act_seat_no()
	var turn_key := "%d:%s:%d" % [hand_counter, str(public_view.get("street", "")), to_act]
	if turn_key != last_turn_key:
		last_turn_key = turn_key
		turn_started_at = Time.get_unix_time_from_system()


func _update_turn_timer() -> void:
	var to_act := _to_act_seat_no()
	var hip: bool = public_view.get("handInProgress", false)
	for seat_no in range(1, 10):
		var lbl: Label = seat_timer_labels[seat_no - 1]
		if hip and seat_no == to_act and turn_started_at > 0.0:
			var remaining := int(ceil(TURN_SECONDS - (Time.get_unix_time_from_system() - turn_started_at)))
			lbl.text = "%d초" % max(remaining, 0)
			lbl.show()
		else:
			lbl.hide()


func _nickname_for(user_id: int) -> String:
	if nickname_cache.has(user_id):
		return nickname_cache[user_id]
	if not nickname_fetching.has(user_id):
		nickname_fetching[user_id] = true
		_fetch_nickname(user_id)
	return "…"


func _fetch_nickname(user_id: int) -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/users/%d" % user_id)
	nickname_fetching.erase(user_id)
	if r.ok:
		nickname_cache[user_id] = r.data.nickname
		_render_seats()


func _update_buttons() -> void:
	var seated := _is_seated()
	stand_button.visible = seated
	stand_button.disabled = public_view.get("handInProgress", false)
	join_button.visible = not seated and not waiting
	join_button.disabled = not stomp_connected
	cancel_request_button.visible = waiting
	back_button.disabled = seated or waiting
	back_button.tooltip_text = "일어선 뒤 나갈 수 있습니다" if back_button.disabled else ""


# --- action bar ---

func _update_action_bar() -> void:
	var seat_no := _my_seat_no()
	var to_act := _to_act_seat_no()
	var show_bar: bool = my_available_actions != null and seat_no != -1 and to_act == seat_no and public_view.get("handInProgress", false)
	action_bar.visible = show_bar
	if not show_bar:
		return
	var actions: Dictionary = my_available_actions
	var can_check: bool = actions.get("canCheck", false)
	check_call_button.text = "체크" if can_check else "콜 %d" % int(actions.get("callAmount", 0))
	var min_raise = actions.get("minRaiseTo")
	var raise_allowed := min_raise != null
	raise_box.visible = raise_allowed
	if raise_allowed:
		var min_v := int(min_raise)
		var max_v := int(actions.get("maxRaiseTo"))
		raise_slider.min_value = min_v
		raise_slider.max_value = max_v
		raise_slider.step = 100
		raise_spin.min_value = min_v
		raise_spin.max_value = max_v
		raise_spin.step = 100
		if int(raise_slider.value) < min_v or int(raise_slider.value) > max_v:
			raise_slider.value = min_v
		raise_spin.value = raise_slider.value
		_update_raise_button_label()
	_set_action_bar_disabled(action_pending)


func _update_raise_button_label() -> void:
	var v := int(raise_slider.value)
	raise_button.text = ("올인 %d" % v) if v == int(raise_slider.max_value) else ("레이즈 %d" % v)


func _set_action_bar_disabled(disabled: bool) -> void:
	fold_button.disabled = disabled
	check_call_button.disabled = disabled
	raise_button.disabled = disabled
	raise_slider.editable = not disabled
	raise_spin.editable = not disabled


func _on_raise_slider_changed(value: float) -> void:
	raise_spin.value = value
	_update_raise_button_label()


func _on_raise_spin_changed(value: float) -> void:
	raise_slider.value = value
	_update_raise_button_label()


func _on_fold_pressed() -> void:
	_send_play_action("FOLD")


func _on_check_call_pressed() -> void:
	if my_available_actions != null and my_available_actions.get("canCheck", false):
		_send_play_action("CHECK")
	else:
		_send_play_action("CALL")


func _on_raise_pressed() -> void:
	_send_play_action("RAISE_TO", int(raise_slider.value))


func _send_play_action(action: String, raise_to_amount = null) -> void:
	action_pending = true
	_set_action_bar_disabled(true)
	var body := {"action": action}
	if raise_to_amount != null:
		body["raiseToAmount"] = raise_to_amount
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables/%d/hands/actions" % table_id, body)
	action_pending = false
	if not r.ok:
		_show_error(r.error)
	_update_action_bar()


# --- seat actions ---

func _on_join_pressed() -> void:
	_open_sit_popup()


func _open_sit_popup() -> void:
	sit_popup_error.hide()
	sit_popup_post_blind.button_pressed = false
	sit_popup_ok.disabled = true
	sit_popup.show()
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet")
	if not r.ok:
		sit_popup_error.text = ErrorText.of(r.error)
		sit_popup_error.show()
		return
	var balance: int = r.data.balance
	if balance < 200:
		sit_popup_error.text = "잔액이 부족합니다"
		sit_popup_error.show()
		return
	var max_buy_in: int = int(balance / 100) * 100
	sit_popup_spin.min_value = 200
	sit_popup_spin.step = 100
	sit_popup_spin.max_value = max_buy_in
	sit_popup_spin.value = min(max_buy_in, 20000)
	sit_popup_ok.disabled = false


func _on_sit_popup_cancel() -> void:
	sit_popup.hide()


func _on_sit_popup_ok() -> void:
	sit_popup_ok.disabled = true
	var buy_in := int(sit_popup_spin.value)
	var post_blind := sit_popup_post_blind.button_pressed
	sit_popup.hide()
	_send_join(buy_in, post_blind)


func _send_join(buy_in: int, post_blind: bool) -> void:
	got_seated = false
	last_buy_in = buy_in
	last_post_blind = post_blind
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables/%d/seats" % table_id, {"buyIn": buy_in, "postBlindImmediately": post_blind})
	if r.status == 202:
		if not _is_seated() and not got_seated: # SEATED 나 공개 뷰가 202 보다 먼저 왔을 수 있다
			waiting = true
			queue_position = int(r.data.position)
	elif not r.ok:
		_show_error(r.error)
	_update_status_label()
	_update_buttons()
	_render_seats()


func _on_cancel_request_pressed() -> void:
	cancel_request_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/tables/%d/seats/request" % table_id)
	cancel_request_button.disabled = false
	if r.ok or r.error == "JOIN_REQUEST_NOT_FOUND":
		waiting = false # 착석 여부는 공개 뷰가 결정한다
		_update_buttons()
		_render_seats()
	else:
		_show_error(r.error)


func _on_stand_pressed() -> void:
	stand_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/seat")
	stand_button.disabled = false
	if not r.ok:
		_show_error(r.error)


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://games/holdem/table_list.tscn")
