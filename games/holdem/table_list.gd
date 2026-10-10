extends Control
## Holdem table list: browse pages, create a table.

const Rules := preload("res://games/holdem/rules.gd")
const PAGE_SIZE := 20

@onready var back_button: Button = %BackButton
@onready var refresh_button: Button = %RefreshButton
@onready var name_edit: LineEdit = %NameEdit
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

var pager: Pager
var seat_error := "" # /me/seat 실패 errorCode. 204·200 이면 빈 문자열


func _ready() -> void:
	pager = Pager.new(pager_box, prev_button, page_label, next_button)
	create_button.disabled = true # /me/seat 확인이 끝나기 전에는 만들 수 없다
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	refresh_button.pressed.connect(func() -> void:
		await _load(pager.page)
		await _check_seat()
		_show_seat_error())
	prev_button.pressed.connect(func() -> void: _load(pager.page - 1))
	next_button.pressed.connect(func() -> void: _load(pager.page + 1))
	create_button.pressed.connect(_on_create)
	name_edit.text_submitted.connect(func(_text: String) -> void: _on_create())
	if await _check_seat():
		return
	await _load(0)
	# 목록을 다 읽은 뒤에 띄워야 _load 의 error_label.hide() 에 지워지지 않는다
	if seat_error != "":
		_show_seat_error()
	elif pending_error != "":
		error_label.text = ErrorText.of(pending_error)
		error_label.show()
		name_edit.text = pending_name
	pending_error = ""
	pending_name = ""


## /me/seat 확인. 이미 앉아 있으면 테이블로 가고 true. 204 일 때만 만들기를 풀고, 그 외(0·5xx 등)는 막아 두고 errorCode 를 seat_error 에 담는다
func _check_seat() -> bool:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/me/seat")
	if r.status == 200:
		enter(r.data.tableId)
		pending_error = ""
		pending_name = ""
		return true
	create_button.disabled = r.status != 204
	seat_error = "" if r.status == 204 else r.error
	return false


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
	refresh_button.disabled = false
	if not await pager.accept(gen, page, r, _load):
		if not r.ok and not pager.is_stale(gen):
			error_label.text = ErrorText.of(r.error)
			error_label.show()
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
	pending_name = name_edit.text
	var table_script = preload("res://games/holdem/table.gd")
	table_script.table_id = 0
	table_script.auto_join = false
	table_script.create_name = name_edit.text
	table_script.creating = true
	get_tree().change_scene_to_file("res://games/holdem/table.tscn")
