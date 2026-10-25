extends Control
## Holdem table: seats, betting round status, private hole cards.

static var table_id := 0
static var auto_join := false # table_list 의 입장 선택 패널이 "게임 참가" 에서 true 로, "관전"/me-seat 자동입장이 false 로 넘긴다
static var auto_join_buy_in := 0 # 0 보다 크면 착석 팝업 없이 이 바이인으로 바로 참가한다(입장 선택 패널이 이미 검사했다)
static var auto_join_post_blind := false
static var create_name := "" # table_list 의 "만들기" 가 넘긴다. creating 이 true 면 STOMP 연결 뒤 방을 만든다 — 서버가 만든 사람을 바로 대기열에 넣는다
static var create_buy_in := 0 # table_list 의 "만들기" 가 넘기는 바이인
static var creating := false # table_list 의 "만들기" 가 true 로 넘긴다 — 이름 검사는 table_list 가 한다

const Cards := preload("res://games/holdem/cards.gd")
const Rules := preload("res://games/holdem/rules.gd")

const PRESENCE_TEXT := {"DISCONNECTED": "연결 끊김", "SITTING_OUT": "자리 비움"}
const SeatScene := preload("res://games/holdem/seat.tscn")
const SeatScript := preload("res://games/holdem/seat.gd")
const Marker := preload("res://games/holdem/marker.gd")
const PublicView := preload("res://games/holdem/public_view.gd")
const Motion := preload("res://games/holdem/motion.gd") # 연출 오버레이 + 연출 시간 상수
const FELT_COLOR := Color("1B5E3A")
const FELT_RIM_COLOR := Color("0F3D26")
const FELT_RIM := 12
const CARD_ASPECT := 190.0 / 140.0 # 카드 이미지 비율(세로/가로)
const BET_GAP := 8.0 # 베팅 칩과 자기 좌석 캡슐 사이 간격
const BET_ANGLES := [0.0, 35.0, -35.0, 70.0, -70.0, 105.0, -105.0, 140.0, -140.0, 180.0] # 기본(펠트 중심 쪽)이 막히면 캡슐 둘레를 따라 돌려 보는 각도
const RESUME_SEAT_CHECK_SEC := 2.0 # 탭 복귀 소켓 교체 뒤 이 시간 동안 POSITION·SEATED 스냅샷이 없으면 me/seat 로 확인한다
# 데스크톱(가로) 배치는 1280x672(FeltArea) 설계 좌표에서 정하고 k = min(w/1280, h/672) 배로 키운다.
# 같은 중심(D_CENTER)의 타원 두 겹: 펠트(스타디움) ⊂ 바깥(좌석 패널 중심). 베팅 더미는 자기 패널 곁(펠트 쪽). D/SB/BB 마커는 자기 패널의 펠트 쪽 모서리에 붙는다
# 베팅은 좌석 패널 중심에서 펠트 중심으로 그은 선 위, 패널 가장자리 바로 안쪽에 놓는다 — 그래서 한 바퀴 타원 띠를 이룬다
const D_W := 1280.0
const D_H := 672.0
const D_CENTER := Vector2(640, 321)
const D_FELT_R := Vector2(446, 235) # 펠트 반지름(가로:세로 ≈ 1.9:1). 모서리 반지름 = 세로 반지름이라 양 끝이 반원
const D_OUTER := Vector2(479.4, 276) # 좌석 패널 중심이 놓이는 타원
## 좌석 패널 중심의 매개 각도(°, 아래 = 90, 시계 방향). v = posmod(seatNo - 내 좌석, 9): 0 내 자리(아래 가운데) → 왼쪽 아래·왼쪽·위 4곳·오른쪽·오른쪽 아래
## 내 자리 오른쪽엔 행동 패널(D_ACTION)이 있어 오른쪽 아래(v8)는 23°(행동 패널 위쪽 바깥)로 올렸다. 위 네 곳은 패널 폭(220)이 겹치지 않게 v4·v5 는 가운데에서 ±14.3° 이상, v3 은 v4 와 닿지 않게 벌렸다. 설계는 scratchpad 의 탐색으로 정했다
const D_ANGLES := [90.0, 155.0, 189.7, 221.0, 255.7, 284.3, 318.5, 349.0, 383.0]
const D_BET_H := 56.0 # 베팅 칸 대략 높이(더미 + 금액). 패널 곁 자리 계산용
const BET_OUT := 5.0 # 베팅 칸과 자기 패널 가장자리 사이 틈
const D_BET_W := 64.0 # 베팅 칸 최소 폭(기둥·금액이 더 넓으면 그만큼 넓어진다)
const D_MARKER := 26.0 # D·SB·BB 칩(모두 같은 크기)
const D_BOARD_CARD := Vector2(64, 88)
const D_BOARD_TOP := 275.0 # 보드 윗변(안쪽 타원 띠 안, 펠트 중심보다 조금 아래)
const D_TOTAL_TOP := 371.0 # Total 상자 윗변(보드 아래)
const D_ACTION := Rect2(836, 476, 374, 196) # 행동 패널(내 패널 오른쪽)
const D_BAR := Rect2(16, 534, 394, 130) # 참가·일어서기 등 버튼 줄(내 패널 왼쪽 아래)
const MARKER_TEXTURES := [preload("res://games/holdem/assets/chips/chip_dealer.png"), preload("res://games/holdem/assets/chips/chip_smallBlind.png"), preload("res://games/holdem/assets/chips/chip_bigBlind.png")]
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
@onready var leave_room_button: Button = %LeaveRoomButton
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
@onready var vbox: VBoxContainer = $VBoxContainer
@onready var top_bar: MarginContainer = $VBoxContainer/TopBar
@onready var bottom_box: VBoxContainer = $VBoxContainer/BottomRegion/Bottom
@onready var bottom_bar: HFlowContainer = $VBoxContainer/BottomRegion/Bottom/BottomBar
@onready var info_box: PanelContainer = %InfoBox
@onready var info_label: Label = %InfoLabel
@onready var total_box: PanelContainer = %TotalBox
@onready var total_label: Label = %TotalLabel
@onready var call_key: Label = %CallKey
@onready var call_label: Label = %CallLabel
@onready var call_spacer: Control = %CallSpacer

var seat_nodes: Array = [] # seat_nodes[seatNo - 1] -> seat.tscn. 위치는 _layout 이 절대 좌표로 정한다
var bet_boxes: Array = [] # bet_boxes[seatNo - 1] -> BoxContainer(폰 가로·데스크톱 세로)(칩 아이콘 + 금액)
var dealer_marker: Control
var sb_marker: Control
var bb_marker: Control
var felt_style := StyleBoxFlat.new()
var compact := false # 논리 너비 700 미만(세로 폰)이면 좌석·카드를 작게
var desktop := false # 데스크톱 배치가 적용돼 있다(_apply_mode). compact 의 반대 — 노드를 옮겨 둔 상태
var k := 1.0 # 데스크톱 배율
var preset_row: HBoxContainer # 데스크톱 행동 패널의 ½팟·팟·올인 줄(폰에서는 RaiseBox 안)
var action_bg: Panel # 데스크톱 행동 패널 바탕
var street_base := {} # seatNo -> 이 스트리트 시작 때의 totalContributed. 공개 뷰엔 스트리트별 베팅이 없어 차이로 구한다
var street_base_key := ""
var board_card_rects: Array = []
var my_card_rects: Array = []
var public_view: Dictionary = {}
var motion: Control # FeltArea 위 연출 오버레이(motion.gd)
var banner_title: Label # 결과 배너 큰 글자(작은 줄은 BoardLabel)
var banner_tween: Tween
var banner_bg: Panel # 결과 배너 글자 뒤 반투명 어두운 판
var geo := {} # 마지막 _layout() 결과
var have_view := false # 첫 뷰·재연결 뒤 첫 뷰는 연출 없이 그린다
var my_hand_text := "" # 개인 뷰 currentHand 의 화면 문구("K 원페어"). 없으면 ""
var hand_text_pill: Label # 폰: 내 큰 카드 위 족보 알약(데스크톱은 내 패널의 HandRank)
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
var resume_event_seen := false # 탭 복귀 뒤 join-queue 이벤트를 받았다 — 서버가 아직 대기열에 두고 있다는 뜻
var leave_room_after_stand := false # 핸드 후 방 나가기 의도. 개인 뷰의 leaveReservation 이 오면 그것을 따라 재접속해도 복원되고, 핸드 비참가자는 개인 뷰가 없어 이 메모리 값이 전부다 — 재접속하면 사라져 관전자로 남는다. 일어선 뒤엔 개인 뷰가 안 오므로 마지막 값으로 목록행을 정한다
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
var turn_total_ms := 0 # 이번 턴 타이머 전체 길이(서버 turnTimeoutMs). 0 이면 막대를 숨긴다
var turn_deadline_ticks := -1 # 턴 마감 시각(get_ticks_msec 기준, OS 시계 아님). -1 이면 카운트다운 없음


