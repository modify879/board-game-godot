extends Control
## Holdem table: seats, betting round status, private hole cards.

static var table_id := 0
static var auto_join := false # table_list 의 "참가" 가 true 로, "관전"/me-seat 자동입장이 false 로 넘긴다
static var create_name := "" # table_list 의 "만들기" 가 넘긴다. creating 이 true 면 STOMP 연결 뒤 방을 만든다 — 서버가 만든 사람을 바로 대기열에 넣는다
static var create_buy_in := 0 # table_list 의 "만들기" 가 넘기는 바이인
static var creating := false # table_list 의 "만들기" 가 true 로 넘긴다 — 이름 검사는 table_list 가 한다

const Cards := preload("res://games/holdem/cards.gd")
const Rules := preload("res://games/holdem/rules.gd")

const PRESENCE_TEXT := {"DISCONNECTED": "연결 끊김", "SITTING_OUT": "자리 비움"}
const SeatScene := preload("res://games/holdem/seat.tscn")
const SeatScript := preload("res://games/holdem/seat.gd")
const Marker := preload("res://games/holdem/marker.gd")
const Motion := preload("res://games/holdem/motion.gd") # 연출 오버레이 + 연출 시간 상수
const FELT_COLOR := Color("1B5E3A")
const FELT_RIM_COLOR := Color("0F3D26")
const FELT_RIM := 12
const CARD_ASPECT := 190.0 / 140.0 # 카드 이미지 비율(세로/가로)
const BET_LERP := 0.38 # 베팅 칩 위치: 좌석 → 펠트 중심 사이 비율
const TURN_SECONDS := 30.0 # 서버 턴 제한. infrastructure/timer/TurnTimer.kt:132
const CREATE_SEAT_CHECK_SEC := 5.0 # 방 생성 뒤 이 시간 동안 join-queue 이벤트가 없으면 me/seat 로 착석을 확인한다 — DROPPED 는 스냅샷으로 다시 오지 않는다

@onready var back_button: Button = %BackButton
@onready var title_label: Label = %TitleLabel
@onready var status_label: Label = %StatusLabel
@onready var board_box: HBoxContainer = %Board
@onready var board_label: Label = %BoardLabel
@onready var felt_area: Control = %FeltArea
@onready var felt: Panel = %Felt
@onready var center_box: VBoxContainer = %Center
@onready var pot_row: HBoxContainer = %PotRow
@onready var pot_label: Label = %PotLabel
@onready var bottom_region: MarginContainer = %BottomRegion
@onready var half_pot_button: Button = %HalfPotButton
@onready var pot_button: Button = %PotButton
@onready var all_in_button: Button = %AllInButton
@onready var my_cards_box: HBoxContainer = %MyCards
@onready var error_label: Label = %ErrorLabel
@onready var join_button: Button = %JoinButton
@onready var stand_button: Button = %StandButton
@onready var cancel_leave_button: Button = %CancelLeaveButton
@onready var add_chips_button: Button = %AddChipsButton
@onready var add_chips_box: HBoxContainer = %AddChipsBox
@onready var add_chips_spin: SpinBox = %AddChipsSpin
@onready var add_chips_ok: Button = %AddChipsOk
@onready var add_chips_cancel: Button = %AddChipsCancel
@onready var show_hand_button: Button = %ShowHandButton
@onready var cancel_request_button: Button = %CancelRequestButton
@onready var sit_popup: Control = %SitPopup
@onready var sit_popup_info: Label = %SitPopupInfo
@onready var sit_popup_spin: SpinBox = %SitPopupBuyIn
@onready var sit_popup_post_blind: CheckBox = %PostBlindCheck
@onready var sit_popup_error: Label = %SitPopupError
@onready var sit_popup_ok: Button = %SitPopupOk
@onready var sit_popup_cancel: Button = %SitPopupCancel
@onready var action_bar: VBoxContainer = %ActionBar
@onready var fold_button: Button = %FoldButton
@onready var check_call_button: Button = %CheckCallButton
@onready var raise_box: HBoxContainer = %RaiseBox
@onready var raise_slider: HSlider = %RaiseSlider
@onready var raise_spin: SpinBox = %RaiseSpin
@onready var raise_button: Button = %RaiseButton

