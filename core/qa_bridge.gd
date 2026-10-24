class_name QaBridge extends RefCounted
## QA 전용 JS 브리지(window.godotQa). Web 이고 URL 에 qa=1 이거나 포트가 8001(QA nginx)일 때만 켠다 — 아니면 아무것도 하지 않는다.
## 키 규칙: unique_name_in_owner Control 의 키는 자기 이름. 인스턴스된 씬 안이면 그 씬 루트들의 이름을 앞에 "/" 로 붙인다
##   예: "FoldButton", "Seat3/NameLabel"(Seat3 로 인스턴스된 씬 안). 겹치면 "#2" 를 붙인다.
## 고유 이름이 없는 보이는 Button 은 가장 가까운 키 있는 조상 아래 "<조상키>/<순번>"(0부터, 보이는 것만) — 방 카드·관리자 행 버튼 등.
## 씬 루트에 qa_state() -> Dictionary 가 있으면 state().extra 에 넣는다(화면이 선택).

static var _callbacks: Array = [] # JavaScriptObject 를 잡아 두지 않으면 해제된다
static var _tree: SceneTree
static var _raw # JavaScriptObject — 결과 전달용


static func setup(tree: SceneTree) -> void:
	if not OS.has_feature("web"):
		return
	var on = JavaScriptBridge.eval("(new URLSearchParams(location.search).get('qa') === '1' || location.port === '8001') ? '1' : '0'")
	if str(on) != "1":
		return
	_tree = tree
	var speed_param = JavaScriptBridge.eval("new URLSearchParams(location.search).get('qa_speed')")
	var speed := 4.0
	if speed_param != null and str(speed_param).is_valid_float():
		speed = float(str(speed_param))
	Engine.time_scale = speed
	# 콜백 반환값은 JS 로 전달되지 않는다 — 콜백이 raw.r 에 결과를 쓰고, JS 래퍼가 동기로 읽어 돌려준다
	_raw = JavaScriptBridge.create_object("Object")
	for fn in ["state", "press", "set_text", "set_value", "speed", "refresh"]:
		var cb := JavaScriptBridge.create_callback(Callable(QaBridge, "_js_" + fn))
		_callbacks.append(cb)
		_raw[fn] = cb
	JavaScriptBridge.get_interface("window").__godotQaRaw = _raw
	JavaScriptBridge.eval("window.godotQa = {}; for (const f of ['state','press','set_text','set_value','speed','refresh']) window.godotQa[f] = function(){ window.__godotQaRaw[f].apply(null, arguments); return window.__godotQaRaw.r; };")


static func _root() -> Node:
	return _tree.current_scene


static func _js_state(_args: Array) -> void:
	_raw.r = JSON.stringify(snapshot(_root()))


static func _js_press(args: Array) -> void:
	_raw.r = JSON.stringify(press(_root(), str(args[0])))


static func _js_set_text(args: Array) -> void:
	_raw.r = JSON.stringify(set_text(_root(), str(args[0]), str(args[1])))


static func _js_set_value(args: Array) -> void:
	_raw.r = JSON.stringify(set_value(_root(), str(args[0]), float(args[1])))


static func _js_speed(args: Array) -> void:
	Engine.time_scale = float(args[0])
	_raw.r = "{}"


static func _js_refresh(_args: Array) -> void:
	_tree.root.get_node("Api")._refresh() # await 하지 않는다 — 결과는 state() 로 본다
	_raw.r = "{}"


## key -> Node. 고유 이름 Control 전부 + 키 있는 컨테이너 아래 보이는 이름 없는 Button.
static func keys(root: Node) -> Dictionary:
	var out := {}
	if root != null:
		_walk(root, root, "", out, {})
	return out


