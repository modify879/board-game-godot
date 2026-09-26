extends Control
## Login screen (main scene): resume session, then login or go to signup.

@onready var status_label: Label = %StatusLabel
@onready var form: VBoxContainer = %Form
@onready var username_edit: LineEdit = %UsernameEdit
@onready var password_edit: LineEdit = %PasswordEdit
@onready var error_label: Label = %ErrorLabel
@onready var login_button: Button = %LoginButton
@onready var signup_button: Button = %SignupButton


func _ready() -> void:
	form.hide()
	error_label.hide()
	status_label.show()
	login_button.pressed.connect(_on_login_pressed)
	signup_button.pressed.connect(_on_signup_pressed)
	password_edit.text_submitted.connect(func(_text: String) -> void: _on_login_pressed())
	if await Api.try_resume():
		get_tree().change_scene_to_file("res://lobby/lobby.tscn")
		return
	status_label.hide()
	form.show()


func _on_login_pressed() -> void:
	if login_button.disabled:
		return # Enter pressed while a request is pending
	error_label.hide()
	login_button.disabled = true
	signup_button.disabled = true
	var r := await Api.login(username_edit.text, password_edit.text)
	if r.ok:
		get_tree().change_scene_to_file("res://lobby/lobby.tscn")
		return
	error_label.text = ErrorText.of(r.error)
	error_label.show()
	login_button.disabled = false
	signup_button.disabled = false


func _on_signup_pressed() -> void:
	get_tree().change_scene_to_file("res://auth/signup.tscn")
