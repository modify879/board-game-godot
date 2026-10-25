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
## 행동 배지 바탕색(문구별). 폴드 회색·체크 파랑·콜 초록·레이즈 주황
const ACTION_COLORS := {"폴드": Color("5F6672"), "체크": Color("3B7DD8"), "콜": Color("2E9E5B"), "레이즈": Color("E07B1F")}
const AVATAR_COLORS := [Color("8FC9DC"), Color("93BEE6"), Color("A3B5EA"), Color("B9A8E6"), Color("E6A8C4"), Color("9FD6C2")]
const WARN_SECONDS := 5.0
const PHONE_TOKEN := 38.0 # 폰 행동 토큰 지름

var compact := false
var desk := false # 데스크톱 패널 모양(table.gd 가 set_desktop 으로 켠다). false 면 폰 캡슐
var avatar_left := true # desk 일 때 아바타 열이 왼쪽(바깥쪽이 왼쪽인 좌석)인지
var hero_slot := false # desk 일 때 아래 가운데 큰 패널
var k := 1.0 # desk 크기 배율
var token_center := Vector2.ZERO # 행동 토큰(BadgeAction) 중심 — 좌석 로컬 좌표, table.gd 가 정한다(데스크톱·폰 모두)
var empty := true
var is_me := false
var to_act := false
var badge_side := 0 # 배지 줄이 캡슐보다 넓으면 넘치는 쪽: 1 = 오른쪽, -1 = 왼쪽, 0 = 양쪽(table.gd 가 화면 가운데 반대쪽으로 정한다)
var badge_bounds := Vector2(-INF, INF) # 배지 줄이 있어야 할 로컬 x 범위(펠트 영역 안)
var timer_left := -1.0 # 남은 초. 음수면 숨김
var timer_total := 0.0 # 이번 턴 타이머 전체 길이(초) — 서버 turnTimeoutMs
var shown_codes: Array = [] # 좌석 위에 그린 카드(테스트가 본다)
var _avatar_color: Color = AVATAR_COLORS[0]
var _avatar_c := Vector2.ZERO # desk 아바타 원 중심·반지름(로컬)
var _avatar_r := 0.0
var _badge_count := 0
var _style := StyleBoxFlat.new()
var _dim := Color.WHITE # desk 에서 폴드·끊김 어둡게(패널 바탕·글자). 폰은 노드 modulate 를 쓴다
var _stack_fs := 17
var _all_in_style: StyleBox

@onready var card_rects: Array = [%CardA, %CardB]
@onready var initial: Label = %Initial
@onready var name_label: Label = %NameLabel
@onready var stack_label: Label = %StackLabel
@onready var empty_label: Label = %EmptyLabel
@onready var badge_all_in: Label = %BadgeAllIn
@onready var badge_presence: Label = %BadgePresence
@onready var badge_leave: Label = %BadgeLeave
@onready var badge_action: Label = %BadgeAction
@onready var hand_pill: Label = %HandPill
@onready var payout_label: Label = %Payout
@onready var fold_label: Label = %FoldLabel
@onready var timer_label: Label = %TimerLabel
@onready var hand_rank: Label = %HandRank


static func capsule_size(is_compact: bool) -> Vector2:
	return Vector2(116, 54) if is_compact else Vector2(150, 60)


static func other_card_size(is_compact: bool) -> Vector2:
	return Vector2(28, 38) if is_compact else Vector2(36, 49)


static func hero_card_size(is_compact: bool) -> Vector2:
	return Vector2(56, 76) if is_compact else Vector2(72, 98)


## 데스크톱 패널 크기(설계 좌표 × 배율 k). 아래 가운데 내 자리는 카드가 크다
static func panel_size(hero: bool, kk: float) -> Vector2:
	return (Vector2(360, 150) if hero else Vector2(220, 90)) * kk


## 데스크톱 좌석 카드 한 장 크기. 내 자리는 큰 카드(내 홀카드 MyCards 와 같다)
static func desk_card_size(hero: bool, kk: float) -> Vector2:
	return (Vector2(62, 84) if hero else Vector2(40, 54)) * kk


