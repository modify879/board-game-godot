extends SceneTree
## Self-check for games/holdem/cards.gd static logic. Run with:
## Godot.exe --headless --path . --script res://games/holdem/test_holdem.gd

var failures := 0


func _init() -> void:
	var cards := preload("res://games/holdem/cards.gd")

	# texture_path
	check(cards.texture_path("As") == "res://games/holdem/assets/cards/As.png", "texture_path builds res:// path")
	for code in ["Td", "As", "2c"]:
		var path: String = cards.texture_path(code)
		check(ResourceLoader.exists(path), "texture_path file exists: " + code)

	# category_text / street_text
	check(cards.category_text("FULL_HOUSE") == "풀하우스", "category_text known")
	check(cards.category_text("NOPE") == "NOPE", "category_text unknown fallback")
	check(cards.street_text("RIVER") == "리버", "street_text known")

	quit(1 if failures else 0)


func check(cond: bool, name: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: ", name)
	else:
		print("ok: ", name)