func _ready() -> void:
	title_label.text = "새 방" if creating else "#%d" % table_id
	back_button.pressed.connect(_leave_closed_table)
	join_button.pressed.connect(_open_sit_popup)
	stand_button.pressed.connect(_on_stand_pressed)
	leave_room_button.pressed.connect(_on_stand_pressed.bind(true))
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
	felt_style.corner_detail = 32  # 큰 모서리가 각져 보이지 않게
	felt_area.resized.connect(func() -> void:
		motion.kill_real()
		_render_seats())
	bottom_region.resized.connect(_fit_bottom_width)
	preset_row = HBoxContainer.new()
	preset_row.name = "PresetRow"
	preset_row.add_theme_constant_override("separation", 8)
	preset_row.hide()
	action_bar.add_child(preset_row)
	action_bar.move_child(preset_row, 0)
	raise_box.visibility_changed.connect(_sync_preset_row)
	info_label.text = "SB %s / BB %s" % [Format.comma(Rules.BIG_BLIND / 2), Format.comma(Rules.BIG_BLIND)]
	_build_seats()
	Stomp.message.connect(_on_stomp_message)
	Stomp.error.connect(_on_stomp_error)
	Stomp.connected.connect(_on_stomp_connected)
	Stomp.closed.connect(_on_stomp_closed)
	Stomp.resumed.connect(_on_stomp_resumed)
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
	Stomp.resumed.disconnect(_on_stomp_resumed)
	Stomp.disconnect_ws()


func _process(_delta: float) -> void:
	if not waiting and not public_view.get("handInProgress", false) and next_hand_due_ticks >= 0:
		_update_status_label()
	_update_turn_timer()


func _build_seats() -> void:
	for seat_no in range(1, 10):
		var box := BoxContainer.new()
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
	action_bg = Panel.new()
	action_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = Color(SeatScript.SURFACE, 0.85)
	bg_style.border_color = SeatScript.BORDER
	bg_style.set_border_width_all(2)
	bg_style.set_corner_radius_all(12)
	action_bg.add_theme_stylebox_override("panel", bg_style)
	action_bg.hide()
	felt_area.add_child(action_bg)
	dealer_marker = _marker(Marker.Kind.DEALER, Vector2(22, 22))
	dealer_marker.hide()
	felt_area.add_child(dealer_marker)
	sb_marker = _marker(Marker.Kind.DEALER, Vector2(22, 22), "SB", Color(0.62, 0.80, 1.0)) # D 와 구별되게 푸른 기
	bb_marker = _marker(Marker.Kind.DEALER, Vector2(22, 22), "BB", Color(1.0, 0.72, 0.62))
	for m: Control in [sb_marker, bb_marker]:
		m.hide()
		felt_area.add_child(m)
	for seat_no in range(1, 10):
		var seat_node: Control = SeatScene.instantiate()
		seat_node.name = "Seat%d" % seat_no # QA 브리지 키(Seat3/NameLabel)
		felt_area.add_child(seat_node)
		seat_nodes.append(seat_node)
	hand_text_pill = Label.new()
	hand_text_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hand_text_pill.add_theme_font_size_override("font_size", 12)
	hand_text_pill.add_theme_color_override("font_color", SeatScript.ACCENT)
	var pill_style := StyleBoxFlat.new()
	pill_style.bg_color = SeatScript.SURFACE_RAISED
	pill_style.set_corner_radius_all(9)
	pill_style.set_border_width_all(1)
	pill_style.border_color = SeatScript.ACCENT
	pill_style.content_margin_left = 8
	pill_style.content_margin_right = 8
	pill_style.content_margin_top = 1
	pill_style.content_margin_bottom = 1
	hand_text_pill.add_theme_stylebox_override("normal", pill_style)
	hand_text_pill.hide()
	felt_area.add_child(hand_text_pill)
	motion = Motion.new()
	banner_title = Label.new()
	banner_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_title.add_theme_color_override("font_color", Color("ffd54a"))
	banner_title.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.0, 0.95))
	banner_title.add_theme_constant_override("outline_size", 10)
	banner_bg = Panel.new()
	banner_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_bg.hide()
	felt_area.add_child(banner_bg)
	felt_area.add_child(banner_title)
	board_label.add_theme_color_override("font_color", Color("fff4d0"))
	board_label.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.0, 0.95))
	board_label.add_theme_constant_override("outline_size", 6)
	felt_area.move_child(board_label, -1)
	felt_area.add_child(motion) # 마지막 자식 = 맨 위
	_render_seats()


func _marker(kind: int, min_size: Vector2, label := "D", tint := Color.WHITE) -> Control:
	var m := Control.new()
	m.set_script(Marker)
	m.kind = kind
	m.label = label
	m.tint = tint
	m.custom_minimum_size = min_size
	m.size = min_size
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return m


func _fit_bottom_width() -> void: # 아래 영역 내용은 최대 640 너비로 가운데
	if desktop: # 데스크톱은 _layout_desktop 이 자리·여백을 정한다
		_sync_action_bg()
		return
	var side := maxi(16, int((bottom_region.size.x - 640) / 2.0))
	bottom_region.add_theme_constant_override("margin_left", side)
	bottom_region.add_theme_constant_override("margin_right", side)


