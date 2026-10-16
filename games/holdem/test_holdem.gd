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

	# table_name
	var rules := preload("res://games/holdem/rules.gd")
	check(rules.table_name("  ") == "TABLE_NAME_INVALID", "방 이름 공백만 거부")
	check(rules.table_name("a".repeat(31)) == "TABLE_NAME_INVALID", "방 이름 31자 거부")
	check(rules.table_name("a".repeat(30)) == "", "방 이름 30자 통과")
	check(rules.table_name(" a ") == "", "방 이름 trim 후 1자 통과")

	# buy_in / chip_add — 서버 순서: 단위 → 범위 → 지갑
	check(rules.buy_in(4000, 4000, 20000, 100000) == "", "바이인 하한 통과")
	check(rules.buy_in(20000, 4000, 20000, 100000) == "", "바이인 상한 통과")
	check(rules.buy_in(4050, 4000, 20000, 100000) == "CHIPS_NOT_UNIT", "바이인 100 단위 아님")
	check(rules.buy_in(3900, 4000, 20000, 100000) == "BUY_IN_OUT_OF_RANGE", "바이인 하한 미만")
	check(rules.buy_in(20100, 4000, 20000, 100000) == "BUY_IN_OUT_OF_RANGE", "바이인 상한 초과")
	check(rules.buy_in(5000, 4000, 20000, 4900) == "INSUFFICIENT_BALANCE", "바이인이 지갑 초과")
	check(rules.buy_in(3950, 4000, 20000, 100) == "CHIPS_NOT_UNIT", "단위가 범위·지갑보다 먼저")
	check(rules.buy_in(3900, 4000, 20000, 100) == "BUY_IN_OUT_OF_RANGE", "범위가 지갑보다 먼저")
	check(rules.buy_in(5000, 4000, 20000) == "", "지갑을 모르면 지갑 검사 생략")
	check(rules.chip_add(5000, 15000, 20000, 9000) == "", "칩 추가 상한 정확히 통과")
	check(rules.chip_add(5100, 15000, 20000, 9000) == "CHIP_ADD_OUT_OF_RANGE", "칩 추가 스택 상한 초과")
	check(rules.chip_add(0, 1000, 20000, 9000) == "CHIP_ADD_OUT_OF_RANGE", "칩 추가 0 거부")
	check(rules.chip_add(150, 1000, 20000, 9000) == "CHIPS_NOT_UNIT", "칩 추가 단위")
	check(rules.chip_add(2000, 1000, 20000, 1900) == "INSUFFICIENT_BALANCE", "칩 추가가 지갑 초과")
	check(rules.buy_in_blocked_text({"walletBalance": 3900.0, "minBuyIn": 4000.0, "obligationExpiresAt": null}) == ErrorText.of("INSUFFICIENT_BALANCE"), "의무 없이 지갑 부족")
	check("이후에 앉을 수" in rules.buy_in_blocked_text({"walletBalance": 100.0, "minBuyIn": 4000.0, "obligationExpiresAt": "2026-01-01T10:00:00Z"}), "의무 시각 안내")
	check(rules.buy_in_blocked_text({"walletBalance": 4000.0, "minBuyIn": 4000.0, "obligationExpiresAt": null}) == "", "지갑이 충분하면 안내 없음")

	# preset_raise_to: 현재 최고 베팅 + f × (팟 + 콜), 100 단위, [min, max] 로 자름
	check(rules.preset_raise_to(0.5, 200, 600, 200, 400, 5000) == 600, "프리셋 ½ 팟 일반")
	check(rules.preset_raise_to(1.0, 200, 600, 200, 400, 5000) == 1000, "프리셋 팟 일반")
	check(rules.preset_raise_to(0.5, 200, 100, 200, 500, 5000) == 500, "프리셋 하한으로 올림")
	check(rules.preset_raise_to(1.0, 200, 600, 200, 400, 800) == 800, "프리셋 상한(올인)으로 내림")
	check(rules.preset_raise_to(0.5, 0, 650, 0, 200, 5000) == 300, "프리셋 100 단위 내림 (325 -> 300)")
	check(rules.preset_raise_to(0.5, 0, 750, 0, 200, 5000) == 400, "프리셋 100 단위 올림 (375 -> 400)")

	quit(1 if failures else 0)


func check(cond: bool, name: String) -> void:
	if not cond:
		failures += 1
		print("FAIL: ", name)
	else:
		print("ok: ", name)
