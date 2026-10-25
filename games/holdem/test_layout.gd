extends Node
## 홀덤 테이블 배치 겹침 점검(폰·데스크톱, 2·9인, 내 좌석 1·5·관전, 프리플랍·쇼다운). 자동로드가 필요해 씬으로 실행:
## Godot.exe --headless --path . res://games/holdem/test_layout.tscn
## 크기: Table 을 정확한 크기의 Control 아래에 둔다(루트 창 크기와 무관). 글꼴은 헤드리스에서도 로드돼 라벨 크기가 실제와 같다.
## 연출: 매 뷰를 have_view=false 로 먹여 고스트·트윈 없이 최종 위치로 그린다(첫 뷰/재연결과 같은 경로).

const SIZES := [Vector2(1280, 720), Vector2(1600, 900), Vector2(1920, 1080), Vector2(488, 1056)]
const HAND := {"category": "STRAIGHT_FLUSH", "tiebreakers": [14.0, 13.0, 12.0, 11.0, 10.0]} # 가장 긴 문구("로열 스트레이트 플러시")
const MIN_GAP := 8.0
const PublicView := preload("res://games/holdem/public_view.gd")
const TOL := 2.0 # 겹침 허용 깊이(px) — 테두리가 살짝 닿는 정도는 겹침으로 세지 않는다
# 같은 주인 안에서 겹쳐도 되는 (종류, 종류) — 캡슐 모서리의 배지, 캡슐·카드 모서리에 걸치는 족보 알약, 보드 줄 위에 겹쳐 그리는 결과 문구
const ALLOWED := [["cap", "badge"], ["cap", "pill"], ["cards", "pill"], ["hero", "pill"], ["pot", "label"]]

var failures := 0
var seq := 0


func _seat(no: int, user: int, status := "ACTIVE", extra := {}) -> Dictionary:
	var s := {"seatNo": float(no), "userId": float(user), "stack": 1000.0, "status": status,
		"presence": "CONNECTED", "totalContributed": 0.0, "leaveReserved": false}
	s.merge(extra, true)
	return s


func _view(seats: Array, extra: Dictionary) -> Dictionary:
	seq += 1
	var v := {"seq": float(seq), "seats": seats, "board": [], "handInProgress": false,
		"toActSeatNo": null, "buttonSeatNo": 1.0, "street": "PREFLOP", "result": null,
		"revealedHands": [], "nextHandInMs": null, "turnRemainingMs": null, "pot": 0.0}
	v.merge(extra, true)
	return v


func _ready() -> void:
	Api.user_id = 7
	var script := preload("res://games/holdem/table.gd")
	script.table_id = 1
	script.auto_join = false
	print("%-9s %-3s %-9s %-9s %8s" % ["size", "n", "hero", "state", "min gap"])
	for sz: Vector2 in SIZES:
		var holder := Control.new()
		holder.size = sz
		add_child(holder)
		var table: Control = load("res://games/holdem/table.tscn").instantiate()
		holder.add_child(table)
		Stomp.disconnect_ws() # 실서버 메시지가 주입한 뷰와 섞이지 않게 소켓을 끊는다
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame # 모드 전환(노드 이동) 뒤 컨테이너가 다시 정렬되는 프레임
		check(is_equal_approx(table.felt_area.size.x, sz.x) and table.felt_area.size.y > 300.0, "%dx%d: felt_area %s" % [sz.x, sz.y, table.felt_area.size])
		for n in [2, 9]:
			for hero in [1, 5, 0]: # 0 = 관전
				for state in ["preflop", "showdown"]:
					await _run_case(table, sz, n, hero, state)
		holder.queue_free()
	get_tree().quit(1 if failures else 0)