## 데스크톱 패널 안의 두 열(로컬 좌표, 배율 적용 전 설계 크기 × kk): avatar(아바타·닉네임) / cards(카드·스택). 아바타는 바깥쪽
static func desk_columns(hero: bool, left: bool, kk: float) -> Dictionary:
	var w := panel_size(hero, 1.0)
	var aw := 90.0 if hero else 80.0
	var m := 8.0 if hero else 6.0
	var av := Rect2(m if left else w.x - m - aw, 0, aw, w.y)
	var cd := Rect2(m + aw + 4.0 if left else m, 0, w.x - 2.0 * m - aw - 4.0, w.y)
	return {"avatar": Rect2(av.position * kk, av.size * kk), "cards": Rect2(cd.position * kk, cd.size * kk)}


func _ready() -> void:
	_pill(badge_all_in, ACCENT, ON_ACCENT)
	_pill(badge_presence, Color(0.33, 0.36, 0.40), TEXT)
	_pill(badge_leave, SURFACE_RAISED, TEXT_MUTED, BORDER)
	_pill(badge_action, SURFACE_RAISED, Color.WHITE)
	_pill(hand_pill, SURFACE_RAISED, TEXT, ACCENT)
	payout_label.add_theme_color_override("font_color", ACCENT)
	payout_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	payout_label.add_theme_constant_override("outline_size", 6)
	name_label.add_theme_color_override("font_color", TEXT_MUTED)
	empty_label.add_theme_color_override("font_color", TEXT_MUTED)
	initial.add_theme_color_override("font_color", Color.WHITE)
	fold_label.add_theme_color_override("font_color", TEXT)
	fold_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	fold_label.add_theme_constant_override("outline_size", 8)
	timer_label.add_theme_constant_override("outline_size", 6)
	timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hand_rank.add_theme_color_override("font_color", ACCENT)
	_all_in_style = badge_all_in.get_theme_stylebox("normal")
	for l: Label in [fold_label, timer_label, hand_rank]:
		l.hide()
	set_compact(false)
	show_empty(0)


func set_compact(is_compact: bool) -> void:
	compact = is_compact
	desk = false
	_style_desk(false)
	size = capsule_size(is_compact)
	var h := size.y
	var d := h - 14.0
	initial.position = Vector2(7, 7)
	initial.size = Vector2(d, d)
	initial.add_theme_font_size_override("font_size", 16 if is_compact else 20)
	var x0 := h
	name_label.add_theme_font_size_override("font_size", 12 if is_compact else 14)
	_stack_fs = 15 if is_compact else 17
	stack_label.add_theme_font_size_override("font_size", _stack_fs)
	name_label.position = Vector2(x0, h / 2.0 - (19 if is_compact else 21))
	name_label.size = Vector2(size.x - x0 - 10, 20)
	stack_label.position = Vector2(x0, h / 2.0 - 1)
	stack_label.size = Vector2(size.x - x0 - 6, 22)
	var fs := 10 if is_compact else 11
	for l: Label in [badge_all_in, badge_presence, badge_leave, hand_pill]:
		l.add_theme_font_size_override("font_size", fs)
	_place_action()
	payout_label.add_theme_font_size_override("font_size", 15 if is_compact else 17)
	var er := _empty_rect()
	empty_label.position = er.position
	empty_label.size = er.size
	empty_label.add_theme_font_size_override("font_size", 12 if is_compact else 13)
	queue_redraw()