## 폰(세로)과 데스크톱(가로) 사이에서 노드를 옮긴다. 데스크톱: 아래 영역(행동 패널)·버튼 줄을 FeltArea 안으로 띄우고 ½팟·팟·올인을 별도 줄로 뺀다. 폰은 원래 자리로 되돌린다
func _apply_mode() -> void:
	var want := not compact
	if want == desktop:
		return
	desktop = want
	var presets: Array = [half_pot_button, pot_button, all_in_button]
	if want:
		bottom_region.reparent(felt_area, false)
		bottom_bar.reparent(felt_area, false)
		felt_area.move_child(action_bg, bottom_region.get_index() - 1) # 바탕이 행동 패널 바로 아래(위에 그리면 버튼이 흐려진다)
		felt_area.move_child(my_cards_box, motion.get_index()) # 내 큰 카드는 좌석 패널 위(아래에 깔리면 패널 바탕에 흐려진다)
		for b: Button in presets:
			b.reparent(preset_row, false)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top_bar.add_theme_constant_override("margin_top", 8)
		top_bar.add_theme_constant_override("margin_bottom", 4)
		pot_row.hide() # 팟은 Total 상자가 보인다
	else:
		bottom_region.reparent(vbox, false)
		vbox.move_child(bottom_region, -1)
		bottom_bar.reparent(bottom_box, false)
		bottom_box.move_child(bottom_bar, -1)
		for i in presets.size():
			var b: Button = presets[i]
			b.reparent(raise_box, false)
			raise_box.move_child(b, i)
			b.size_flags_horizontal = Control.SIZE_FILL
			b.custom_minimum_size.y = 36
			b.remove_theme_font_size_override("font_size")
		for b: Button in [fold_button, check_call_button, raise_button]:
			b.custom_minimum_size.y = 52
			b.remove_theme_font_size_override("font_size")
		bottom_region.custom_minimum_size = Vector2(0, 206)
		bottom_region.add_theme_constant_override("margin_top", 6)
		bottom_region.add_theme_constant_override("margin_bottom", 12)
		top_bar.add_theme_constant_override("margin_top", 16)
		top_bar.add_theme_constant_override("margin_bottom", 8)
		pot_row.show()
		total_box.hide()
		bottom_bar.custom_minimum_size = Vector2.ZERO
		felt_style.set_border_width_all(FELT_RIM)
		for box: BoxContainer in bet_boxes:
			box.vertical = false
			var chip: Control = box.get_child(0)
			chip.pile = 0
			chip.custom_minimum_size = Vector2(18, 18)
			chip.size = Vector2(18, 18)
			var amount: Label = box.get_child(1)
			amount.add_theme_font_size_override("font_size", 15)
			amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			amount.custom_minimum_size = Vector2.ZERO
		for m: Control in [dealer_marker, sb_marker, bb_marker]:
			m.texture = null
			m.custom_minimum_size = Vector2(22, 22)
			m.size = Vector2(22, 22)
			m.queue_redraw()
	info_box.visible = want
	_sync_preset_row()
	_sync_action_bg()


func _sync_preset_row() -> void:
	if preset_row != null:
		preset_row.visible = desktop and raise_box.visible


func _sync_action_bg() -> void:
	if action_bg == null:
		return
	action_bg.visible = desktop and action_bar.visible
	action_bg.position = bottom_region.position
	action_bg.size = bottom_region.size


## 중심 c 에서 점 p 로 그은 선이 반지름 r 타원과 만나는 점
static func ring_point(p: Vector2, c: Vector2, r: Vector2) -> Vector2:
	var d := p - c
	return c + d / sqrt(pow(d.x / r.x, 2.0) + pow(d.y / r.y, 2.0))


## 데스크톱 배치. 타원 매개변수(D_*)·각도표(D_ANGLES)에서 슬롯을 계산한다. 설계 좌표 × k + 가운데 정렬 오프셋.
## 반환 g: center(펠트 중심), hc(내 카드 크기), slots[v] = {panel, bet, cands[마커 후보 자리, 우선순위 순]}(FeltArea 좌표)
func _layout_desktop() -> Dictionary:
	var area := felt_area.size
	k = maxf(minf(area.x / D_W, area.y / D_H), 0.3)
	var off := (area - Vector2(D_W, D_H) * k) / 2.0
	felt.position = off + (D_CENTER - D_FELT_R) * k
	felt.size = D_FELT_R * 2.0 * k
	felt_style.set_corner_radius_all(int(D_FELT_R.y * k))
	felt_style.set_border_width_all(maxi(int(FELT_RIM * k), 4))
	var slots: Array = []
	for v in 9:
		var a := deg_to_rad(D_ANGLES[v])
		var pc := D_CENTER + D_OUTER * Vector2(cos(a), sin(a))
		var half: Vector2 = (SeatScript.panel_size(v == 0, 1.0)) / 2.0
		var bet: Vector2
		var cands: Array = []
		var mg := D_MARKER / 2.0 + 3.0 # 마커 중심이 패널 가장자리에서 떨어지는 거리(마커 반 + 틈 3)
		if v == 0: # 내 패널은 넓어 베팅이 윗변 오른쪽 위에 있다 — 마커는 윗변 위 왼쪽부터 한 줄
			bet = pc + Vector2(50, -117)
			for i in 3:
				cands.append(pc + Vector2(-half.x + D_MARKER / 2.0 + 4.0 + i * (D_MARKER + 4.0), -half.y - mg))
		else: # 패널의 펠트 쪽 모서리(바깥 대각) → 같은 모서리에서 가로·세로 변을 따라 한 칸씩
			var dir := (D_CENTER - pc).normalized() # 패널 중심 → 펠트 중심 선을 따라, 칸이 패널(BET_OUT 만큼 키운)과 처음 안 닿는 곳에 놓는다
			var keep := Rect2(pc - half, half * 2.0).grow(BET_OUT)
			var t := 0.0
			while Rect2(pc + dir * t - Vector2(D_BET_W, D_BET_H) / 2.0, Vector2(D_BET_W, D_BET_H)).intersects(keep) and t < 400.0:
				t += 1.0
			bet = pc + dir * t
			var sx := signf(D_CENTER.x - pc.x)
			var sy := signf(D_CENTER.y - pc.y)
			var cx := pc.x + sx * half.x
			var cy := pc.y + sy * half.y
			var st := D_MARKER + 7.0 # 베팅 칸이 패널 아래·옆에 붙으니 후보 간격을 조금 더 벌린다
			cands = [Vector2(cx + sx * mg, cy + sy * mg),
				Vector2(cx - sx * (D_MARKER / 2.0 + 4.0), cy + sy * mg), Vector2(cx + sx * mg, cy - sy * (D_MARKER / 2.0 + 4.0)),
				Vector2(cx - sx * (D_MARKER / 2.0 + 4.0 + st), cy + sy * mg), Vector2(cx + sx * mg, cy - sy * (D_MARKER / 2.0 + 4.0 + st)),
				Vector2(cx - sx * (D_MARKER / 2.0 + 4.0 + 2.0 * st), cy + sy * mg), Vector2(cx + sx * mg, cy - sy * (D_MARKER / 2.0 + 4.0 + 2.0 * st)),
				Vector2(pc.x - sx * (half.x - D_MARKER / 2.0 - 4.0), cy + sy * mg), Vector2(pc.x - sx * (half.x - D_MARKER / 2.0 - 4.0 - st), cy + sy * mg)] # 끝: 바깥쪽 모서리(베팅 칸이 안쪽 모서리를 막을 때)
		var sl := {"panel": Rect2(off + (pc - half) * k, half * 2.0 * k), "left": pc.x <= D_CENTER.x} # left: 아바타 열이 왼쪽
		sl.bet = off + bet * k
		sl.cands = cands.map(func(m: Vector2) -> Vector2: return off + m * k)
		slots.append(sl)
	var hc := SeatScript.desk_card_size(true, k)
	var board_size := Vector2(D_BOARD_CARD.x * 5.0 + 24.0, D_BOARD_CARD.y) * k # 카드 사이 6(HBox 간격)
	for r: TextureRect in board_card_rects:
		r.custom_minimum_size = D_BOARD_CARD * k
	board_box.custom_minimum_size = board_size
	center_box.size = board_size
	center_box.position = off + Vector2(D_CENTER.x * k - board_size.x / 2.0, D_BOARD_TOP * k)
	for r: TextureRect in my_card_rects:
		r.custom_minimum_size = hc
	my_cards_box.size = Vector2(2.0 * hc.x + 8.0 * k, hc.y)
	var hero_cd: Rect2 = SeatScript.desk_columns(true, true, k).cards # 내 큰 카드는 안쪽(카드) 열 가운데
	my_cards_box.position = (slots[0].panel as Rect2).position + Vector2(hero_cd.get_center().x - my_cards_box.size.x / 2.0, 8.0 * k)
	# Total / Call 상자와 결과 문구는 보드 아래 같은 자리(핸드 중엔 상자, 끝나면 결과 문구)
	total_box.custom_minimum_size = Vector2(230.0 * k, 0)
	for l: Label in [total_label, call_label]:
		l.add_theme_font_size_override("font_size", int(round(22.0 * k)))
	for l: Label in [call_key, %TotalKey]:
		l.add_theme_font_size_override("font_size", int(round(18.0 * k)))
	%PotIcon.custom_minimum_size = Vector2(26, 26) * k
	total_box.reset_size()
	total_box.position = off + Vector2(D_CENTER.x * k - total_box.size.x / 2.0, D_TOTAL_TOP * k)
	_place_board_label()
	# 행동 패널·버튼 줄
	bottom_region.custom_minimum_size = Vector2.ZERO
	for side in ["left", "right", "top", "bottom"]:
		bottom_region.add_theme_constant_override("margin_" + side, int(8.0 * k))
	bottom_region.position = off + D_ACTION.position * k
	bottom_region.size = D_ACTION.size * k
	bottom_bar.position = off + D_BAR.position * k
	bottom_bar.size = D_BAR.size * k
	for b: Button in [half_pot_button, pot_button, all_in_button]:
		b.custom_minimum_size.y = 30.0 * k
		b.add_theme_font_size_override("font_size", int(round(16.0 * k)))
	for b: Button in [fold_button, check_call_button, raise_button]:
		b.custom_minimum_size.y = 44.0 * k
		b.add_theme_font_size_override("font_size", int(round(17.0 * k)))
	_sync_action_bg()
	return {"center": off + D_CENTER * k, "hc": hc, "slots": slots}


