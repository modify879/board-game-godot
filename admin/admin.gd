extends Control
## 관리자: 충전·환전 요청 처리, 회원 관리(잠금 해제·역할·잔액 조정).

const Wallet := preload("res://lobby/wallet.gd")
const PAGE_SIZE := 20
const DEPOSIT := 0
const WITHDRAW := 1
const PATHS := ["/api/admin/deposit-requests", "/api/admin/withdrawal-requests"]

@onready var back_button: Button = %BackButton
@onready var error_label: Label = %ErrorLabel
@onready var result_label: Label = %ResultLabel
@onready var tabs: TabContainer = %Tabs
@onready var search_edit: LineEdit = %SearchEdit
@onready var search_button: Button = %SearchButton
@onready var user_rows: VBoxContainer = %UserRows
@onready var user_empty: Label = %UserEmpty
@onready var user_pager: HBoxContainer = %UserPager
@onready var user_prev: Button = %UserPrev
@onready var user_page_label: Label = %UserPage
@onready var user_next: Button = %UserNext
@onready var user_id_edit: LineEdit = %UserIdEdit
@onready var lookup_button: Button = %LookupButton
@onready var user_info_label: Label = %UserInfoLabel
@onready var unlock_button: Button = %UnlockButton
@onready var role_option: OptionButton = %RoleOption
@onready var role_button: Button = %RoleButton
@onready var adjust_amount_edit: LineEdit = %AdjustAmountEdit
@onready var adjust_reason_edit: LineEdit = %AdjustReasonEdit
@onready var adjust_button: Button = %AdjustButton

# 요청 목록 탭별 노드·상태 (DEPOSIT, WITHDRAW 순)
@onready var statuses: Array[OptionButton] = [%DepositStatus, %WithdrawStatus]
@onready var rows: Array[VBoxContainer] = [%DepositRows, %WithdrawRows]
@onready var empties: Array[Label] = [%DepositEmpty, %WithdrawEmpty]
@onready var pagers: Array[HBoxContainer] = [%DepositPager, %WithdrawPager]
@onready var prevs: Array[Button] = [%DepositPrev, %WithdrawPrev]
@onready var page_labels: Array[Label] = [%DepositPage, %WithdrawPage]
@onready var nexts: Array[Button] = [%DepositNext, %WithdrawNext]

var pages := [0, 0]
var gens := [0, 0] # 목록 응답이 낡았는지 가리는 세대
var users_gen := 0
var total_pages := [0, 0]
var adjust_key := ""
var selected_id := -1 # 잔액 응답이 낡았는지 가리는 기준
var role_synced_id := -1 # 역할 드롭다운을 서버 값으로 맞춘 회원 — 같은 회원을 다시 그릴 때는 관리자가 고른 값을 유지한다
var user_query := ""
var user_page := 0
var user_total_pages := 0
var user_items := {} # 현재 페이지 회원 (id → item)
var _busy := false


func _ready() -> void:
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	tabs.tab_changed.connect(_on_tab_changed)
	for k in 2:
		statuses[k].item_selected.connect(func(_i: int) -> void: _load(k, 0))
		prevs[k].pressed.connect(func() -> void: _load(k, pages[k] - 1))
		nexts[k].pressed.connect(func() -> void: _load(k, pages[k] + 1))
	search_button.pressed.connect(_on_search)
	search_edit.text_submitted.connect(func(_t: String) -> void: _on_search())
	user_prev.pressed.connect(func() -> void: _load_users(user_page - 1))
	user_next.pressed.connect(func() -> void: _load_users(user_page + 1))
	lookup_button.pressed.connect(func() -> void:
		error_label.hide() # 직접 조회할 때만 이전 오류를 지운다 — _finish 가 부를 때는 방금 띄운 오류를 남긴다
		_on_lookup())
	unlock_button.pressed.connect(_on_unlock)
	role_button.pressed.connect(_on_role)
	adjust_button.pressed.connect(_on_adjust)
	# 입력이 바뀌면 새 키. 실패 뒤 입력을 그대로 두고 다시 누르면 같은 키가 나가 중복 반영되지 않는다
	for e in [user_id_edit, adjust_amount_edit, adjust_reason_edit]:
		e.text_changed.connect(func(_t: String) -> void: _new_key())
	_new_key()
	_on_tab_changed(tabs.current_tab)


func _new_key() -> void:
	adjust_key = Api.new_idempotency_key()


func _on_tab_changed(index: int) -> void:
	error_label.hide()
	result_label.hide()
	if index < 2:
		_load(index, pages[index])
	elif index == 2:
		_load_users(user_page)


func _show_error(code: String) -> void:
	error_label.text = ErrorText.of(code)
	error_label.show()
	result_label.hide()


func _show_result(text: String) -> void:
	result_label.text = text
	result_label.show()
	error_label.hide()


func _label(text: String, expand := false) -> Label:
	var l := Label.new()
	l.text = text
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