## 데스크톱 패널 모양으로 바꾸고 안쪽을 배치한다. 바깥쪽 열 = 아바타 원 + 아래 닉네임, 안쪽 열 = 작은 카드 + 아래 스택(left 면 아바타가 왼쪽).
## 내 자리(hero)는 큰 카드가 위, 스택·족보 칸(HandRank)이 그 아래다. 알약(지급액·족보·예약·끊김)은 아바타 열 닉네임 아래
func set_desktop(kk: float, hero: bool, left := true) -> void:
	desk = true
	compact = false
	k = kk
	hero_slot = hero
	avatar_left = left
	_style_desk(true)
	size = panel_size(hero, kk)
	var cols := desk_columns(hero, left, kk)
	var av: Rect2 = cols.avatar
	var cd: Rect2 = cols.cards
	var d := (82.0 if hero else 60.0) * kk # 아바타 사진: 둥근 사각, 열을 거의 채운다(닉네임은 그 아래)
	_avatar_r = d / 2.0
	_avatar_c = Vector2(av.get_center().x, (5.0 if hero else 4.0) * kk + _avatar_r)
	initial.position = _avatar_c - Vector2(_avatar_r, _avatar_r)
	initial.size = Vector2(d, d)
	initial.add_theme_font_size_override("font_size", int(round((24.0 if hero else 18.0) * kk)))
	name_label.add_theme_font_size_override("font_size", int(round((17.0 if hero else 14.0) * kk)))
	_stack_fs = int(round((22.0 if hero else 18.0) * kk))
	stack_label.add_theme_font_size_override("font_size", _stack_fs)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if hero:
		name_label.position = Vector2(av.position.x, 89.0 * kk)
		name_label.size = Vector2(av.size.x, 24.0 * kk)
		stack_label.position = Vector2(cd.position.x, 96.0 * kk)
		stack_label.size = Vector2(cd.size.x, 28.0 * kk)
		hand_rank.position = Vector2(cd.position.x, 124.0 * kk)
		hand_rank.size = Vector2(cd.size.x, 20.0 * kk)
	else:
		name_label.position = Vector2(av.position.x, 66.0 * kk)
		name_label.size = Vector2(av.size.x, 20.0 * kk)
		stack_label.position = Vector2(cd.position.x, 59.0 * kk)
		stack_label.size = Vector2(cd.size.x, 26.0 * kk)
	hand_rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hand_rank.add_theme_font_size_override("font_size", int(round(16.0 * kk)))
	var pf := int(round(11.0 * kk))
	for l: Label in [badge_presence, badge_leave, hand_pill]:
		l.add_theme_font_size_override("font_size", pf)
	payout_label.add_theme_font_size_override("font_size", int(round(14.0 * kk)))
	fold_label.add_theme_font_size_override("font_size", int(round(36.0 * kk)))
	fold_label.position = Vector2.ZERO
	fold_label.size = size
	for l: Label in [badge_action, fold_label, badge_all_in]: # 내 큰 카드(table.gd 의 MyCards)가 좌석보다 위에 그려진다 — 오버레이는 그 위로
		l.z_index = 1 if hero else 0
	badge_all_in.add_theme_font_size_override("font_size", int(round(26.0 * kk)))
	timer_label.add_theme_font_size_override("font_size", int(round((32.0 if hero else 38.0) * kk)))
	var er := _empty_rect()
	empty_label.position = er.position
	empty_label.size = er.size
	empty_label.add_theme_font_size_override("font_size", int(round(14.0 * kk)))
	_place_action()
	queue_redraw()


## desk 와 폰 사이에서 달라지는 노드 모양(올인 글자·정렬)을 바꾼다. 행동 배지는 폰 = 둥근 토큰, 데스크톱 = 아바타 아래 알약
func _style_desk(on: bool) -> void:
	var sb := badge_action.get_theme_stylebox("normal") as StyleBoxFlat
	if on: # 데스크톱: 카드 칸 위에 큰 글자(바탕 없음, 색은 show_player 가 글자색으로)
		sb.bg_color = Color(0, 0, 0, 0)
		sb.content_margin_left = 0
		sb.content_margin_right = 0
		sb.set_border_width_all(0)
		badge_action.custom_minimum_size = Vector2.ZERO
		badge_action.add_theme_font_size_override("font_size", int(round(30.0 * k)))
		badge_action.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	else: # 폰: 둥근 토큰
		sb.set_corner_radius_all(int(PHONE_TOKEN / 2.0))
		sb.content_margin_left = 0
		sb.content_margin_right = 0
		sb.set_border_width_all(2)
		sb.border_color = Color(1, 1, 1, 0.85)
		badge_action.custom_minimum_size = Vector2(PHONE_TOKEN, PHONE_TOKEN)
		badge_action.add_theme_font_size_override("font_size", 11)
	badge_action.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge_action.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge_action.add_theme_constant_override("outline_size", int(round(8.0 * k)) if on else 0)
	badge_action.z_index = 0
	badge_all_in.text = "ALLIN" if on else "ALL-IN"
	badge_all_in.add_theme_stylebox_override("normal", StyleBoxEmpty.new() if on else _all_in_style)
	badge_all_in.add_theme_color_override("font_color", ACCENT if on else ON_ACCENT)
	if on:
		badge_all_in.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		badge_all_in.add_theme_constant_override("outline_size", 6)
	else:
		badge_all_in.remove_theme_constant_override("outline_size")
		stack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		for l: Label in [fold_label, timer_label, hand_rank]:
			l.hide()
	modulate = Color.WHITE
	_set_dim(Color.WHITE)


