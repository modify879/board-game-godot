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
		check(ResourceLoader.exists(path), "texture_path file exists (ResourceLoader): " + code)
		check(FileAccess.file_exists(path), "texture_path file exists (FileAccess): " + code)

	# category_text: all 9 categories + unknown fallback
	var categories := {
		"HIGH_CARD": "하이카드", "PAIR": "원 페어", "TWO_PAIR": "투 페어",
		"THREE_OF_A_KIND": "트리플", "STRAIGHT": "스트레이트", "FLUSH": "플러시",
		"FULL_HOUSE": "풀하우스", "FOUR_OF_A_KIND": "포카드", "STRAIGHT_FLUSH": "스트레이트 플러시",
	}
	for category in categories:
		check(cards.category_text(category) == categories[category], "category_text: " + category)
	check(cards.category_text("NOPE") == "NOPE", "category_text unknown fallback")

	# street_text
	check(cards.street_text("PREFLOP") == "프리플롭", "street_text PREFLOP")
	check(cards.street_text("FLOP") == "플랍", "street_text FLOP")
	check(cards.street_text("TURN") == "턴", "street_text TURN")
	check(cards.street_text("RIVER") == "리버", "street_text RIVER")

	quit(1 if failures else 0)


func check(cond: bool, name: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: ", name)
	else:
		print("ok: ", name)
