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

# 닉네임 최악(12자): 한글 2종·넓은 W·섞인 것. 좌석마다 돌려 쓴다
const WORST := ["가나다라마바사아자차카타", "뷁뷁뷁뷁뷁뷁뷁뷁뷁뷁뷁뷁", "WWWWWWWWWWWW", "QA유저WWWW가나다라"]

var worst := false
var min_name_fs := {} # 크기 라벨 -> 관찰한 최소 닉네임 글자 크기
var failures := 0
var seq := 0


func _seat(no: int, user: int, status := "ACTIVE", extra := {}) -> Dictionary:
	var s := {"seatNo": float(no), "userId": float(user), "stack": 1000.0, "status": status,
		"presence": "CONNECTED", "totalContributed": 0.0, "streetBet": 0.0, "leaveReserved": false}
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
		check(not table.settings_popup.visible, "%dx%d: 설정 팝업은 처음엔 닫혀 있다" % [sz.x, sz.y])
		table.settings_button.pressed.emit()
		await get_tree().process_frame
		await get_tree().process_frame
		var panel: Control = table.settings_popup.get_node("CenterContainer/PanelContainer")
		var tall := true
		for b: Control in [table.sfx_toggle, table.voice_toggle, table.settings_close]:
			tall = tall and b.size.y >= 44.0
		check(Rect2(Vector2.ZERO, sz).encloses(panel.get_global_rect()) and tall, "%dx%d: 설정 팝업은 화면 안에 들고 버튼이 44px 이상 %s" % [sz.x, sz.y, panel.get_global_rect()])
		table.settings_close.pressed.emit()
		for n in [2, 9]:
			for hero in [1, 5, 0]: # 0 = 관전
				for state in ["preflop", "showdown", "sidepots", "runout"]:
					await _run_case(table, sz, n, hero, state)
		worst = true # 모든 좌석이 12자 최악 닉네임
		for hero in [5, 0]:
			for state in ["preflop", "showdown"]:
				await _run_case(table, sz, 9, hero, state)
		worst = false
		holder.queue_free()
	print("min nickname font size: ", min_name_fs)
	get_tree().quit(1 if failures else 0)


