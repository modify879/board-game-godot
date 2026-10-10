extends Control
## Holdem table: seats, betting round status, private hole cards.

static var table_id := 0
static var auto_join := false # table_list 의 "참가" 가 true 로, "관전"/me-seat 자동입장이 false 로 넘긴다
static var create_name := "" # table_list 의 "만들기" 가 넘긴다. creating 이 true 면 STOMP 연결 뒤 방을 만든다 — 서버가 만든 사람을 바로 대기열에 넣는다
static var creating := false # table_list 의 "만들기" 가 true 로 넘긴다 — 이름 검사는 table_list 가 한다

const Cards := preload("res://games/holdem/cards.gd")
const Rules := preload("res://games/holdem/rules.gd")

const STATUS_TEXT := {"FOLDED": "폴드", "ALL_IN": "올인"}
const PRESENCE_TEXT := {"DISCONNECTED": "연결 끊김", "SITTING_OUT": "자리 비움"}
const TO_ACT_COLOR := Color(1.0, 0.85, 0.4)
const TURN_SECONDS := 60.0
const CREATE_SEAT_CHECK_SEC := 5.0 # 방 생성 뒤 이 시간 동안 join-queue 이벤트가 없으면 me/seat 로 착석을 확인한다 — DROPPED 는 스냅샷으로 다시 오지 않는다

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
@onready var sit_popup_info: Label = %SitPopupInfo
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
var sit_popup_gen := 0 # 착석 팝업을 열 때마다 올린다 — 늦게 온 지갑 응답을 거른다
var join_event_seen := false # 이 테이블의 join-queue 이벤트(POSITION·SEATED·DROPPED)를 하나라도 받았다 — 방 생성 뒤 착석 확인을 건너뛴다
var queue_position := 0
var got_seated := false # SEATED 가 202 응답보다 먼저 올 수 있다 — 공개 뷰가 오기 전이라도 대기 상태로 되돌리지 않는다
var last_post_blind := false
var retry_pending := false # DROPPED 재시도 대기 중 — 그 1초 동안 참가 버튼을 숨긴다
var retry_notice_shown := false # error_label 에 DROPPED 재시도 안내가 떠 있다 — 착석·대기 뒤 이 안내만 지운다
var dropped_retried := false # TEMPORARILY_UNAVAILABLE 로 대기열에서 빠지면 한 번만 자동으로 다시 요청한다
var rejoin_pending := false # Stomp closed 될 때 대기 중이었다 — 재연결 후 다시 요청해야 한다
var pending_join_queue: Array = [] # 방 생성 응답 전에는 table_id 를 몰라 join-queue 이벤트를 모아 둔다 — SEATED 가 201 보다 먼저 올 수 있다

var my_available_actions = null # SeatPrivateView.availableActions (Dictionary) or null
var action_pending := false

# 서버는 턴 마감 시각을 보내지 않는다 — toActSeatNo 가 바뀐 시점부터 60초로 어림한다.
var hand_counter := 0
var last_hand_in_progress := false
var last_turn_key := ""
var raise_turn_key := "" # 레이즈 슬라이더를 초기화한 턴
var turn_deadline_ticks := -1 # 턴 마감 시각(get_ticks_msec 기준, OS 시계 아님). -1 이면 카운트다운 없음


func _ready() -> void:
	title_label.text = "새 방" if creating else "#%d" % table_id
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
	if table_id != 0:
		Stomp.subscribe("/topic/tables/%d" % table_id)
	Stomp.subscribe("/user/queue/holdem/join-queue")
	Stomp.connect_ws()


func _exit_tree() -> void:
	create_name = "" # 연결 전에 나가면 다음 입장 때 방이 만들어지지 않게
	creating = false
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
	if body.get("type") == "TABLE_CLOSED": # seq 가 없다 — 공개 뷰보다 먼저 분기한다
		_leave_closed_table()
		return
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
			_send_join(last_post_blind, true)
	_sync_private_subscription()
	_update_turn_key()
	if body.has("turnRemainingMs"): # 없으면(옛 서버) _update_turn_key 의 60초 어림을 그대로 쓴다
		var left_ms = body.turnRemainingMs
		turn_deadline_ticks = -1 if left_ms == null else Time.get_ticks_msec() + int(left_ms)
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
	if table_id == 0:
		pending_join_queue.append(body)
		return
	if int(body.tableId) != table_id:
		return
	join_event_seen = true
	match body.type:
		"POSITION":
			queue_position = int(body.position)
			rejoin_pending = false # 서버가 아직 대기열에 두고 있다(재연결 스냅샷) — 다시 요청하면 중복
			_hide_retry_notice()
			_update_status_label()
		"SEATED":
			got_seated = true
			dropped_retried = false # 다음 착석 시도마다 1회 기회
			waiting = false
			rejoin_pending = false
			_hide_retry_notice() # DROPPED 재시도 안내가 착석 뒤에 남지 않게
			_update_status_label()
			_update_buttons()
		"DROPPED":
			if body.errorCode == "TEMPORARILY_UNAVAILABLE" and not dropped_retried:
				dropped_retried = true
				waiting = false # _send_join 은 202 일 때만 waiting 을 세운다 — 재요청이 실패하면 대기 표시가 남지 않게 한다
				error_label.text = "서버가 잠시 바빠 다시 대기열에 등록합니다"
				error_label.show()
				retry_notice_shown = true
				_update_status_label()
				retry_pending = true
				_update_buttons()
				get_tree().create_timer(1.0).timeout.connect(_retry_dropped_join) # await 은 노드가 해제돼도 재개된다 — connect 는 끊긴다
				return
			waiting = false
			_show_error(body.errorCode)
			_update_status_label()
			_update_buttons()


