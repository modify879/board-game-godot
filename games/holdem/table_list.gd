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
@onready var pager: HBoxContainer = %Pager
@onready var prev_button: Button = %PrevButton
@onready var page_label: Label = %PageLabel
@onready var next_button: Button = %NextButton

static var pending_error := "" # 테이블 화면이 방 만들기에 실패하면 errorCode 를 넘긴다
static var pending_name := "" # 실패해 돌아왔을 때 입력했던 방 이름을 되살린다

var current_page := 0
var total_pages := 0


func _ready() -> void:
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	refresh_button.pressed.connect(func() -> void: _load(current_page))
	prev_button.pressed.connect(func() -> void: _load(current_page - 1))
	next_button.pressed.connect(func() -> void: _load(current_page + 1))
	create_button.pressed.connect(_on_create)
	name_edit.text_submitted.connect(func(_text: String) -> void: _on_create())
	var seat_r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/me/seat")
	if seat_r.status == 200:
		enter(seat_r.data.tableId)
		pending_error = ""
		pending_name = ""
		return
	await _load(0)
	# 목록을 다 읽은 뒤에 띄워야 _load 의 error_label.hide() 에 지워지지 않는다
	if pending_error != "":
		error_label.text = ErrorText.of(pending_error)
		error_label.show()
		name_edit.text = pending_name
	pending_error = ""
	pending_name = ""


func enter(id: int, join := false) -> void:
	var table_script = preload("res://games/holdem/table.gd")
	table_script.table_id = id
	table_script.auto_join = join
	get_tree().change_scene_to_file("res://games/holdem/table.tscn")


func _load(page: int) -> void:
	refresh_button.disabled = true
	prev_button.disabled = true
	next_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/holdem/tables?page=%d&size=%d" % [page, PAGE_SIZE])
	refresh_button.disabled = false
	if not r.ok:
		error_label.text = ErrorText.of(r.error)
		error_label.show()
		_update_pager()
		return
	var page_info: Dictionary = r.data.page
	var new_total_pages: int = page_info.totalPages
	if page >= new_total_pages and new_total_pages > 0:
		_load(new_total_pages - 1)
		return
	error_label.hide()
	current_page = page_info.number
	total_pages = new_total_pages
	_build_rows(Api.page_items(r.data))
	_update_pager()


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


func _update_pager() -> void:
	pager.visible = total_pages > 1
	page_label.text = "%d / %d" % [current_page + 1, total_pages]
	prev_button.disabled = current_page <= 0
	next_button.disabled = current_page >= total_pages - 1


func _on_create() -> void:
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