var seat_nodes: Array = [] # seat_nodes[seatNo - 1] -> seat.tscn. 위치는 _layout 이 절대 좌표로 정한다
var bet_boxes: Array = [] # bet_boxes[seatNo - 1] -> HBoxContainer(칩 아이콘 + 금액)
var dealer_marker: Control
var felt_style := StyleBoxFlat.new()
var compact := false # 논리 너비 700 미만(세로 폰)이면 좌석·카드를 작게
var street_base := {} # seatNo -> 이 스트리트 시작 때의 totalContributed. 공개 뷰엔 스트리트별 베팅이 없어 차이로 구한다
var street_base_key := ""
var board_card_rects: Array = []
var my_card_rects: Array = []
var public_view: Dictionary = {}
var motion: Control # FeltArea 위 연출 오버레이(motion.gd)
var geo := {} # 마지막 _layout() 결과
var have_view := false # 첫 뷰·재연결 뒤 첫 뷰는 연출 없이 그린다
var my_codes: Array = [] # 지금 MyCards 에 그린 홀카드
var my_codes_ticks := -100000 # my_codes 가 바뀐 시각 — 개인 뷰가 공개 뷰보다 먼저 올 때 딜 연출을 맞춘다
var deal_plan := {} # seatNo -> [첫 장, 둘째 장] 딜 지연(초). 내 좌석은 홀카드가 올 때 쓴다
var deal_plan_ticks := -100000
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
var last_buy_in := 0 # 재시도·재연결 뒤 다시 요청할 때 같은 바이인을 보낸다
var show_denied_hand := -1 # SHOW_NOT_ALLOWED 를 받은 hand_counter — 그 판 동안은 버튼을 다시 띄우지 않는다
var show_pending := false # 패 보여 주기 요청 진행 중
var add_chips_gen := 0 # 칩 추가 입력을 열 때마다 올린다 — 늦게 온 buy-in 응답을 거른다
var add_chips_pending := false # 열기 조회·추가 요청이 진행 중이다
var add_chips_max_stack := 0 # 칩 추가 입력을 열 때 받은 buy-in 응답
var add_chips_wallet := 0
var sit_min := 0 # 착석 팝업이 받은 buy-in 응답 — 확인 때 Rules.buy_in 으로 다시 검사한다
var sit_max := 0
var sit_wallet := 0
var retry_pending := false # DROPPED 재시도 대기 중 — 그 1초 동안 참가 버튼을 숨긴다
var retry_notice_shown := false # error_label 에 DROPPED 재시도 안내가 떠 있다 — 착석·대기 뒤 이 안내만 지운다
var dropped_retried := false # TEMPORARILY_UNAVAILABLE 로 대기열에서 빠지면 한 번만 자동으로 다시 요청한다
var rejoin_pending := false # Stomp closed 될 때 대기 중이었다 — 재연결 후 다시 요청해야 한다
var pending_join_queue: Array = [] # 방 생성 응답 전에는 table_id 를 몰라 join-queue 이벤트를 모아 둔다 — SEATED 가 201 보다 먼저 올 수 있다

var my_available_actions = null # SeatPrivateView.availableActions (Dictionary) or null
var action_pending := false

# 서버는 턴 마감 시각을 보내지 않는다 — toActSeatNo 가 바뀐 시점부터 30초로 어림한다.
var hand_counter := 0
var last_hand_in_progress := false
var last_turn_key := ""
var raise_turn_key := "" # 레이즈 슬라이더를 초기화한 턴
var turn_deadline_ticks := -1 # 턴 마감 시각(get_ticks_msec 기준, OS 시계 아님). -1 이면 카운트다운 없음


func _ready() -> void:
	title_label.text = "새 방" if creating else "#%d" % table_id
	back_button.pressed.connect(_leave_closed_table)
	join_button.pressed.connect(_open_sit_popup)
	stand_button.pressed.connect(_on_stand_pressed)
	cancel_leave_button.pressed.connect(_on_cancel_leave_pressed)
	cancel_request_button.pressed.connect(_on_cancel_request_pressed)
	show_hand_button.pressed.connect(_on_show_hand_pressed)
	add_chips_button.pressed.connect(_on_add_chips_pressed)
	add_chips_ok.pressed.connect(_on_add_chips_ok)
	add_chips_cancel.pressed.connect(func() -> void: add_chips_box.hide())
	sit_popup_ok.pressed.connect(_on_sit_popup_ok)
	sit_popup_cancel.pressed.connect(func() -> void: sit_popup.hide())
	fold_button.pressed.connect(_send_play_action.bind("FOLD"))
	check_call_button.pressed.connect(_on_check_call_pressed)
	raise_button.pressed.connect(_on_raise_pressed)
	raise_slider.value_changed.connect(_on_raise_slider_changed)
	raise_spin.value_changed.connect(_on_raise_spin_changed)
	board_card_rects = board_box.get_children()
	my_card_rects = my_cards_box.get_children()
	half_pot_button.pressed.connect(_apply_preset.bind(0.5))
	pot_button.pressed.connect(_apply_preset.bind(1.0))
	all_in_button.pressed.connect(func() -> void: raise_slider.value = raise_slider.max_value)
	felt.add_theme_stylebox_override("panel", felt_style)
	felt_style.bg_color = FELT_COLOR
	felt_style.border_color = FELT_RIM_COLOR
	felt_style.set_border_width_all(FELT_RIM)
	felt_area.resized.connect(func() -> void:
		motion.kill_real()
		_render_seats())
	bottom_region.resized.connect(_fit_bottom_width)
	_build_seats()
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


func _build_seats() -> void:
	for seat_no in range(1, 10):
		var box := HBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_constant_override("separation", 4)
		var chip := _marker(Marker.Kind.CHIP, Vector2(18, 18))
		box.add_child(chip)
		var amount := Label.new()
		amount.add_theme_font_size_override("font_size", 15)
		amount.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		amount.add_theme_constant_override("outline_size", 4)
		box.add_child(amount)
		box.hide()
		felt_area.add_child(box)
		bet_boxes.append(box)
	dealer_marker = _marker(Marker.Kind.DEALER, Vector2(22, 22))
	dealer_marker.hide()
	felt_area.add_child(dealer_marker)
	for seat_no in range(1, 10):
		var seat_node: Control = SeatScene.instantiate()
		felt_area.add_child(seat_node)
		seat_nodes.append(seat_node)
	motion = Motion.new()
	felt_area.add_child(motion) # 마지막 자식 = 맨 위
	_render_seats()


func _marker(kind: int, min_size: Vector2) -> Control:
	var m := Control.new()
	m.set_script(Marker)
	m.kind = kind
	m.custom_minimum_size = min_size
	m.size = min_size
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return m


func _fit_bottom_width() -> void: # 아래 영역 내용은 최대 640 너비로 가운데
	var side := maxi(16, int((bottom_region.size.x - 640) / 2.0))
	bottom_region.add_theme_constant_override("margin_left", side)
	bottom_region.add_theme_constant_override("margin_right", side)