func _run_case(table: Control, sz: Vector2, n: int, hero: int, state: String) -> void:
	var nos: Array = [1, 5] if n == 2 else [1, 2, 3, 4, 5, 6, 7, 8, 9]
	var seats: Array = []
	for i in nos.size():
		var no: int = nos[i]
		var user := 7 if no == hero else 100 + no
		table.nickname_cache[user] = "플레이어%d" % no
		var status := "ACTIVE"
		var extra := {}
		if state == "preflop":
			extra["totalContributed"] = 180000.0 if i % 2 == 1 else 200.0 # 넓은 금액 문구도 본다
		else: # 배지 최악: 3개 다(예약·올인·끊김), 하나, 올인
			if i % 3 == 0:
				extra["leaveReserved"] = true
				extra["presence"] = "DISCONNECTED"
				status = "ALL_IN"
			elif i % 3 == 1:
				extra["leaveReserved"] = true
			else:
				status = "ALL_IN"
		if i % 2 == 1:
			extra["stack"] = 1234567.0 # 7자리 스택도 캡슐 안에 잘리지 않아야 한다
		extra["lastAction"] = "RAISE_TO" # 행동 배지(가장 긴 문구)도 겹침을 본다
		seats.append(_seat(no, user, status, extra))
	var view_extra := {}
	var hole := ["As", "Kd"]
	if state == "preflop":
		view_extra = {"handInProgress": true, "pot": 3000.0, "toActSeatNo": float(hero if hero > 0 else nos[0])}
	else:
		var payouts := []
		var shown := []
		for i in nos.size():
			var uid: float = seats[i].userId
			if i < 2:
				payouts.append({"seatNo": float(nos[i]), "userId": uid, "amount": 180000.0 - i})
			shown.append({"seatNo": float(nos[i]), "userId": uid, "holeCards": ["Qh", "Jh"], "category": "FULL_HOUSE" if i % 2 == 0 else "STRAIGHT_FLUSH"})
		view_extra = {"board": ["2c", "7d", "9s", "Th", "Ah"], "result": {"payouts": payouts, "shownHands": shown}}
	var dealers: Array = nos
	var min_gap := INF
	var tag := "%dx%d n=%d hero=%s %s" % [sz.x, sz.y, n, "spec" if hero == 0 else str(hero), state]
	var bad: Array = []
	for d: int in dealers:
		view_extra["buttonSeatNo"] = float(d)
		var di: int = nos.find(d) # 헤즈업은 버튼 == SB, 그 외엔 버튼 다음 두 좌석
		var sbi: int = di if n == 2 else (di + 1) % nos.size()
		view_extra["smallBlindSeatNo"] = float(nos[sbi])
		view_extra["bigBlindSeatNo"] = float(nos[(sbi + 1) % nos.size()])
		table.last_public_seq = -1
		table.last_private_seq = -1
		table.have_view = false
		table.my_cards_box.hide()
		table.my_available_actions = null
		var first: bool = d == dealers[0]
		table._handle_public(_view(seats, view_extra))
		if first: # 개인 뷰·행동 막대는 한 번만 먹이고 레이아웃이 가라앉길 기다린다
			if hero > 0:
				var priv := {"seq": float(seq), "holeCards": hole, "currentHand": HAND}
				if state == "preflop":
					priv["availableActions"] = {"canCheck": false, "callAmount": 200.0, "minRaiseTo": 400.0, "maxRaiseTo": 1000.0}
				table._handle_private(priv)
			await get_tree().process_frame
			await get_tree().process_frame
		else:
			table.motion.kill_real()
			if hero > 0:
				table._handle_private({"seq": float(seq), "holeCards": hole, "currentHand": HAND, "availableActions": table.my_available_actions})
		var r := _collect(table, hero)
		min_gap = minf(min_gap, r.gap)
		for b: String in r.bad:
			var msg := "btn=%d %s" % [d, b] if "dealer" in b else b # 딜러 위치와 무관한 위반은 한 번만
			if not bad.has(msg):
				bad.append(msg)
	var shown_gap := "%.1f" % min_gap
	print("%-9s %-3d %-9s %-9s %8s" % ["%dx%d" % [sz.x, sz.y], n, "spec" if hero == 0 else str(hero), state, shown_gap])
	check(bad.is_empty() and min_gap >= MIN_GAP, "%s (min capsule gap %s)%s" % [tag, shown_gap, "" if bad.is_empty() else ": " + "; ".join(bad.slice(0, 8)) + ("" if bad.size() <= 8 else " ... (+%d)" % (bad.size() - 8))])