func _clear(box: VBoxContainer) -> void:
	for child in box.get_children():
		child.queue_free()


func _edit(placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return e


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	return b


## 목록 읽기. 대기=PENDING, 전체는 status 생략
func _load(kind: int, page: int) -> void:
	prevs[kind].disabled = true
	nexts[kind].disabled = true
	var path: String = PATHS[kind] + "?page=%d&size=%d" % [page, PAGE_SIZE]
	if statuses[kind].selected == 0:
		path += "&status=PENDING"
	var gen: int = gens[kind] + 1
	gens[kind] = gen
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, path)
	if gen != gens[kind]:
		return
	if not r.ok:
		_show_error(r.error)
		_update_pager(kind)
		return
	var new_total: int = r.data.page.totalPages
	if page >= new_total and new_total > 0:
		_load(kind, new_total - 1)
		return
	pages[kind] = r.data.page.number
	total_pages[kind] = new_total
	var items := Api.page_items(r.data)
	_clear(rows[kind])
	empties[kind].visible = items.is_empty()
	for item in items:
		rows[kind].add_child(_request_row(kind, item))
	_update_pager(kind)


func _update_pager(kind: int) -> void:
	pagers[kind].visible = total_pages[kind] > 1
	page_labels[kind].text = "%d / %d" % [pages[kind] + 1, total_pages[kind]]
	prevs[kind].disabled = pages[kind] <= 0
	nexts[kind].disabled = pages[kind] >= total_pages[kind] - 1


func _request_row(kind: int, item: Dictionary) -> VBoxContainer:
	var id := int(item.id)
	var amount := int(item.requestedAmount) if kind == DEPOSIT else int(item.amount)
	var box := VBoxContainer.new()
	var info := HBoxContainer.new()
	info.add_child(_label("#%d" % id))
	info.add_child(_label("회원 %d" % int(item.userId)))
	info.add_child(_label(Format.time(item.requestedAt)))
	info.add_child(_label("%s원" % Format.comma(amount), true))
	var status: String = Wallet.STATUS_TEXT.get(item.status, item.status)
	if kind == DEPOSIT and item.status == "APPROVED" and item.creditedAmount != null:
		status += " (%s)" % Format.comma(int(item.creditedAmount))
	elif item.status == "REJECTED" and item.rejectionReason != null:
		status += " (%s)" % item.rejectionReason
	info.add_child(_label(status))
	box.add_child(info)
	if kind == WITHDRAW:
		box.add_child(_label("%s %s (예금주 %s)" % [item.bankName, item.accountNumber, item.accountHolder]))
	if item.status != "PENDING":
		return box
	var approve := HBoxContainer.new()
	var credited: LineEdit = null
	if kind == DEPOSIT:
		credited = _edit("승인액 (%s)" % Format.comma(amount))
		approve.add_child(credited)
	approve.add_child(_button("승인", _on_approve.bind(kind, id, credited)))
	box.add_child(approve)
	var reject := HBoxContainer.new()
	var reason := _edit("거절 사유")
	reject.add_child(reason)
	reject.add_child(_button("거절", _on_reject.bind(kind, id, reason)))
	box.add_child(reject)
	return box


## 요청 보내기. 이미 요청 중이면 빈 Dictionary
func _post(path: String, body = null, headers: Array = []) -> Dictionary:
	if _busy:
		return {}
	_busy = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, path, body, headers)
	_busy = false
	return r


## 성공·실패 표시 뒤 현재 탭 목록을 다시 읽는다(이미 처리됨 등 반영)
func _finish(r: Dictionary, done: String) -> void:
	if r.ok:
		_show_result(done)
	else:
		_show_error(r.error)
	if tabs.current_tab < 2:
		_load(tabs.current_tab, pages[tabs.current_tab])
	elif tabs.current_tab == 2:
		await _load_users(user_page)
		if user_id_edit.text != "":
			var item = user_items.get(int(user_id_edit.text))
			if item != null:
				_select_user(item)
			else:
				_on_lookup()


func _on_approve(kind: int, id: int, credited: LineEdit) -> void:
	var body = null # 비우면 본문 없이 요청 금액 그대로 승인
	if credited != null and credited.text.strip_edges() != "":
		var amount = Format.parse_amount(credited.text)
		if amount == null:
			_show_error("DEPOSIT_AMOUNT_INVALID")
			return
		body = {"creditedAmount": amount}
	var r := await _post("%s/%d/approve" % [PATHS[kind], id], body)
	if not r.is_empty():
		_finish(r, "승인했습니다")


func _on_reject(kind: int, id: int, reason: LineEdit) -> void:
	var r := await _post("%s/%d/reject" % [PATHS[kind], id], {"reason": reason.text})
	if not r.is_empty():
		_finish(r, "거절했습니다")


func _on_search() -> void:
	user_query = search_edit.text.strip_edges()
	_load_users(0)


