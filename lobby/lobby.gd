extends Control
## Minimal lobby shell: nickname + logout. Game/room list comes later.

@onready var nickname_label: Label = %NicknameLabel
@onready var logout_button: Button = %LogoutButton


func _ready() -> void:
	logout_button.pressed.connect(_on_logout_pressed)
	var r := await Api.request(HTTPClient.METHOD_GET, "/api/users/%d" % Api.user_id)
	if r.ok:
		nickname_label.text = "%s님" % r.data.nickname
	else:
		nickname_label.text = ErrorText.of(r.error)


func _on_logout_pressed() -> void:
	logout_button.disabled = true
	await Api.logout()
	get_tree().change_scene_to_file("res://auth/login.tscn")