## 펠트·좌석·보드·내 카드를 절대 좌표로 놓는다. 세로·가로 모두 같은 코드다.
## 좌석은 펠트에 내접한 타원 위(v 번째 = 90° + v×40°, v=0 이 아래 가운데)에 놓는다
func _layout() -> Dictionary:
	var area := felt_area.size
	compact = area.x < 700
	var cap := SeatScript.capsule_size(compact)
	var oc := SeatScript.other_card_size(compact)
	var hc := SeatScript.hero_card_size(compact)
	var m_x := cap.x / 2.0 + 6.0
	var m_top := cap.y / 2.0 + oc.y + 4.0
	var m_bottom := cap.y / 2.0 + 24.0
	var rect := Rect2(m_x, m_top, maxf(area.x - 2.0 * m_x, 100.0), maxf(area.y - m_top - m_bottom, 100.0))
	felt.position = rect.position
	felt.size = rect.size
	felt_style.set_corner_radius_all(int(minf(rect.size.x, rect.size.y) / 2.0))
	var c := rect.get_center()
	var hero_top := rect.end.y - cap.y / 2.0 - 2.0 - hc.y
	# 가운데 묶음(팟·보드·결과 문구): 내 카드 위에 붙이되 펠트 안에 둔다
	# 결과 문구(BoardLabel)는 블록 밖 — 핸드가 끝나면 비는 팟 줄 자리에 겹쳐 그려 보드가 더 커질 수 있다
	var clear := 26.0 if compact else 16.0 # 내 카드와의 간격
	var avail_h := hero_top - clear - (rect.position.y + FELT_RIM + 8.0)
	var card_w := clampf(minf((rect.size.x - 90.0 - 24.0) / 5.0, (avail_h - 36.0) / CARD_ASPECT), 36.0, 72.0)
	var card_h := roundf(card_w * CARD_ASPECT)
	var block_h := 28.0 + 4.0 + card_h
	var block_w := card_w * 5.0 + 24.0
	var block_top := maxf(rect.position.y + FELT_RIM + 8.0, minf(c.y - block_h / 2.0, hero_top - clear - block_h)) # 세로(compact)는 내 베팅 칩 자리를 비워 둔다
	# 보드가 좌우 끝 좌석(캡슐)보다 넓으면 그 좌석 위로 올린다 — 좁은 세로 화면의 9인 테이블
	var side_top := c.y + sin(deg_to_rad(170.0)) * rect.size.y / 2.0 - cap.y / 2.0
	var side_in := cos(deg_to_rad(10.0)) * rect.size.x / 2.0 - cap.x / 2.0
	if block_w / 2.0 > side_in - 4.0:
		block_top = maxf(rect.position.y + FELT_RIM + 8.0, minf(block_top, side_top - 6.0 - block_h))
	for r: TextureRect in board_card_rects:
		r.custom_minimum_size = Vector2(card_w, card_h)
	board_box.custom_minimum_size = Vector2(block_w, card_h)
	center_box.size = Vector2(maxf(block_w, 180.0), block_h)
	center_box.position = Vector2(c.x - center_box.size.x / 2.0, block_top)
	board_label.size = Vector2(center_box.size.x, 28.0)
	board_label.position = center_box.position
	for r: TextureRect in my_card_rects:
		r.custom_minimum_size = hc
	my_cards_box.size = Vector2(2.0 * hc.x + 8.0, hc.y)
	my_cards_box.position = Vector2(c.x - my_cards_box.size.x / 2.0, hero_top)
	return {"center": c, "rx": rect.size.x / 2.0, "ry": rect.size.y / 2.0, "cap": cap, "hc": hc, "hero_top": hero_top}


func _seat_center(seat_no: int, hero: int, g: Dictionary) -> Vector2:
	var v := posmod(seat_no - hero, 9)
	var deg := 90.0 + v * 40.0
	if compact and (v == 1 or v == 8): # 세로: 내 카드 양옆 좌석이 내 카드와 닿지 않게 위쪽 바깥으로 6° 옮긴다
		deg += 6.0 if v == 1 else -6.0
	elif not compact and (v == 2 or v == 7): # 가로: 왼·오른쪽 끝 좌석을 10° 아래로 — 위 좌석의 작은 카드가 닿지 않게
		deg += -10.0 if v == 2 else 10.0
	var a := deg_to_rad(deg)
	return g.center + Vector2(cos(a) * g.rx, sin(a) * g.ry)


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
	var prev := _motion_snapshot()
	public_view = body
	var in_ms = body.get("nextHandInMs")
	next_hand_due_ticks = -1 if in_ms == null else Time.get_ticks_msec() + int(in_ms)
	if _is_seated():
		waiting = false
	if rejoin_pending:
		rejoin_pending = false
		if not _is_seated():
			_send_join(last_post_blind, last_buy_in, true)
	_sync_private_subscription()
	_update_turn_key()
	if not have_view or hand_counter != prev.hand: # 같은 판의 뷰는 도는 실제 노드 연출을 끝까지 둔다(고스트와 겹치지 않게)
		motion.kill_real()
	_track_street_base()
	if body.has("turnRemainingMs"): # 없으면(옛 서버) _update_turn_key 의 30초 어림을 그대로 쓴다
		var left_ms = body.turnRemainingMs
		turn_deadline_ticks = -1 if left_ms == null else Time.get_ticks_msec() + int(left_ms)
	if _to_act_seat_no() != _my_seat_no():
		my_available_actions = null
	_update_status_label()
	_show_cards(board_card_rects, public_view.get("board", []))
	_update_board_label()
	_update_pot()
	_render_seats()
	_update_buttons()
	_update_action_bar()
	if have_view and hand_counter - prev.hand <= 1:
		_play_motion(prev)
	have_view = true