static func _walk(node: Node, root: Node, prefix: String, out: Dictionary, counters: Dictionary) -> void:
	for child in node.get_children():
		var p := prefix # 인스턴스된 씬 루트 이름만 접두로 쌓는다 — 같은 씬의 고유 이름은 그 씬 안에서 이미 유일하다
		var named: bool = child.unique_name_in_owner
		var instanced: bool = child.scene_file_path != "" and child != root
		if instanced:
			p = child.name if prefix == "" else prefix + "/" + child.name
		if child is Control and named:
			var base: String = p if instanced else (String(child.name) if prefix == "" else prefix + "/" + child.name)
			var key := base
			var n := 2
			while out.has(key):
				key = "%s#%d" % [base, n]
				n += 1
			out[key] = child
			counters[child] = 0
		elif child is Button and child.is_visible_in_tree() and p == prefix:
			var holder = _holder(child, out)
			if holder != null:
				var i: int = counters[holder[1]]
				counters[holder[1]] = i + 1
				out["%s/%d" % [holder[0], i]] = child
		_walk(child, root, p, out, counters)


## 가장 가까운 키 있는 조상. [key, node] 또는 null
static func _holder(node: Node, out: Dictionary) -> Variant:
	var cur := node.get_parent()
	while cur != null:
		for k in out:
			if out[k] == cur:
				return [k, cur]
		cur = cur.get_parent()
	return null


static func find(root: Node, key: String) -> Node:
	return keys(root).get(key)


static func snapshot(root: Node) -> Dictionary:
	var nodes := {}
	var extra := {}
	if root != null:
		var ks := keys(root)
		for key in ks:
			nodes[key] = _describe(ks[key])
		if root.has_method("qa_state"):
			extra = root.qa_state()
	return {"scene": "" if root == null else root.scene_file_path, "nodes": nodes, "extra": extra, "env": EnvBadge.environment, "env_badge_visible": EnvBadge.is_visible(), "token_tail": "" if _tree == null else _tree.root.get_node("Api").access_token.right(8)}


static func _describe(c: Control) -> Dictionary:
	var d := {"type": c.get_class(), "visible": c.is_visible_in_tree()}
	var r := c.get_global_rect()
	d["rect"] = [r.position.x, r.position.y, r.size.x, r.size.y]
	if c is Label:
		d["text"] = c.text
	elif c is RichTextLabel:
		d["text"] = c.get_parsed_text()
	elif c is LineEdit:
		d["text"] = c.text
	elif c is BaseButton:
		if c is Button:
			d["text"] = c.text
		d["disabled"] = c.disabled
		if c.toggle_mode:
			d["pressed"] = c.button_pressed
	if c is Range:
		d["value"] = c.value
		d["min"] = c.min_value
		d["max"] = c.max_value
	if c is SpinBox:
		d["text"] = c.get_line_edit().text
	return d


static func _target(root: Node, key: String) -> Variant:
	var node := find(root, key)
	if node == null:
		return {"ok": false, "error": "not found: " + key}
	if not (node as Control).is_visible_in_tree():
		return {"ok": false, "error": "not visible: " + key}
	return node


static func press(root: Node, key: String) -> Dictionary:
	var node = _target(root, key)
	if node is Dictionary:
		return node
	if not node is BaseButton:
		return {"ok": false, "error": "not a button: " + key}
	if node.disabled:
		return {"ok": false, "error": "disabled: " + key}
	if node.toggle_mode:
		node.button_pressed = not node.button_pressed
	else:
		node.pressed.emit()
	return {"ok": true, "error": ""}


static func set_text(root: Node, key: String, text: String) -> Dictionary:
	var node = _target(root, key)
	if node is Dictionary:
		return node
	if not node is LineEdit:
		return {"ok": false, "error": "not a LineEdit: " + key}
	if not node.editable:
		return {"ok": false, "error": "not editable: " + key}
	node.text = text
	node.text_changed.emit(text)
	return {"ok": true, "error": ""}


static func set_value(root: Node, key: String, value: float) -> Dictionary:
	var node = _target(root, key)
	if node is Dictionary:
		return node
	if not node is Range:
		return {"ok": false, "error": "not a Range: " + key}
	if node is SpinBox and not node.editable:
		return {"ok": false, "error": "not editable: " + key}
	node.value = value
	return {"ok": true, "error": ""}
