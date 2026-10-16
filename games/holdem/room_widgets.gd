extends RefCounted
## 방 카드 조각: 눌러서 입장하는 카드 버튼과 상태 배지. 홀덤 방 목록 전용.

const MUTED := Color("6B7584")


## 0명 대기 중(흐림) · 1~8명 빈 자리(강조) · 가득 참(회색)
static func badge(occupied: int, max_seats: int) -> PanelContainer:
	var pill := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("242C38")
	sb.set_corner_radius_all(999)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	pill.add_theme_stylebox_override("panel", sb)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 14)
	if occupied <= 0:
		l.text = "대기 중"
		l.theme_type_variation = &"LabelHint"
	elif occupied < max_seats:
		l.text = "빈 자리"
		l.theme_type_variation = &"LabelAccent"
	else:
		l.text = "가득 참"
		l.add_theme_color_override("font_color", MUTED)
	pill.add_child(l)
	return pill


## 카드 한 장 = 평평한 Button(호버·눌림·포커스 피드백) + 이름·배지·인원. 눌림은 호출자가 연결한다
static func card_button(room_name: String, occupied: int, max_seats: int) -> Button:
	var card := Button.new()
	card.custom_minimum_size.y = 64
	card.focus_mode = Control.FOCUS_ALL
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(12)
		sb.set_border_width_all(1)
		sb.bg_color = {"normal": Color("1B212B"), "hover": Color("242C38"), "pressed": Color("12161C"), "focus": Color("1B212B")}[state]
		sb.border_color = Color("E6B94A") if state == "focus" else Color("323C4A")
		card.add_theme_stylebox_override(state, sb)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 16
	row.offset_right = -16
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_label := Rows.label(room_name, true)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)
	row.add_child(badge(occupied, max_seats))
	row.add_child(count_label(occupied, max_seats))
	for c in row.get_children():
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for g in c.get_children():
			g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(row)
	return card


static func count_label(occupied: int, max_seats: int) -> Label:
	var count := Label.new()
	count.text = "%d/%d명" % [occupied, max_seats]
	count.theme_type_variation = &"LabelHint"
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return count