func _handle_private(body: Dictionary) -> void:
	if int(body.seq) < last_private_seq:
		return
	last_private_seq = int(body.seq)
	var hole_cards: Array = body.get("holeCards", [])
	_show_cards(my_card_rects, hole_cards)
	my_cards_box.visible = not hole_cards.is_empty()
	if hole_cards != my_codes:
		my_codes = hole_cards
		my_codes_ticks = Time.get_ticks_msec()
		_deal_my_cards()
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
		_send_join(last_post_blind, last_buy_in)


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
	have_view = false
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
		_create_table(new_name, create_buy_in)


func _create_table(new_name: String, buy_in: int) -> void:
	last_buy_in = buy_in
	waiting = true
	_update_status_label()
	_update_buttons()
	var queue_before := pending_join_queue.size() # POST 전에 온 이벤트(구독 직후 스냅샷 등)는 이 방 것이 아니다
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables", {"name": new_name, "buyIn": buy_in})
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
	if private_subscribed: # 재연결이 이 구독을 착석 확인 전에 재생한다 — 공개 스냅샷으로 다시 구독한다
		_drop_private()
	if waiting:
		rejoin_pending = true
		error_label.text = "연결이 끊겨 다시 대기열에 등록합니다"
		error_label.show()
		retry_notice_shown = true # 착석·재등록 뒤 지운다
	_update_buttons()


# --- motion (보이는 것만. 상태·네트워크·버튼은 건드리지 않는다) ---

## 새 뷰를 반영하기 전의 화면 상태 — 연출이 앞뒤를 비교한다
func _motion_snapshot() -> Dictionary:
	var snap := {"hand": hand_counter, "street": str(public_view.get("street", "")), "board": public_view.get("board", []).size(),
		"hip": public_view.get("handInProgress", false), "result": public_view.get("result"),
		"bets": {}, "status": {}, "boxes": [], "backs": {}}
	for seat in public_view.get("seats", []):
		snap.status[int(seat.seatNo)] = seat.status
		if snap.hip:
			snap.bets[int(seat.seatNo)] = _street_bet(seat)
	for i in 9:
		var box: Control = bet_boxes[i]
		if box.visible:
			snap.boxes.append({"center": box.position + box.size / 2.0, "text": (box.get_child(1) as Label).text})
		var sn: Control = seat_nodes[i]
		if sn.shown_codes == ["back", "back"]:
			snap.backs[i + 1] = [_seat_card_rect(i + 1, 0), _seat_card_rect(i + 1, 1)]
	return snap


func _seat_card_rect(seat_no: int, i: int) -> Rect2:
	var sn: Control = seat_nodes[seat_no - 1]
	var r: Control = sn.card_rects[i]
	return Rect2(sn.position + r.position, r.size)


func _pot_center() -> Vector2:
	return center_box.position + Vector2(center_box.size.x / 2.0, 14.0)


func _chip_ghost(text: String) -> Control:
	var g: HBoxContainer = bet_boxes[0].duplicate()
	(g.get_child(1) as Label).text = text
	g.show()
	g.size = g.get_combined_minimum_size()
	return g


func _play_motion(prev: Dictionary) -> void:
	var hip: bool = public_view.get("handInProgress", false)
	var street := str(public_view.get("street", ""))
	var result = public_view.get("result")
	var same_hand: bool = prev.hand == hand_counter
	var seats: Array = public_view.get("seats", [])
	var pot := _pot_center()
	# 팟으로 쓸어 담기: 스트리트가 바뀌거나 결과가 오면 직전에 보이던 베팅 박스가 팟으로 간다
	if not prev.boxes.is_empty() and ((same_hand and street != prev.street) or (prev.result == null and result != null)):
		for b in prev.boxes:
			motion.fly(_chip_ghost(b.text), b.center, pot, Motion.BET_TO_POT, 0.0, true)
	# 베팅 팝: 같은 스트리트에서 금액이 늘었다
	if same_hand and hip and prev.hip and street == prev.street:
		for seat in seats:
			var n := int(seat.seatNo)
			if _street_bet(seat) > prev.bets.get(n, 0) and bet_boxes[n - 1].visible:
				motion.pop(bet_boxes[n - 1])
	# 보드: 새로 깔린 카드는 뒤집으며 나온다
	if same_hand:
		var board: Array = public_view.get("board", [])
		for i in range(prev.board, mini(board.size(), board_card_rects.size())):
			motion.appear(board_card_rects[i], (i - prev.board) * Motion.FLIP_STAGGER, true)
	# 폴드: 뒷면이던 작은 카드가 중심 쪽으로 조금 날아가며 사라진다
	if same_hand:
		for seat in seats:
			var n := int(seat.seatNo)
			if seat.status == "FOLDED" and prev.status.get(n) != "FOLDED" and prev.backs.has(n):
				for r: Rect2 in prev.backs[n]:
					var c := r.get_center()
					motion.fly(motion.card_ghost("back", r.size), c, c.lerp(geo.center, 0.3), Motion.FOLD_FLY, 0.0, true, Tween.EASE_IN)
	# 승자에게 팟을 밀어 준다(베팅 쓸어 담기가 끝난 뒤)
	if prev.result == null and result != null:
		for payout in result.get("payouts", []):
			var n := int(payout.seatNo)
			if int(payout.amount) <= 0 or not _seat_held_by(n, payout.get("userId")):
				continue
			var sn: Control = seat_nodes[n - 1]
			var land: float = Motion.BET_TO_POT + Motion.PUSH_FLY
			motion.fly(_chip_ghost("+" + Format.comma(int(payout.amount))), pot, sn.position + sn.size / 2.0, Motion.PUSH_FLY, Motion.BET_TO_POT, true, Tween.EASE_IN_OUT, Tween.TRANS_QUAD)
			if _find_seat(n) != null:
				motion.pulse(sn, land)
				motion.appear(sn.payout_label, land, false, Motion.PAYOUT_FADE)
	# 딜: 새 판이면 딜러 다음 좌석부터 시계 방향으로 두 바퀴
	if hip and hand_counter > prev.hand:
		_plan_deal()
		for n in deal_plan:
			if n == _my_seat_no():
				continue
			var sn: Control = seat_nodes[n - 1]
			for i in 2:
				if sn.card_rects[i].visible:
					var r := _seat_card_rect(n, i)
					motion.fly(motion.card_ghost("back", r.size), geo.center, r.get_center(), Motion.DEAL_FLY, deal_plan[n][i])
					motion.appear(sn.card_rects[i], deal_plan[n][i] + Motion.DEAL_FLY)
		if Time.get_ticks_msec() - my_codes_ticks < 1500: # 개인 뷰가 먼저 왔다
			_deal_my_cards()