## {"gap": 좌석 캡슐 사이 최소 간격, "bad": 위반 목록}
func _collect(table: Control, hero: int) -> Dictionary:
	if table.desktop:
		return _collect_desktop(table, hero)
	var area: Rect2 = table.felt_area.get_global_rect()
	var bad_extra: Array = []
	var items: Array = [] # {o: 주인, k: 종류, r: Rect2}
	var caps := {}
	for no in range(1, 10):
		var s: Control = table.seat_nodes[no - 1]
		if s.empty:
			continue
		var o := "seat%d" % no
		var cap := Rect2(s.global_position, s.size)
		caps[no] = cap
		items.append({"o": o, "k": "cap", "r": cap})
		var sl: Label = s.stack_label
		var sw := sl.get_theme_font("font").get_string_size(sl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, sl.get_theme_font_size("font_size")).x
		if sw > sl.size.x + 0.5:
			bad_extra.append("%s 스택 문구 잘림 %s (%.0f > %.0f)" % [o, sl.text, sw, sl.size.x])
		for c: Control in s.card_rects:
			if c.visible:
				items.append({"o": o, "k": "cards", "r": c.get_global_rect()})
		for l: Label in [s.badge_all_in, s.badge_presence, s.badge_leave]:
			if l.visible:
				items.append({"o": o, "k": "badge", "r": l.get_global_rect()})
		if s.hand_pill.visible: # 캡슐 윗변에 걸친 알약 — 자기 카드에 높이 절반까지만 걸친다
			items.append({"o": o, "k": "pill", "r": s.hand_pill.get_global_rect()})
		if s.badge_action.visible: # 둥근 행동 토큰 — 아무것과도 겹치면 안 된다
			items.append({"o": o, "k": "token", "r": Rect2(s.global_position + s.badge_action.position, s.badge_action.size)})
			if abs(s.badge_action.size.x - 38.0) > 1.0 or abs(s.badge_action.size.y - 38.0) > 1.0:
				bad_extra.append("%s 토큰 크기 %s" % [o, s.badge_action.size])
		if s.payout_label.visible:
			items.append({"o": o, "k": "payout", "r": s.payout_label.get_global_rect()})
		if table.bet_boxes[no - 1].visible:
			items.append({"o": o, "k": "bet", "r": table.bet_boxes[no - 1].get_global_rect()})
	if table.dealer_marker.visible:
		items.append({"o": "dealer", "k": "dealer", "r": table.dealer_marker.get_global_rect()})
	for pair: Array in [["dealer-sb", table.sb_marker], ["dealer-bb", table.bb_marker]]: # 딜러와 같은 종류(o 가 달라 마커끼리 겹침도 본다)
		if pair[1].visible:
			items.append({"o": pair[0], "k": "dealer", "r": pair[1].get_global_rect()})
	for c: Control in table.board_card_rects:
		if c.visible:
			items.append({"o": "center", "k": "board", "r": c.get_global_rect()})
	if table.pot_row.modulate.a > 0.0: # 칩 아이콘 + 글자만(줄 자체는 중앙 박스 너비 전체)
		var pr: Rect2 = table.pot_row.get_child(0).get_global_rect().merge(table.pot_label.get_global_rect())
		items.append({"o": "center", "k": "pot", "r": pr})
	if table.board_label.text != "": # 줄바꿈된 실제 라벨 사각(글자 너비보다 넓어도 그 폭 안에서만 그린다)
		items.append({"o": "center", "k": "label", "r": table.board_label.get_global_rect()})
	if hero > 0 and not table.hand_text_pill.visible:
		bad_extra.append("폰 족보 알약이 보이지 않음")
	elif hero > 0:
		items.append({"o": "mypill", "k": "mypill", "r": table.hand_text_pill.get_global_rect()})
	if table.my_cards_box.visible and hero > 0: # 내 큰 카드는 내 좌석 소유
		for c: Control in table.my_card_rects:
			if c.visible:
				items.append({"o": "seat%d" % hero, "k": "hero", "r": c.get_global_rect()})
	var bad: Array = bad_extra
	for it in items:
		if not area.grow(0.5).encloses(it.r):
			bad.append("%s/%s 화면 밖 %s (area %s)" % [it.o, it.k, _s(it.r), _s(area)])
	for i in items.size():
		for j in range(i + 1, items.size()):
			var a: Dictionary = items[i]
			var b: Dictionary = items[j]
			if not _overlap(a, b):
				continue
			if a.o == b.o and (ALLOWED.has([a.k, b.k]) or ALLOWED.has([b.k, a.k])):
				# 알약은 자기 카드 가장자리에 걸치되 자기 높이의 절반까지만(그 이상은 카드를 가린다)
				var pill: Dictionary = a if a.k == "pill" else b
				var oth: Dictionary = b if a.k == "pill" else a
				if not (oth.k in ["hero", "cards"]) or pill.r.intersection(oth.r).size.y <= pill.r.size.y / 2.0 + 1.0:
					continue
			bad.append("%s/%s x %s/%s %s %s" % [a.o, a.k, b.o, b.k, _s(a.r), _s(b.r)])
	for no: int in caps: # 칩은 자기 좌석 캡슐 곁에 있어야 한다(가장 가까운 캡슐이 자기 것)
		var bb: Control = table.bet_boxes[no - 1]
		if not bb.visible:
			continue
		var br := bb.get_global_rect()
		var nearest := -1
		var best := INF
		for other: int in caps:
			var d := _gap(br, caps[other])
			if d < best:
				best = d
				nearest = other
		if nearest != no:
			bad.append("seat%d/bet 가장 가까운 캡슐이 seat%d (%s)" % [no, nearest, _s(br)])
	for no: int in caps: # 토큰도 자기 캡슐 곁
		var s: Control = table.seat_nodes[no - 1]
		if not s.badge_action.visible:
			continue
		var tr := Rect2(s.global_position + s.badge_action.position, s.badge_action.size)
		var nearest := -1
		var best := INF
		for other: int in caps:
			var d := _gap(tr, caps[other])
			if d < best:
				best = d
				nearest = other
		if nearest != no:
			bad.append("seat%d/token 가장 가까운 캡슐이 seat%d (%s)" % [no, nearest, _s(tr)])
	var gap := INF
	var keys := caps.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			gap = minf(gap, _gap(caps[keys[i]], caps[keys[j]]))
	return {"gap": gap, "bad": bad}