## 데스크톱: 슬롯에 좌석·베팅을 고정 자리로 놓고(겹치지 않게 타원을 짰다. test_layout 이 확인한다), 마커는 후보 중 빈 자리를 고른다
func _place_desktop(g: Dictionary, hero: int, marks: Array) -> void:
	for seat_no in range(1, 10):
		var v := posmod(seat_no - hero, 9)
		var sl: Dictionary = g.slots[v]
		var seat_node: Control = seat_nodes[seat_no - 1]
		seat_node.set_desktop(k, v == 0, sl.left)
		seat_node.position = (sl.panel as Rect2).position
		_render_seat(seat_no, seat_node)
		var box: BoxContainer = bet_boxes[seat_no - 1]
		box.vertical = true
		var chip: Control = box.get_child(0)
		var amount: Label = box.get_child(1)
		chip.unit = k
		amount.add_theme_font_size_override("font_size", int(round(16.0 * k)))
		amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if box.visible: # 최소 크기는 다음 프레임에야 갱신되므로 직접 계산한다(더미 + 간격 4 + 금액). 폭은 기둥 수·금액 글자 중 넓은 쪽
			var ps := Marker.pile_size(chip.pile, k)
			var bw := maxf(maxf(ps.x, amount.get_combined_minimum_size().x), D_BET_W * k)
			chip.custom_minimum_size = Vector2(bw, ps.y)
			amount.custom_minimum_size = Vector2(bw, 0)
			var bm := Vector2(bw, ps.y + 4.0 + amount.get_combined_minimum_size().y)
			box.size = bm
			box.position = (sl.bet as Vector2) - bm / 2.0
	# 마커: 자기 패널 모서리 후보 중 처음으로 아무것(패널·베팅·보드·Total·행동 패널·앞선 마커)과도 안 닿는 자리
	var blocks: Array = []
	for sl: Dictionary in g.slots:
		blocks.append(sl.panel)
	blocks.append_array([center_box.get_rect(), total_box.get_rect(), bottom_region.get_rect(), bottom_bar.get_rect()])
	for seat_no in range(1, 10):
		if bet_boxes[seat_no - 1].visible:
			blocks.append(bet_boxes[seat_no - 1].get_rect())
	for mk: Array in marks: # [마커, 좌석, 종류(D 0·SB 1·BB 2)] — 놓는 순서 = 우선순위
		var m: Control = mk[0]
		m.custom_minimum_size = Vector2(D_MARKER, D_MARKER) * k
		m.size = m.custom_minimum_size
		m.texture = MARKER_TEXTURES[mk[2]]
		m.queue_redraw()
		if mk[1] == -1:
			continue
		var own := posmod(mk[1] - hero, 9)
		var cands: Array = g.slots[own].cands
		var pos: Vector2 = cands[0]
		var fallback := -1
		for ci in cands.size():
			var r := Rect2((cands[ci] as Vector2) - m.size / 2.0, m.size)
			var free := true
			for bi in blocks.size():
				if r.grow(0.0 if bi < 9 else 2.0).intersects(blocks[bi]): # 앞 아홉은 패널 — 살짝 닿는 것까지는 둔다
					free = false
					break
			if not free:
				continue
			if fallback == -1:
				fallback = ci
			if _nearest_slot(r, g.slots, own) == own: # 옆 좌석 것으로 보이면 건너뛴다
				fallback = ci
				break
		if fallback != -1:
			pos = cands[fallback]
		m.position = pos - m.size / 2.0
		blocks.append(m.get_rect())


## r 에서 가장 가까운(사각 사이 거리) 슬롯 패널의 번호
func _nearest_slot(r: Rect2, slots: Array, own: int) -> int: # 동률은 남에게 진 것으로 센다(own 거리 +1)
	var best := INF
	var nearest := -1
	for v in slots.size():
		var p: Rect2 = slots[v].panel
		var d := Vector2(maxf(maxf(r.position.x - p.end.x, p.position.x - r.end.x), 0.0), maxf(maxf(r.position.y - p.end.y, p.position.y - r.end.y), 0.0)).length()
		if v == own:
			d += 1.0
		if d < best:
			best = d
			nearest = v
	return nearest


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
	for r: TextureRect in my_card_rects:
		r.custom_minimum_size = hc
	my_cards_box.size = Vector2(2.0 * hc.x + 8.0, hc.y)
	my_cards_box.position = Vector2(c.x - my_cards_box.size.x / 2.0, hero_top)
	var g := {"center": c, "rx": rect.size.x / 2.0, "ry": rect.size.y / 2.0, "cap": cap, "hc": hc, "hero_top": hero_top}
	_place_board_label()
	return g


func _seat_center(seat_no: int, hero: int, g: Dictionary) -> Vector2:
	var v := posmod(seat_no - hero, 9)
	var deg := 90.0 + v * 40.0
	if compact and (v == 1 or v == 8): # 세로: 내 카드 양옆 좌석이 내 카드와 닿지 않게 위쪽 바깥으로 6° 옮긴다
		deg += 6.0 if v == 1 else -6.0
	elif compact and (v == 4 or v == 5): # 세로: 위 두 좌석 캡슐 간격이 8px 로 좁아 3° 씩 벌린다(≈24px)
		deg += -3.0 if v == 4 else 3.0
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
	if _should_leave_room(): # 개인 큐는 미리 끊지 않는다 — 공개 뷰가 미착석을 확인한 지금 씬을 바꿔 정리한다
		leave_room_after_stand = false
		_leave_closed_table()
		return
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
	var left_ms = body.get("turnRemainingMs")
	turn_deadline_ticks = -1 if left_ms == null else Time.get_ticks_msec() + int(left_ms)
	var total_ms = body.get("turnTimeoutMs")
	turn_total_ms = 0 if total_ms == null else int(total_ms)
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
	leave_room_after_stand = body.get("leaveReservation") == "LEAVE" # null | "SPECTATE" | "LEAVE"
	my_hand_text = Cards.current_hand_text(body.get("currentHand"))
	_update_pot()
	_update_buttons()
	_render_seats()
	_update_action_bar()


