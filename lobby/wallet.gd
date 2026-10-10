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
const DEBIT_TYPES := ["WITHDRAWAL_HOLD", "ADMIN_ADJUSTMENT_DEBIT", "GAME_BUY_IN"]
const DEPOSIT := 0
const WITHDRAW := 1
const LEDGER := 2

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

# 목록 탭별 페이저 (DEPOSIT, WITHDRAW, LEDGER 순)
@onready var pagers: Array[HBoxContainer] = [%DepositPager, %WithdrawPager, %Pager]
@onready var prevs: Array[Button] = [%DepositPrev, %WithdrawPrev, %PrevButton]
@onready var page_labels: Array[Label] = [%DepositPage, %WithdrawPage, %PageLabel]
@onready var nexts: Array[Button] = [%DepositNext, %WithdrawNext, %NextButton]

var pages := [0, 0, 0]
var total_pages := [0, 0, 0]
var gens := [0, 0, 0] # 목록 응답이 낡았는지 가리는 세대
var _busy := false
# 입력이 바뀌거나 성공했을 때만 새 키 — 실패 뒤 그대로 다시 누르면 같은 키가 나가 요청이 두 번 생기지 않는다
var deposit_key := ""
var withdraw_key := ""


func _ready() -> void:
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/lobby.tscn"))
	tabs.tab_changed.connect(_load_tab)
	deposit_button.pressed.connect(_on_deposit)
	withdraw_button.pressed.connect(_on_withdraw)
	_new_deposit_key()
	_new_withdraw_key()
	deposit_edit.text_changed.connect(func(_t: String) -> void: _new_deposit_key())
	for e in [withdraw_amount_edit, bank_name_edit, account_number_edit, account_holder_edit]:
		e.text_changed.connect(func(_t: String) -> void: _new_withdraw_key())
	var loaders := [_load_deposits, _load_withdrawals, _load_ledger]
	for k in 3:
		prevs[k].pressed.connect(func() -> void: loaders[k].call(pages[k] - 1))
		nexts[k].pressed.connect(func() -> void: loaders[k].call(pages[k] + 1))
	_load_balance()
	_load_tab(tabs.current_tab)


func _new_deposit_key() -> void:
	deposit_key = Api.new_idempotency_key()


func _new_withdraw_key() -> void:
	withdraw_key = Api.new_idempotency_key()


func _load_tab(index: int) -> void:
	error_label.hide()
	match index:
		0: _load_deposits(pages[DEPOSIT])
		1: _load_withdrawals(pages[WITHDRAW])
		2: _load_ledger(pages[LEDGER])


## 요청 중에는 뒤로 가지 못하게 한다 — 화면이 해제된 노드에서 응답이 재개되지 않게
func _set_busy(on: bool) -> void:
	_busy = on
	back_button.disabled = on


func _show_error(code: String) -> void:
	error_label.text = ErrorText.of(code)
	error_label.show()


func _load_balance() -> void:
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet")
	if r.ok:
		balance_label.text = "잔액 %s" % Format.comma(int(r.data.balance))
	else:
		_show_error(r.error)


## 목록 응답을 받은 뒤 공통 처리. 낡았거나 실패·마지막 페이지 초과면 false (초과는 마지막 페이지로 다시 읽는다)
func _accept(kind: int, gen: int, page: int, r: Dictionary, reload: Callable) -> bool:
	if gen != gens[kind]:
		return false
	if not r.ok:
		_show_error(r.error)
		_update_pager(kind)
		return false
	var new_total: int = r.data.page.totalPages
	if page >= new_total and new_total > 0:
		reload.call(new_total - 1)
		return false
	pages[kind] = r.data.page.number
	total_pages[kind] = new_total
	return true


func _begin(kind: int) -> int:
	prevs[kind].disabled = true
	nexts[kind].disabled = true
	gens[kind] += 1
	return gens[kind]


func _load_deposits(page: int) -> void:
	var gen := _begin(DEPOSIT)
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet/deposit-requests?page=%d&size=%d" % [page, PAGE_SIZE])
	if not _accept(DEPOSIT, gen, page, r, _load_deposits):
		return
	Rows.clear(deposit_rows)
	for item in Api.page_items(r.data):
		var row := HBoxContainer.new()
		row.add_child(Rows.label(Format.time(item.requestedAt)))
		row.add_child(Rows.label("%s원" % Format.comma(int(item.requestedAmount)), true))
		var status: String = Format.request_status(item.status)
		if item.status == "APPROVED" and item.creditedAmount != null:
			status += " (%s)" % Format.comma(int(item.creditedAmount))
		elif item.status == "REJECTED" and item.rejectionReason != null:
			status += " (%s)" % item.rejectionReason
		row.add_child(Rows.label(status))
		if item.status == "PENDING":
			row.add_child(_cancel_button("/api/wallet/deposit-requests/%d" % int(item.id), func() -> void: _load_deposits(pages[DEPOSIT])))
		deposit_rows.add_child(row)
	_update_pager(DEPOSIT)