## 캡슐은 양 끝이 반원인 알약 모양이라 사각 모서리에는 비어 있다(딜러 마커가 거기 붙는다). 캡슐과 다른 것은 중심 선분과의 거리로 겹침을 판단한다
func _overlap(a: Dictionary, b: Dictionary) -> bool:
	if a.k == "cap" and b.k != "cap":
		return _stadium_hit(a.r, b.r, b.k == "dealer")
	if b.k == "cap" and a.k != "cap":
		return _stadium_hit(b.r, a.r, a.k == "dealer")
	return _in(a.r).intersects(_in(b.r))


func _in(r: Rect2) -> Rect2: # 가장자리 TOL 만큼 안쪽(작은 사각은 빈 사각)
	return Rect2(r.position + Vector2(TOL, TOL), (r.size - Vector2(2.0 * TOL, 2.0 * TOL)).max(Vector2.ZERO))


func _stadium_hit(cap: Rect2, r: Rect2, round_r: bool) -> bool:
	var rad := cap.size.y / 2.0
	var spine := Rect2(cap.position.x + rad, cap.position.y + rad, cap.size.x - cap.size.y, 0.0)
	if round_r: # 딜러 마커는 원
		var c := r.get_center()
		var p := Vector2(clampf(c.x, spine.position.x, spine.end.x), spine.position.y)
		return c.distance_to(p) < rad + r.size.x / 2.0 - TOL
	return _gap(r, spine) < rad - TOL


func _nearest_panel(r: Rect2, panels: Dictionary) -> int:
	var best := INF
	var nearest := -1
	for no: int in panels:
		var d := _gap(r, panels[no])
		if d < best:
			best = d
			nearest = no
	return nearest


func _gap(a: Rect2, b: Rect2) -> float:
	var gx := maxf(a.position.x - b.end.x, b.position.x - a.end.x)
	var gy := maxf(a.position.y - b.end.y, b.position.y - a.end.y)
	return Vector2(gx, gy).length() if gx > 0.0 and gy > 0.0 else maxf(gx, gy)


func check(cond: bool, label: String) -> void:
	if cond:
		print("ok: ", label)
	else:
		failures += 1
		print("FAIL: ", label)


func _s(r: Rect2) -> String:
	return "(%d,%d %dx%d)" % [r.position.x, r.position.y, r.size.x, r.size.y]