func _plan_deal() -> void:
	deal_plan = {}
	deal_plan_ticks = Time.get_ticks_msec()
	var dealer := int(public_view.get("buttonSeatNo", 0))
	var order: Array = []
	for seat in public_view.get("seats", []):
		if seat.status == "ACTIVE" or seat.status == "ALL_IN":
			order.append(int(seat.seatNo))
	order.sort_custom(func(a: int, b: int) -> bool: return posmod(a - dealer - 1, 9) < posmod(b - dealer - 1, 9))
	for k in order.size():
		deal_plan[order[k]] = [k * Motion.DEAL_STAGGER, (order.size() + k) * Motion.DEAL_STAGGER]


## 내 홀카드: 가운데에서 뒷면이 날아오고, 닿으면 뒤집힌다. 딜 계획이 있고(공개 뷰) 카드가 막 바뀌었을 때(개인 뷰) 한 번만
func _deal_my_cards() -> void:
	var seat_no := _my_seat_no()
	if not have_view or not my_cards_box.visible or not deal_plan.has(seat_no) or Time.get_ticks_msec() - deal_plan_ticks > 1500:
		return
	var plan: Array = deal_plan[seat_no]
	deal_plan.erase(seat_no)
	var hc: Vector2 = geo.hc
	for i in my_card_rects.size():
		var r: Control = my_card_rects[i]
		if not r.visible:
			continue
		var c: Vector2 = my_cards_box.position + Vector2(i * (hc.x + 8.0) + hc.x / 2.0, hc.y / 2.0)
		motion.fly(motion.card_ghost("back", hc), geo.center, c, Motion.DEAL_FLY, plan[i])
		motion.appear(r, plan[i] + Motion.DEAL_FLY, true)


# --- rendering ---

func _is_seated() -> bool:
	return _find_seat_by_user(Api.user_id) != null


func _find_seat(seat_no: int) -> Variant:
	for seat in public_view.get("seats", []):
		if seat.seatNo == seat_no:
			return seat
	return null


func _seat_held_by(seat_no: int, user_id) -> bool:
	# 결과는 다음 핸드 전까지 남는다 — 그 사이 같은 좌석에 다른 사람이 앉으면 물려받지 못하게 막는다.
	# 좌석이 비었다면 결과 주인이 나간 것(정산 때 나가기 예약 등)이라 결과를 그대로 보인다
	var seat: Variant = _find_seat(seat_no)
	return user_id != null and (seat == null or int(seat.userId) == int(user_id))


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
		status_label.text = Cards.street_text(public_view.get("street", ""))
		return
	if next_hand_due_ticks >= 0:
		var remaining := int(ceil((next_hand_due_ticks - Time.get_ticks_msec()) / 1000.0))
		status_label.text = "다음 판 %d초" % max(remaining, 0)
	else:
		status_label.text = "대기 중 (2명 이상 필요)"


func _show_cards(rects: Array, codes: Array) -> void:
	for i in rects.size():
		var rect: TextureRect = rects[i]
		if i < codes.size():
			rect.texture = load(Cards.texture_path(codes[i]))
			rect.show()
		else:
			rect.hide()


func _update_pot() -> void:
	var pot := int(public_view.get("pot", 0))
	var show_pot: bool = public_view.get("handInProgress", false) and pot > 0
	pot_row.modulate.a = 1.0 if show_pot else 0.0 # 숨겨도 자리는 유지 — 보드가 움직이지 않게
	pot_label.text = "팟 %s" % Format.comma(pot)


func _update_board_label() -> void:
	var result = public_view.get("result")
	var text := ""
	if result != null:
		var wins := []
		for payout in result.get("payouts", []):
			var uid = payout.get("userId")
			if uid == null and _find_seat(int(payout.seatNo)) != null:
				uid = _find_seat(int(payout.seatNo)).userId
			if payout.amount > 0 and uid != null and _seat_held_by(int(payout.seatNo), uid):
				wins.append("%s +%s" % [_nickname_for(int(uid)), Format.comma(int(payout.amount))])
		if not wins.is_empty():
			text = "승리: " + ", ".join(wins)
	board_label.text = text