func _hide_retry_notice() -> void:
	if retry_notice_shown:
		retry_notice_shown = false
		error_label.hide()


func _retry_dropped_join() -> void:
	retry_pending = false
	if not _is_seated() and not waiting: # 그새 사용자가 직접 참가했으면 중복 요청하지 않는다
		_send_join(last_post_blind)


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


func _leave_closed_table() -> void:
	get_tree().change_scene_to_file("res://games/holdem/table_list.tscn")


func _show_error(code: String) -> void:
	if code == "TABLE_NOT_FOUND": # 닫힘 알림이 유실됐을 수 있다 — REST 가 이 코드면 닫힘과 똑같이 목록으로 돌아간다
		_leave_closed_table()
		return
	retry_notice_shown = false
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
	if creating:
		var new_name := create_name
		create_name = "" # 재연결 때 두 번 만들지 않게
		creating = false
		_create_table(new_name)


func _create_table(new_name: String) -> void:
	waiting = true
	_update_status_label()
	_update_buttons()
	var queue_before := pending_join_queue.size() # POST 전에 온 이벤트(구독 직후 스냅샷 등)는 이 방 것이 아니다
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables", {"name": new_name})
	if not r.ok and r.status == 0: # 응답이 유실됐어도 방은 만들어졌을 수 있다
		# 서버는 생성 즉시 대기열에 넣고 join-queue 로 알린다 — POST 뒤에 버퍼에 쌓인 이벤트에 tableId 가 있다
		if pending_join_queue.size() > queue_before:
			_enter_created_table(int(pending_join_queue[queue_before].tableId))
			return
		var seat_r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/me/seat")
		if seat_r.status == 200:
			_enter_created_table(int(seat_r.data.tableId))
			return
	if not r.ok:
		preload("res://games/holdem/table_list.gd").pending_error = r.error
		get_tree().change_scene_to_file("res://games/holdem/table_list.tscn")
		return
	_enter_created_table(int(r.data.tableId))


func _enter_created_table(id: int) -> void:
	table_id = id
	title_label.text = "#%d" % table_id
	Stomp.subscribe("/topic/tables/%d" % table_id)
	last_post_blind = false
	dropped_retried = false
	var events := pending_join_queue
	pending_join_queue = []
	for event in events:
		_handle_join_queue(event)
	_update_status_label()
	_update_buttons()
	get_tree().create_timer(CREATE_SEAT_CHECK_SEC).timeout.connect(_check_create_seat.bind(table_id))


func _check_create_seat(id: int) -> void:
	if table_id != id or join_event_seen or _is_seated() or not waiting:
		return
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/me/seat")
	if table_id != id or join_event_seen or _is_seated() or not waiting:
		return # 요청 중에 앉았으면 실패 문구를 띄우지 않는다
	if r.ok and r.status == 200 and r.data is Dictionary and int(r.data.tableId) == id:
		return # 공개 뷰가 곧 착석을 그린다
	# 요청 실패거나 204 거나 다른 테이블에 앉아 있다 — 대기를 풀어 둔다. 실제로 앉아 있었다면 공개 뷰가 곧 좌석을 그린다
	waiting = false
	_show_error(r.error if not r.ok else "CREATE_SEAT_FAILED")
	_update_status_label()
	_update_buttons()


func _on_stomp_closed() -> void:
	stomp_connected = false
	if waiting:
		rejoin_pending = true
		error_label.text = "연결이 끊겨 다시 대기열에 등록합니다"
		error_label.show()
		retry_notice_shown = true # 착석·재등록 뒤 지운다
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
	if waiting and table_id == 0:
		status_label.text = "방을 만드는 중"
		return
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
		bet_label.text = "총 베팅 %d" % contributed
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
		turn_deadline_ticks = Time.get_ticks_msec() + int(TURN_SECONDS * 1000) # 옛 서버용 어림


