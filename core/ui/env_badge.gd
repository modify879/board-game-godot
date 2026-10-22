class_name EnvBadge extends RefCounted
## 서버 환경 배지. GET /api/server-info(인증 없음)를 앱 시작 때 한 번 물어, environment 가 "qa" 면 오른쪽 위에 "QA 서버" 배지를 띄운다.
## 값이 늘어날 수 있어 모르는 값·필드 없음·요청 실패는 모두 "default"(아무것도 안 보임).
## 배지는 Api autoload 의 자식 CanvasLayer 라 change_scene_to_file 을 넘어 유지된다.

static var environment := "default"
static var _badge: Control


static func setup(api: Node) -> void:
	_fetch(api)


static func _fetch(api: Node) -> void:
	# Api.request 를 그대로 쓴다 — 토큰이 없으면 Bearer 를 안 싣고, 401 이 아니라 갱신 로직도 타지 않으며, 503 재시도는 오히려 이득이다
	var r: Dictionary = await api.request(HTTPClient.METHOD_GET, "/api/server-info")
	environment = environment_of(r)
	if environment == "qa":
		_show(api)


static func environment_of(r: Dictionary) -> String:
	if r.get("ok", false) == true and r.get("data") is Dictionary and r.data.get("environment") == "qa":
		return "qa"
	return "default"


static func is_visible() -> bool:
	return _badge != null and _badge.is_visible_in_tree()


static func _show(api: Node) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	var panel := PanelContainer.new()
	panel.theme = load("res://core/ui/theme.tres") # 최상위 CanvasLayer 라 씬의 테마를 상속하지 않는다
	panel.theme_type_variation = &"PanelBadgeWarn"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var label := Label.new()
	label.text = "QA 서버"
	label.theme_type_variation = &"LabelBadge"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)
	layer.add_child(panel)
	api.add_child(layer)
	_badge = panel