func _render_seats() -> void:
	if seat_nodes.size() < 9:
		return
	var g := _layout()
	geo = g
	var hero := _my_seat_no()
	if hero == -1:
		hero = 1
	var dealer_seat := -1
	var button_no = public_view.get("buttonSeatNo")
	if button_no != null and _find_seat(int(button_no)) != null:
		dealer_seat = int(button_no)
	dealer_marker.visible = dealer_seat != -1
	for seat_no in range(1, 10):
		var sp := _seat_center(seat_no, hero, g)
		var seat_node: Control = seat_nodes[seat_no - 1]
		seat_node.set_compact(compact)
		seat_node.position = sp - seat_node.size / 2.0
		_render_seat(seat_no, seat_node)
		var to_center: Vector2 = (g.center - sp).normalized()
		var is_hero := seat_no == hero
		if seat_no == dealer_seat:
			var ext := 1.0 / sqrt(pow(to_center.x / (g.cap.x / 2.0), 2) + pow(to_center.y / (g.cap.y / 2.0), 2)) # 캡슐 가장자리까지 거리
			var d: Vector2 = sp + to_center * (ext + 16.0)
			if is_hero:
				d = sp + Vector2(g.hc.x + 26.0, -g.cap.y / 2.0 - 12.0)
			else: # 마커가 이 좌석의 작은 카드를 가리면 캡슐 아래 안쪽 모서리로 옮긴다
				var mr := Rect2(d - dealer_marker.size / 2.0, dealer_marker.size)
				for cr: Control in seat_node.card_rects:
					if cr.visible and Rect2(seat_node.position + cr.position, cr.size).grow(2.0).intersects(mr):
						d = sp + Vector2(signf(to_center.x) * (g.cap.x / 2.0 - 12.0), g.cap.y / 2.0 + 10.0)
						break
			dealer_marker.position = d - dealer_marker.size / 2.0
		var bet_box: HBoxContainer = bet_boxes[seat_no - 1]
		if bet_box.visible:
			bet_box.reset_size()
			var bm := bet_box.get_combined_minimum_size()
			var b: Vector2 = sp.lerp(g.center, BET_LERP)
			var rel := posmod(seat_no - hero, 9)
			if not compact and (rel == 2 or rel == 7): # 아래 옆 좌석의 작은 카드 위로 칩이 걸치지 않게 조금 올린다
				b.y -= 20.0
			# 좌석 캡슐(+칩 박스)과 겹치지 않게 최소한 캡슐 가장자리 밖으로 밀어낸다. 딜러 마커가 같은 쪽이면 그만큼 더
			var clear_d := 1.0 / sqrt(pow(to_center.x / ((g.cap.x + bm.x) / 2.0), 2) + pow(to_center.y / ((g.cap.y + bm.y) / 2.0), 2)) + 8.0
			if sp.distance_to(b) < clear_d:
				b = sp + to_center * clear_d
			if seat_no == dealer_seat and not is_hero: # 딜러 마커와 겹치면 마커 바깥으로 민다
				var msz := dealer_marker.size
				var dpos: Vector2 = dealer_marker.position + msz / 2.0
				if Rect2(b - bm / 2.0, bm).grow(4.0).intersects(Rect2(dpos - msz / 2.0, msz)):
					b = dpos + to_center * (absf(to_center.x) * (bm.x + msz.x) / 2.0 + absf(to_center.y) * (bm.y + msz.y) / 2.0 + 4.0)
			if is_hero: # 내 카드를 가리지 않게: 가로는 카드 왼쪽, 세로는 카드 바로 위
				b = Vector2(g.center.x, g.hero_top - 12.0) if compact else Vector2(b.x - g.hc.x - 56.0, b.y)
			bet_box.position = b - bm / 2.0


func _render_seat(seat_no: int, seat_node: Control) -> void:
	var bet_box: HBoxContainer = bet_boxes[seat_no - 1]
	bet_box.hide()
	var seat: Variant = _find_seat(seat_no)
	if seat == null:
		var left_shown: Variant = _find_shown_hand(seat_no) # 정산 때 일어선 승자가 보여 준 패
		if left_shown != null:
			var left_category = left_shown.get("category")
			seat_node.show_empty(seat_no, left_shown.holeCards, "" if left_category == null else Cards.category_text(left_category))
		else:
			seat_node.show_empty(seat_no)
		return

	var is_me := int(seat.userId) == Api.user_id
	var hand_in_progress: bool = public_view.get("handInProgress", false)
	var cards: Array = []
	var category := ""
	var shown_hand: Variant = _find_shown_hand(seat_no)
	var revealed_hand: Variant = _find_revealed_hand(seat_no)
	if shown_hand != null:
		cards = shown_hand.holeCards
		if shown_hand.get("category") != null: # 프리플랍 종료 등 보드가 3장 미만이면 null
			category = Cards.category_text(shown_hand.category)
	elif revealed_hand != null:
		cards = revealed_hand.holeCards
	elif hand_in_progress and not is_me and (seat.status == "ACTIVE" or seat.status == "ALL_IN"):
		cards = ["back", "back"]
	seat_node.show_player({
		"nickname": _nickname_for(seat.userId),
		"stack": int(seat.stack),
		"is_me": is_me,
		"to_act": _to_act_seat_no() == seat_no,
		"folded": seat.status == "FOLDED",
		"all_in": seat.status == "ALL_IN",
		"presence_text": PRESENCE_TEXT.get(seat.presence, ""),
		"leave_reserved": seat.get("leaveReserved", false),
		"cards": [] if is_me else cards, # 내 카드는 아래 MyCards 가 크게 그린다
		"category": category,
		"payout": _payout_for(seat_no),
	})
	var street_bet := _street_bet(seat)
	if hand_in_progress and street_bet > 0:
		(bet_box.get_child(1) as Label).text = Format.comma(street_bet)
		bet_box.show()


