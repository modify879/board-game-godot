extends Control
## Holdem table list: browse pages, create a table.

const Rules := preload("res://games/holdem/rules.gd")
const RoomWidgets := preload("res://games/holdem/room_widgets.gd")
const PAGE_SIZE := 20
const MAX_WIDTH := 720.0 # 목록 최대 폭
const PHONE_WIDTH := 700.0 # 이보다 좁으면 카드를 세로로 쌓고 만들기를 바닥 시트로

@onready var back_button: Button = %BackButton
@onready var refresh_button: Button = %RefreshButton
@onready var history_button: Button = %HistoryButton
@onready var name_edit: LineEdit = %NameEdit
@onready var buy_in_spin: SpinBox = %BuyInSpin
@onready var buy_in_info: Label = %BuyInInfo
@onready var buy_in_blocked_label: Label = %BuyInBlocked
@onready var create_button: Button = %CreateButton
@onready var open_create_button: Button = %OpenCreateButton
@onready var empty_create_button: Button = %EmptyCreateButton
@onready var cancel_button: Button = %CancelButton
@onready var create_overlay: Control = %CreateOverlay
@onready var dim: ColorRect = %Dim
@onready var create_panel: PanelContainer = %CreatePanel
@onready var create_error_label: Label = %CreateErrorLabel
@onready var entry_panel: PanelContainer = %EntryPanel
@onready var entry_title: Label = %EntryTitle
@onready var entry_sub: HBoxContainer = %EntrySub
@onready var entry_info: Label = %EntryInfo
@onready var entry_spin: SpinBox = %EntrySpin
@onready var entry_post_blind: CheckBox = %EntryPostBlind
@onready var entry_error: Label = %EntryError
@onready var entry_watch: Button = %EntryWatch
@onready var entry_join: Button = %EntryJoin
@onready var rows_margin: MarginContainer = %RowsMargin
@onready var error_label: Label = %ErrorLabel
@onready var rows: VBoxContainer = %Rows
@onready var empty_box: Control = %EmptyBox
@onready var pager_box: HBoxContainer = %Pager
@onready var prev_button: Button = %PrevButton
@onready var page_label: Label = %PageLabel
@onready var next_button: Button = %NextButton

static var pending_error := "" # 테이블 화면이 방 만들기에 실패하면 errorCode 를 넘긴다
static var pending_name := "" # 실패해 돌아왔을 때 입력했던 방 이름을 되살린다
static var pending_buy_in := 0 # 같은 이유로 바이인도 되살린다

var pager: Pager
var seat_ok := false # /me/seat 가 204(미착석)
var buy_in_blocked := false # 지갑이 최소 바이인에 못 미친다
var buy_in_loaded := false # GET /api/holdem/buy-in 성공 — 전에는 만들기를 막아 범위 검사를 건너뛰지 않게 한다
var room_items: Array = [] # 지금 그려진 방 카드(qa_state 용)
var buy_in_min := Rules.DEFAULT_MIN_BUY_IN # buy-in GET 응답. 못 받으면 기본 범위(서버보다 엄격하지 않게)
var buy_in_max := Rules.DEFAULT_MAX_BUY_IN
var buy_in_wallet := -1 # -1 = 모름
var entry_id := 0 # 입장 선택 패널이 가리키는 방
var entry_gen := 0 # 패널을 열 때마다 올린다 — 늦게 온 buy-in 응답을 거른다
var entry_min := Rules.DEFAULT_MIN_BUY_IN
var entry_max := Rules.DEFAULT_MAX_BUY_IN
var entry_wallet := -1
var seat_error := "" # /me/seat 실패 errorCode. 204·200 이면 빈 문자열


func _ready() -> void:
	pager = Pager.new(pager_box, prev_button, page_label, next_button, _load)
	create_button.disabled = true # /me/seat 확인이 끝나기 전에는 만들 수 없다
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	history_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://games/holdem/hand_history.tscn"))
	refresh_button.pressed.connect(func() -> void:
		await _load(pager.page)
		await _check_seat()
		await _load_buy_in()
		_show_seat_error())
	create_button.pressed.connect(_on_create)
	open_create_button.pressed.connect(_open_create)
	empty_create_button.pressed.connect(_open_create)
	cancel_button.pressed.connect(_close_overlay)
	entry_watch.pressed.connect(func() -> void: enter(entry_id, false))
	entry_join.pressed.connect(_on_entry_join)
	dim.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_close_overlay())
	resized.connect(_fit)
	_fit()
	name_edit.text_submitted.connect(func(_text: String) -> void: _on_create())
	if await _check_seat():
		return
	await _load_buy_in()
	await _load(0)
	# 목록을 다 읽은 뒤에 띄워야 _load 의 error_label.hide() 에 지워지지 않는다
	if seat_error != "":
		_show_error(seat_error)
	if pending_error != "":
		name_edit.text = pending_name
		buy_in_spin.value = pending_buy_in # 범위 밖이면 SpinBox 가 범위로 맞춘다
		_open_create()
		_show_create_error(pending_error)
	pending_error = ""
	pending_name = ""
	pending_buy_in = 0


