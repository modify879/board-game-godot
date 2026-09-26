extends Control
## Signup screen: register then log in with the same credentials.

@onready var username_edit: LineEdit = %UsernameEdit
@onready var nickname_edit: LineEdit = %NicknameEdit
@onready var password_edit: LineEdit = %PasswordEdit
@onready var password_confirm_edit: LineEdit = %PasswordConfirmEdit
@onready var error_label: Label = %ErrorLabel
@onready var submit_button: Button = %SubmitButton
@onready var back_button: Button = %BackButton


func _ready() -> void:
	error_label.hide()
	submit_button.pressed.connect(_on_submit_pressed)
	back_button.pressed.connect(_on_back_pressed)


func _on_submit_pressed() -> void:
	error_label.hide()
	submit_button.disabled = true
	back_button.disabled = true
	var username := username_edit.text
	var password := password_edit.text
	var r := await Api.signup(username, password, password_confirm_edit.text, nickname_edit.text)
	if r.ok:
		r = await Api.login(username, password)
	if r.ok:
		get_tree().change_scene_to_file("res://lobby/lobby.tscn")
		return
	error_label.text = ErrorText.of(r.error)
	error_label.show()
	submit_button.disabled = false
	back_button.disabled = false


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://auth/login.tscn")
