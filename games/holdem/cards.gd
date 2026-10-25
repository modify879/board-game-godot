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


## 서버 개인 뷰 currentHand {category, tiebreakers}(타이브레이커 = 랭크 값 2..14, A=14, 앞이 중요) → 화면 문구("K 원페어"). null·잘못된 값 = ""
static func current_hand_text(h) -> String:
	if not (h is Dictionary) or not (h.get("category") is String) or not (h.get("tiebreakers") is Array):
		return ""
	var tb: Array = h.tiebreakers
	var need := 2 if h.category == "TWO_PAIR" else 1
	if tb.size() < need:
		return ""
	for i in need:
		if not (tb[i] is float or tb[i] is int) or int(tb[i]) < 2 or int(tb[i]) > 14:
			return ""
	var top := _rank_name(int(tb[0]))
	match h.category:
		"HIGH_CARD":
			return "%s탑" % top
		"PAIR":
			return "%s 원페어" % top
		"TWO_PAIR":
			return "%s·%s 투페어" % [top, _rank_name(int(tb[1]))]
		"THREE_OF_A_KIND":
			return "%s 트리플" % top
		"STRAIGHT":
			return "%s 스트레이트" % top
		"FLUSH":
			return "%s 플러시" % top
		"FULL_HOUSE":
			return "%s 풀하우스" % top
		"FOUR_OF_A_KIND":
			return "%s 포카드" % top
		"STRAIGHT_FLUSH":
			return "로열 스트레이트 플러시" if int(tb[0]) == 14 else "%s 스트레이트 플러시" % top
	return ""


static func _rank_name(r: int) -> String:
	return {11: "J", 12: "Q", 13: "K", 14: "A"}.get(r, str(r))


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
