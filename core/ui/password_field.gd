class_name PasswordField
## HTML <input type="password"> 처럼 동작하는 비밀번호 칸: 폰은 비밀번호 키보드, 포커스 동안 IME 끔.
## Web 에서 window_set_ime_active 는 DisplayServerWeb 에 구현이 없어(베이스 no-op) 효과가 없다고 본다 —
## 그래서 비ASCII(한글 조합 등)가 들어가면 칸 아래에 중립 안내를 띄운다(입력은 막거나 바꾸지 않는다).
## 게임 개념 없음. 로그인에도 쓰므로 오류 코드가 아니라 힌트다.

const WARNING := "한글 입력 상태입니다 — 영문으로 바꿔 입력하세요"

## IME 켜고 끄기 훅(테스트가 바꿔치기한다)
static var set_ime := func(on: bool) -> void: DisplayServer.window_set_ime_active(on)


## edit 에 비밀번호 키보드·IME 끄기·비ASCII 안내를 붙이고 안내 Label 을 돌려준다(edit 바로 아래 형제)
static func setup(edit: LineEdit) -> Label:
	edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	var disabled := [false] # 우리가 껐을 때만 복구한다
	edit.focus_entered.connect(func() -> void:
		disabled[0] = true
		set_ime.call(false))
	edit.focus_exited.connect(func() -> void:
		if disabled[0]:
			disabled[0] = false
			set_ime.call(true))
	var hint := Label.new()
	hint.theme_type_variation = &"LabelHint"
	hint.text = WARNING
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.visible = false
	edit.add_sibling(hint)
	edit.get_parent().move_child(hint, edit.get_index() + 1)
	edit.text_changed.connect(func(t: String) -> void: hint.visible = has_non_ascii(t))
	return hint


static func has_non_ascii(text: String) -> bool:
	for i in text.length():
		if text.unicode_at(i) > 127:
			return true
	return false