func _run_case(table: Control, sz: Vector2, n: int, hero: int, state: String) -> void:
	var nos: Array = [1, 5] if n == 2 else [1, 2, 3, 4, 5, 6, 7, 8, 9]
	var seats: Array = []
	for i in nos.size():
		var no: int = nos[i]
		var user := 7 if no == hero else 100 + no
		table.nickname_cache[user] = WORST[i % WORST.size()] if worst else "플레이어%d" % no
		var status := "ACTIVE"
		var extra := {}
		if state == "runout":
			extra["totalContributed"] = 5000.0
			status = "ALL_IN"
		if state == "preflop" or state == "sidepots":
			extra["totalContributed"] = 180000.0 if i % 2 == 1 else 200.0 # 넓은 금액 문구도 본다
			extra["streetBet"] = extra["totalContributed"]
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
	if state != "showdown":
		view_extra = {"handInProgress": true, "pot": 3000.0, "toActSeatNo": float(hero if hero > 0 else nos[0])}
		if state == "sidepots" or state == "runout": # 팟 3개(최악 폭: 큰 금액). runout = 올인 런아웃: 모두 올인, streetBet 0 — 베팅 칸 없이 사이드 팟 줄만
			view_extra.pots = [{"amount": 1234567.0, "eligibleSeatNos": [1.0, 2.0, 3.0]}, {"amount": 1234567.0, "eligibleSeatNos": [1.0, 2.0]}, {"amount": 1234567.0, "eligibleSeatNos": [1.0]}]
	else:
		var payouts := []
		var shown := []
		for i in nos.size():
			var uid: float = seats[i].userId
			if i < 2:
				payouts.append({"seatNo": float(nos[i]), "userId": uid, "amount": 180000.0 - i})
			shown.append({"seatNo": float(nos[i]), "userId": uid, "holeCards": ["Qh", "Jh"], "category": "FULL_HOUSE" if i % 2 == 0 else "STRAIGHT_FLUSH"})
		view_extra = {"board": ["2c", "7d", "9s", "Th", "Ah"], "result": {"payouts": payouts, "shownHands": shown}}
	view_extra["tableName"] = "화면 확인"
	var dealers: Array = nos
	var min_gap := INF
	var tag := "%dx%d n=%d hero=%s %s%s" % [sz.x, sz.y, n, "spec" if hero == 0 else str(hero), state, " worst-nick" if worst else ""]
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
				if state != "showdown":
					priv["availableActions"] = {"canCheck": false, "callAmount": 200.0, "minRaiseTo": 400.0, "maxRaiseTo": 1000.0}
				table._handle_private(priv)
			await get_tree().process_frame
			await get_tree().process_frame
		else:
			table.motion.kill_real()
			if hero > 0:
				table._handle_private({"seq": float(seq), "holeCards": hole, "currentHand": HAND, "availableActions": table.my_available_actions})
		if table.banner_tween != null and table.banner_tween.is_valid():
			table.banner_tween.custom_step(1.0) # 팝인 끝난 크기로 잰다
		var r := _collect(table, hero)
		min_gap = minf(min_gap, r.gap)
		for b: String in r.bad:
			var msg := "btn=%d %s" % [d, b] if "마커" in b else b # 딜러 위치와 무관한 위반은 한 번만
			if not bad.has(msg):
				bad.append(msg)
	if state == "sidepots" or state == "runout": # 사이드 팟 줄은 폰·데스크톱 모두 보이고(크기가 있고 글자 12px 이상) 펠트 안에 있다
		var pl: Label = table.pots_label
		if not pl.visible or pl.size.x < 20.0 or pl.size.y < 12.0 or pl.get_theme_font_size("font_size") < 12:
			bad.append("사이드 팟 줄이 안 보임·너무 작음 vis=%s size=%s" % [pl.visible, pl.size])
		elif not table.felt.get_global_rect().grow(0.5).encloses(pl.get_global_rect()):
			bad.append("사이드 팟 줄이 펠트 밖 %s (펠트 %s)" % [_s(pl.get_global_rect()), _s(table.felt.get_global_rect())])
	if state == "runout": # 올인 런아웃: 베팅 칸은 하나도 없다
		for bb in table.bet_boxes:
			if bb.visible:
				bad.append("런아웃인데 베팅 칸이 보임")
	var shown_gap := "%.1f" % min_gap
	print("%-9s %-3d %-9s %-9s %8s" % ["%dx%d" % [sz.x, sz.y], n, "spec" if hero == 0 else str(hero), state, shown_gap])
	check(bad.is_empty() and min_gap >= MIN_GAP, "%s (min capsule gap %s)%s" % [tag, shown_gap, "" if bad.is_empty() else ": " + "; ".join(bad.slice(0, 8)) + ("" if bad.size() <= 8 else " ... (+%d)" % (bad.size() - 8))])


## {"gap": 좌석 캡슐 사이 최소 간격, "bad": 위반 목록}
## 관전이면 아래 가운데(1번 좌석)는 일반 패널이고 내 카드·족보는 없다
func _collect(table: Control, hero: int) -> Dictionary:
	var r := _collect_view(table, hero)
	if hero == 0:
		var s1: Control = table.seat_nodes[0]
		if s1.hero_slot:
			r.bad.append("관전: 1번 좌석이 큰 내 패널로 그려짐")
		if table.desktop and not s1.size.is_equal_approx(s1.panel_size(false, table.k)):
			r.bad.append("관전: 1번 좌석 패널 크기가 일반이 아님 %s" % s1.size)
		if table.my_cards_box.visible or table.hand_text_pill.visible or s1.hand_rank.visible:
			r.bad.append("관전: 내 카드·족보가 보임")
	return r


## 닉네임은 어느 좌석이든 잘리지 않아야 한다: 글자 폭 <= 라벨 폭, 글자 크기 >= 최소, 말줄임·클립 없음
func _name_bad(table: Control, sz: Vector2) -> Array:
	var out: Array = []
	for no in range(1, 10):
		var s: Control = table.seat_nodes[no - 1]
		var l: Label = s.name_label
		if s.empty:
			continue
		var fs := l.get_theme_font_size("font_size")
		var font := l.get_theme_font("font")
		var w := font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if l.autowrap_mode != TextServer.AUTOWRAP_OFF: # 폰 두 줄: 가장 넓은 줄 폭이 라벨 폭 안, 줄 수 2 이하, 높이가 라벨 안
			var ms := font.get_multiline_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, l.size.x, fs, -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_GRAPHEME_BOUND)
			w = ms.x
			if ms.y > font.get_height(fs) * 2.0 + 0.5 or ms.y > l.size.y + 0.5:
				out.append("seat%d 닉네임 두 줄에 안 들어감 %s (%.0f > %.0f)" % [no, l.text, ms.y, l.size.y])
		if not table.desktop and l.get_global_rect().grow(-TOL).intersects(s.stack_label.get_global_rect().grow(-TOL)):
			out.append("seat%d 닉네임 x 스택 %s %s" % [no, _s(l.get_global_rect()), _s(s.stack_label.get_global_rect())])
		if not table.desktop and l.position.y < 0.0 or l.position.y + l.size.y > s.size.y:
			out.append("seat%d 닉네임이 캡슐 밖 %s" % [no, _s(Rect2(l.position, l.size))])
		var key := "%dx%d" % [sz.x, sz.y]
		min_name_fs[key] = mini(min_name_fs.get(key, 999), fs)
		if w > l.size.x + 0.5:
			out.append("seat%d 닉네임 잘림 %s (%.0f > %.0f, fs %d)" % [no, l.text, w, l.size.x, fs])
		if fs < s._name_min:
			out.append("seat%d 닉네임 글자 %d < 최소 %d" % [no, fs, s._name_min])
		if l.clip_text or l.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING:
			out.append("seat%d 닉네임 라벨에 clip/말줄임" % no)
	return out