## 이 스트리트에 이 좌석이 건 금액. 공개 뷰엔 totalContributed(핸드 누적)만 있어 스트리트 시작 값과의 차로 구한다
func _street_bet(seat: Dictionary) -> int:
	return maxi(int(seat.totalContributed) - int(street_base.get(int(seat.seatNo), 0)), 0)


func _track_street_base() -> void:
	var key := "%d:%s" % [hand_counter, str(public_view.get("street", ""))]
	if key == street_base_key:
		return
	street_base_key = key
	street_base = {}
	if public_view.get("street", "") != "PREFLOP": # 프리플랍은 블라인드부터 베팅이라 0 에서 센다
		for seat in public_view.get("seats", []):
			street_base[int(seat.seatNo)] = int(seat.totalContributed)


func _current_max_bet() -> int:
	var best := 0
	for seat in public_view.get("seats", []):
		best = maxi(best, _street_bet(seat))
	return best


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
		var left := -1.0
		if hip and seat_no == to_act and turn_deadline_ticks >= 0:
			left = maxf((turn_deadline_ticks - Time.get_ticks_msec()) / 1000.0, 0.0)
		seat_nodes[seat_no - 1].set_timer(left)


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
		_update_board_label()


func _update_buttons() -> void:
	var seated := _is_seated()
	var my_seat: Variant = _find_seat_by_user(Api.user_id)
	# 핸드 중 일어서기는 나가기 예약(서버가 202) — 예약돼 있으면 취소 버튼으로 바꾼다
	var leave_reserved: bool = seated and my_seat != null and my_seat.get("leaveReserved", false)
	stand_button.visible = seated and not leave_reserved
	stand_button.text = "핸드 후 나가기" if public_view.get("handInProgress", false) else "일어서기"
	cancel_leave_button.visible = leave_reserved
	# 칩 추가는 핸드 사이에만, 스택 < 상한일 때만. 상한은 기본 테이블 값 — 정확한 값은 입력을 열 때 buy-in GET 이 준다
	var can_add: bool = my_seat != null and not public_view.get("handInProgress", false) and int(my_seat.stack) < Rules.DEFAULT_MAX_BUY_IN
	show_hand_button.visible = _can_show_hand()
	show_hand_button.disabled = show_pending
	add_chips_button.visible = seated
	add_chips_button.disabled = not can_add or add_chips_pending
	if not can_add:
		add_chips_box.hide() # 판이 시작되거나 일어서면 열려 있던 입력을 닫는다
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
		raise_slider.step = 100 # 서버 칩은 100 단위다 — holdem/domain/model/Chips.kt:10 CHIP_UNIT
		raise_spin.min_value = min_v
		raise_spin.max_value = max_v
		raise_spin.step = 100 # 서버 칩은 100 단위다 — holdem/domain/model/Chips.kt:10 CHIP_UNIT
		var raise_key := "%s:%d" % [last_turn_key, min_v] # 턴+최소값이 바뀔 때만 초기화 — 공개/개인 뷰 도착 순서와 무관하고, 같은 턴 갱신은 사용자 조정을 덮지 않는다
		if raise_turn_key != raise_key or int(raise_slider.value) < min_v or int(raise_slider.value) > max_v:
			raise_turn_key = raise_key
			raise_slider.value = min_v
		raise_spin.value = raise_slider.value
		_update_raise_button_label()
	_set_action_bar_disabled(action_pending)


## ½ 팟·팟: 현재 최고 베팅(좌석별 스트리트 베팅의 최대) + 비율 × (팟 + 콜 금액). 계산은 Rules.preset_raise_to
func _apply_preset(fraction: float) -> void:
	if my_available_actions == null:
		return
	raise_slider.value = Rules.preset_raise_to(fraction, _current_max_bet(), int(public_view.get("pot", 0)),
		int(my_available_actions.get("callAmount", 0)), int(raise_slider.min_value), int(raise_slider.max_value))


func _update_raise_button_label() -> void:
	var v := int(raise_slider.value)
	var is_bet: bool = my_available_actions != null and my_available_actions.get("canCheck", false) and public_view.get("street", "") != "PREFLOP"
	raise_button.text = ("올인 %d" % v) if v == int(raise_slider.max_value) else (("베팅 %d" if is_bet else "레이즈 %d") % v)


func _set_action_bar_disabled(disabled: bool) -> void:
	fold_button.disabled = disabled
	check_call_button.disabled = disabled
	raise_button.disabled = disabled
	raise_slider.editable = not disabled
	half_pot_button.disabled = disabled
	pot_button.disabled = disabled
	all_in_button.disabled = disabled
	raise_spin.editable = not disabled


func _on_raise_slider_changed(value: float) -> void:
	raise_spin.value = value
	_update_raise_button_label()


func _on_raise_spin_changed(value: float) -> void:
	raise_slider.value = value
	_update_raise_button_label()


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

func _open_sit_popup() -> void:
	sit_popup_info.text = ""
	sit_popup_error.hide()
	sit_popup_spin.hide()
	sit_popup_post_blind.button_pressed = false
	sit_popup_ok.disabled = true
	sit_popup.show()
	sit_popup_gen += 1
	var gen := sit_popup_gen
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/tables/%d/buy-in" % table_id)
	_apply_sit_buy_in(gen, r)


