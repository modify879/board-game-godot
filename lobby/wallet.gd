extends Control
## 지갑: 잔액, 충전·환전 요청, 원장 내역.

const PAGE_SIZE := 20
const LEDGER_TYPE := {
	"DEPOSIT": "충전",
	"WITHDRAWAL_HOLD": "환전 신청",
	"WITHDRAWAL_REFUND": "환전 취소 환급",
	"ADMIN_ADJUSTMENT_CREDIT": "관리자 지급",
	"ADMIN_ADJUSTMENT_DEBIT": "관리자 차감",
	"GAME_BUY_IN": "게임 입장",
	"GAME_CASH_OUT": "게임 정산",
}
const CREDIT_TYPES := ["DEPOSIT", "WITHDRAWAL_REFUND", "ADMIN_ADJUSTMENT_CREDIT", "GAME_CASH_OUT"]
const STATUS_TEXT := {"PENDING": "대기", "APPROVED": "승인", "REJECTED": "거절", "CANCELED": "취소"}

@onready var back_button: Button = %BackButton
@onready var balance_label: Label = %BalanceLabel
@onready var error_label: Label = %ErrorLabel
@onready var tabs: TabContainer = %Tabs
@onready var deposit_edit: LineEdit = %DepositEdit
@onready var deposit_button: Button = %DepositButton
@onready var deposit_result: Label = %DepositResult
@onready var deposit_rows: VBoxContainer = %DepositRows
@onready var withdraw_amount_edit: LineEdit = %WithdrawAmountEdit
@onready var bank_name_edit: LineEdit = %BankNameEdit
@onready var account_number_edit: LineEdit = %AccountNumberEdit
@onready var account_holder_edit: LineEdit = %AccountHolderEdit
@onready var withdraw_button: Button = %WithdrawButton
@onready var withdraw_rows: VBoxContainer = %WithdrawRows
@onready var ledger_rows: VBoxContainer = %LedgerRows
@onready var empty_label: Label = %EmptyLabel
@onready var pager: HBoxContainer = %Pager
@onready var prev_button: Button = %PrevButton
@onready var page_label: Label = %PageLabel
@onready var next_button: Button = %NextButton

var ledger_page := 0
var total_pages := 0
var _busy := false


func _ready() -> void:
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	tabs.tab_changed.connect(_load_tab)
	deposit_button.pressed.connect(_on_deposit)
	withdraw_button.pressed.connect(_on_withdraw)
	prev_button.pressed.connect(func() -> void: _load_ledger(ledger_page - 1))
	next_button.pressed.connect(func() -> void: _load_ledger(ledger_page + 1))
	_load_balance()
	_load_tab(tabs.current_tab)


## 천 단위 쉼표
static func comma(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


## ISO Instant(UTC) → 로컬 "MM-DD HH:MM". 소수 초·Z 는 앞 19자만 써서 버린다
static func format_time(iso: String) -> String:
	var t := int(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))
	t += int(Time.get_time_zone_from_system().bias) * 60
	var d := Time.get_datetime_dict_from_unix_time(t)
	return "%02d-%02d %02d:%02d" % [d.month, d.day, d.hour, d.minute]


func _load_tab(index: int) -> void:
	error_label.hide()
	match index:
		0: _load_deposits()
		1: _load_withdrawals()
		2: _load_ledger(0)


func _show_error(code: String) -> void:
	error_label.text = ErrorText.of(code)
	error_label.show()


func _load_balance() -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet")
	if r.ok:
		balance_label.text = "잔액 %s" % comma(int(r.data.balance))
	else:
		_show_error(r.error)


func _label(text: String, expand := false) -> Label:
	var l := Label.new()
	l.text = text
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


func _clear(rows: VBoxContainer) -> void:
	for child in rows.get_children():
		child.queue_free()


func _load_deposits() -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet/deposit-requests?page=0&size=20")
	if not r.ok:
		_show_error(r.error)
		return
	_clear(deposit_rows)
	for item in Api.page_items(r.data):
		var row := HBoxContainer.new()
		row.add_child(_label(format_time(item.requestedAt)))
		row.add_child(_label("%s원" % comma(int(item.requestedAmount)), true))
		var status: String = STATUS_TEXT.get(item.status, item.status)
		if item.status == "APPROVED" and item.creditedAmount != null:
			status += " (%s)" % comma(int(item.creditedAmount))
		elif item.status == "REJECTED" and item.rejectionReason != null:
			status += " (%s)" % item.rejectionReason
		row.add_child(_label(status))
		if item.status == "PENDING":
			row.add_child(_cancel_button("/api/wallet/deposit-requests/%d" % int(item.id), _load_deposits))
		deposit_rows.add_child(row)