## D·SB·BB 마커는 자기 좌석 패널·캡슐 안에 있고, 서로·닉네임 라벨·스택 글자와 안 겹치며, 공개 뷰의 버튼·블라인드 좌석과 일치해야 한다
func _markers_bad(table: Control) -> Array:
	var out: Array = []
	var want := {}
	var blinds := PublicView.blind_seats(table.public_view)
	var btn = table.public_view.get("buttonSeatNo")
	for pair: Array in [[0, int(btn) if btn != null else -1], [1, blinds.sb], [2, blinds.bb]]:
		if PublicView.find_seat(table.public_view, pair[1]) != null:
			want[pair[1]] = want.get(pair[1], []) + [pair[0]]
	for no in range(1, 10):
		var s: Control = table.seat_nodes[no - 1]
		if s.markers != want.get(no, []):
			out.append("seat%d 마커 %s (기대 %s)" % [no, s.markers, want.get(no, [])])
		var panel := Rect2(s.global_position, s.size)
		var rects: Array = s.marker_rects().map(func(r: Rect2) -> Rect2: return Rect2(s.global_position + r.position, r.size))
		for i in rects.size():
			var r: Rect2 = rects[i]
			if not panel.grow(0.5).encloses(r):
				out.append("seat%d 마커 %d 가 패널 밖 %s (패널 %s)" % [no, s.markers[i], _s(r), _s(panel)])
			if s.name_label.visible and _in(r).intersects(_in(s.name_label.get_global_rect())):
				out.append("seat%d 마커 %d x 닉네임 %s %s" % [no, s.markers[i], _s(r), _s(s.name_label.get_global_rect())])
			if s.stack_label.visible and _in(r).intersects(_in(s.stack_label.get_global_rect())):
				out.append("seat%d 마커 %d x 스택 %s" % [no, s.markers[i], _s(r)])
			for j in range(i + 1, rects.size()):
				if _in(r).intersects(_in(rects[j])):
					out.append("seat%d 마커 %d x %d 겹침" % [no, s.markers[i], s.markers[j]])
	return out


func _collect_view(table: Control, hero: int) -> Dictionary:
	var r := _collect_view2(table, hero)
	r.bad.append_array(_name_bad(table, table.get_global_rect().size))
	r.bad.append_array(_markers_bad(table))
	r.bad.append_array(_actions_bad(table, hero))
	return r


