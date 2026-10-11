extends Control
## 홀덤 핸드 기록. admin=true 면 전체 기록(회원·테이블 필터), 아니면 내가 친 핸드.

const Cards := preload("res://games/holdem/cards.gd")
const PAGE_SIZE := 20

@export var admin := false

@onready var back_button: Button = %BackButton
@onready var refresh_button: Button = %RefreshButton
@onready var error_label: Label = %ErrorLabel
@onready var filter_box: HBoxContainer = %Filter
@onready var user_id_edit: LineEdit = %UserIdEdit
@onready var table_id_edit: LineEdit = %TableIdEdit
@onready var search_button: Button = %SearchButton
@onready var rows: VBoxContainer = %Rows
@onready var empty_label: Label = %EmptyLabel
@onready var pager_box: HBoxContainer = %Pager
@onready var prev_button: Button = %PrevButton
@onready var page_label: Label = %PageLabel
@onready var next_button: Button = %NextButton

var pager: Pager
var user_filter := "" # 검색 때 잡아 둔 필터 — 페이지를 넘겨도 유지한다
var table_filter := ""


func _ready() -> void:
	pager = Pager.new(pager_box, prev_button, page_label, next_button, _load)
	filter_box.visible = admin
	back_button.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://admin/admin.tscn" if admin else "res://games/holdem/table_list.tscn"))
	refresh_button.pressed.connect(func() -> void: _load(pager.page))
	search_button.pressed.connect(_on_search)
	user_id_edit.text_submitted.connect(func(_t: String) -> void: _on_search())
	table_id_edit.text_submitted.connect(func(_t: String) -> void: _on_search())
	_load(0)


func _on_search() -> void:
	var u := user_id_edit.text.strip_edges()
	var t := table_id_edit.text.strip_edges()
	# 서버: holdem/presentation/rest/HoldemHandHistoryController.kt AdminHoldemHandHistoryController `@RequestParam userId: Long?`
	# 숫자가 아니면 400 REQUEST_INVALID. 0·음수는 서버가 받으므로 막지 않는다
	if (u != "" and not u.is_valid_int()) or (t != "" and not t.is_valid_int()):
		error_label.text = ErrorText.of("REQUEST_INVALID")
		error_label.show()
		return
	user_filter = "" if u == "" else str(int(u))
	table_filter = "" if t == "" else str(int(t))
	_load(0)


func _load(page: int) -> void:
	refresh_button.disabled = true
	var gen := pager.begin()
	var path := "/api/holdem/me/hands?page=%d&size=%d" % [page, PAGE_SIZE]
	if admin:
		path = "/api/admin/holdem/hands?page=%d&size=%d" % [page, PAGE_SIZE]
		if user_filter != "":
			path += "&userId=" + user_filter
		if table_filter != "":
			path += "&tableId=" + table_filter
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, path)
	if not pager.is_stale(gen):
		refresh_button.disabled = false # 낡은 응답이 뒤 요청의 잠금을 풀지 않게
	if not await pager.accept(gen, page, r, func(code: String) -> void:
			error_label.text = ErrorText.of(code)
			error_label.show()):
		return
	error_label.hide()
	_build_rows(Api.page_items(r.data))
	pager.update()


## 좌석 한 줄. 예: "좌석 3 (D) 나  +1,200". 순손익 = endingStack - startingStack
static func player_text(p: Dictionary, button_seat: int, me: int, admin: bool) -> String:
	var seat := int(p.seatNo)
	var uid := int(p.userId)
	var s := "좌석 %d" % seat
	if seat == button_seat:
		s += " (D)"
	if admin:
		s += " 회원 #%d" % uid
	elif uid == me:
		s += " 나"
	var net := int(p.endingStack) - int(p.startingStack)
	return "%s  %s%s" % [s, "+" if net > 0 else "", Format.comma(net)]


func _build_rows(items: Array) -> void:
	Rows.clear(rows)
	empty_label.visible = items.is_empty()
	for hand in items:
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var box := VBoxContainer.new()
		panel.add_child(box)
		box.add_child(Rows.label("%s · 테이블 #%d · 핸드 #%d" % [Format.time(hand.endedAt), int(hand.tableId), int(hand.handId)]))
		if hand.board.is_empty():
			box.add_child(Rows.label("보드 없음"))
		else:
			box.add_child(_card_row(hand.board))
		for p in hand.players:
			var line := HBoxContainer.new()
			line.add_child(Rows.label(player_text(p, int(hand.buttonSeatNo), Api.user_id if not admin else -1, admin), true))
			if p.holeCards != null:
				line.add_child(_card_row(p.holeCards))
			else:
				line.add_child(Rows.label("비공개"))
			box.add_child(line)
		rows.add_child(panel)


func _card_row(codes: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	for code in codes:
		var rect := TextureRect.new()
		rect.custom_minimum_size = Vector2(30, 41)
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.texture = load(Cards.texture_path(code))
		row.add_child(rect)
	return row