## /me/seat 확인. 이미 앉아 있으면 테이블로 가고 true. 204 일 때만 만들기를 풀고, 그 외(0·5xx 등)는 막아 두고 errorCode 를 seat_error 에 담는다
func _check_seat() -> bool:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/me/seat")
	if r.status == 200:
		enter(r.data.tableId)
		pending_error = ""
		pending_name = ""
		return true
	seat_ok = r.status == 204
	_update_create_button()
	seat_error = "" if r.status == 204 else r.error
	return false


func _update_create_button() -> void:
	create_button.disabled = not seat_ok or not buy_in_loaded or buy_in_blocked
	open_create_button.disabled = create_button.disabled
	empty_create_button.disabled = create_button.disabled


## 방 생성 바이인 범위·지갑을 GET /api/holdem/buy-in 으로 읽는다. 실패하면 기본 범위로 둔다
func _load_buy_in() -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/buy-in")
	if not r.ok: # 범위를 모르면 만들기를 막아 둔다(새로고침으로 다시 읽는다)
		buy_in_loaded = false
		buy_in_info.text = ""
		buy_in_blocked_label.hide()
		_update_create_button()
		return
	buy_in_loaded = true
	buy_in_min = int(r.data.minBuyIn)
	buy_in_max = int(r.data.maxBuyIn)
	buy_in_wallet = int(r.data.walletBalance)
	buy_in_info.text = "바이인 %s ~ %s · 지갑 %s" % [Format.comma(buy_in_min), Format.comma(buy_in_max), Format.comma(buy_in_wallet)]
	var blocked: String = Rules.buy_in_blocked_text(r.data)
	buy_in_blocked = blocked != ""
	buy_in_blocked_label.text = blocked
	buy_in_blocked_label.visible = buy_in_blocked
	if not buy_in_blocked:
		buy_in_spin.min_value = buy_in_min
		buy_in_spin.max_value = mini(buy_in_max, buy_in_wallet / Rules.CHIP_UNIT * Rules.CHIP_UNIT)
		buy_in_spin.value = buy_in_spin.max_value
	_update_create_button()


func _show_error(code: String) -> void:
	error_label.text = ErrorText.of(code)
	error_label.show()


func _show_create_error(code: String) -> void:
	create_error_label.text = ErrorText.of(code)
	create_error_label.show()


func _open_create() -> void:
	create_error_label.hide()
	entry_panel.hide()
	create_panel.show()
	create_overlay.show()
	name_edit.grab_focus()


func _close_overlay() -> void:
	create_overlay.hide()


## 방 카드를 누르면 열린다. 바이인 범위·지갑은 착석 팝업(table.gd)과 같은 GET·같은 규칙이다
func _open_entry(item: Dictionary) -> void:
	var occupied := int(item.occupiedSeats)
	var max_seats := int(item.maxSeats)
	entry_id = int(item.tableId)
	entry_gen += 1
	var gen := entry_gen
	entry_title.text = item.name
	Rows.clear(entry_sub)
	entry_sub.add_child(RoomWidgets.count_label(occupied, max_seats))
	entry_sub.add_child(RoomWidgets.badge(occupied, max_seats))
	if item.handInProgress:
		entry_sub.add_child(RoomWidgets.in_progress_pill())
	entry_info.text = ""
	entry_error.hide()
	entry_spin.hide()
	entry_post_blind.button_pressed = false
	entry_join.disabled = true
	entry_join.text = "대기 참가" if occupied >= max_seats else "게임 참가" # 가득 찬 방도 서버가 대기열에 넣는다(SeatRequester.kt:68, AdmitJoinRequestService.kt:47)
	create_panel.hide()
	entry_panel.show()
	create_overlay.show()
	entry_watch.grab_focus()
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/tables/%d/buy-in" % entry_id)
	if gen != entry_gen or not entry_panel.visible:
		return
	if not r.ok:
		if r.error == "TABLE_NOT_FOUND": # 그새 닫힌 방
			_close_overlay()
			await _load(pager.page)
			_show_error(r.error)
			return
		entry_error.text = ErrorText.of(r.error)
		entry_error.show()
		return
	entry_min = int(r.data.minBuyIn)
	entry_max = int(r.data.maxBuyIn)
	entry_wallet = int(r.data.walletBalance)
	entry_info.text = "바이인 %s ~ %s · 지갑 %s" % [Format.comma(entry_min), Format.comma(entry_max), Format.comma(entry_wallet)]
	var blocked: String = Rules.buy_in_blocked_text(r.data)
	if blocked != "":
		entry_error.text = blocked
		entry_error.show()
		return
	var top := mini(entry_max, entry_wallet / Rules.CHIP_UNIT * Rules.CHIP_UNIT)
	entry_spin.min_value = entry_min
	entry_spin.max_value = top
	entry_spin.step = Rules.CHIP_UNIT
	entry_spin.value = top
	entry_spin.show()
	entry_join.disabled = false
	if entry_watch.has_focus(): # 처음엔 게임 참가가 막혀 있어 관전하기에 포커스가 간다 — 참가가 열리면 옮긴다
		entry_join.grab_focus()


