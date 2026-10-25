extends Control
## 칩 아이콘과 딜러 버튼을 코드로 그린다(이미지 에셋 없음). 크기는 custom_minimum_size 로 정한다.

enum Kind { CHIP, DEALER }

const ACCENT := Color(0.9020, 0.7255, 0.2902)

@export var kind := Kind.CHIP
@export var label := "D" # DEALER 모양에 쓰는 글자(D·SB·BB)
@export var tint := Color.WHITE # DEALER 모양 바탕색
@export var texture: Texture2D # 있으면 DEALER·CHIP 모양 대신 이 칩 그림을 크기에 맞춰 그린다(데스크톱 D·SB·BB)
@export var pile := 0 # CHIP 모양에서 0 보다 크면 이 금액만큼 옆면 칩을 쌓아 그린다(데스크톱 베팅 더미)

const SIDE_CHIPS := {
	"white": preload("res://games/holdem/assets/chips/sideChip_white.png"),
	"red": preload("res://games/holdem/assets/chips/sideChip_red.png"),
	"green": preload("res://games/holdem/assets/chips/sideChip_green.png"),
	"blue": preload("res://games/holdem/assets/chips/sideChip_blue.png"),
	"black": preload("res://games/holdem/assets/chips/sideChip_black.png"),
	"purple": preload("res://games/holdem/assets/chips/sideChip_purple.png"),
}
const CHIP_W := 40.0 # 옆면 칩 한 장 폭(size.x 가 76 일 때 기준 — 크기에 비례해 키운다)
const CHIP_STEP := 4.0 # 칩 사이 세로 간격
const MAX_CHIPS := 6


## 금액 → 쌓는 장수(100 → 1, 200 → 2, 400 → 3 … 최대 6). 높이가 금액을 가늠하게 한다
static func pile_count(amount: int) -> int:
	return clampi(1 + int(floor(log(maxf(amount, 1.0) / 100.0) / log(2.0))), 1, MAX_CHIPS)


## 금액대별 칩 색
static func pile_color(amount: int) -> String:
	for t: Array in [[500, "white"], [1000, "red"], [5000, "green"], [20000, "blue"], [100000, "black"]]:
		if amount < t[0]:
			return t[1]
	return "purple"


## 더미 한 줄 높이(칩 한 장 높이 + 간격 × 5) — 크기 계산용. w 는 더미 폭
static func pile_height(w: float) -> float:
	var s := w / 76.0
	return (CHIP_W * 64.0 / 123.0 + CHIP_STEP * (MAX_CHIPS - 1)) * s


func _draw() -> void:
	if texture != null:
		draw_texture_rect(texture, Rect2(Vector2.ZERO, size), false)
		return
	if kind == Kind.CHIP and pile > 0:
		var tex: Texture2D = SIDE_CHIPS[pile_color(pile)]
		var s := size.x / 76.0
		var cw := CHIP_W * s
		var ch := cw * 64.0 / 123.0
		var n := pile_count(pile)
		for i in n: # 아래부터 쌓는다 — 맨 아래 칩이 영역 바닥에 닿는다
			draw_texture_rect(tex, Rect2((size.x - cw) / 2.0, size.y - ch - i * CHIP_STEP * s, cw, ch), false)
		return
	var c := size / 2.0
	var r := minf(size.x, size.y) / 2.0
	if kind == Kind.CHIP:
		draw_circle(c, r, ACCENT)
		for i in 8: # 가장자리 흰 줄무늬
			var a := TAU * i / 8.0
			draw_arc(c, r - 2.0, a - 0.2, a + 0.2, 4, Color.WHITE, 3.0)
		draw_arc(c, r * 0.55, 0.0, TAU, 20, Color(0, 0, 0, 0.25), 1.5)
	else:
		draw_circle(c, r, tint)
		var font := get_theme_default_font()
		var fs := int(r * (1.2 if label.length() == 1 else 0.95))
		draw_string(font, Vector2(0, c.y + fs * 0.36), label, HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, Color(0.07, 0.09, 0.11))