## 상단 제목("#id · 이름")은 한 덩어리, 행동 버튼은 고정 자리·충분한 크기·패널 안, 뒤로가기 메뉴는 버튼 아래 화면 안
func _actions_bad(table: Control, hero: int) -> Array:
	var out: Array = []
	var tl: Rect2 = table.title_label.get_global_rect()
	var nl: Rect2 = table.name_label.get_global_rect()
	if table.name_label.text != "" and nl.position.x - tl.end.x > 8.0:
		out.append("제목과 방 이름 사이가 넓음 (%.0f)" % (nl.position.x - tl.end.x))
	if table.name_label.text != "" and nl.end.x > table.status_label.get_global_rect().position.x + 0.5:
		out.append("방 이름이 상태 글자와 겹침")
	if not table.action_bar.visible:
		return out
	var region: Rect2 = table.bottom_region.get_global_rect()
	var btns: Array = [table.fold_button, table.check_button, table.call_button, table.raise_button, table.all_in_button]
	var min_h: float = 44.0 * (table.k if table.desktop else 1.0)
	for i in btns.size():
		var b: Button = btns[i]
		var br := b.get_global_rect()
		if not b.visible:
			out.append("%s 숨겨짐(자리 고정이어야 함)" % b.name)
		if br.size.y < min_h - 0.5 or (not table.desktop and br.size.x < 44.0):
			out.append("%s 터치 크기 부족 %s" % [b.name, _s(br)])
		if not region.grow(0.5).encloses(br):
			out.append("%s 행동 패널 밖 %s (패널 %s)" % [b.name, _s(br), _s(region)])
		for j in range(i + 1, btns.size()):
			if _in(br).intersects(_in((btns[j] as Button).get_global_rect())):
				out.append("%s x %s 겹침" % [b.name, btns[j].name])
		var fw := b.get_theme_font("font").get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, b.get_theme_font_size("font_size")).x
		if fw > br.size.x + 0.5:
			out.append("%s 글자 넘침 '%s' (%.0f > %.0f)" % [b.name, b.text, fw, br.size.x])
	for c: Control in [table.raise_slider, table.minus_button, table.raise_spin, table.plus_button]:
		if not c.visible or not region.grow(0.5).encloses(c.get_global_rect()):
			out.append("%s 숨겨졌거나 행동 패널 밖" % c.name)
	var all_btns: Array = btns + [table.minus_button, table.plus_button]
	if table.desktop:
		var row1: Rect2 = table.raise_slider.get_global_rect().merge(table.plus_button.get_global_rect())
		if table.raise_slider.size.x < row1.size.x * 0.5:
			out.append("슬라이더가 첫 줄의 절반 미만 %.0f/%.0f" % [table.raise_slider.size.x, row1.size.x])
		if table.raise_spin.size.x > 90.0 * table.k:
			out.append("RaiseSpin 이 넓음 %.0f" % table.raise_spin.size.x)
		var content_h: float = table.bottom_region.get_combined_minimum_size().y
		if table.bottom_region.size.y > content_h + 1.0:
			out.append("행동 패널 아래에 빈 칸 (%.0f > 내용 %.0f)" % [table.bottom_region.size.y, content_h])
		var ys := {}
		for b: Button in btns:
			ys[int(b.get_global_rect().position.y)] = true
		if ys.size() != 1:
			out.append("데스크톱 버튼 줄이 한 줄이 아님")
	else:
		for b: Control in [table.minus_button, table.plus_button]:
			if b.size.x < 44.0 or b.size.y < 44.0:
				out.append("%s 폰 터치 크기 부족" % b.name)
		var fold_r: Rect2 = table.fold_button.get_global_rect()
		var raise_r: Rect2 = table.raise_button.get_global_rect()
		if raise_r.position.x - fold_r.end.x < 16.0:
			out.append("폴드·레이즈 사이 간격 부족 %.0f" % (raise_r.position.x - fold_r.end.x))
	# 상태별 가용(이 테스트의 행동: 콜 200, 레이즈 400~1000)
	if hero > 0 and table.my_available_actions != null:
		if table.fold_button.disabled or not table.check_button.disabled or table.call_button.disabled or table.raise_button.disabled or table.all_in_button.disabled:
			out.append("행동 버튼 가용 상태가 행동과 다름")
		if table.call_button.text != "콜 200":
			out.append("콜 문구 '%s'" % table.call_button.text)
	return out