## desk: 패널 바탕·글자만 어둡게 한다(폴드 글자·타이머 숫자·행동 토큰은 그대로)
func _set_dim(c: Color) -> void:
	_dim = c
	for n: CanvasItem in [initial, name_label, stack_label, hand_pill, payout_label, badge_presence, badge_leave, hand_rank]:
		n.modulate = c if desk else Color.WHITE


## 카드 칸 중심(오버레이·ALLIN·타이머 숫자 자리)
func _zone_center() -> Vector2:
	var cd: Rect2 = desk_columns(hero_slot, avatar_left, k).cards
	return Vector2(cd.get_center().x, (50.0 if hero_slot else 31.0) * k)


func _center_label(l: Label) -> void:
	l.reset_size()
	l.position = _zone_center() - l.size / 2.0


## desk 알약 줄: 우선순위 지급액·족보·예약·끊김. 일반 패널은 아래 줄에 왼쪽부터 놓고 넘치면 숨긴다. 내 자리는 카드 양옆(족보·지급액 오른쪽, 나머지 왼쪽)
func _place_desk_pills() -> void:
	var list: Array = []
	for l: Label in [payout_label, hand_pill, badge_leave, badge_presence]:
		if l.visible:
			l.reset_size()
			list.append(l)
	var av: Rect2 = desk_columns(hero_slot, avatar_left, k).avatar
	if hero_slot: # 아바타 열 닉네임 아래로 세로로 쌓는다
		var y := 114.0 * k
		for l: Label in list:
			if y + l.size.y > size.y - 8.0 * k:
				l.hide() # 아래로 넘치면 낮은 우선순위부터 숨긴다
				continue
			l.position = Vector2(av.get_center().x - l.size.x / 2.0, y)
			y += l.size.y + 3.0 * k
		return
	var x := av.position.x
	for l: Label in list:
		if x + l.size.x > av.end.x:
			l.hide() # 아바타 열 한 줄에 다 못 담으면 낮은 우선순위부터 숨긴다
			continue
		l.position = Vector2(x, _avatar_c.y + _avatar_r - l.size.y - 3.0 * k) # 아바타 아랫부분에 걸친다(닉네임 자리를 비운다)
		x += l.size.x + 3.0 * k