## 데스크톱 배치 점검. 좌석 패널·행동 토큰·베팅 칸·마커·보드·Total 상자·결과 문구·행동 패널·버튼 줄·위 막대가 서로 겹치지 않고 화면 안이어야 한다.
## 패널 안쪽(카드·이름·스택·알약·내 큰 카드)은 패널 안이고 서로 겹치지 않아야 한다(오버레이 ALLIN·폴드·타이머는 카드 위가 의도라 제외)
func _collect_desktop(table: Control, hero: int) -> Dictionary:
	var area: Rect2 = table.get_global_rect()
	var bad: Array = []
	var items: Array = [] # {o, k, r}
	var panels := {}
	for no in range(1, 10):
		var s: Control = table.seat_nodes[no - 1]
		var o := "seat%d" % no
		var pr := Rect2(s.global_position, s.size)
		panels[no] = pr
		items.append({"o": o, "k": "panel", "r": pr})
		if s.empty:
			continue
		var inner: Array = []
		for c: Control in s.card_rects:
			if c.visible:
				inner.append({"n": "cards", "r": c.get_global_rect()})
		for pair: Array in [["name", s.name_label], ["stack", s.stack_label], ["badge_leave", s.badge_leave], ["badge_presence", s.badge_presence], ["hand_pill", s.hand_pill], ["payout", s.payout_label], ["hand_rank", s.hand_rank]]:
			if (pair[1] as Control).visible:
				inner.append({"n": pair[0], "r": (pair[1] as Control).get_global_rect()})
		if s.badge_action.visible: # 행동 글자는 자기 패널의 카드 칸 안에 얹힌다(카드와 겹치는 게 목적). 올인·폴드 오버레이와 동시에 보이지 않는다
			var cr: Rect2 = s.desk_columns(s.hero_slot, s.avatar_left, table.k).cards
			var cr_g := Rect2(s.global_position + cr.position, cr.size)
			if not cr_g.grow(1.0).encloses(s.badge_action.get_global_rect()):
				bad.append("%s/action 글자가 카드 칸 밖 %s %s" % [o, _s(s.badge_action.get_global_rect()), _s(cr_g)])
			if s.badge_all_in.visible or s.fold_label.visible:
				bad.append("%s/action 글자가 올인·폴드 오버레이와 같이 보임" % o)
		if hero > 0 and no == hero and table.my_cards_box.visible:
			for c: Control in table.my_card_rects:
				if c.visible:
					inner.append({"n": "herocards", "r": c.get_global_rect()})
		var sl: Label = s.stack_label
		var sw := sl.get_theme_font("font").get_string_size(sl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, sl.get_theme_font_size("font_size")).x
		if sw > sl.size.x + 0.5:
			bad.append("%s 스택 문구 잘림 %s (%.0f > %.0f)" % [o, sl.text, sw, sl.size.x])
		for i in inner.size():
			if not pr.grow(0.5).encloses(inner[i].r):
				bad.append("%s/%s 패널 밖 %s (패널 %s)" % [o, inner[i].n, _s(inner[i].r), _s(pr)])
			for j in range(i + 1, inner.size()):
				if _in(inner[i].r).intersects(_in(inner[j].r)):
					bad.append("%s/%s x %s %s %s" % [o, inner[i].n, inner[j].n, _s(inner[i].r), _s(inner[j].r)])
		if table.bet_boxes[no - 1].visible:
			items.append({"o": o, "k": "bet", "r": table.bet_boxes[no - 1].get_global_rect()})
	for pair: Array in [["dealer", table.dealer_marker], ["dealer-sb", table.sb_marker], ["dealer-bb", table.bb_marker]]:
		if pair[1].visible:
			items.append({"o": pair[0], "k": "marker", "r": pair[1].get_global_rect()})
	for c: Control in table.board_card_rects:
		if c.visible:
			items.append({"o": "center", "k": "board", "r": c.get_global_rect()})
	if table.total_box.visible:
		items.append({"o": "center", "k": "total", "r": table.total_box.get_global_rect()})
	if table.board_label.text != "":
		items.append({"o": "center", "k": "label", "r": table.board_label.get_global_rect()})
	items.append({"o": "ui", "k": "action", "r": table.bottom_region.get_global_rect()})
	items.append({"o": "ui", "k": "bar", "r": table.bottom_bar.get_global_rect()})
	items.append({"o": "ui", "k": "topbar", "r": table.top_bar.get_global_rect()})
	if table.action_bg.visible:
		var bg: Rect2 = table.action_bg.get_global_rect()
		if not bg.grow(1.0).encloses(table.bottom_region.get_global_rect()):
			bad.append("행동 패널 바탕이 내용보다 작다")
	if not table.info_box.visible or not table.top_bar.get_global_rect().encloses(table.info_box.get_global_rect()):
		bad.append("SB/BB 정보 상자 보이지 않음·막대 밖")
	for it in items:
		if not area.grow(0.5).encloses(it.r):
			bad.append("%s/%s 화면 밖 %s (area %s)" % [it.o, it.k, _s(it.r), _s(area)])
	for i in items.size():
		for j in range(i + 1, items.size()):
			var a: Dictionary = items[i]
			var b: Dictionary = items[j]
			if [a.k, b.k] in [["total", "label"], ["label", "total"]]:
				continue # 핸드 중엔 상자, 끝나면 문구 — 같은 자리를 번갈아 쓴다
			if _in(a.r).intersects(_in(b.r)):
				bad.append("%s/%s x %s/%s %s %s" % [a.o, a.k, b.o, b.k, _s(a.r), _s(b.r)])
	# 토큰·베팅·마커는 가장 가까운 패널이 자기 좌석이어야 한다(옆 좌석 것으로 보이지 않게)
	var hero_no := hero if hero > 0 else 1
	for it in items:
		if it.k == "bet":
			var own := int(str(it.o).substr(4))
			if _nearest_panel(it.r, panels) != own:
				bad.append("%s/%s 가장 가까운 패널이 seat%d %s own %s near %s" % [it.o, it.k, _nearest_panel(it.r, panels), _s(it.r), _s(panels[own]), _s(panels[_nearest_panel(it.r, panels)])])
			if own != hero_no: # 베팅은 자기 패널 바로 곁(틈 14px 이내)
				var bgap := _gap(it.r, panels[own])
				if bgap > 14.0 * table.k:
					bad.append("%s/bet 이 자기 패널에서 멂 (%.0f)" % [it.o, bgap])
	for pair: Array in [["dealer", table.dealer_marker, 0], ["dealer-sb", table.sb_marker, 1], ["dealer-bb", table.bb_marker, 2]]:
		if not pair[1].visible:
			continue
		var seat_no: int = int(table.public_view.get("buttonSeatNo")) if pair[2] == 0 else int(PublicView.blind_seats(table.public_view)["sb" if pair[2] == 1 else "bb"])
		var near := _nearest_panel((pair[1] as Control).get_global_rect(), panels)
		if near != seat_no:
			bad.append("%s 마커의 가장 가까운 패널이 seat%d (주인 seat%d)" % [pair[0], near, seat_no])
	for pair: Array in [["dealer", table.dealer_marker, 0], ["dealer-sb", table.sb_marker, 1], ["dealer-bb", table.bb_marker, 2]]: # 마커는 자기 패널 바로 곁(틈 12px 이내)
		if pair[1].visible:
			var own_no: int = int(table.public_view.get("buttonSeatNo")) if pair[2] == 0 else int(PublicView.blind_seats(table.public_view)["sb" if pair[2] == 1 else "bb"])
			var mgap := _gap((pair[1] as Control).get_global_rect(), panels[own_no])
			if mgap > 12.0 * table.k:
				bad.append("%s 마커가 자기 패널에서 멂 (%.0f)" % [pair[0], mgap])
	if table.pot_row.visible:
		bad.append("데스크톱에서 PotRow 가 보임")
	if table.action_bg.get_index() > table.bottom_region.get_index() or table.my_cards_box.get_index() < table.seat_nodes[8].get_index():
		bad.append("그리기 순서: 행동 바탕이 패널 위이거나 내 카드가 좌석 아래")
	if hero > 0 and not table.seat_nodes[hero - 1].hand_rank.visible:
		bad.append("데스크톱 HandRank 가 보이지 않음")
	if table.hand_text_pill.visible:
		bad.append("데스크톱에서 폰 족보 알약이 보임")
	for m: Control in [table.dealer_marker, table.sb_marker, table.bb_marker]:
		if m.visible and m.size.x < 24.0 * table.k:
			bad.append("마커가 너무 작음 %s" % m.size)
	var gap := INF
	var keys := panels.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			gap = minf(gap, _gap(panels[keys[i]], panels[keys[j]]))
	return {"gap": gap, "bad": bad}