func _handle_join_queue(body: Dictionary) -> void:
	if table_id == 0:
		pending_join_queue.append(body)
		return
	if int(body.tableId) != table_id:
		return
	join_event_seen = true
	resume_event_seen = true
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
	my_hand_text = ""
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
		var join_buy_in := auto_join_buy_in
		auto_join_buy_in = 0 # 재연결 때 다시 보내지 않는다 — 그 뒤는 last_buy_in 이 맡는다
		if join_buy_in > 0:
			dropped_retried = false
			_send_join(auto_join_post_blind, join_buy_in)
		else:
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


## 숨은 탭에서 잃었을 수 있는 join-queue SEATED/DROPPED 를 me/seat 로 보충한다.
## me/seat 는 좌석만 본다(대기열 중이면 204) — 소켓 교체가 끝나 서버가 POSITION·SEATED 스냅샷을 줄 시간을 준 뒤, 안 왔을 때만 묻는다(DROPPED 는 스냅샷으로 안 온다)
func _on_stomp_resumed() -> void:
	if not waiting or _is_seated() or table_id == 0:
		return
	resume_event_seen = false
	if not Stomp.connected.is_connected(_start_resume_seat_check): # 교체가 끝나면(connected) 유예를 센다
		Stomp.connected.connect(_start_resume_seat_check, CONNECT_ONE_SHOT)


func _start_resume_seat_check() -> void:
	get_tree().create_timer(RESUME_SEAT_CHECK_SEC).timeout.connect(_check_resume_seat.bind(table_id)) # await 은 노드가 해제돼도 재개된다 — connect 는 끊긴다


func _check_resume_seat(id: int) -> void:
	if table_id != id or resume_event_seen or not waiting or _is_seated():
		return
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/me/seat")
	if table_id != id or resume_event_seen or not waiting or _is_seated() or not r.ok:
		return
	if r.status == 200 and r.data is Dictionary:
		if int(r.data.tableId) == id:
			_handle_join_queue({"tableId": id, "type": "SEATED"})
	elif r.status == 204: # 스냅샷도 없고 앉지도 않았다 — DROPPED 를 잃었다
		_handle_join_queue({"tableId": id, "type": "DROPPED", "errorCode": "CREATE_SEAT_FAILED"})


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
	if desktop:
		return total_box.position + total_box.size / 2.0
	return center_box.position + Vector2(center_box.size.x / 2.0, 14.0)


func _chip_ghost(text: String) -> Control:
	var g: BoxContainer = bet_boxes[0].duplicate()
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
			var board_rect := Rect2(board_box.global_position - motion.global_position, board_box.size) # 지나가는 동안은 보드 위에서 숨긴다
			motion.fly(_chip_ghost("+" + Format.comma(int(payout.amount))), pot, sn.position + sn.size / 2.0, Motion.PUSH_FLY, Motion.BET_TO_POT, true, Tween.EASE_IN_OUT, Tween.TRANS_QUAD, board_rect)
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
	var order := PublicView.deal_order(public_view)
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


## QA 브리지(core/qa_bridge.gd)가 state().extra 로 읽는다. 표시 없이 현재 상태만 돌려준다
func qa_state() -> Dictionary:
	var seats := []
	for seat in public_view.get("seats", []):
		var nick: String = nickname_cache.get(seat.userId, seat_nodes[int(seat.seatNo) - 1].name_label.text) # 캐시가 비면 화면에 보이는 이름
		seats.append({"seat_no": int(seat.seatNo), "nickname": nick, "stack": int(seat.stack), "status": seat.status, "leave_reserved": seat.leaveReserved,
			"last_action": PublicView.action_label(seat)})
	var winners := []
	var result = public_view.get("result")
	if result != null:
		for payout in result.get("payouts", []):
			winners.append({"seat_no": int(payout.seatNo), "amount": int(payout.amount)})
	var actions := []
	if my_available_actions != null:
		var a: Dictionary = my_available_actions
		actions.append("CHECK" if a.get("canCheck", false) else "CALL")
		actions.append("FOLD")
		if a.get("minRaiseTo") != null:
			actions.append("RAISE_TO")
	var countdown := -1.0
	if next_hand_due_ticks >= 0:
		countdown = maxf((next_hand_due_ticks - Time.get_ticks_msec()) / 1000.0, 0.0)
	return {
		"table_id": table_id,
		"last_public_seq": last_public_seq,
		"my_seat_no": _my_seat_no(),
		"hand_in_progress": public_view.get("handInProgress", false),
		"sb_seat_no": PublicView.blind_seats(public_view).sb,
		"bb_seat_no": PublicView.blind_seats(public_view).bb,
		"street": public_view.get("street", ""),
		"my_hole_cards": my_codes,
		"my_hand_text": my_hand_text,
		"to_act_seat": _to_act_seat_no(),
		"available_actions": actions,
		"seats": seats,
		"board": public_view.get("board", []),
		"winners": winners,
		"next_hand_seconds": countdown,
		"leave_room_after_stand": leave_room_after_stand,
	}


# --- rendering ---

func _is_seated() -> bool:
	return _find_seat_by_user(Api.user_id) != null


func _find_seat(seat_no: int) -> Variant:
	return PublicView.find_seat(public_view, seat_no)


func _seat_held_by(seat_no: int, user_id) -> bool:
	return PublicView.seat_held_by(public_view, seat_no, user_id)


func _find_seat_by_user(user_id: int) -> Variant:
	return PublicView.find_seat_by_user(public_view, user_id)


func _my_seat_no() -> int:
	var seat: Variant = _find_seat_by_user(Api.user_id)
	return int(seat.seatNo) if seat != null else -1


func _to_act_seat_no() -> int:
	return PublicView.to_act_seat_no(public_view)


func _find_shown_hand(seat_no: int) -> Variant:
	return PublicView.find_shown_hand(public_view, seat_no)


func _find_revealed_hand(seat_no: int) -> Variant:
	return PublicView.find_revealed_hand(public_view, seat_no)


func _payout_for(seat_no: int) -> int:
	return PublicView.payout_for(public_view, seat_no)


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
	var hip: bool = public_view.get("handInProgress", false)
	total_box.visible = desktop and hip
	total_label.text = Format.comma(pot)
	var my_turn: bool = hip and my_available_actions != null and _my_seat_no() != -1 and _to_act_seat_no() == _my_seat_no()
	var call_amount := int(my_available_actions.get("callAmount", 0) if my_turn and my_available_actions.get("callAmount") != null else 0)
	call_label.text = Format.comma(call_amount) if call_amount > 0 else ""
	for n: Control in [call_spacer, call_key, call_label]:
		n.visible = call_amount > 0


