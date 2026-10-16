extends RefCounted
## Pure helpers for card codes ("As","Td","9c") and server enum strings. No state, no signals.

const CATEGORY_TEXT := {
	"HIGH_CARD": "하이카드",
	"PAIR": "원 페어",
	"TWO_PAIR": "투 페어",
	"THREE_OF_A_KIND": "트리플",
	"STRAIGHT": "스트레이트",
	"FLUSH": "플러시",
	"FULL_HOUSE": "풀하우스",
	"FOUR_OF_A_KIND": "포카드",
	"STRAIGHT_FLUSH": "스트레이트 플러시",
}

const STREET_TEXT := {
	"PREFLOP": "프리플롭",
	"FLOP": "플랍",
	"TURN": "턴",
	"RIVER": "리버",
	"SHOWDOWN": "쇼다운",
}


static func texture_path(code: String) -> String:
	return "res://games/holdem/assets/cards/%s.png" % code


static func category_text(category: String) -> String:
	return CATEGORY_TEXT.get(category, category)


static func street_text(street) -> String:
	return STREET_TEXT.get(street, str(street))


static func card_row(codes: Array, size: Vector2) -> HBoxContainer:
	var row := HBoxContainer.new()
	for code in codes:
		var rect := TextureRect.new()
		rect.custom_minimum_size = size
		rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.texture = load(texture_path(code))
		row.add_child(rect)
	return row
