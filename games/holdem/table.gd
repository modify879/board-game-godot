extends Control
## Holdem table: seats, betting round status, private hole cards.

static var table_id := 0

const STATUS_TEXT := {"FOLDED": "폴드", "ALL_IN": "올인"}
const PRESENCE_TEXT := {"DISCONNECTED": "연결 끊김", "SITTING_OUT": "자리 비움"}
const TO_ACT_COLOR := Color(1.0, 0.85, 0.4)

@onready var back_button: Button = %BackButton
@onready var title_label: Label = %TitleLabel
@onready var status_label: Label = %StatusLabel
@onready var board_label: Label = %BoardLabel
@onready var seats_grid: GridContainer = %Seats
@onready var my_cards_label: Label = %MyCardsLabel
@onready var error_label: Label = %ErrorLabel
@onready var stand_button: Button = %StandButton
@onready var cancel_request_button: Button = %CancelRequestButton
@onready var sit_popup: Control = %SitPopup
@onready var sit_popup_label: Label = %SitPopupLabel
@onready var sit_popup_spin: SpinBox = %SitPopupSpin
@onready var sit_popup_error: Label = %SitPopupError
@onready var sit_popup_ok: Button = %SitPopupOk
@onready var sit_popup_cancel: Button = %SitPopupCancel

var seat_panels: Array = [] # seat_panels[seatNo - 1] -> PanelContainer
var public_view: Dictionary = {}
var received_first_public := false
var last_public_seq := -1
var last_private_seq := -1
var my_pending_seat := 0
var sitting_seat_no := 0
var private_subscribed := false
var private_sub_id := ""
var nickname_cache := {} # userId -> nickname
var nickname_fetching := {} # userId -> true while request in flight


func _ready() -> void:
	title_label.text = "#%d" % table_id
	back_button.pressed.connect(_on_back_pressed)
	stand_button.pressed.connect(_on_stand_pressed)
	cancel_request_button.pressed.connect(_on_cancel_request_pressed)
	sit_popup_ok.pressed.connect(_on_sit_popup_ok)
	sit_popup_cancel.pressed.connect(_on_sit_popup_cancel)
	_build_seat_panels()
	Stomp.message.connect(_on_stomp_message)
	Stomp.error.connect(_on_stomp_error)
	Stomp.connect_ws()
	Stomp.subscribe("/topic/tables/%d" % table_id)


func _exit_tree() -> void:
	Stomp.message.disconnect(_on_stomp_message)
	Stomp.error.disconnect(_on_stomp_error)
	Stomp.disconnect_ws()


func _process(_delta: float) -> void:
	if received_first_public and not public_view.get("handInProgress", false) and public_view.get("nextHandAt") != null:
		_update_status_label()


func _build_seat_panels() -> void:
	for seat_no in range(1, 10):
		var panel := PanelContainer.new()
		panel.add_child(VBoxContainer.new())
		seats_grid.add_child(panel)
		seat_panels.append(panel)
	_render_seats()


# --- STOMP ---

func _on_stomp_message(destination: String, body: Variant) -> void:
	if destination == "/topic/tables/%d" % table_id:
		_handle_public(body)
	elif destination == "/user/queue/tables/%d" % table_id:
		_handle_private(body)


func _handle_public(body: Dictionary) -> void:
	if int(body.seq) < last_public_seq:
		return
	last_public_seq = int(body.seq)
	received_first_public = true
	public_view = body
	if _is_seated() or (my_pending_seat > 0 and not _is_pending(my_pending_seat)):
		my_pending_seat = 0 # 입장했거나, 입장 처리에서 요청이 떨어져 나갔다
	_sync_private_subscription()
	_update_status_label()
	_update_board_label()
	_render_seats()
	_update_buttons()


func _handle_private(body: Dictionary) -> void:
	if int(body.seq) < last_private_seq:
		return
	last_private_seq = int(body.seq)
	my_cards_label.text = "내 카드: " + " ".join(body.holeCards)
	my_cards_label.show()


func _sync_private_subscription() -> void:
	var seated := _is_seated()
	if seated and not private_subscribed:
		private_sub_id = Stomp.subscribe("/user/queue/tables/%d" % table_id)
		private_subscribed = true
	elif not seated and private_subscribed:
		Stomp.unsubscribe(private_sub_id)
		private_subscribed = false
		last_private_seq = -1
		my_cards_label.hide()


func _on_stomp_error(code: String) -> void:
	error_label.text = ErrorText.of(code)
	error_label.show()
	if code == "ACCESS_DENIED":
		if private_subscribed:
			Stomp.unsubscribe(private_sub_id)
			private_subscribed = false
			last_private_seq = -1
			my_cards_label.hide()
		Stomp.connect_ws()


# --- rendering ---

func _is_seated() -> bool:
	return _find_seat_by_user(Api.user_id) != null