func _update_board_label() -> void:
	var banner := PublicView.result_banner(public_view)
	var title: String = banner.get("title", "")
	var wins := []
	for w: Array in banner.get("sub", []):
		wins.append("%s +%s" % [_nickname_for(w[1]), Format.comma(w[2])])
	var sub := "  ".join(wins)
	var appear := banner_title.text == "" and title != ""
	banner_title.text = title
	board_label.text = sub
	_place_board_label()
	if appear:
		if banner_tween != null:
			banner_tween.kill()
		banner_tween = create_tween().set_parallel(true)
		for l: Control in [banner_bg, banner_title, board_label]:
			l.scale = Vector2(0.6, 0.6)
			banner_tween.tween_property(l, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## 결과 배너: 보드 카드 가운데에 큰 글자, 그 아래 작은 줄. 보드 위에 겹쳐 그린다(카드는 가려도 된다)
func _place_board_label() -> void:
	var tk := k if desktop else 0.7
	var w := center_box.size.x
	var sizes := {banner_title: int(round(40.0 * tk)), board_label: int(round(18.0 * k)) if desktop else 15}
	for l: Label in sizes:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", sizes[l])
		l.custom_minimum_size = Vector2(w, 0)
		l.reset_size()
		l.size.x = w
		l.pivot_offset = l.size / 2.0
	var cy := center_box.position.y + center_box.size.y - board_box.custom_minimum_size.y / 2.0
	var gap := 8.0 * tk # 큰 글자 외곽선과 작은 줄 사이
	var top := cy - (banner_title.size.y + gap + board_label.size.y) / 2.0
	banner_title.position = Vector2(center_box.position.x + (center_box.size.x - w) / 2.0, top)
	board_label.position = banner_title.position + Vector2(0, banner_title.size.y + gap)
	# 글자 뒤 판: 두 줄의 실제 글자 너비에 맞춰 가운데에 둔다
	var f := banner_title.get_theme_font("font")
	var tw := f.get_string_size(banner_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, sizes[banner_title]).x
	var sw := 0.0
	var text_rect := Rect2(banner_title.position, banner_title.size)
	if board_label.text != "":
		sw = f.get_string_size(board_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, sizes[board_label]).x
		text_rect = text_rect.merge(Rect2(board_label.position, board_label.size))
	var pad := 12.0 * tk
	var bw := minf(maxf(tw, sw), w) + pad * 2.0
	var bh := text_rect.size.y + pad * 2.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.6)
	sb.set_corner_radius_all(int(round(10.0 * tk)))
	banner_bg.add_theme_stylebox_override("panel", sb)
	banner_bg.size = Vector2(bw, bh)
	banner_bg.position = text_rect.get_center() - banner_bg.size / 2.0
	banner_bg.pivot_offset = banner_bg.size / 2.0
	banner_bg.visible = banner_title.text != ""


func _render_seats() -> void:
	if seat_nodes.size() < 9:
		return
	compact = size.x < 700.0
	_apply_mode()
	var g := _layout() if compact else _layout_desktop()
	geo = g
	hand_text_pill.visible = compact and my_hand_text != "" and my_cards_box.visible
	if hand_text_pill.visible: # 내 큰 카드 바로 위 가운데
		hand_text_pill.text = my_hand_text
		hand_text_pill.reset_size()
		hand_text_pill.position = Vector2(my_cards_box.position.x + (my_cards_box.size.x - hand_text_pill.size.x) / 2.0, my_cards_box.position.y - hand_text_pill.size.y - 3.0)
	var hero := _my_seat_no()
	if hero == -1:
		hero = 1
	var dealer_seat := -1
	var button_no = public_view.get("buttonSeatNo")
	if button_no != null and _find_seat(int(button_no)) != null:
		dealer_seat = int(button_no)
	dealer_marker.visible = dealer_seat != -1
	var blinds := PublicView.blind_seats(public_view)
	var sb_seat: int = blinds.sb if _find_seat(blinds.sb) != null else -1
	var bb_seat: int = blinds.bb if _find_seat(blinds.bb) != null else -1
	sb_marker.visible = sb_seat != -1
	bb_marker.visible = bb_seat != -1
	if desktop:
		_place_desktop(g, hero, [[dealer_marker, dealer_seat, 0], [sb_marker, sb_seat, 1], [bb_marker, bb_seat, 2]])
		return
	var marks: Array = [[dealer_marker, dealer_seat], [sb_marker, sb_seat], [bb_marker, bb_seat]] # 놓는 순서 = 겹침 우선순위
	var area := felt_area.size
	for seat_no in range(1, 10):
		var sp := _seat_center(seat_no, hero, g)
		var seat_node: Control = seat_nodes[seat_no - 1]
		seat_node.set_compact(compact)
		seat_node.position = sp - seat_node.size / 2.0
		seat_node.badge_side = 0 if absf(sp.x - g.center.x) < 20.0 else int(signf(sp.x - g.center.x))
		seat_node.badge_bounds = Vector2(4.0 - seat_node.position.x, area.x - 4.0 - seat_node.position.x)
		_render_seat(seat_no, seat_node)
	var placed: Array = [] # 이미 놓은 마커 사각 — 다음 마커의 자리 검사에서 막는다. 행동 토큰도 먼저 넣는다
	_place_tokens(g, placed)
	for mk: Array in marks:
		if mk[1] != -1:
			_place_marker(mk[0], mk[1], hero, g, placed)
	var bet_blockers := _bet_blockers() # 카드·배지·마커·보드·내 카드. 놓은 칩도 여기에 보탠다
	for seat_no in range(1, 10): # 베팅은 모든 좌석·마커가 놓인 뒤 — 좌석 사이 충돌을 본다
		var sp := _seat_center(seat_no, hero, g)
		var to_center: Vector2 = (g.center - sp).normalized()
		var bet_box: BoxContainer = bet_boxes[seat_no - 1]
		if bet_box.visible:
			bet_box.reset_size()
			var bm := bet_box.get_combined_minimum_size()
			var b := _bet_spot(sp, bm, to_center, g, bet_blockers)
			bet_box.position = b - bm / 2.0
			bet_blockers.append(Rect2(bet_box.position, bm))
	_place_payouts(hero, g)


## 폰 행동 토큰: 자기 캡슐에서 펠트 가운데 쪽으로 시작해, 막히면 둘레를 따라 돌려 가며 카드·배지·알약·보드·다른 캡슐을 피하는 첫 자리. 놓은 사각은 placed 에 보탠다
func _place_tokens(g: Dictionary, placed: Array) -> void:
	var blockers: Array = _center_blockers()
	for n: Control in seat_nodes:
		for c: Control in n.card_rects + [n.badge_all_in, n.badge_presence, n.badge_leave, n.hand_pill]:
			if c.visible:
				blockers.append(_seat_rect(n, c))
		if n.timer_left >= 0.0 and not n.empty:
			blockers.append(Rect2(n.position + Vector2(0, n.size.y), Vector2(n.size.x, 18.0))) # 타이머 막대 자리
	for seat_no in range(1, 10):
		var n: Control = seat_nodes[seat_no - 1]
		if not n.badge_action.visible:
			continue
		var sp := n.position + n.size / 2.0
		var to_center: Vector2 = (g.center - sp).normalized()
		var tsz: Vector2 = n.badge_action.size
		var chosen := Vector2.ZERO
		var found := false
		for i in BET_ANGLES.size():
			var dir := to_center.rotated(deg_to_rad(BET_ANGLES[i]))
			var p0 := _push_clear(sp, sp, tsz, dir, 4.0, g.cap)
			if i == 0:
				chosen = p0
			for extra in range(0, 40, 6): # 같은 방향으로 조금씩 더 밀어 본다(카드·배지 가장자리를 비켜 간다)
				var p := p0 + dir * float(extra)
				var r := Rect2(p - tsz / 2.0, tsz)
				var ok := Rect2(Vector2.ZERO, felt_area.size).encloses(r)
				for bl: Rect2 in blockers + placed:
					ok = ok and not bl.grow(2.0).intersects(r)
				for o: Control in seat_nodes:
					ok = ok and (o.empty or not _near_capsule(o.position + o.size / 2.0, g.cap, r, 2.0))
				if ok:
					chosen = p
					found = true
					break
			if found:
				break
		n.set_token_center(chosen - n.position)
		placed.append(Rect2(chosen - tsz / 2.0, tsz))


