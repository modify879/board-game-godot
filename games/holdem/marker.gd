extends Control
## 칩 아이콘과 딜러 버튼을 코드로 그린다(이미지 에셋 없음). 크기는 custom_minimum_size 로 정한다.

enum Kind { CHIP, DEALER }

const ACCENT := Color(0.9020, 0.7255, 0.2902)

@export var kind := Kind.CHIP
@export var label := "D" # DEALER 모양에 쓰는 글자(D·SB·BB)
@export var tint := Color.WHITE # DEALER 모양 바탕색
@export var texture: Texture2D # 있으면 DEALER·CHIP 모양 대신 이 칩 그림을 크기에 맞춰 그린다(데스크톱 D·SB·BB)
@export var pile := 0 # CHIP 모양에서 0 보다 크면 이 금액만큼 옆면 칩을 쌓아 그린다(데스크톱 베팅 더미)

const PublicView := preload("res://games/holdem/public_view.gd")
const SIDE_CHIPS := {
	100: preload("res://games/holdem/assets/chips/sideChip_white.png"),
	500: preload("res://games/holdem/assets/chips/sideChip_red.png"),
	1000: preload("res://games/holdem/assets/chips/sideChip_blue.png"),
	5000: preload("res://games/holdem/assets/chips/sideChip_green.png"),
	10000: preload("res://games/holdem/assets/chips/sideChip_black.png"),
	50000: preload("res://games/holdem/assets/chips/sideChip_purple.png"),
	100000: preload("res://games/holdem/assets/chips/sideChip_yellow.png"),
	500000: preload("res://games/holdem/assets/chips/sideChip_orange.png"),
}
const CHIP_W := 22.0 # 옆면 칩 한 장 폭(설계 좌표, unit 배)
const CHIP_H := CHIP_W * 64.0 / 123.0
const CHIP_STEP := 4.0 # 칩 사이 세로 간격
const COL_GAP := 3.0 # 단위별 기둥 사이 간격
const MAX_CHIPS := 6 # 한 기둥에 그리는 최대 장수

@export var unit := 1.0 # pile 크기 배율(데스크톱 k)


## 더미 크기: 폭은 기둥 수에 비례, 높이는 최대 장수 기준 고정
static func pile_size(amount: int, u: float) -> Vector2:
	var n := PublicView.chip_breakdown(amount).size()
	return Vector2(n * CHIP_W + maxi(n - 1, 0) * COL_GAP, CHIP_H + CHIP_STEP * (MAX_CHIPS - 1)) * u


func _draw() -> void:
	if texture != null:
		draw_texture_rect(texture, Rect2(Vector2.ZERO, size), false)
		return
	if kind == Kind.CHIP and pile > 0:
		var cols := PublicView.chip_breakdown(pile)
		var cw := CHIP_W * unit
		var ch := CHIP_H * unit
		var x := (size.x - pile_size(pile, unit).x) / 2.0
		for col: Array in cols: # 왼쪽이 큰 단위. 아래부터 쌓아 맨 아래 칩이 영역 바닥에 닿는다
			for i in mini(col[1], MAX_CHIPS):
				draw_texture_rect(SIDE_CHIPS[col[0]], Rect2(x, size.y - ch - i * CHIP_STEP * unit, cw, ch), false)
			x += cw + COL_GAP * unit
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