func _update_turn_timer() -> void:
	var to_act := _to_act_seat_no()
	var hip: bool = public_view.get("handInProgress", false)
	for seat_no in range(1, 10):
		var lbl: Label = seat_timer_labels[seat_no - 1]
		if hip and seat_no == to_act and turn_deadline_ticks >= 0:
			var remaining := int(ceil((turn_deadline_ticks - Time.get_ticks_msec()) / 1000.0))
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
	if r.ok:
		nickname_fetching.erase(user_id) # 실패하면 이 화면에서는 다시 묻지 않는다 — 메시지마다 좌석 수만큼 재요청하지 않게
		nickname_cache[user_id] = r.data.nickname
		_render_seats()


func _update_buttons() -> void:
	var seated := _is_seated()
	stand_button.visible = seated
	stand_button.disabled = public_view.get("handInProgress", false)
	join_button.visible = not seated and not waiting and not retry_pending
	join_button.disabled = not stomp_connected or table_id == 0
	cancel_request_button.visible = waiting
	cancel_request_button.disabled = table_id == 0
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
		var raise_key := "%s:%d" % [last_turn_key, min_v] # 턴+최소값이 바뀔 때만 초기화 — 공개/개인 뷰 도착 순서와 무관하고, 같은 턴 갱신은 사용자 조정을 덮지 않는다
		if raise_turn_key != raise_key or int(raise_slider.value) < min_v or int(raise_slider.value) > max_v:
			raise_turn_key = raise_key
			raise_slider.value = min_v
		raise_spin.value = raise_slider.value
		_update_raise_button_label()
	_set_action_bar_disabled(action_pending)


func _update_raise_button_label() -> void:
	var v := int(raise_slider.value)
	var is_bet: bool = my_available_actions != null and my_available_actions.get("canCheck", false) and public_view.get("street", "") != "PREFLOP"
	raise_button.text = ("올인 %d" % v) if v == int(raise_slider.max_value) else (("베팅 %d" if is_bet else "레이즈 %d") % v)


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
	sit_popup_info.text = ""
	sit_popup_error.hide()
	sit_popup_post_blind.button_pressed = false
	sit_popup_ok.disabled = true
	sit_popup.show()
	sit_popup_gen += 1
	var gen := sit_popup_gen
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet")
	_apply_sit_wallet(gen, r)


## 지갑 응답을 팝업에 반영. 그사이 팝업이 닫히거나 다시 열렸으면 버린다
func _apply_sit_wallet(gen: int, r: Dictionary) -> void:
	if gen != sit_popup_gen or not sit_popup.visible:
		return
	if not r.ok:
		sit_popup_error.text = ErrorText.of(r.error)
		sit_popup_error.show()
		return
	var balance := int(r.data.balance)
	if balance < Rules.BIG_BLIND:
		sit_popup_error.text = ErrorText.of("BUY_IN_OUT_OF_RANGE")
		sit_popup_error.show()
		return
	sit_popup_info.text = "착석하면 지갑 잔액 %s 전부가 칩으로 들어갑니다" % Format.comma(balance)
	sit_popup_ok.disabled = false


func _on_sit_popup_cancel() -> void:
	sit_popup.hide()


func _on_sit_popup_ok() -> void:
	sit_popup_ok.disabled = true
	var post_blind := sit_popup_post_blind.button_pressed
	sit_popup.hide()
	dropped_retried = false
	_send_join(post_blind)


func _send_join(post_blind: bool, rejoin := false) -> void:
	got_seated = false
	last_post_blind = post_blind
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables/%d/seats" % table_id, {"postBlindImmediately": post_blind})
	if r.status == 202:
		_hide_retry_notice() # 재시도 안내가 대기 중에 남지 않게
		if not _is_seated() and not got_seated: # SEATED 나 공개 뷰가 202 보다 먼저 왔을 수 있다
			waiting = true
			queue_position = int(r.data.position)
	elif rejoin and r.error == "ALREADY_SEATED":
		_apply_already_seated()
	elif not r.ok:
		_show_error(r.error)
	_update_status_label()
	_update_buttons()
	_render_seats()


## 재연결 전부터 대기열에 있었다 — 착석은 공개 뷰가 정한다. 그새 착석한 뷰가 왔으면 대기로 되돌리지 않는다
func _apply_already_seated() -> void:
	if not _is_seated():
		waiting = true


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