## 칩이 가려선 안 되는 것: 모든 좌석의 작은 카드·배지·알약, 마커, 보드 묶음·결과 문구·내 큰 카드
func _bet_blockers() -> Array:
	var out: Array = _center_blockers()
	for n: Control in seat_nodes:
		for c: Control in n.card_rects + [n.badge_all_in, n.badge_presence, n.badge_leave, n.badge_action, n.hand_pill]:
			if c.visible:
				out.append(_seat_rect(n, c))
	for m: Control in [dealer_marker, sb_marker, bb_marker]:
		if m.visible:
			out.append(Rect2(m.position, m.size))
	return out


## 베팅 칩 자리: 자기 캡슐에서 BET_GAP 만큼 떨어진 곳에서 펠트 중심 쪽(to_center)으로 시작해, 막히면 캡슐 둘레로 돌려 가며 처음 비는 곳. 모두 막히면 기본 자리
func _bet_spot(sp: Vector2, bm: Vector2, to_center: Vector2, g: Dictionary, blockers: Array) -> Vector2:
	var first := Vector2.ZERO
	for i in BET_ANGLES.size():
		var dir := to_center.rotated(deg_to_rad(BET_ANGLES[i]))
		var p0 := _push_clear(sp, sp, bm, dir, BET_GAP, g.cap)
		if i == 0:
			first = p0
		for extra in range(0, 40, 6): # 같은 방향으로 조금씩 더 밀어 본다(토큰·카드 가장자리를 비켜 간다)
			var b := p0 + dir * float(extra)
			var r := Rect2(b - bm / 2.0, bm)
			var ok := Rect2(Vector2.ZERO, felt_area.size).encloses(r)
			for bl: Rect2 in blockers:
				ok = ok and not bl.grow(2.0).intersects(r)
			for n: Control in seat_nodes:
				ok = ok and (n.empty or not _near_capsule(n.position + n.size / 2.0, g.cap, r, 2.0))
			if ok:
				return b
	return first


## 마커(딜러·SB·BB)를 seat_no 좌석 곁에 놓는다. 가리는 것이 없는 첫 후보 자리에 두고 placed 에 사각을 보탠다
func _place_marker(marker: Control, seat_no: int, hero: int, g: Dictionary, placed: Array) -> void:
	var sp := _seat_center(seat_no, hero, g)
	var seat_node: Control = seat_nodes[seat_no - 1]
	var to_center: Vector2 = (g.center - sp).normalized()
	var msz := marker.size
	var d := _push_clear(sp, sp, msz, to_center, 4.0, g.cap)
	if seat_no == hero:
		d = sp + Vector2(g.hc.x + 26.0, -g.cap.y / 2.0 - 12.0)
		for _i in 6: # 같은 자리에 이미 놓였으면(마커·토큰) 옆으로 한 칸씩
			for r: Rect2 in placed:
				if r.grow(2.0).intersects(Rect2(d - msz / 2.0, msz)):
					d.x += msz.x + 4.0
	else: # 마커가 이 좌석의 작은 카드·배지를 가리거나 화면 밖이면 캡슐 옆·아래 모서리로 옮긴다
		var sx := 1.0 if to_center.x >= 0.0 else -1.0
		var cands: Array = [d, sp + Vector2(sx * (g.cap.x / 2.0 + msz.x / 2.0 + 4.0), 0.0),
			sp + Vector2(-sx * (g.cap.x / 2.0 + msz.x / 2.0 + 4.0), 0.0),
			sp + Vector2(sx * (g.cap.x / 2.0 - 12.0), g.cap.y / 2.0 + 10.0),
			sp + Vector2(-sx * (g.cap.x / 2.0 - 12.0), g.cap.y / 2.0 + 10.0),
			sp + Vector2(sx * (g.cap.x / 2.0 - 12.0), -g.cap.y / 2.0 - 10.0),
			sp + Vector2(-sx * (g.cap.x / 2.0 - 12.0), -g.cap.y / 2.0 - 10.0)]
		for cd: Vector2 in cands:
			if _dealer_spot_ok(Rect2(cd - msz / 2.0, msz), seat_node, hero, g, placed):
				d = cd
				break
	marker.position = d - msz / 2.0
	placed.append(Rect2(marker.position, msz))


## r 이 sp 에 있는 알약 캡슐에서 margin 보다 가까우면 true. 캡슐은 양 끝이 반원이라 사각 모서리가 비어 있다
func _near_capsule(sp: Vector2, cap: Vector2, r: Rect2, margin: float) -> bool:
	var half := cap.x / 2.0 - cap.y / 2.0
	var dx := maxf(maxf(r.position.x - (sp.x + half), (sp.x - half) - r.end.x), 0.0)
	var dy := maxf(maxf(r.position.y - sp.y, sp.y - r.end.y), 0.0)
	return Vector2(dx, dy).length() < cap.y / 2.0 + margin


## 중심 p 의 sz 크기 사각이 sp 캡슐에서 margin 이상 떨어질 때까지 dir 로 민다
func _push_clear(sp: Vector2, p: Vector2, sz: Vector2, dir: Vector2, margin: float, cap: Vector2) -> Vector2:
	for i in 200:
		if not _near_capsule(sp, cap, Rect2(p - sz / 2.0, sz), margin):
			break
		p += dir
	return p


func _seat_rect(n: Control, c: Control) -> Rect2:
	return Rect2(n.position + c.position, c.size)


## 보드 묶음(팟·보드)·결과 문구·내 큰 카드. 내 카드는 개인 뷰보다 공개 뷰가 먼저 와도 앉아 있으면 자리를 잡아 둔다
func _center_blockers() -> Array:
	var out: Array = [Rect2(center_box.position, center_box.size)]
	if board_label.text != "":
		out.append(Rect2(banner_title.position, banner_title.size).merge(Rect2(board_label.position, board_label.size)))
	if _my_seat_no() != -1:
		out.append(Rect2(my_cards_box.position, my_cards_box.size))
	if hand_text_pill.visible:
		out.append(Rect2(hand_text_pill.position, hand_text_pill.size))
	return out


## 이 좌석의 카드·배지·이미 놓은 마커와 겹치지 않고, 펠트 영역 안이고, 다른 좌석 캡슐과 닿지 않으면 마커 자리로 쓴다
func _dealer_spot_ok(r: Rect2, seat_node: Control, hero: int, g: Dictionary, placed: Array) -> bool:
	if not Rect2(Vector2.ZERO, felt_area.size).encloses(r):
		return false
	for cr: Control in seat_node.card_rects + [seat_node.badge_all_in, seat_node.badge_presence, seat_node.badge_leave, seat_node.badge_action, seat_node.hand_pill]:
		if cr.visible and _seat_rect(seat_node, cr).grow(2.0).intersects(r):
			return false
	for b: Rect2 in _center_blockers() + placed:
		if b.grow(2.0).intersects(r):
			return false
	for no in range(1, 10):
		var other: Control = seat_nodes[no - 1]
		if other != seat_node and not other.empty and _near_capsule(other.position + other.size / 2.0, g.cap, r, 2.0):
			return false
	return true