## buy-in 응답을 팝업에 반영. 그사이 팝업이 닫히거나 다시 열렸으면 버린다
func _apply_sit_buy_in(gen: int, r: Dictionary) -> void:
	if gen != sit_popup_gen or not sit_popup.visible:
		return
	sit_popup_spin.hide()
	sit_popup_ok.disabled = true
	if not r.ok:
		sit_popup_error.text = ErrorText.of(r.error)
		sit_popup_error.show()
		return
	sit_min = int(r.data.minBuyIn)
	sit_max = int(r.data.maxBuyIn)
	sit_wallet = int(r.data.walletBalance)
	sit_popup_info.text = "바이인 %s ~ %s · 지갑 %s" % [Format.comma(sit_min), Format.comma(sit_max), Format.comma(sit_wallet)]
	var blocked: String = Rules.buy_in_blocked_text(r.data)
	if blocked != "":
		sit_popup_error.text = blocked
		sit_popup_error.show()
		return
	var top := mini(sit_max, sit_wallet / Rules.CHIP_UNIT * Rules.CHIP_UNIT)
	sit_popup_spin.min_value = sit_min
	sit_popup_spin.max_value = top
	sit_popup_spin.step = Rules.CHIP_UNIT
	sit_popup_spin.value = top
	sit_popup_spin.show()
	sit_popup_error.hide()
	sit_popup_ok.disabled = false


func _on_sit_popup_ok() -> void:
	var buy_in := int(sit_popup_spin.value)
	var invalid := Rules.buy_in(buy_in, sit_min, sit_max, sit_wallet)
	if invalid != "":
		sit_popup_error.text = ErrorText.of(invalid)
		sit_popup_error.show()
		return
	sit_popup_ok.disabled = true
	var post_blind := sit_popup_post_blind.button_pressed
	sit_popup.hide()
	dropped_retried = false
	_send_join(post_blind, buy_in)


func _send_join(post_blind: bool, buy_in: int, rejoin := false) -> void:
	got_seated = false
	last_post_blind = post_blind
	last_buy_in = buy_in
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables/%d/seats" % table_id, {"buyIn": buy_in, "postBlindImmediately": post_blind})
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


## 폴드로 이긴 사람만, 다음 판 전에 한 번 보여 줄 수 있다. 폴드 종료 = 결과가 있고 shownHands 가 비었다(쇼다운이면 채워진다 — 내가 이미 보여 줬어도 채워져 조건이 꺼진다)
func _can_show_hand() -> bool:
	var result = public_view.get("result")
	if result == null or show_denied_hand == hand_counter or public_view.get("handInProgress", false) or not result.get("shownHands", []).is_empty():
		return false
	# 좌석이 아니라 userId 로 찾는다 — 나가기 예약이 정산에서 실행돼 자리가 비어도 다음 판 전까지 보여 줄 수 있다
	for payout in result.get("payouts", []):
		if int(payout.userId) == Api.user_id and int(payout.amount) > 0:
			return true
	return false


func _on_show_hand_pressed() -> void:
	show_pending = true
	_update_buttons()
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables/%d/hands/show" % table_id)
	show_pending = false
	if not r.ok:
		_show_error(r.error)
		if r.error == "SHOW_NOT_ALLOWED":
			show_denied_hand = hand_counter
	_update_buttons()


func _on_add_chips_pressed() -> void:
	add_chips_pending = true
	add_chips_button.disabled = true
	add_chips_gen += 1
	var gen := add_chips_gen
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/tables/%d/buy-in" % table_id)
	add_chips_pending = false
	_apply_add_chips_open(gen, r)
	_update_buttons()


## buy-in 응답으로 추가할 수 있는 최대(min(상한 - 스택, 지갑) 을 100 단위 내림)를 정해 입력을 연다. 낡은 응답은 버린다
func _apply_add_chips_open(gen: int, r: Dictionary) -> void:
	if gen != add_chips_gen:
		return
	if not r.ok:
		add_chips_box.hide()
		_show_error(r.error)
		return
	var seat: Variant = _find_seat_by_user(Api.user_id)
	if seat == null or public_view.get("handInProgress", false):
		return
	add_chips_max_stack = int(r.data.maxStack)
	add_chips_wallet = int(r.data.walletBalance)
	var top := mini(add_chips_max_stack - int(seat.stack), add_chips_wallet) / Rules.CHIP_UNIT * Rules.CHIP_UNIT
	if top < Rules.CHIP_UNIT:
		add_chips_box.hide()
		_show_error("CHIP_ADD_OUT_OF_RANGE" if add_chips_max_stack - int(seat.stack) < Rules.CHIP_UNIT else "INSUFFICIENT_BALANCE")
		return
	error_label.hide()
	add_chips_spin.min_value = Rules.CHIP_UNIT
	add_chips_spin.max_value = top
	add_chips_spin.step = Rules.CHIP_UNIT
	add_chips_spin.value = top
	add_chips_box.show()


func _on_add_chips_ok() -> void:
	var seat: Variant = _find_seat_by_user(Api.user_id)
	if seat == null:
		return
	var amount := int(add_chips_spin.value)
	var invalid := Rules.chip_add(amount, int(seat.stack), add_chips_max_stack, add_chips_wallet)
	if invalid != "":
		_show_error(invalid)
		return
	add_chips_pending = true
	add_chips_ok.disabled = true
	_update_buttons()
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/seat/chips", {"amount": amount})
	add_chips_pending = false
	add_chips_ok.disabled = false
	if r.ok:
		add_chips_box.hide() # 새 스택은 서버가 다시 방송하는 공개 뷰로 온다
	else:
		_show_error(r.error)
	_update_buttons()


func _on_stand_pressed() -> void:
	stand_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/seat")
	stand_button.disabled = false
	# 202(나가기 예약)는 로컬 상태를 바꾸지 않는다 — 다시 방송되는 공개 뷰의 leaveReserved 가 화면을 바꾼다
	if not r.ok:
		_show_error(r.error)


func _on_cancel_leave_pressed() -> void:
	cancel_leave_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/seat/leave-reservation")
	cancel_leave_button.disabled = false
	if not r.ok:
		_show_error(r.error)
