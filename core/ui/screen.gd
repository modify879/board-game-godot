class_name Screen extends RefCounted
## 화면 배율. 기준 크기를 정사각형 L×L 로 두어 짧은 변이 L, 긴 변은 늘어난다(가로·세로 모두 한 레이아웃).
## L = 짧은 변(CSS px)×1.25 를 480~720 으로 제한 — 1280x720 은 배율 1, 390x844 폰은 논리 ≈488x1056.

static var _connected := false


static func setup(window: Window) -> void:
	if _connected:
		return
	_connected = true
	window.size_changed.connect(apply.bind(window))
	apply(window)


static func apply(window: Window) -> void:
	var css_short := minf(window.size.x, window.size.y) / DisplayServer.screen_get_scale()
	var l := clampi(roundi(css_short * 1.25), 480, 720)
	window.content_scale_size = Vector2i(l, l)