func _load_withdrawals() -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet/withdrawal-requests?page=0&size=20")
	if not r.ok:
		_show_error(r.error)
		return
	_clear(withdraw_rows)
	for item in Api.page_items(r.data):
		var row := HBoxContainer.new()
		row.add_child(_label(format_time(item.requestedAt)))
		row.add_child(_label("%s원" % comma(int(item.amount))))
		row.add_child(_label("%s %s" % [item.bankName, item.accountNumber], true))
		var status: String = STATUS_TEXT.get(item.status, item.status)
		if item.status == "REJECTED" and item.rejectionReason != null:
			status += " (%s)" % item.rejectionReason
		row.add_child(_label(status))
		if item.status == "PENDING":
			row.add_child(_cancel_button("/api/wallet/withdrawal-requests/%d" % int(item.id), _load_withdrawals, true))
		withdraw_rows.add_child(row)


func _cancel_button(path: String, reload: Callable, refund := false) -> Button:
	var b := Button.new()
	b.text = "취소"
	b.pressed.connect(_on_cancel.bind(b, path, reload, refund))
	return b


func _on_cancel(button: Button, path: String, reload: Callable, refund: bool) -> void:
	if _busy:
		return
	_busy = true
	button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, path)
	_busy = false
	if not r.ok:
		_show_error(r.error) # ALREADY_PROCESSED·NOT_FOUND 도 아래에서 목록을 다시 읽는다
	else:
		error_label.hide()
	reload.call()
	if r.ok and refund:
		_load_balance()


func _load_ledger(page: int) -> void:
	prev_button.disabled = true
	next_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet/ledger?page=%d&size=%d" % [page, PAGE_SIZE])
	if not r.ok:
		_show_error(r.error)
		_update_pager()
		return
	var page_info: Dictionary = r.data.page
	var new_total_pages: int = page_info.totalPages
	if page >= new_total_pages and new_total_pages > 0:
		_load_ledger(new_total_pages - 1)
		return
	ledger_page = page_info.number
	total_pages = new_total_pages
	var items := Api.page_items(r.data)
	_clear(ledger_rows)
	empty_label.visible = items.is_empty()
	for item in items:
		var row := HBoxContainer.new()
		row.add_child(_label(format_time(item.occurredAt)))
		row.add_child(_label(LEDGER_TYPE.get(item.type, item.type), true))
		var sign := "+" if item.type in CREDIT_TYPES else "-"
		row.add_child(_label(sign + comma(int(item.amount))))
		row.add_child(_label("잔액 %s" % comma(int(item.balanceAfter))))
		ledger_rows.add_child(row)
	_update_pager()


func _update_pager() -> void:
	pager.visible = total_pages > 1
	page_label.text = "%d / %d" % [ledger_page + 1, total_pages]
	prev_button.disabled = ledger_page <= 0
	next_button.disabled = ledger_page >= total_pages - 1


func _on_deposit() -> void:
	if _busy:
		return
	_busy = true
	deposit_button.disabled = true
	var amount := int(deposit_edit.text)
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/wallet/deposit-requests", {"amount": amount})
	_busy = false
	deposit_button.disabled = false
	if not r.ok:
		_show_error(r.error)
		return
	error_label.hide()
	var a: Dictionary = r.data.depositAccount
	deposit_result.text = "아래 계좌로 %s 원을 입금해주세요\n%s %s (예금주 %s)\n관리자 확인 후 잔액에 들어옵니다" % [
		comma(amount), a.bankName, a.accountNumber, a.accountHolder]
	_load_deposits()


func _on_withdraw() -> void:
	if _busy:
		return
	_busy = true
	withdraw_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/wallet/withdrawal-requests", {
		"amount": int(withdraw_amount_edit.text),
		"bankName": bank_name_edit.text,
		"accountNumber": account_number_edit.text,
		"accountHolder": account_holder_edit.text,
	})
	_busy = false
	withdraw_button.disabled = false
	if not r.ok:
		_show_error(r.error)
		return
	error_label.hide()
	for e in [withdraw_amount_edit, bank_name_edit, account_number_edit, account_holder_edit]:
		e.text = ""
	_load_withdrawals()
	_load_balance()
