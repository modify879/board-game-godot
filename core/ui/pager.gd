class_name Pager extends RefCounted
## 목록 페이저 공용 상태. 세대 카운터로 낡은 응답을 거르고, 마지막 페이지 초과는 재조회한다.

var page := 0
var total := 0
var _gen := 0
var _box: HBoxContainer
var _prev: Button
var _label: Label
var _next: Button


func _init(box: HBoxContainer, prev: Button, label: Label, next: Button, loader: Callable) -> void:
	prev.pressed.connect(func() -> void: loader.call(page - 1))
	next.pressed.connect(func() -> void: loader.call(page + 1))
	_box = box
	_prev = prev
	_label = label
	_next = next


## 요청 직전에 부른다. 버튼을 잠그고 이 요청의 세대를 돌려준다
func begin() -> int:
	_prev.disabled = true
	_next.disabled = true
	_gen += 1
	return _gen


func is_stale(gen: int) -> bool:
	return gen != _gen


## 응답 공통 처리. 낡았거나 실패·마지막 페이지 초과면 false. 실패면 낡지 않았을 때만 on_error.call(errorCode)
## 초과는 reload.call(마지막 페이지)를 기다린 뒤 false
func accept(gen: int, page_req: int, r: Dictionary, reload: Callable, on_error: Callable) -> bool:
	if gen != _gen:
		return false
	if not r.ok:
		update()
		on_error.call(r.error)
		return false
	var new_total: int = r.data.page.totalPages
	if page_req >= new_total and new_total > 0:
		await reload.call(new_total - 1)
		return false
	page = r.data.page.number
	total = new_total
	return true


func update() -> void:
	_box.visible = total > 1
	_label.text = "%d / %d" % [page + 1, total]
	_prev.disabled = page <= 0
	_next.disabled = page >= total - 1