func _collect_view2(table: Control, hero: int) -> Dictionary:
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
		if table.public_view.get("result") == null and int(table.public_view.get("toActSeatNo", -1)) == no: # 타이머 막대(차례인 좌석만, 결과 화면엔 없다 — 지급액과 같은 자리를 쓴다). 자기 글자·카드와도 안 겹쳐야 한다
			items.append({"o": o, "k": "timer", "r": Rect2(s.global_position + s.timer_bar_rect().position, s.timer_bar_rect().size)})
		if table.bet_boxes[no - 1].visible:
			items.append({"o": o, "k": "bet", "r": table.bet_boxes[no - 1].get_global_rect()})
	for c: Control in table.board_card_rects:
		if c.visible:
			items.append({"o": "center", "k": "board", "r": c.get_global_rect()})
	if table.pot_row.modulate.a > 0.0: # 칩 아이콘 + 글자만(줄 자체는 중앙 박스 너비 전체)
		var pr: Rect2 = table.pot_row.get_child(0).get_global_rect().merge(table.pot_label.get_global_rect())
		items.append({"o": "center", "k": "pot", "r": pr})
		if table.pots_label.visible:
			items.append({"o": "center", "k": "pots", "r": table.pots_label.get_global_rect()})
	if table.board_label.text != "": # 결과 배너(큰 글자+작은 줄) — 보드 카드와는 겹쳐도 된다(위에 얹는다)
		items.append({"o": "banner", "k": "label", "r": table.banner_title.get_global_rect().merge(table.board_label.get_global_rect())})
	if table.add_chips_button.visible:
		items.append({"o": "addchips", "k": "addchips", "r": table.add_chips_button.get_global_rect()})
	if hero > 0 and not table.hand_text_pill.visible:
		bad_extra.append("폰 족보 알약이 보이지 않음")
	elif hero > 0:
		items.append({"o": "mypill", "k": "mypill", "r": table.hand_text_pill.get_global_rect()})
	if table.my_cards_box.visible and hero > 0: # 내 큰 카드는 내 좌석 소유
		for c: Control in table.my_card_rects:
			if c.visible:
				items.append({"o": "seat%d" % hero, "k": "hero", "r": c.get_global_rect()})
	var bad: Array = bad_extra
	bad.append_array(_face_up_actions(table))
	for it in items:
		if not area.grow(0.5).encloses(it.r):
			bad.append("%s/%s 화면 밖 %s (area %s)" % [it.o, it.k, _s(it.r), _s(area)])
	for i in items.size():
		for j in range(i + 1, items.size()):
			var a: Dictionary = items[i]
			var b: Dictionary = items[j]
			if not _overlap(a, b) or [a.k, b.k] in [["board", "label"], ["label", "board"]]: # 배너는 보드 카드 위에 얹는다
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