## 지급액은 캡슐 아래(기본) → 바깥쪽 옆 → 안쪽 옆 순으로, 펠트 영역 안이고 다른 요소(좌석·카드·배지·베팅·딜러·보드·내 카드·결과 문구)와 안 겹치는 첫 자리에 둔다
func _place_payouts(hero: int, g: Dictionary) -> void:
	var blockers: Array = []
	for seat_no in range(1, 10):
		var n: Control = seat_nodes[seat_no - 1]
		for c: Control in n.card_rects + [n.badge_all_in, n.badge_presence, n.badge_leave, n.badge_action, n.hand_pill]:
			if c.visible:
				blockers.append(_seat_rect(n, c))
		if bet_boxes[seat_no - 1].visible:
			blockers.append(Rect2(bet_boxes[seat_no - 1].position, bet_boxes[seat_no - 1].size))
	for m: Control in [dealer_marker, sb_marker, bb_marker]:
		if m.visible:
			blockers.append(Rect2(m.position, m.size))
	blockers.append_array(_center_blockers())
	for seat_no in range(1, 10):
		var n: Control = seat_nodes[seat_no - 1]
		if n.empty or not n.payout_label.visible:
			continue
		var pl: Label = n.payout_label
		var sx := 1.0 if n.position.x + n.size.x / 2.0 >= g.center.x else -1.0
		var spots: Array = [pl.position, Vector2(n.size.x + 6.0 if sx > 0.0 else -6.0 - pl.size.x, (n.size.y - pl.size.y) / 2.0),
			Vector2(-6.0 - pl.size.x if sx > 0.0 else n.size.x + 6.0, (n.size.y - pl.size.y) / 2.0),
			Vector2(n.size.x + 34.0 if sx > 0.0 else -34.0 - pl.size.x, (n.size.y - pl.size.y) / 2.0)] # 마지막: 바깥 옆, 딜러 마커 한 칸 더 바깥
		for sp: Vector2 in spots:
			var r := Rect2(n.position + sp, pl.size)
			var ok := Rect2(Vector2.ZERO, felt_area.size).encloses(r)
			for b: Rect2 in blockers:
				ok = ok and not b.grow(2.0).intersects(r)
			for no in range(1, 10):
				var o: Control = seat_nodes[no - 1]
				ok = ok and (o.empty or not _near_capsule(o.position + o.size / 2.0, g.cap, r, 2.0))
			if ok:
				pl.position = sp
				break
		blockers.append(Rect2(n.position + pl.position, pl.size))


func _render_seat(seat_no: int, seat_node: Control) -> void:
	var bet_box: BoxContainer = bet_boxes[seat_no - 1]
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
	# 앞면 카드(쇼다운 공개·런아웃 공개)나 결과 화면의 내 큰 카드 위에는 행동 글자·토큰을 그리지 않는다
	var face_up: bool = (is_me and public_view.get("result") != null) or (not cards.is_empty() and cards[0] != "back")
	if is_me and hand_text_pill.visible: # 폰: 내 족보는 카드 위 알약이 보이므로 캡슐 알약은 숨긴다
		category = ""
	seat_node.show_player({
		"nickname": _nickname_for(seat.userId),
		"stack": int(seat.stack),
		"is_me": is_me,
		"to_act": _to_act_seat_no() == seat_no,
		"folded": seat.status == "FOLDED",
		"all_in": seat.status == "ALL_IN",
		"action": "" if face_up else PublicView.action_label(seat),
		"presence_text": PRESENCE_TEXT.get(seat.presence, ""),
		"leave_reserved": seat.leaveReserved,
		"leave_text": ("나가기 예약" if leave_room_after_stand else "관전 예약") if is_me else "일어서기 예약",
		"cards": [] if is_me else cards, # 내 카드는 아래 MyCards 가 크게 그린다
		"category": category,
		"hand_text": my_hand_text if is_me else "",
		"payout": _payout_for(seat_no),
	})
	var street_bet := _street_bet(seat)
	if hand_in_progress and street_bet > 0:
		(bet_box.get_child(1) as Label).text = Format.comma(street_bet)
		var chip: Control = bet_box.get_child(0)
		chip.pile = street_bet if desktop else 0
		chip.queue_redraw()
		bet_box.show()


func _street_bet(seat: Dictionary) -> int:
	return PublicView.street_bet(seat, street_base)


func _track_street_base() -> void:
	var key := "%d:%s" % [hand_counter, str(public_view.get("street", ""))]
	if key == street_base_key:
		return
	street_base_key = key
	street_base = PublicView.street_base(public_view)


func _current_max_bet() -> int:
	return PublicView.current_max_bet(public_view, street_base)


func _update_turn_key() -> void:
	var hip: bool = public_view.get("handInProgress", false)
	if hip and not last_hand_in_progress:
		hand_counter += 1
	last_hand_in_progress = hip
	var to_act := _to_act_seat_no()
	var turn_key := "%d:%s:%d" % [hand_counter, str(public_view.get("street", "")), to_act]
	if turn_key != last_turn_key:
		last_turn_key = turn_key


func _update_turn_timer() -> void:
	var to_act := _to_act_seat_no()
	var hip: bool = public_view.get("handInProgress", false)
	for seat_no in range(1, 10):
		var left := -1.0
		if hip and seat_no == to_act and turn_deadline_ticks >= 0 and turn_total_ms > 0:
			left = maxf((turn_deadline_ticks - Time.get_ticks_msec()) / 1000.0, 0.0)
		seat_nodes[seat_no - 1].set_timer(left, turn_total_ms / 1000.0)


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
	var leave_reserved: bool = seated and my_seat != null and my_seat.leaveReserved
	var in_hand: bool = public_view.get("handInProgress", false)
	stand_button.visible = seated and not leave_reserved
	stand_button.text = "핸드 후 관전" if in_hand else "일어서기"
	leave_room_button.visible = seated and not leave_reserved
	leave_room_button.text = "핸드 후 방 나가기" if in_hand else "방 나가기"
	cancel_leave_button.visible = leave_reserved
	cancel_leave_button.text = "나가기 예약됨 · 취소" if leave_room_after_stand else "관전 예약됨 · 취소"
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
	_sync_action_bg()
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
		if r.error == "TABLE_NOT_FOUND": # 닫힌 방 — 닫힘 알림과 똑같이 목록으로
			_leave_closed_table()
			return
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


func _can_show_hand() -> bool:
	return show_denied_hand != hand_counter and PublicView.can_show_hand(public_view, Api.user_id)


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


func _on_stand_pressed(leave_room := false) -> void:
	stand_button.disabled = true
	leave_room_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/seat?after=" + ("LEAVE" if leave_room else "SPECTATE"))
	stand_button.disabled = false
	leave_room_button.disabled = false
	_apply_stand_result(r, leave_room)


## 202(나가기 예약)는 로컬 상태를 바꾸지 않는다 — 다시 방송되는 공개 뷰의 leaveReserved 가 화면을 바꾼다.
## 방 나가기 의도(leave_room_after_stand)는 202 때 로컬에 두고, 개인 뷰의 leaveReservation 이 오면 그 값을 따른다(변수 주석 참고)
func _apply_stand_result(r: Dictionary, leave_room: bool) -> void:
	if not r.ok:
		_show_error(r.error)
	elif r.status == 202: # 예약 종류만 바뀔 수도 있다(이미 예약된 뒤 다시 보냄)
		leave_room_after_stand = leave_room
		_update_buttons()
		_render_seats()
	elif leave_room: # 204 — 바로 일어섰다. 개인 큐는 공개 뷰가 미착석으로 보이면 해제되는 대로 둔다(씬 전환이 정리한다)
		_leave_closed_table()


## 공개 뷰에서 내가 앉아 있지 않은데 방 나가기 의도가 있으면 목록으로 돌아간다
func _should_leave_room() -> bool:
	return leave_room_after_stand and not _is_seated()


func _on_cancel_leave_pressed() -> void:
	cancel_leave_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, "/api/holdem/seat/leave-reservation")
	cancel_leave_button.disabled = false
	_apply_cancel_result(r)


func _apply_cancel_result(r: Dictionary) -> void:
	if r.ok:
		leave_room_after_stand = false
		_update_buttons()
		_render_seats()
	else:
		_show_error(r.error)
