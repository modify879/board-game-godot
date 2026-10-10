extends Control
## 관리자: 충전·환전 요청 처리, 회원 관리(잠금 해제·역할·잔액 조정).

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
@onready var users := Pager.new(%UserPager, %UserPrev, %UserPage, %UserNext, _load_users)
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
@onready var pagers: Array[Pager] = [
	Pager.new(%DepositPager, %DepositPrev, %DepositPage, %DepositNext, func(p: int) -> void: _load(DEPOSIT, p)),
	Pager.new(%WithdrawPager, %WithdrawPrev, %WithdrawPage, %WithdrawNext, func(p: int) -> void: _load(WITHDRAW, p)),
]

var adjust_key := ""
var selected_id := -1 # 잔액 응답이 낡았는지 가리는 기준
var role_synced_id := -1 # 역할 드롭다운을 서버 값으로 맞춘 회원 — 같은 회원을 다시 그릴 때는 관리자가 고른 값을 유지한다
var user_query := ""
var user_items := {} # 현재 페이지 회원 (id → item)
var _busy := false


func _ready() -> void:
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	tabs.tab_changed.connect(_on_tab_changed)
	for k in 2:
		statuses[k].item_selected.connect(func(_i: int) -> void: _load(k, 0))
	search_button.pressed.connect(_on_search)
	search_edit.text_submitted.connect(func(_t: String) -> void: _on_search())
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
		_load(index, pagers[index].page)
	elif index == 2:
		_load_users(users.page)


func _show_error(code: String) -> void:
	error_label.text = ErrorText.of(code)
	error_label.show()
	result_label.hide()


func _show_result(text: String) -> void:
	result_label.text = text
	result_label.show()
	error_label.hide()


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
	var gen := pagers[kind].begin()
	var path: String = PATHS[kind] + "?page=%d&size=%d" % [page, PAGE_SIZE]
	if statuses[kind].selected == 0:
		path += "&status=PENDING"
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, path)
	if not await pagers[kind].accept(gen, page, r, func(p: int) -> void: await _load(kind, p), _show_error):
		return
	var items := Api.page_items(r.data)
	Rows.clear(rows[kind])
	empties[kind].visible = items.is_empty()
	for item in items:
		rows[kind].add_child(_request_row(kind, item))
	pagers[kind].update()


func _request_row(kind: int, item: Dictionary) -> VBoxContainer:
	var id := int(item.id)
	var amount := int(item.requestedAmount) if kind == DEPOSIT else int(item.amount)
	var box := VBoxContainer.new()
	var info := HBoxContainer.new()
	info.add_child(Rows.label("#%d" % id))
	info.add_child(Rows.label("회원 %d" % int(item.userId)))
	info.add_child(Rows.label(Format.time(item.requestedAt)))
	info.add_child(Rows.label("%s원" % Format.comma(amount), true))
	var status: String = Format.request_status(item.status)
	if kind == DEPOSIT and item.status == "APPROVED" and item.creditedAmount != null:
		status += " (%s)" % Format.comma(int(item.creditedAmount))
	elif item.status == "REJECTED" and item.rejectionReason != null:
		status += " (%s)" % item.rejectionReason
	info.add_child(Rows.label(status))
	box.add_child(info)
	if kind == WITHDRAW:
		box.add_child(Rows.label("%s %s (예금주 %s)" % [item.bankName, item.accountNumber, item.accountHolder]))
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


## 요청 중에는 뒤로 가지 못하게 한다 — 화면이 해제된 노드에서 응답이 재개되지 않게
func _set_busy(on: bool) -> void:
	_busy = on
	back_button.disabled = on


## 요청 보내기. 호출부가 _set_busy(true) 로 잡고 _finish 뒤에 푼다 — 재조회까지 끝나야 뒤로 갈 수 있다
func _post(path: String, body = null, headers: Array = []) -> Dictionary:
	return await Api.request(HTTPClient.METHOD_POST, path, body, headers)


## 현재 탭 목록을 다시 읽은 뒤(이미 처리됨 등 반영) 결과를 띄운다 — 재조회 실패가 결과 문구를 숨기지 않게 맨 끝에 둔다
## target_id 가 있으면 회원 탭을 그 회원으로 다시 그린다(입력칸이 아니라 실제로 보낸 대상)
func _finish(r: Dictionary, done: String, target_id := -1) -> void:
	# 호출부가 busy 를 쥐고 있다 — 재조회는 _lookup 의 busy 가드를 건너뛴다(force)
	if tabs.current_tab < 2:
		await _load(tabs.current_tab, pagers[tabs.current_tab].page)
	elif tabs.current_tab == 2:
		await _load_users(users.page)
		if target_id > 0:
			var item = user_items.get(target_id)
			if item != null:
				await _show_user(item)
			else:
				await _do_lookup(target_id, true)
	if r.ok:
		_show_result(done)
	else:
		_show_error(r.error)


func _on_approve(kind: int, id: int, credited: LineEdit) -> void:
	var body = null # 비우면 본문 없이 요청 금액 그대로 승인
	if credited != null and credited.text.strip_edges() != "":
		var amount = Format.parse_amount(credited.text)
		var invalid := "DEPOSIT_AMOUNT_INVALID" if amount == null else InputRules.credited_amount(amount)
		if invalid != "":
			_show_error(invalid)
			return
		body = {"creditedAmount": amount}
	if _busy:
		return
	_set_busy(true)
	var r := await _post("%s/%d/approve" % [PATHS[kind], id], body)
	await _finish(r, "승인했습니다")
	_set_busy(false)