## 회원 검색 목록 읽기. user_query 는 username/nickname 부분 일치
func _load_users(page: int) -> void:
	user_prev.disabled = true
	user_next.disabled = true
	var path := "/api/admin/users?query=%s&page=%d&size=%d" % [user_query.uri_encode(), page, PAGE_SIZE]
	users_gen += 1
	var gen := users_gen
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, path)
	if gen != users_gen:
		return
	if not r.ok:
		_show_error(r.error)
		_update_user_pager()
		return
	var new_total: int = r.data.page.totalPages
	if page >= new_total and new_total > 0:
		await _load_users(new_total - 1)
		return
	user_page = r.data.page.number
	user_total_pages = new_total
	var items := Api.page_items(r.data)
	_clear(user_rows)
	user_items.clear()
	user_empty.visible = items.is_empty()
	for item in items:
		user_items[int(item.id)] = item
		user_rows.add_child(_user_row(item))
	_update_user_pager()


func _update_user_pager() -> void:
	user_pager.visible = user_total_pages > 1
	user_page_label.text = "%d / %d" % [user_page + 1, user_total_pages]
	user_prev.disabled = user_page <= 0
	user_next.disabled = user_page >= user_total_pages - 1


func _user_row(item: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(_label("#%d" % int(item.id)))
	row.add_child(_label(item.username))
	row.add_child(_label(item.nickname, true))
	row.add_child(_label("관리자" if item.role == "ADMIN" else "일반"))
	if item.locked:
		row.add_child(_label("잠김"))
	row.add_child(_button("선택", _select_user.bind(item)))
	return row


func _select_user(item: Dictionary) -> void:
	var id := int(item.id)
	if user_id_edit.text != str(id):
		user_id_edit.text = str(id)
		_new_key() # text_changed 는 코드 대입으로 안 울린다
	if role_synced_id != id:
		role_option.select(1 if item.role == "ADMIN" else 0)
		role_synced_id = id
	selected_id = id
	var info := "%s (%s) · %s" % [item.nickname, item.username, "관리자" if item.role == "ADMIN" else "일반"]
	if item.locked:
		info += " · 잠김"
	user_info_label.text = info
	_append_balance(id, info)


## 잔액을 읽어 info 끝에 붙인다. 그 사이 다른 회원이 선택됐으면 버린다
func _append_balance(id: int, info: String) -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/admin/wallets/%d" % id)
	if selected_id != id:
		return
	if r.ok:
		user_info_label.text = "%s · 잔액 %s" % [info, Format.comma(int(r.data.balance))]
	else:
		user_info_label.text = info + " · 잔액 확인 실패" # 오류 표시는 방금 띄운 결과를 지운다


## 회원 ID 입력을 숫자로. int() 는 빈 칸·"a1" 을 조용히 0·1 로 바꾸므로 막는다. 실패하면 -1
func _target_id() -> int:
	var t := user_id_edit.text.strip_edges()
	if not t.is_valid_int():
		_show_error("USER_ID_INVALID")
		return -1
	var id := int(t)
	if id <= 0:
		_show_error("USER_ID_INVALID")
		return -1
	return id


func _on_lookup() -> void:
	if _busy:
		return
	var id := _target_id()
	if id < 0:
		return
	_busy = true
	selected_id = id
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/users/%d" % id)
	_busy = false
	if r.ok:
		var info := "%s (%s)" % [r.data.nickname, r.data.username]
		user_info_label.text = info
		_append_balance(id, info)
	else:
		user_info_label.text = ""
		_show_error(r.error)


func _on_unlock() -> void:
	var id := _target_id()
	if id < 0:
		return
	var r := await _post("/api/admin/users/%d/unlock" % id)
	if not r.is_empty():
		_finish(r, "잠금을 해제했습니다")


func _on_role() -> void:
	var id := _target_id()
	if id < 0:
		return
	var r := await _post("/api/admin/users/%d/role" % id, {"role": role_option.get_item_text(role_option.selected)})
	if not r.is_empty():
		_finish(r, "역할을 변경했습니다")


func _on_adjust() -> void:
	var id := _target_id()
	if id < 0:
		return
	var amount = Format.parse_amount(adjust_amount_edit.text) # 형식 검증이 아니라, 문자열→숫자 변환이 조용히 다른 값을 만드는 것을 막는다
	if amount == null:
		_show_error("ADJUSTMENT_AMOUNT_INVALID")
		return
	var r := await _post("/api/admin/wallets/%d/adjustments" % id, {
		"amount": amount,
		"reason": adjust_reason_edit.text,
	}, ["Idempotency-Key: " + adjust_key])
	if r.is_empty():
		return
	if not r.ok and r.error == "ADJUSTMENT_ALREADY_APPLIED":
		_show_result("이미 반영된 조정입니다")
		adjust_amount_edit.text = ""
		adjust_reason_edit.text = ""
		_new_key()
	else:
		_finish(r, "조정했습니다")
		if r.ok:
			adjust_amount_edit.text = ""
			adjust_reason_edit.text = ""
			_new_key()