## 결과 화면에서 앞면 카드(공개 패·내 큰 카드)를 가진 좌석은 행동 글자·토큰이 보이면 안 된다
func _face_up_actions(table: Control) -> Array:
	var out: Array = []
	if table.public_view.get("result") == null:
		return out
	for no in range(1, 10):
		var s: Control = table.seat_nodes[no - 1]
		if not s.empty and s.badge_action.visible and (table._find_shown_hand(no) != null or no == table._my_seat_no()):
			out.append("seat%d 앞면 카드 위에 행동 글자가 보임" % no)
	return out


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
	bad.append_array(_face_up_actions(table))
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
		var stack_r: Rect2 = s.stack_label.get_global_rect()
		if hero > 0 and no == hero: # 내 스택은 글자 폭만(옆 "+" 와 겹치는지 본다)
			var txt: Rect2 = s.stack_text_rect()
			stack_r = Rect2(s.global_position + txt.position, txt.size)
		if hero > 0 and no == hero and table.add_chips_button.visible:
			inner.append({"n": "addchips", "r": table.add_chips_button.get_global_rect()})
		for pair: Array in [["name", s.name_label], ["stack", s.stack_label], ["badge_leave", s.badge_leave], ["badge_presence", s.badge_presence], ["hand_pill", s.hand_pill], ["payout", s.payout_label], ["hand_rank", s.hand_rank]]:
			if (pair[1] as Control).visible:
				inner.append({"n": pair[0], "r": stack_r if pair[0] == "stack" else (pair[1] as Control).get_global_rect()})
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
		var tr := Rect2(s.global_position + s.timer_bar_rect().position, s.timer_bar_rect().size) # 타이머 막대는 자기 글자·카드·내 큰 카드와 안 겹치고 다른 것과도 안 겹친다
		items.append({"o": o, "k": "timer", "r": tr})
		if s.desk: # 데스크톱 아바타는 닉네임 줄 아래 ~ 타이머 띠 위의 높이를 꽉 채운다(여백 합 10·k 이내)
			var side: float = s._avatar_r * 2.0
			var content_h: float = s.timer_bar_rect().position.y - s.name_row(s.hero_slot) * table.k
			if side < content_h - 10.0 * table.k - 0.01:
				bad.append("%s 아바타가 작음 %.1f < %.1f" % [o, side, content_h - 10.0 * table.k])
		for it2 in inner:
			if _in(it2.r).intersects(_in(tr)):
				bad.append("%s/%s x 타이머 막대 %s %s" % [o, it2.n, _s(it2.r), _s(tr)])
		for i in inner.size():
			if not pr.grow(0.5).encloses(inner[i].r):
				bad.append("%s/%s 패널 밖 %s (패널 %s)" % [o, inner[i].n, _s(inner[i].r), _s(pr)])
			for j in range(i + 1, inner.size()):
				if _in(inner[i].r).intersects(_in(inner[j].r)):
					bad.append("%s/%s x %s %s %s" % [o, inner[i].n, inner[j].n, _s(inner[i].r), _s(inner[j].r)])
		if table.bet_boxes[no - 1].visible:
			items.append({"o": o, "k": "bet", "r": table.bet_boxes[no - 1].get_global_rect()})
	for c: Control in table.board_card_rects:
		if c.visible:
			items.append({"o": "center", "k": "board", "r": c.get_global_rect()})
	if table.total_box.visible:
		items.append({"o": "center", "k": "total", "r": table.total_box.get_global_rect()})
	if table.pots_label.visible:
		items.append({"o": "center", "k": "pots", "r": table.pots_label.get_global_rect()})
	if table.board_label.text != "":
		items.append({"o": "banner", "k": "label", "r": table.banner_title.get_global_rect().merge(table.board_label.get_global_rect())})
	if table.add_chips_button.visible: # 내 패널 안(스택 옆)에 있어야 한다 — 안쪽 요소와 겹치면 아래에서 걸린다
		var hs: Control = table.seat_nodes[hero - 1]
		if not Rect2(hs.global_position, hs.size).grow(0.5).encloses(table.add_chips_button.get_global_rect()):
			bad.append("칩 추가 + 가 내 패널 밖")
		var ab: Rect2 = table.add_chips_button.get_global_rect() # 닉네임 줄(패널 위 name_row·k) 안, 알약 모양(글자 "+ 칩"이 안 잘림)
		if ab.end.y > hs.global_position.y + (hs.name_row(true) + 4.0) * table.k + 0.5:
			bad.append("칩 추가 버튼이 닉네임 줄 밖 %s" % _s(ab))
		if ab.get_center().x < hs.global_position.x + hs.size.x / 2.0:
			bad.append("칩 추가 버튼이 닉네임 줄 오른쪽 끝이 아님 %s" % _s(ab))
		var bfont: Font = table.add_chips_button.get_theme_font("font")
		if bfont.get_string_size(table.add_chips_button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, table.add_chips_button.get_theme_font_size("font_size")).x > ab.size.x - 4.0:
			bad.append("칩 추가 버튼 글자가 좁은 폭에 잘림")
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
			if [a.k, b.k] in [["board", "label"], ["label", "board"]]:
				continue # 배너는 보드 카드 위에 얹는다
			if a.o == b.o and [a.k, b.k] in [["panel", "timer"], ["timer", "panel"]]:
				continue # 막대는 자기 패널 안쪽 띠 — 글자·카드와의 겹침은 위에서 따로 본다
			if _in(a.r).intersects(_in(b.r)):
				bad.append("%s/%s x %s/%s %s %s" % [a.o, a.k, b.o, b.k, _s(a.r), _s(b.r)])
	# 토큰·베팅·마커는 가장 가까운 패널이 자기 좌석이어야 한다(옆 좌석 것으로 보이지 않게)
	var hero_no := hero if hero > 0 else -1 # 관전은 아무도 큰 패널이 아니다
	for it in items:
		if it.k == "bet":
			var own := int(str(it.o).substr(4))
			if _nearest_panel(it.r, panels) != own:
				bad.append("%s/%s 가장 가까운 패널이 seat%d %s own %s near %s" % [it.o, it.k, _nearest_panel(it.r, panels), _s(it.r), _s(panels[own]), _s(panels[_nearest_panel(it.r, panels)])])
			if own != hero_no: # 베팅은 자기 패널 바로 곁(틈 14px 이내)
				var bgap := _gap(it.r, panels[own])
				if bgap > 14.0 * table.k:
					bad.append("%s/bet 이 자기 패널에서 멂 (%.0f)" % [it.o, bgap])
	if table.pot_row.visible:
		bad.append("데스크톱에서 PotRow 가 보임")
	if table.action_bg.get_index() > table.bottom_region.get_index() or table.my_cards_box.get_index() < table.seat_nodes[8].get_index():
		bad.append("그리기 순서: 행동 바탕이 패널 위이거나 내 카드가 좌석 아래")
	if hero > 0 and not table.seat_nodes[hero - 1].hand_rank.visible:
		bad.append("데스크톱 HandRank 가 보이지 않음")
	if table.hand_text_pill.visible:
		bad.append("데스크톱에서 폰 족보 알약이 보임")
	var gap := INF
	var keys := panels.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			gap = minf(gap, _gap(panels[keys[i]], panels[keys[j]]))
	return {"gap": gap, "bad": bad}
