extends Control
## 칩 아이콘과 딜러 버튼을 코드로 그린다(이미지 에셋 없음). 크기는 custom_minimum_size 로 정한다.

enum Kind { CHIP, DEALER }

const ACCENT := Color(0.9020, 0.7255, 0.2902)

@export var kind := Kind.CHIP


func _draw() -> void:
	var c := size / 2.0
	var r := minf(size.x, size.y) / 2.0
	if kind == Kind.CHIP:
		draw_circle(c, r, ACCENT)
		for i in 8: # 가장자리 흰 줄무늬
			var a := TAU * i / 8.0
			draw_arc(c, r - 2.0, a - 0.2, a + 0.2, 4, Color.WHITE, 3.0)
		draw_arc(c, r * 0.55, 0.0, TAU, 20, Color(0, 0, 0, 0.25), 1.5)
	else:
		draw_circle(c, r, Color.WHITE)
		var font := get_theme_default_font()
		var fs := int(r * 1.2)
		draw_string(font, Vector2(0, c.y + fs * 0.36), "D", HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, Color(0.07, 0.09, 0.11))
