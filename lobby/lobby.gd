extends Control
## Minimal lobby shell: nickname + logout + game list.

const GAMES := [
	{"title": "텍사스 홀덤", "scene": "res://games/holdem/table_list.tscn",
		"description": "최대 9인 노리밋 텍사스 홀덤", "color": Color("1B5E3A")},
]

@onready var nickname_label: Label = %NicknameLabel
@onready var balance_label: Label = %BalanceLabel
@onready var wallet_button: Button = %WalletButton
@onready var admin_button: Button = %AdminButton
@onready var logout_button: Button = %LogoutButton
@onready var game_list: HFlowContainer = %GameList


func _ready() -> void:
	logout_button.pressed.connect(_on_logout_pressed)
	wallet_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://lobby/wallet.tscn"))
	admin_button.visible = Api.is_admin()
	admin_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://admin/admin.tscn"))
	Balance.load_into(balance_label)
	for game in GAMES:
		game_list.add_child(_make_card(game))
	_fit_cards()
	resized.connect(_fit_cards)
	var r := await Api.request(HTTPClient.METHOD_GET, "/api/users/%d" % Api.user_id)
	if r.ok:
		nickname_label.text = "%s님" % r.data.nickname
	else:
		nickname_label.text = ErrorText.of(r.error)


func _make_card(game: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.theme_type_variation = &"PanelCard"
	card.custom_minimum_size = Vector2(300, 220)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	card.add_child(box)
	var banner := PanelContainer.new()
	banner.custom_minimum_size.y = 96
	var sb := StyleBoxFlat.new()
	sb.bg_color = game.color
	sb.corner_radius_top_left = 11
	sb.corner_radius_top_right = 11
	banner.add_theme_stylebox_override("panel", sb)
	var title := Label.new()
	title.text = game.title
	title.theme_type_variation = &"LabelTitle"
	title.add_theme_color_override("font_color", Color.WHITE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.add_child(title)
	box.add_child(banner)
	var pad := MarginContainer.new()
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 16)
	box.add_child(pad)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 12)
	pad.add_child(inner)
	var desc := Label.new()
	desc.text = game.description
	desc.theme_type_variation = &"LabelHint"
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(desc)
	var enter := Button.new()
	enter.text = "입장"
	enter.theme_type_variation = &"ButtonPrimary"
	enter.pressed.connect(func() -> void: get_tree().change_scene_to_file(game.scene))
	inner.add_child(enter)
	return card


## Phone width: each card spans the row.
func _fit_cards() -> void:
	var w := size.x - 32.0
	for card in game_list.get_children():
		card.custom_minimum_size.x = w if size.x < 700 else 300.0


func _on_logout_pressed() -> void:
	logout_button.disabled = true
	await Api.logout()
	get_tree().change_scene_to_file("res://auth/login.tscn")
