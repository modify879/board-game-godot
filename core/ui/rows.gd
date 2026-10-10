class_name Rows
## 목록 행 만들기·비우기 공용 도우미.


static func label(text: String, expand := false) -> Label:
	var l := Label.new()
	l.text = text
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


static func clear(box: Node) -> void:
	for child in box.get_children():
		child.queue_free()
