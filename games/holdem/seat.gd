extends Control
## 홀덤 좌석 위젯. table.gd 가 무엇을 보일지 정하고, 여기는 어떻게 그릴지만 안다. 위치는 table.gd 가 절대 좌표로 정한다.

const Cards := preload("res://games/holdem/cards.gd")

const SURFACE := Color(0.1059, 0.1294, 0.1686, 0.92)
const SURFACE_RAISED := Color(0.1412, 0.1725, 0.2196)
const BORDER := Color(0.1961, 0.2353, 0.2902)
const ACCENT := Color(0.9020, 0.7255, 0.2902)
const DANGER := Color(0.8980, 0.2824, 0.3020)
const TEXT := Color(0.9098, 0.9255, 0.9490)
const TEXT_MUTED := Color(0.6039, 0.6431, 0.6980)
const ON_ACCENT := Color(0.1020, 0.0784, 0.0196)
const AVATAR_COLORS := [Color("5B7DB1"), Color("7A5BB1"), Color("B15B7A"), Color("B1895B"), Color("4F9E7E"), Color("5B9EB1")]
const TURN_SECONDS := 30.0
const WARN_SECONDS := 5.0

var compact := false
var empty := true
var is_me := false
var to_act := false
var badge_side := 0 # 배지 줄이 캡슐보다 넓으면 넘치는 쪽: 1 = 오른쪽, -1 = 왼쪽, 0 = 양쪽(table.gd 가 화면 가운데 반대쪽으로 정한다)
var badge_bounds := Vector2(-INF, INF) # 배지 줄이 있어야 할 로컬 x 범위(펠트 영역 안)
var timer_left := -1.0 # 남은 초. 음수면 숨김
var shown_codes: Array = [] # 좌석 위에 그린 카드(테스트가 본다)
var _avatar_color: Color = AVATAR_COLORS[0]
var _badge_count := 0
var _style := StyleBoxFlat.new()

@onready var card_rects: Array = [%CardA, %CardB]
@onready var initial: Label = %Initial
@onready var name_label: Label = %NameLabel
@onready var stack_label: Label = %StackLabel
@onready var empty_label: Label = %EmptyLabel
@onready var badge_all_in: Label = %BadgeAllIn
@onready var badge_presence: Label = %BadgePresence
@onready var badge_leave: Label = %BadgeLeave
@onready var hand_pill: Label = %HandPill
@onready var payout_label: Label = %Payout


static func capsule_size(is_compact: bool) -> Vector2:
	return Vector2(116, 54) if is_compact else Vector2(150, 60)


static func other_card_size(is_compact: bool) -> Vector2:
	return Vector2(28, 38) if is_compact else Vector2(36, 49)


static func hero_card_size(is_compact: bool) -> Vector2:
	return Vector2(56, 76) if is_compact else Vector2(72, 98)


func _ready() -> void:
	_pill(badge_all_in, ACCENT, ON_ACCENT)
	_pill(badge_presence, Color(0.33, 0.36, 0.40), TEXT)
	_pill(badge_leave, SURFACE_RAISED, TEXT_MUTED, BORDER)
	_pill(hand_pill, SURFACE_RAISED, TEXT, ACCENT)
	payout_label.add_theme_color_override("font_color", ACCENT)
	payout_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	payout_label.add_theme_constant_override("outline_size", 6)
	name_label.add_theme_color_override("font_color", TEXT_MUTED)
	empty_label.add_theme_color_override("font_color", TEXT_MUTED)
	initial.add_theme_color_override("font_color", Color.WHITE)
	set_compact(false)
	show_empty(0)


func set_compact(is_compact: bool) -> void:
	compact = is_compact
	size = capsule_size(is_compact)
	var h := size.y
	var d := h - 14.0
	initial.position = Vector2(7, 7)
	initial.size = Vector2(d, d)
	initial.add_theme_font_size_override("font_size", 16 if is_compact else 20)
	var x0 := h
	name_label.add_theme_font_size_override("font_size", 12 if is_compact else 14)
	stack_label.add_theme_font_size_override("font_size", 15 if is_compact else 17)
	name_label.position = Vector2(x0, h / 2.0 - (19 if is_compact else 21))
	name_label.size = Vector2(size.x - x0 - 10, 20)
	stack_label.position = Vector2(x0, h / 2.0 - 1)
	stack_label.size = Vector2(size.x - x0 - 10, 22)
	var fs := 10 if is_compact else 11
	for l: Label in [badge_all_in, badge_presence, badge_leave, hand_pill]:
		l.add_theme_font_size_override("font_size", fs)
	payout_label.add_theme_font_size_override("font_size", 15 if is_compact else 17)
	var er := _empty_rect()
	empty_label.position = er.position
	empty_label.size = er.size
	empty_label.add_theme_font_size_override("font_size", 12 if is_compact else 13)
	queue_redraw()


func _empty_rect() -> Rect2:
	var s := Vector2(size.x * 0.62, size.y * 0.55)
	return Rect2((size - s) / 2.0, s)


func _pill(l: Label, bg: Color, fg: Color, border := Color(0, 0, 0, 0)) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	if border.a > 0:
		sb.set_border_width_all(1)
		sb.border_color = border
	l.add_theme_stylebox_override("normal", sb)
	l.add_theme_color_override("font_color", fg)
	l.hide()