func _on_entry_join() -> void:
	var buy_in := int(entry_spin.value)
	var invalid := Rules.buy_in(buy_in, entry_min, entry_max, entry_wallet)
	if invalid != "":
		entry_error.text = ErrorText.of(invalid)
		entry_error.show()
		return
	enter(entry_id, true, buy_in, entry_post_blind.button_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if create_overlay.visible and event.is_action_pressed("ui_cancel"):
		_close_overlay()
		get_viewport().set_input_as_handled()


func _is_phone() -> bool:
	return size.x < PHONE_WIDTH


## 화면 폭에 맞춰 목록 여백·카드 방향·바닥 버튼·만들기 패널을 다시 잡는다
func _fit() -> void:
	var side := maxf(16.0, (size.x - MAX_WIDTH) / 2.0)
	rows_margin.add_theme_constant_override("margin_left", int(side))
	rows_margin.add_theme_constant_override("margin_right", int(side))
	open_create_button.custom_minimum_size.x = minf(360.0, size.x - 32.0)
	var sheet := _is_phone()
	for panel in [create_panel, entry_panel]:
		panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE if sheet else Control.PRESET_CENTER)
		var half := 0.0 if sheet else 210.0 # 데스크톱은 폭 420, 높이는 내용만큼
		panel.offset_left = -half
		panel.offset_right = half
		panel.offset_top = 0.0
		panel.offset_bottom = 0.0
		panel.grow_vertical = Control.GROW_DIRECTION_BEGIN if sheet else Control.GROW_DIRECTION_BOTH
		if sheet: # 바닥 시트: 위 모서리만 둥글게
			var sb: StyleBoxFlat = panel.get_theme_stylebox("panel").duplicate()
			sb.corner_radius_bottom_left = 0
			sb.corner_radius_bottom_right = 0
			panel.add_theme_stylebox_override("panel", sb)
		else:
			panel.remove_theme_stylebox_override("panel")


func _show_seat_error() -> void:
	if seat_error != "":
		_show_error(seat_error)


func enter(id: int, join := false, buy_in := 0, post_blind := false) -> void:
	var table_script = preload("res://games/holdem/table.gd")
	table_script.table_id = id
	table_script.auto_join = join
	table_script.auto_join_buy_in = buy_in
	table_script.auto_join_post_blind = post_blind
	get_tree().change_scene_to_file("res://games/holdem/table.tscn")


func _load(page: int) -> void:
	refresh_button.disabled = true
	var gen := pager.begin()
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/tables?page=%d&size=%d" % [page, PAGE_SIZE])
	if not pager.is_stale(gen):
		refresh_button.disabled = false # 낡은 응답이 뒤 요청의 잠금을 풀지 않게
	if not await pager.accept(gen, page, r, _show_error):
		return
	error_label.hide()
	_build_rows(Api.page_items(r.data))
	pager.update()


func _build_rows(items: Array) -> void:
	Rows.clear(rows)
	room_items = items
	empty_box.visible = items.is_empty()
	for item in items:
		var card := RoomWidgets.card_button(item.name, int(item.occupiedSeats), int(item.maxSeats), item.handInProgress)
		card.pressed.connect(_open_entry.bind(item))
		rows.add_child(card)


## QA 브리지(core/qa_bridge.gd)용. card_key = 그 방 카드 버튼의 브리지 키
func qa_state() -> Dictionary:
	var out := []
	for i in room_items.size():
		var it: Dictionary = room_items[i]
		out.append({"table_id": int(it.tableId), "name": it.name, "occupied": int(it.occupiedSeats), "max": int(it.maxSeats), "in_progress": it.handInProgress, "card_key": "Rows/%d" % i})
	return {"rooms": out}


func _on_create() -> void:
	if create_button.disabled:
		return
	var invalid := Rules.table_name(name_edit.text)
	if invalid != "":
		_show_create_error(invalid)
		return
	var buy_in := int(buy_in_spin.value)
	invalid = Rules.buy_in(buy_in, buy_in_min, buy_in_max, buy_in_wallet)
	if invalid != "":
		_show_create_error(invalid)
		return
	pending_name = name_edit.text
	pending_buy_in = buy_in
	var table_script = preload("res://games/holdem/table.gd")
	table_script.table_id = 0
	table_script.auto_join = false
	table_script.create_name = name_edit.text
	table_script.create_buy_in = buy_in
	table_script.creating = true
	get_tree().change_scene_to_file("res://games/holdem/table.tscn")