## 스택 문구가 라벨 폭보다 넓으면(세로 폰의 6자리 이상) 글자를 1px 씩 줄여 잘리지 않게 한다
func _fit_stack() -> void:
	var fs := _stack_fs
	var font := stack_label.get_theme_font("font")
	while fs > 10 and font.get_string_size(stack_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > stack_label.size.x:
		fs -= 1
	stack_label.add_theme_font_size_override("font_size", fs)


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
	_set_dim(Color.WHITE)
	for l: Control in [initial, name_label, stack_label, badge_all_in, badge_presence, badge_leave, badge_action, payout_label, fold_label, timer_label, hand_rank]:
		l.hide()
	_badge_count = 0
	empty_label.text = "빈 자리 %d" % seat_no
	empty_label.show()
	_set_cards(cards)
	_set_pill(category)
	if desk:
		_place_desk_pills()
	queue_redraw()


## info: action(optional), nickname, stack, is_me, to_act, folded, all_in, presence_text, leave_reserved, leave_text(optional), cards, category, payout
func show_player(info: Dictionary) -> void:
	empty = false
	is_me = info.is_me
	to_act = info.to_act
	empty_label.hide()
	var nick: String = info.nickname
	_avatar_color = AVATAR_COLORS[nick.hash() % AVATAR_COLORS.size()]
	initial.text = "" # 기본 프로필 실루엣을 그리므로 이니셜은 쓰지 않는다
	name_label.text = nick
	stack_label.text = Format.comma(info.stack)
	_fit_stack()
	for l: Control in [initial, name_label, stack_label]:
		l.show()
	var disconnected: bool = info.presence_text != ""
	var dim := Color(1, 1, 1, 0.45) if info.folded else (Color(0.72, 0.72, 0.72) if disconnected else Color.WHITE)
	if desk: # 폴드 글자·타이머·토큰이 흐려지지 않게 노드 전체가 아니라 패널 바탕·글자만 어둡게 한다
		modulate = Color.WHITE
		_set_dim(dim)
	else:
		modulate = dim
	fold_label.visible = desk and info.folded
	badge_all_in.visible = info.all_in
	badge_presence.text = info.presence_text
	badge_presence.visible = disconnected
	badge_leave.text = info.get("leave_text", "일어서기 예약") # 서버는 예약 종류를 구분하지 않는다 — 내 좌석만 로컬 의도(관전/나가기)를 안다
	badge_leave.visible = info.leave_reserved
	var action: String = info.get("action", "")
	var changed := action != "" and action != badge_action.text
	badge_action.text = action
	badge_action.visible = action != "" and not (desk and (info.all_in or info.folded)) # 카드 칸 겹침 우선순위: ALLIN > 폴드 > 행동
	if action != "":
		if desk:
			badge_action.add_theme_color_override("font_color", (ACTION_COLORS.get(action, SURFACE_RAISED) as Color).lightened(0.35))
		else:
			(badge_action.get_theme_stylebox("normal") as StyleBoxFlat).bg_color = ACTION_COLORS.get(action, SURFACE_RAISED)
	_place_action()
	_place_badges()
	if changed and badge_action.visible:
		_pop(badge_action)
	_set_cards(info.cards) # 내 카드는 table.gd 가 크게 따로 그린다 — 여기엔 빈 배열이 온다
	_set_pill(info.category)
	hand_rank.text = info.get("hand_text", "")
	hand_rank.visible = desk and hero_slot and hand_rank.text != ""
	payout_label.text = "+%s" % Format.comma(info.payout)
	payout_label.visible = info.payout > 0
	payout_label.reset_size()
	if desk:
		_place_desk_pills()
		_center_label(badge_all_in)
		queue_redraw()
		return
	# 위는 작은 카드·내 카드가 차지하므로 캡슐 아래 가운데(배지 줄 바로 밑)에 둔다
	payout_label.position = Vector2((size.x - payout_label.size.x) / 2.0, size.y + (12.0 if _badge_count > 0 else 4.0))
	queue_redraw()


func set_timer(left: float, total: float) -> void:
	if not is_equal_approx(left, timer_left) or not is_equal_approx(total, timer_total):
		timer_left = left
		timer_total = total
		if desk:
			timer_label.visible = left >= 0.0 and not empty
			timer_label.text = str(int(ceil(left)))
			timer_label.add_theme_color_override("font_color", DANGER if left < WARN_SECONDS else ACCENT)
			_center_label(timer_label)
			if hero_slot: # 내 자리는 두 카드 사이가 아니라 아바타 위에 숫자를 놓는다
				timer_label.position = _avatar_c - timer_label.size / 2.0
		else:
			_place_badges()
		queue_redraw()


func _set_cards(codes: Array) -> void:
	shown_codes = codes
	var cs := other_card_size(compact)
	var gap := 3.0
	var x0 := (size.x - (2.0 * cs.x + gap)) / 2.0
	var y0 := -cs.y - 2.0
	if desk: # 패널 안: 일반은 오른쪽, 내 자리는 위 가운데
		cs = desk_card_size(hero_slot, k)
		gap = (8.0 if hero_slot else 4.0) * k
		x0 = (desk_columns(hero_slot, avatar_left, k).cards as Rect2).get_center().x - (2.0 * cs.x + gap) / 2.0
		y0 = 8.0 * k if hero_slot else 4.0 * k
	for i in 2:
		var r: TextureRect = card_rects[i]
		if i < codes.size():
			r.texture = load(Cards.texture_path(codes[i]))
			r.size = cs
			r.position = Vector2(x0 + i * (cs.x + gap), y0)
			r.show()
		else:
			r.hide()


func _set_pill(category: String) -> void:
	hand_pill.text = category
	hand_pill.visible = category != ""
	hand_pill.reset_size()
	if desk: # 자리는 _place_desk_pills 가 정한다. 행동 토큰은 패널 밖이라 같은 자리를 다투지 않는다
		return
	hand_pill.position = Vector2((size.x - hand_pill.size.x) / 2.0, -hand_pill.size.y / 2.0 - 2)


func _place_badges() -> void:
	if desk:
		return
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


## 폰 행동 토큰은 token_center(table.gd 가 캡슐과 펠트 가운데 사이에서 비는 곳으로 정한다), 데스크톱 글자는 카드 칸 위에 둔다
func _place_action() -> void:
	badge_action.reset_size()
	if desk: # 카드 칸 가운데(내 자리는 큰 카드 아랫부분에 반투명으로 얹는다)
		var c := _zone_center()
		if hero_slot:
			c.y = 72.0 * k
		badge_action.position = c - badge_action.size / 2.0
	else:
		badge_action.position = token_center - badge_action.size / 2.0


func set_token_center(c: Vector2) -> void:
	token_center = c
	_place_action()


## 배지가 새 문구로 바뀔 때 살짝 커졌다 돌아온다
func _pop(l: Label) -> void:
	l.pivot_offset = l.size / 2.0
	l.scale = Vector2(1.35, 1.35)
	create_tween().tween_property(l, "scale", Vector2.ONE, 0.18)


func _draw() -> void:
	if desk:
		_draw_desk()
		return
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
	_draw_avatar(Vector2(size.y / 2.0, size.y / 2.0), (size.y - 14.0) / 2.0, _avatar_color, 1.0)
	if timer_left >= 0.0:
		var w := size.x - 20.0
		var y := size.y + (12.0 if _badge_count > 0 else 4.0)
		draw_rect(Rect2(10, y, w, 4), BORDER)
		var frac := clampf(timer_left / timer_total, 0.0, 1.0)
		draw_rect(Rect2(10, y, w * frac, 4), DANGER if timer_left < WARN_SECONDS else ACCENT)


## 기본 프로필: 파스텔 바탕 + 흰 머리·어깨 실루엣. square 면 둥근 사각(어깨는 아래 변에 닿고 사각 안으로 잘린다), 아니면 원
func _draw_avatar(c: Vector2, r: float, col: Color, a: float, square := false) -> void:
	var white := Color(1, 1, 1, 0.65 * a)
	if square:
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_corner_radius_all(int(round(6.0 * k)))
		sb.draw(get_canvas_item(), Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0))
		draw_circle(c + Vector2(0, -0.2 * r), 0.38 * r, white)
		var q := PackedVector2Array()
		for i in 48:
			var t := TAU * i / 48.0
			q.append(c + Vector2(0.8 * r * cos(t), minf(r + 0.62 * r * sin(t), r)))
		draw_colored_polygon(q, white)
		return
	draw_circle(c, r, col)
	draw_circle(c + Vector2(0, -0.25 * r), 0.36 * r, white)
	var pts := PackedVector2Array()
	for i in 48:
		var t := TAU * i / 48.0
		var p := Vector2(0.75 * r * cos(t), 0.95 * r + 0.65 * r * sin(t))
		if p.length() > r:
			p = p.normalized() * r
		pts.append(c + p)
	draw_colored_polygon(pts, white)


