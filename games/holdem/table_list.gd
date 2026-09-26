extends Control
## Holdem table list: browse pages, create a table.

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

var current_page := 0
var total_pages := 0
var _creating := false


func _ready() -> void:
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	refresh_button.pressed.connect(func() -> void: _load(current_page))
	prev_button.pressed.connect(func() -> void: _load(current_page - 1))
	next_button.pressed.connect(func() -> void: _load(current_page + 1))
	create_button.pressed.connect(_on_create)
	name_edit.text_submitted.connect(func(_text: String) -> void: _on_create())
	_load(0)


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
	for child in rows.get_children():
		child.queue_free()
	empty_label.visible = items.is_empty()
	for item in items:
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = item.name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(name_label)
		var seats_label := Label.new()
		seats_label.text = "%d/%d명" % [item.occupiedSeats, item.maxSeats]
		row.add_child(seats_label)
		rows.add_child(row)


func _update_pager() -> void:
	pager.visible = total_pages > 1
	page_label.text = "%d / %d" % [current_page + 1, total_pages]
	prev_button.disabled = current_page <= 0
	next_button.disabled = current_page >= total_pages - 1


func _on_create() -> void:
	if _creating:
		return
	_creating = true
	create_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/holdem/tables", {"name": name_edit.text})
	_creating = false
	create_button.disabled = false
	if r.ok:
		error_label.hide()
		name_edit.text = ""
		_load(current_page)
	else:
		error_label.text = ErrorText.of(r.error)
		error_label.show()