func _find_seat(seat_no: int) -> Variant:
	for seat in public_view.get("seats", []):
		if seat.seatNo == seat_no:
			return seat
	return null


func _find_seat_by_user(user_id: int) -> Variant:
	for seat in public_view.get("seats", []):
		if seat.userId == user_id:
			return seat
	return null


func _is_pending(seat_no: int) -> bool:
	for n in public_view.get("pendingSeatNos", []):
		if int(n) == seat_no: # JSON 숫자는 float 로 온다 — Array.has 로는 int 와 안 맞는다
			return true
	return false


func _update_status_label() -> void:
	if public_view.get("handInProgress", false):
		status_label.text = "%s · 팟 %d" % [str(public_view.get("street", "")), int(public_view.get("pot", 0))]
		return
	var next_hand_at = public_view.get("nextHandAt")
	if next_hand_at != null:
		var remaining := int(ceil(Time.get_unix_time_from_datetime_string(next_hand_at) - Time.get_unix_time_from_system()))
		status_label.text = "다음 판 %d초" % max(remaining, 0)
	else:
		status_label.text = "대기 중 (2명 이상 필요)"


func _update_board_label() -> void:
	var board: Array = public_view.get("board", [])
	var text := "보드: " + (" ".join(board) if not board.is_empty() else "-")
	var result = public_view.get("result")
	if result != null:
		var wins := []
		for payout in result.get("payouts", []):
			if payout.amount > 0:
				wins.append("%d번 +%d" % [payout.seatNo, payout.amount])
		if not wins.is_empty():
			text += " · 승리: " + ", ".join(wins)
	board_label.text = text


func _render_seats() -> void:
	for seat_no in range(1, 10):
		_render_seat_panel(seat_no)


func _render_seat_panel(seat_no: int) -> void:
	var panel: PanelContainer = seat_panels[seat_no - 1]
	var vbox: VBoxContainer = panel.get_child(0)
	for child in vbox.get_children():
		child.queue_free()
	panel.self_modulate = TO_ACT_COLOR if public_view.get("toActSeatNo", -1) == seat_no else Color(1, 1, 1, 1)

	var seat_no_label := Label.new()
	seat_no_label.text = "%d번" % seat_no
	vbox.add_child(seat_no_label)

	var seat: Variant = _find_seat(seat_no)
	if seat == null:
		if _is_pending(seat_no):
			var pending_label := Label.new()
			pending_label.text = "대기 중"
			vbox.add_child(pending_label)
		else:
			var sit_button := Button.new()
			sit_button.text = "앉기"
			sit_button.disabled = not received_first_public or _is_seated() or my_pending_seat > 0
			sit_button.pressed.connect(_on_sit_pressed.bind(seat_no))
			vbox.add_child(sit_button)
		return

	var nickname_label := Label.new()
	var suffix := ""
	if public_view.get("buttonSeatNo", -1) == seat_no:
		suffix += " D"
	if seat.userId == Api.user_id:
		suffix += " (나)"
	nickname_label.text = _nickname_for(seat.userId) + suffix
	vbox.add_child(nickname_label)

	var stack_label := Label.new()
	stack_label.text = "%d칩" % seat.stack
	vbox.add_child(stack_label)

	var status_text: String = STATUS_TEXT.get(seat.status, "")
	if status_text == "":
		status_text = PRESENCE_TEXT.get(seat.presence, "")
	if status_text != "":
		var status_label_node := Label.new()
		status_label_node.text = status_text
		vbox.add_child(status_label_node)


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
	cancel_request_button.visible = my_pending_seat > 0
	back_button.disabled = seated or my_pending_seat > 0
	back_button.tooltip_text = "일어선 뒤 나갈 수 있습니다" if back_button.disabled else ""


# --- actions ---

func _on_sit_pressed(seat_no: int) -> void:
	sitting_seat_no = seat_no
	sit_popup_label.text = "%d번 좌석에 앉기" % seat_no
	sit_popup_error.hide()
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
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables/%d/seats" % table_id, {"seatNo": sitting_seat_no, "buyIn": buy_in})
	sit_popup.hide()
	if r.status == 202:
		my_pending_seat = sitting_seat_no
		_update_buttons()
		_render_seats()
	elif not r.ok:
		error_label.text = ErrorText.of(r.error)
		error_label.show()


func _on_cancel_request_pressed() -> void:
	cancel_request_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/tables/%d/seats/request" % table_id)
	cancel_request_button.disabled = false
	if r.ok:
		my_pending_seat = 0
		_update_buttons()
		_render_seats()
	else:
		error_label.text = ErrorText.of(r.error)
		error_label.show()


func _on_stand_pressed() -> void:
	stand_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/seat")
	stand_button.disabled = false
	if not r.ok:
		error_label.text = ErrorText.of(r.error)
		error_label.show()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://games/holdem/table_list.tscn")