## 데스크톱 패널: 둥근 사각 바탕 + 테두리(차례면 금색 굵게) + 아래 가장자리 안쪽 타이머 막대
func _draw_desk() -> void:
	var radius := int(10.0 * k)
	if empty:
		_style.bg_color = Color(SURFACE, 0.4)
		_style.set_border_width_all(1)
		_style.border_color = Color(BORDER, 0.6)
		_style.set_corner_radius_all(radius)
		_style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
		return
	_style.bg_color = Color(SURFACE.r, SURFACE.g, SURFACE.b, SURFACE.a * _dim.a)
	_style.set_border_width_all(int(ceil((4.0 if to_act else 2.0) * k)))
	_style.border_color = ACCENT if to_act else (Color(ACCENT, 0.55) if is_me else BORDER)
	_style.set_corner_radius_all(radius)
	_style.draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
	_draw_avatar(_avatar_c, _avatar_r, _avatar_color * Color(1, 1, 1, _dim.a), _dim.a, true)
	if timer_left >= 0.0:
		var bar := Rect2(10.0 * k, size.y - 8.0 * k, size.x - 20.0 * k, 4.0 * k)
		draw_rect(bar, BORDER)
		bar.size.x *= clampf(timer_left / timer_total, 0.0, 1.0)
		draw_rect(bar, DANGER if timer_left < WARN_SECONDS else ACCENT)