func _on_reject(kind: int, id: int, reason: LineEdit) -> void:
	var invalid := InputRules.reject_reason(reason.text)
	if invalid != "":
		_show_error(invalid)
		return
	if _busy:
		return
	_set_busy(true)
	var r := await _post("%s/%d/reject" % [PATHS[kind], id], {"reason": reason.text})
	await _finish(r, "거절했습니다")
	_set_busy(false)


func _on_search() -> void:
	user_query = search_edit.text.strip_edges()
	_load_users(0)


## 회원 검색 목록 읽기. user_query 는 username/nickname 부분 일치
func _load_users(page: int) -> void:
	var gen := users.begin()
	var path := "/api/admin/users?query=%s&page=%d&size=%d" % [user_query.uri_encode(), page, PAGE_SIZE]
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, path)
	if not await users.accept(gen, page, r, _load_users, _show_error):
		return
	var items := Api.page_items(r.data)
	Rows.clear(user_rows)
	user_items.clear()
	user_empty.visible = items.is_empty()
	for item in items:
		user_items[int(item.id)] = item
		user_rows.add_child(_user_row(item))
	users.update()


func _user_row(item: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(Rows.label("#%d" % int(item.id)))
	row.add_child(Rows.label(item.username))
	row.add_child(Rows.label(item.nickname, true))
	row.add_child(Rows.label("관리자" if item.role == "ADMIN" else "일반"))
	if item.locked:
		row.add_child(Rows.label("잠김"))
	row.add_child(_button("선택", _select_user.bind(item)))
	return row


## 목록 행의 "선택" 버튼. 잔액 조회가 끝날 때까지 busy
func _select_user(item: Dictionary) -> void:
	if _busy:
		return
	_set_busy(true)
	await _show_user(item)
	_set_busy(false)


## 회원을 입력칸·정보 라벨에 반영하고 잔액을 읽는다. busy 는 호출부가 쥔다
func _show_user(item: Dictionary) -> void:
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
	await _append_balance(id, info)


## 잔액을 읽어 info 끝에 붙인다. 그 사이 다른 회원이 선택됐으면 버린다
func _append_balance(id: int, info: String) -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/admin/wallets/%d" % id)
	if selected_id != id:
		return
	if r.ok:
		user_info_label.text = "%s · %s" % [info, Format.balance(int(r.data.balance))]
	else:
		user_info_label.text = info + " · " + Format.BALANCE_FAILED # 오류 표시는 방금 띄운 결과를 지운다


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
	var id := _target_id()
	if id > 0:
		_lookup(id)


func _lookup(id: int) -> void:
	if _busy:
		return
	_set_busy(true)
	await _do_lookup(id, false)
	_set_busy(false)


## 회원 조회 본체. busy 는 호출부가 쥔다
func _do_lookup(id: int, quiet: bool) -> void:
	selected_id = id
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/users/%d" % id)
	if selected_id != id:
		return
	if r.ok:
		# /api/users/{id} 에는 role·locked 가 없다 — 관리자 목록에서 같은 회원을 찾아 맞춘다
		var list: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/admin/users?query=%s&size=20" % str(r.data.username).uri_encode())
		if selected_id != id:
			return
		if list.ok:
			for item in Api.page_items(list.data):
				if int(item.id) == id:
					await _show_user(item)
					return
		role_synced_id = -1 # 서버 값을 못 읽었다 — 다음 선택 때 맞춘다
		var info := "%s (%s)" % [r.data.nickname, r.data.username]
		user_info_label.text = info
		await _append_balance(id, info)
	elif quiet: # 작업 뒤 재조회 실패가 방금 띄운 결과를 덮지 않게
		user_info_label.text = "회원 정보 확인 실패"
	else:
		user_info_label.text = ""
		_show_error(r.error)


func _on_unlock() -> void:
	var id := _target_id()
	if id < 0:
		return
	if _busy:
		return
	_set_busy(true)
	var r := await _post("/api/admin/users/%d/unlock" % id)
	await _finish(r, "잠금을 해제했습니다", id)
	_set_busy(false)


func _on_role() -> void:
	var id := _target_id()
	if id < 0:
		return
	if _busy:
		return
	_set_busy(true)
	var r := await _post("/api/admin/users/%d/role" % id, {"role": role_option.get_item_text(role_option.selected)})
	if not r.ok:
		role_synced_id = -1 # 실패하면 드롭다운이 서버 값으로 돌아오게 재그리기에서 강제 동기화
	await _finish(r, "역할을 변경했습니다", id)
	_set_busy(false)


func _on_adjust() -> void:
	var id := _target_id()
	if id < 0:
		return
	var amount = Format.parse_amount(adjust_amount_edit.text) # 변환 오류를 막고, 형식은 InputRules 가 본다
	var invalid := "ADJUSTMENT_AMOUNT_INVALID" if amount == null else InputRules.adjust(amount, adjust_reason_edit.text)
	if invalid != "":
		_show_error(invalid)
		return
	if _busy:
		return
	_set_busy(true)
	var r := await _post("/api/admin/wallets/%d/adjustments" % id, {
		"amount": amount,
		"reason": adjust_reason_edit.text,
	}, ["Idempotency-Key: " + adjust_key])
	var applied: bool = r.ok or r.error == "ADJUSTMENT_ALREADY_APPLIED"
	if applied:
		adjust_amount_edit.text = ""
		adjust_reason_edit.text = ""
		_new_key()
	elif not Api.keeps_idempotency_key(r):
		_new_key()
	await _finish(r if not applied else {"ok": true}, "조정했습니다" if r.ok else "이미 반영된 조정입니다", id)
	_set_busy(false)