func _load_withdrawals(page: int) -> void:
	var gen := _begin(WITHDRAW)
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet/withdrawal-requests?page=%d&size=%d" % [page, PAGE_SIZE])
	if not _accept(WITHDRAW, gen, page, r, _load_withdrawals):
		return
	Rows.clear(withdraw_rows)
	for item in Api.page_items(r.data):
		var row := HBoxContainer.new()
		row.add_child(Rows.label(Format.time(item.requestedAt)))
		row.add_child(Rows.label("%s원" % Format.comma(int(item.amount))))
		row.add_child(Rows.label("%s %s" % [item.bankName, item.accountNumber], true))
		var status: String = Format.request_status(item.status)
		if item.status == "REJECTED" and item.rejectionReason != null:
			status += " (%s)" % item.rejectionReason
		row.add_child(Rows.label(status))
		if item.status == "PENDING":
			row.add_child(_cancel_button("/api/wallet/withdrawal-requests/%d" % int(item.id), func() -> void: _load_withdrawals(pages[WITHDRAW]), true))
		withdraw_rows.add_child(row)
	_update_pager(WITHDRAW)


func _cancel_button(path: String, reload: Callable, refund := false) -> Button:
	var b := Button.new()
	b.text = "취소"
	b.pressed.connect(_on_cancel.bind(b, path, reload, refund))
	return b


func _on_cancel(button: Button, path: String, reload: Callable, refund: bool) -> void:
	if _busy:
		return
	_set_busy(true)
	button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_DELETE, path)
	if not r.ok:
		_show_error(r.error) # ALREADY_PROCESSED·NOT_FOUND 도 아래에서 목록을 다시 읽는다
	else:
		error_label.hide()
	await reload.call()
	if r.ok and refund:
		await _load_balance()
	_set_busy(false)


func _load_ledger(page: int) -> void:
	var gen := _begin(LEDGER)
	var r: Dictionary = await Api.request(HTTPClient.METHOD_GET, "/api/wallet/ledger?page=%d&size=%d" % [page, PAGE_SIZE])
	if not _accept(LEDGER, gen, page, r, _load_ledger):
		return
	var items := Api.page_items(r.data)
	Rows.clear(ledger_rows)
	empty_label.visible = items.is_empty()
	for item in items:
		var row := HBoxContainer.new()
		row.add_child(Rows.label(Format.time(item.occurredAt)))
		row.add_child(Rows.label(LEDGER_TYPE.get(item.type, item.type), true))
		var sign := "+" if item.type in CREDIT_TYPES else ("-" if item.type in DEBIT_TYPES else "") # 모르는 종류는 부호 없이
		row.add_child(Rows.label(sign + Format.comma(int(item.amount))))
		row.add_child(Rows.label("잔액 %s" % Format.comma(int(item.balanceAfter))))
		ledger_rows.add_child(row)
	_update_pager(LEDGER)


func _update_pager(kind: int) -> void:
	pagers[kind].visible = total_pages[kind] > 1
	page_labels[kind].text = "%d / %d" % [pages[kind] + 1, total_pages[kind]]
	prevs[kind].disabled = pages[kind] <= 0
	nexts[kind].disabled = pages[kind] >= total_pages[kind] - 1


func _on_deposit() -> void:
	if _busy:
		return
	deposit_result.text = "" # 실패 시 지난 안내가 새 요청 것처럼 남지 않게
	var amount = Format.parse_amount(deposit_edit.text)
	var invalid := "DEPOSIT_AMOUNT_INVALID" if amount == null else InputRules.deposit_amount(amount)
	if invalid != "":
		_show_error(invalid)
		return
	_set_busy(true)
	deposit_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/wallet/deposit-requests", {"amount": amount}, ["Idempotency-Key: " + deposit_key])
	deposit_button.disabled = false
	if not r.ok:
		if not Api.keeps_idempotency_key(r):
			_new_deposit_key()
		_show_error(r.error)
		_set_busy(false)
		return
	error_label.hide()
	deposit_edit.text = "" # 코드 대입은 text_changed 를 안 울린다
	_new_deposit_key()
	var a: Dictionary = r.data.depositAccount
	deposit_result.text = "아래 계좌로 %s 원을 입금해주세요\n%s %s (예금주 %s)\n관리자 확인 후 잔액에 들어옵니다" % [
		Format.comma(amount), a.bankName, a.accountNumber, a.accountHolder]
	await _load_deposits(0) # 새 요청은 최신순 첫 페이지에 있다
	_set_busy(false)


func _on_withdraw() -> void:
	if _busy:
		return
	var amount = Format.parse_amount(withdraw_amount_edit.text)
	var invalid := "WITHDRAWAL_AMOUNT_INVALID" if amount == null else InputRules.withdrawal_amount(amount)
	if invalid == "":
		invalid = InputRules.bank_account(bank_name_edit.text, account_number_edit.text, account_holder_edit.text)
	if invalid != "":
		_show_error(invalid)
		return
	_set_busy(true)
	withdraw_button.disabled = true
	var r: Dictionary = await Api.request(HTTPClient.METHOD_POST, "/api/wallet/withdrawal-requests", {
		"amount": amount,
		"bankName": bank_name_edit.text,
		"accountNumber": account_number_edit.text,
		"accountHolder": account_holder_edit.text,
	}, ["Idempotency-Key: " + withdraw_key])
	withdraw_button.disabled = false
	if not r.ok:
		if not Api.keeps_idempotency_key(r):
			_new_withdraw_key()
		_show_error(r.error)
		_set_busy(false)
		return
	error_label.hide()
	for e in [withdraw_amount_edit, bank_name_edit, account_number_edit, account_holder_edit]:
		e.text = ""
	_new_withdraw_key()
	await _load_withdrawals(0) # 새 요청은 최신순 첫 페이지에 있다
	await _load_balance()
	_set_busy(false)