## 빈 자리. 정산 때 일어선 승자가 보여 준 패(cards)·족보가 있으면 그대로 그린다
func show_empty(seat_no: int, cards: Array = [], category := "") -> void:
	empty = true
	is_me = false
	to_act = false
	modulate = Color.WHITE
	for l: Control in [initial, name_label, stack_label, badge_all_in, badge_presence, badge_leave, payout_label]:
		l.hide()
	_badge_count = 0
	empty_label.text = "빈 자리 %d" % seat_no
	empty_label.show()
	_set_cards(cards)
	_set_pill(category)
	queue_redraw()


## info: nickname, stack, is_me, to_act, folded, all_in, presence_text, leave_reserved, leave_text(optional), cards, category, payout
func show_player(info: Dictionary) -> void:
	empty = false
	is_me = info.is_me
	to_act = info.to_act
	empty_label.hide()
	var nick: String = info.nickname
	_avatar_color = AVATAR_COLORS[nick.hash() % AVATAR_COLORS.size()]
	initial.text = nick.substr(0, 1).to_upper()
	name_label.text = nick
	stack_label.text = Format.comma(info.stack)
	for l: Control in [initial, name_label, stack_label]:
		l.show()
	var disconnected: bool = info.presence_text != ""
	modulate = Color(1, 1, 1, 0.45) if info.folded else (Color(0.72, 0.72, 0.72) if disconnected else Color.WHITE)
	badge_all_in.visible = info.all_in
	badge_presence.text = info.presence_text
	badge_presence.visible = disconnected
	badge_leave.text = info.get("leave_text", "일어서기 예약") # 서버는 예약 종류를 구분하지 않는다 — 내 좌석만 로컬 의도(관전/나가기)를 안다
	badge_leave.visible = info.leave_reserved
	_place_badges()
	_set_cards(info.cards) # 내 카드는 table.gd 가 크게 따로 그린다 — 여기엔 빈 배열이 온다
	_set_pill(info.category)
	payout_label.text = "+%s" % Format.comma(info.payout)
	payout_label.visible = info.payout > 0
	payout_label.reset_size()
	# 위는 작은 카드·내 카드가 차지하므로 캡슐 아래 가운데(배지 줄 바로 밑)에 둔다
	payout_label.position = Vector2((size.x - payout_label.size.x) / 2.0, size.y + (12.0 if _badge_count > 0 else 4.0))
	queue_redraw()


func set_timer(left: float) -> void:
	if not is_equal_approx(left, timer_left):
		timer_left = left
		_place_badges()
		queue_redraw()


func _set_cards(codes: Array) -> void:
	shown_codes = codes
	var cs := other_card_size(compact)
	var gap := 3.0
	var x0 := (size.x - (2.0 * cs.x + gap)) / 2.0
	for i in 2:
		var r: TextureRect = card_rects[i]
		if i < codes.size():
			r.texture = load(Cards.texture_path(codes[i]))
			r.size = cs
			r.position = Vector2(x0 + i * (cs.x + gap), -cs.y - 2)
			r.show()
		else:
			r.hide()


func _set_pill(category: String) -> void:
	hand_pill.text = category
	hand_pill.visible = category != ""
	hand_pill.reset_size()
	hand_pill.position = Vector2((size.x - hand_pill.size.x) / 2.0, -hand_pill.size.y / 2.0 - 2)


func _place_badges() -> void:
	var shown: Array = []
	for l: Label in [badge_all_in, badge_presence, badge_leave]:
		if l.visible:
			l.reset_size()
			shown.append(l)
	_badge_count = shown.size()
	var total := 4.0 * maxi(shown.size() - 1, 0)
	for l: Label in shown:
		total += l.size.x
	var x := (size.x - total) / 2.0
	if total > size.x and badge_side != 0:
		x = 0.0 if badge_side > 0 else size.x - total
	x = clampf(x, badge_bounds.x, maxf(badge_bounds.x, badge_bounds.y - total))
	for l: Label in shown:
		l.position = Vector2(x, size.y - 6)
		x += l.size.x + 4.0


func _draw() -> void:
	if empty:
		var er := _empty_rect()
		_style.bg_color = Color(SURFACE, 0.4)
		_style.set_border_width_all(1)
		_style.border_color = Color(BORDER, 0.6)
		_style.set_corner_radius_all(int(er.size.y / 2.0))
		_style.draw(get_canvas_item(), er)
		return
	_style.bg_color = SURFACE
	_style.set_border_width_all(3 if to_act else 2)
	_style.border_color = ACCENT if to_act else (Color(ACCENT, 0.55) if is_me else BORDER)
	_style.set_corner_radius_all(int(size.y / 2.0))
	_style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
	draw_circle(Vector2(size.y / 2.0, size.y / 2.0), (size.y - 14.0) / 2.0, _avatar_color)
	if timer_left >= 0.0:
		var w := size.x - 20.0
		var y := size.y + (12.0 if _badge_count > 0 else 4.0)
		draw_rect(Rect2(10, y, w, 4), BORDER)
		var frac := clampf(timer_left / TURN_SECONDS, 0.0, 1.0)
		draw_rect(Rect2(10, y, w * frac, 4), DANGER if timer_left < WARN_SECONDS else ACCENT)
