extends Control
## Holdem table list: browse pages, create a table.

const Rules := preload("res://games/holdem/rules.gd")
const PAGE_SIZE := 20

@onready var back_button: Button = %BackButton
@onready var refresh_button: Button = %RefreshButton
@onready var name_edit: LineEdit = %NameEdit
@onready var buy_in_spin: SpinBox = %BuyInSpin
@onready var buy_in_info: Label = %BuyInInfo
@onready var create_button: Button = %CreateButton
@onready var error_label: Label = %ErrorLabel
@onready var rows: VBoxContainer = %Rows
@onready var empty_label: Label = %EmptyLabel
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
var buy_in_min := Rules.DEFAULT_MIN_BUY_IN # buy-in GET 응답. 못 받으면 기본 범위(서버보다 엄격하지 않게)
var buy_in_max := Rules.DEFAULT_MAX_BUY_IN
var buy_in_wallet := -1 # -1 = 모름
var seat_error := "" # /me/seat 실패 errorCode. 204·200 이면 빈 문자열


func _ready() -> void:
	pager = Pager.new(pager_box, prev_button, page_label, next_button, _load)
	create_button.disabled = true # /me/seat 확인이 끝나기 전에는 만들 수 없다
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	refresh_button.pressed.connect(func() -> void:
		await _load(pager.page)
		await _check_seat()
		await _load_buy_in()
		_show_seat_error())
	create_button.pressed.connect(_on_create)
	name_edit.text_submitted.connect(func(_text: String) -> void: _on_create())
	if await _check_seat():
		return
	await _load_buy_in()
	await _load(0)
	# 목록을 다 읽은 뒤에 띄워야 _load 의 error_label.hide() 에 지워지지 않는다
	if pending_error != "":
		name_edit.text = pending_name
		buy_in_spin.value = pending_buy_in # 범위 밖이면 SpinBox 가 범위로 맞춘다
	var msgs: Array[String] = []
	if seat_error != "":
		msgs.append(ErrorText.of(seat_error))
	if pending_error != "":
		msgs.append(ErrorText.of(pending_error))
	if not msgs.is_empty():
		error_label.text = "\n".join(msgs)
		error_label.show()
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
	create_button.disabled = not seat_ok or buy_in_blocked


## 방 생성 바이인 범위·지갑을 GET /api/holdem/buy-in 으로 읽는다. 실패하면 기본 범위로 둔다
func _load_buy_in() -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/buy-in")
	if not r.ok: # 범위를 모르면 기본 범위로 두고 서버가 판단하게 한다
		buy_in_info.text = ""
		return
	buy_in_min = int(r.data.minBuyIn)
	buy_in_max = int(r.data.maxBuyIn)
	buy_in_wallet = int(r.data.walletBalance)
	buy_in_info.text = "바이인 %s ~ %s · 지갑 %s" % [Format.comma(buy_in_min), Format.comma(buy_in_max), Format.comma(buy_in_wallet)]
	var blocked: String = Rules.buy_in_blocked_text(r.data)
	buy_in_blocked = blocked != ""
	if buy_in_blocked:
		buy_in_info.text += "\n" + blocked
	else:
		buy_in_spin.min_value = buy_in_min
		buy_in_spin.max_value = mini(buy_in_max, buy_in_wallet / Rules.CHIP_UNIT * Rules.CHIP_UNIT)
		buy_in_spin.value = buy_in_spin.max_value
	_update_create_button()


func _show_seat_error() -> void:
	if seat_error != "":
		error_label.text = ErrorText.of(seat_error)
		error_label.show()


func enter(id: int, join := false) -> void:
	var table_script = preload("res://games/holdem/table.gd")
	table_script.table_id = id
	table_script.auto_join = join
	get_tree().change_scene_to_file("res://games/holdem/table.tscn")


func _load(page: int) -> void:
	refresh_button.disabled = true
	var gen := pager.begin()
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/tables?page=%d&size=%d" % [page, PAGE_SIZE])
	if not pager.is_stale(gen):
		refresh_button.disabled = false # 낡은 응답이 뒤 요청의 잠금을 풀지 않게
	if not await pager.accept(gen, page, r, func(code: String) -> void:
			error_label.text = ErrorText.of(code)
			error_label.show()):
		return
	error_label.hide()
	_build_rows(Api.page_items(r.data))
	pager.update()


func _build_rows(items: Array) -> void:
	Rows.clear(rows)
	empty_label.visible = items.is_empty()
	for item in items:
		var row := HBoxContainer.new()
		row.add_child(Rows.label(item.name, true))
		var seats_label := Label.new()
		seats_label.text = "%d/%d명" % [item.occupiedSeats, item.maxSeats]
		row.add_child(seats_label)
		var watch_button := Button.new()
		watch_button.text = "관전"
		watch_button.pressed.connect(enter.bind(item.tableId, false))
		row.add_child(watch_button)
		var join_button := Button.new()
		join_button.text = "참가"
		join_button.pressed.connect(enter.bind(item.tableId, true))
		row.add_child(join_button)
		rows.add_child(row)


func _on_create() -> void:
	if create_button.disabled:
		return
	var invalid := Rules.table_name(name_edit.text)
	if invalid != "":
		error_label.text = ErrorText.of(invalid)
		error_label.show()
		return
	var buy_in := int(buy_in_spin.value)
	invalid = Rules.buy_in(buy_in, buy_in_min, buy_in_max, buy_in_wallet)
	if invalid != "":
		error_label.text = ErrorText.of(invalid)
		error_label.show()
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
