class_name FocusVisible extends Node
## 앱 전체 버튼 공통 처리: 포커스 링은 키보드로 옮겼을 때만, 손바닥 커서, 터치 기기에서는 hover 를 normal 과 같게.
## Api._ready 가 setup() 을 한 번 부른다(autoload 를 늘리지 않는다).

var touch_device := OS.has_feature("web_android") or OS.has_feature("web_ios")
var _keyboard := false # 마지막 입력이 키보드/패드인가


static func setup(tree: SceneTree) -> void:
	var fv := FocusVisible.new()
	fv.name = "FocusVisible"
	tree.root.add_child.call_deferred(fv) # _ready 중에는 루트가 바쁘다
	tree.node_added.connect(fv._on_node_added)
	tree.root.gui_focus_changed.connect(fv._on_focus_changed)


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		node.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		if touch_device:
			_flatten_hover.call_deferred(node) # 테마(변형 이름)가 정해진 뒤에 normal 을 복사


func _flatten_hover(b: BaseButton) -> void:
	if is_instance_valid(b):
		b.add_theme_stylebox_override("hover", b.get_theme_stylebox("normal"))


func _input(event: InputEvent) -> void:
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_keyboard = true
	elif event is InputEventMouseButton or event is InputEventScreenTouch:
		_keyboard = false


func _on_focus_changed(c: Control) -> void:
	if c is BaseButton:
		if _keyboard:
			c.remove_theme_stylebox_override("focus")
		else:
			c.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
