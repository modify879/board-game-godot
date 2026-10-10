extends Control
## Minimal lobby shell: nickname + logout + game list.

const GAMES := [
	{"title": "텍사스 홀덤", "scene": "res://games/holdem/table_list.tscn"},
]

@onready var nickname_label: Label = %NicknameLabel
@onready var balance_label: Label = %BalanceLabel
@onready var wallet_button: Button = %WalletButton
@onready var admin_button: Button = %AdminButton
@onready var logout_button: Button = %LogoutButton
@onready var game_list: VBoxContainer = %GameList


func _ready() -> void:
	logout_button.pressed.connect(_on_logout_pressed)
	wallet_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/wallet.tscn"))
	admin_button.visible = Api.is_admin()
	admin_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://admin/admin.tscn"))
	_load_balance()
	for game in GAMES:
		var button := Button.new()
		button.text = game.title
		button.custom_minimum_size = Vector2(240, 56)
		button.pressed.connect(func() -> void: get_tree().change_scene_to_file(game.scene))
		game_list.add_child(button)
	var r := await Api.request(HTTPClient.METHOD_GET, "/api/users/%d" % Api.user_id)
	if r.ok:
		nickname_label.text = "%s님" % r.data.nickname
	else:
		nickname_label.text = ErrorText.of(r.error)


func _load_balance() -> void:
	var r := await Api.request(HTTPClient.METHOD_GET, "/api/wallet")
	if r.ok:
		balance_label.text = Format.balance(int(r.data.balance))
	else:
		balance_label.text = Format.BALANCE_FAILED


func _on_logout_pressed() -> void:
	logout_button.disabled = true
	await Api.logout()
	get_tree().change_scene_to_file("res://auth/login.tscn")
