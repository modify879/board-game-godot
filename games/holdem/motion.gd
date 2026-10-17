extends Control
## 홀덤 테이블 연출 오버레이(FeltArea 전체를 덮는다). 연출은 보이는 것뿐이다 — 상태는 table.gd 가 즉시 반영한다.
## 움직이는 것: (a) 이 오버레이 안의 임시 고스트, (b) 레이아웃이 건드리지 않는 실제 노드의 scale·modulate:a.
## position·size 는 실제 노드에서 절대 건드리지 않는다.

const Cards := preload("res://games/holdem/cards.gd")

const DEAL_FLY := 0.25 # 카드 한 장이 가운데에서 자리까지
const DEAL_STAGGER := 0.05 # 딜 순서 간격
const FLIP := 0.2 # 카드 뒤집기(scale.x 0→1)
const FLIP_STAGGER := 0.08 # 보드 카드 간격
const BET_TO_POT := 0.35 # 베팅 칩 → 팟
const BET_POP := 0.15 # 베팅 박스 팝
const PUSH_FLY := 0.6 # 팟 → 승자
const PUSH_PULSE := 0.3 # 승자 좌석 펄스(1 → 1.08 → 1)
const PAYOUT_FADE := 0.3
const FOLD_FLY := 0.25
const FADE_TAIL := 0.1 # 고스트가 사라지는 마지막 구간

var _real := {} # 움직이는 실제 노드 → {"t": Tween, "alpha": bool}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 새 뷰가 오면 실제 노드의 연출을 끊고 최종값(scale 1, alpha 1)으로 맞춘다. 고스트는 스스로 끝나고 사라진다
func kill_real() -> void:
	for n: Control in _real:
		if is_instance_valid(n):
			_real[n].t.kill()
			n.scale = Vector2.ONE
			if _real[n].alpha:
				n.modulate.a = 1.0
	_real.clear()


func card_ghost(code: String, card_size: Vector2) -> TextureRect:
	var r := TextureRect.new()
	r.texture = load(Cards.texture_path(code))
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size = card_size
	return r


## 고스트를 from → to(중심 좌표)로 날린다. delay 동안은 숨겨 둔다. 끝나면 queue_free
func fly(g: Control, from: Vector2, to: Vector2, dur: float, delay := 0.0, fade := false, ease_type := Tween.EASE_OUT, trans := Tween.TRANS_CUBIC, avoid := Rect2()) -> void:
	add_child(g)
	g.position = from - g.size / 2.0
	var t := g.create_tween().set_parallel(true)
	if delay > 0.0:
		g.hide()
		t.tween_callback(g.show).set_delay(delay)
	if avoid.has_area(): # avoid 영역과 겹치는 동안 고스트를 숨긴다(보드 카드 위를 지나지 않게)
		var a := from - g.size / 2.0
		var b := to - g.size / 2.0
		t.tween_method(func(k: float) -> void:
			g.position = a.lerp(b, k)
			g.visible = not avoid.intersects(Rect2(g.position, g.size)), 0.0, 1.0, dur).set_delay(delay).set_trans(trans).set_ease(ease_type)
	else:
		t.tween_property(g, "position", to - g.size / 2.0, dur).set_delay(delay).set_trans(trans).set_ease(ease_type)
	if fade:
		t.tween_property(g, "modulate:a", 0.0, FADE_TAIL).set_delay(delay + dur - FADE_TAIL)
	t.chain().tween_callback(g.queue_free)


## 실제 노드를 delay 뒤에 나타낸다(flip 이면 scale.x 0→1, 아니면 alpha 0→1). 그 전엔 보이지 않는다
func appear(n: Control, delay: float, flip := false, fade := 0.05) -> void:
	_begin(n, not flip)
	var t := _tween(n)
	if flip:
		n.scale.x = 0.0
		t.tween_property(n, "scale:x", 1.0, FLIP).set_delay(delay)
	else:
		n.modulate.a = 0.0
		t.tween_property(n, "modulate:a", 1.0, fade).set_delay(delay)


func pop(n: Control) -> void:
	_begin(n, false)
	n.scale = Vector2(0.7, 0.7)
	_tween(n).tween_property(n, "scale", Vector2.ONE, BET_POP).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func pulse(n: Control, delay: float) -> void:
	_begin(n, false)
	var t := _tween(n)
	t.tween_property(n, "scale", Vector2(1.08, 1.08), PUSH_PULSE * 0.4).set_delay(delay).set_ease(Tween.EASE_OUT)
	t.tween_property(n, "scale", Vector2.ONE, PUSH_PULSE * 0.6)


func _begin(n: Control, alpha: bool) -> void:
	if _real.has(n):
		_real[n].t.kill()
		alpha = alpha or _real[n].alpha
	n.pivot_offset = n.size.max(n.get_combined_minimum_size()) / 2.0
	_real[n] = {"t": null, "alpha": alpha}


func _tween(n: Control) -> Tween:
	var t := n.create_tween()
	_real[n].t = t
	return t
