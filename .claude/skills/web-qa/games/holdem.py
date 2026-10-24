"""홀덤 QA: 봇(REST+STOMP), 덱 고정(QA 서버 전용), 브라우저 보조, 시나리오. suite.py 가 SCENARIOS·cleanup 을 찾아 쓴다.
(이 폴더 파일만 지우면 홀덤이 빠진다 — qa.py 는 게임을 모른다)"""
import collections, re, threading, time
import qa

# ---------------------------------------------------------------- 봇
def _seats(v): return [s for s in (v or {}).get("seats", []) if s]


class Bot(qa.Client):
    """REST 로 행동하고 STOMP 로 공개·개인 뷰를 받는다(holdem.md: 행동=REST, STOMP=수신 전용).
    join-queue 는 연결 직후 구독해 두고 POST 한다. 개인 큐는 공개 뷰에 내가 앉아 있을 때만 구독한다."""

    def __init__(self, user):
        self.view = self.last_view = None; self.results = []; self.private = None; self.events = []; self.log = collections.deque(maxlen=20); self.tid = None; self._priv = False
        super().__init__(user)
        self.subscribe("jq", "/user/queue/holdem/join-queue")

    def on_message(self, h, d):
        self.log.append(dict(t=round(time.time(), 2), dest=(re.search(r"destination:(\S+)", h) or [0, "?"])[1], type=d.get("type"), seq=d.get("seq"), hand=d.get("handInProgress")))
        if "/user/queue/tables/" in h: self.private = d
        elif "/topic/tables/" in h:
            if d.get("type") == "TABLE_CLOSED": self.last_view = self.view; self.view = None; return
            if "seq" in d and d.get("seq", 0) >= (self.view or {}).get("seq", -1):  # seq 가 줄어든 메시지는 버린다
                self.view = d; self._sync_private()
                if d.get("result") and (not self.results or self.results[-1] != d["result"]): self.results.append(d["result"])
        else: self.events.append(d)

    def _sync_private(self):
        me = self.my_seat()
        if me and not self._priv:
            self._priv = True; self.subscribe(f"pv{self.tid}", f"/user/queue/tables/{self.tid}")
        elif not me and self._priv:
            self._priv = False; self.unsubscribe(f"pv{self.tid}"); self.private = None

    def watch(self, tid):
        """공개 토픽 구독(관전). 이미 구독 중이면 무시"""
        if self.tid != tid:
            self.tid = tid; self.view = None
            self.subscribe(f"pb{tid}", f"/topic/tables/{tid}")

    # --- 뷰 ---
    def seat_of(self, uid): return next((s for s in _seats(self.view) if int(s["userId"]) == uid), None)
    def my_seat(self): return self.seat_of(self.uid)
    def hero_uid(self, bots):
        """뷰에서 봇이 아닌 첫 착석자의 userId — 브라우저 사용자(REST 로그인 없이 알아낸다)"""
        ids = {b.uid for b in bots}
        return next((int(s["userId"]) for s in _seats(self.view) if int(s["userId"]) not in ids), None)
    def wait_for(self, pred, timeout=30, what="뷰 조건"):
        """pred(public_view) 가 참 값을 돌려줄 때까지"""
        return qa.wait_for(lambda: self.view and pred(self.view), timeout, what=what)

    # --- 행동 ---
    def _buy_in(self, path, want):
        """원하는 바이인(없으면 하한)을 서버 범위로 맞춘다. 나간 지 30분 안이면 나간 금액만큼 하한이 올라간다(obligation)"""
        r = qa.call(path, self.token)[1]; return min(max(want or r["minBuyIn"], r["minBuyIn"]), r["maxBuyIn"])
    def create_table(self, name, buy_in=None):
        """만든 사람이 서버에서 바로 착석한다. 201 뒤 공개 토픽 구독"""
        bi = self._buy_in("/api/holdem/buy-in", buy_in)
        s, d = qa.call("/api/holdem/tables", self.token, {"name": name, "buyIn": bi})
        if s not in (200, 201): raise RuntimeError(f"방 생성 {s} {d}")
        self.watch(d["tableId"]); self.wait_for(lambda v: self.my_seat(), 15, "방장 착석"); return d["tableId"]
    def sit(self, tid, buy_in=None, wait=True):
        """바이인(기본 하한)으로 참가. 핸드 중이면 대기열이라 다음 판에 앉는다"""
        self.watch(tid)
        bi = self._buy_in(f"/api/holdem/tables/{tid}/buy-in", buy_in)
        s, d = qa.call(f"/api/holdem/tables/{tid}/seats", self.token, {"buyIn": bi, "postBlindImmediately": False})
        if s >= 300: raise RuntimeError(f"{self.user} 착석 {s} {d}")
        if wait: self.wait_for(lambda v: self.my_seat(), 60, f"{self.user} 착석")
    def stand(self): return qa.call("/api/holdem/seat", self.token, method="DELETE")[0]  # 핸드 중 202(예약)
    def act(self, action, amount=None):
        b = {"action": action}
        if amount: b["raiseToAmount"] = amount
        return qa.call(f"/api/holdem/tables/{self.tid}/hands/actions", self.token, b)[0]


def policy_check_call(bot, v):  # 기본: 체크, 안 되면 콜, 그것도 안 되면 폴드
    for a in ("CHECK", "CALL", "FOLD"):
        if bot.act(a) < 300: return
def policy_fold(bot, v): bot.act("FOLD")


class Autoplay:
    """백그라운드 스레드: 자기 차례인 봇(skip 제외)이 policy(bot, view) 로 행동. 브라우저 사용자는 Viewer.pump() 가 맡는다
    (playwright 동기 API 는 다른 스레드에서 못 쓴다)"""
    def __init__(self, bots, policy=policy_check_call, skip=()):
        self.bots, self.policy, self.skip, self.on, self.delay = bots, policy, set(skip), True, 0.0
        self._turn, self._t0 = None, 0.0
        self.acted = set(); threading.Thread(target=self._run, daemon=True).start()
    def stop(self): self.on = False
    def slow(self, delay=3.0):
        """봇이 차례가 된 뒤 delay 초 만에 행동한다 — 핸드가 길어진다. 멈추지 않는다: QA 서버는 차례 8초 초과 시 폴드+즉시 기립시켜
        빈 방이 닫히므로, 핸드를 오래 두려면 얼리지 말고 8초보다 짧게 늦춘다"""
        self.delay = delay
    def fast(self): self.delay = 0.0
    def _run(self):
        while self.on:
            try:
                v = next((b.view for b in self.bots if b.view), None)
                if v and v.get("handInProgress") and v.get("toActSeatNo") is not None:
                    n = int(v["toActSeatNo"]); k = (n, v.get("street"))
                    if k != self._turn: self._turn, self._t0 = k, time.time()  # 차례가 처음 보인 시각
                    if time.time() - self._t0 < self.delay: time.sleep(0.1); continue
                    s = next((x for x in _seats(v) if int(x["seatNo"]) == n), None)
                    bot = next((b for b in self.bots if s and b.uid == int(s["userId"])), None)
                    if bot and bot.user not in self.skip and (n, v["seq"]) not in self.acted:
                        self.acted.add((n, v["seq"])); self.policy(bot, v)
            except Exception as e: print("autoplay", e)
            time.sleep(0.25)


def wait_result(bot, since=0, timeout=60):
    """bot.results[since] 가 생길 때까지 기다려 돌려준다. result = {payouts[{seatNo,userId,amount}], shownHands[{seatNo,holeCards,category}]}.
    다음 판이 빨리 시작해 뷰의 result 가 사라져도 bot.results 에 남는다 — 쓰기 전에 since=len(bot.results) 를 잡아 둔다"""
    return qa.wait_for(lambda: len(bot.results) > since and bot.results[since], timeout, what="핸드 결과")


def _login_retry(u, tries=4):
    """서버가 바쁠 때 로그인이 소켓 시간 초과(OSError)로 터지는 일이 있어 재시도한다"""
    for i in range(tries):
        try: return qa.rest_login(u)
        except OSError:
            if i == tries - 1: raise
            time.sleep(2)


def unseat_all(users=qa.USERS, timeout=120):
    """모든 qa 계정을 미착석으로 만든다(대기열 취소 + 차례면 폴드 + 일어서기를 미착석이 확인될 때까지 반복 — 핸드 중 일어서기는 예약뿐이라
    핸드를 빨리 끝내려고 폴드를 계속 시도한다). 멱등이라 시나리오 시작·끝에 모두 부른다. 시나리오 SIGALRM 과 별개의 자기 제한시간.
    REST 로그인하므로 브라우저를 닫은 뒤에 부른다."""
    toks = {u: _login_retry(u) for u in users}
    try:
        def left(u):
            s, d = qa.call("/api/holdem/me/seat", toks[u][0])
            if s == 200 and d: return d["tableId"]  # 204 = 미착석
        t0 = time.time()
        while time.time() - t0 < timeout:
            pend = {u: left(u) for u in users}; pend = {u: t for u, t in pend.items() if t}
            if not pend: return
            for u, tid in pend.items():
                tok = toks[u][0]
                qa.call(f"/api/holdem/tables/{tid}/seats/request", tok, method="DELETE")
                qa.call(f"/api/holdem/tables/{tid}/hands/actions", tok, {"action": "FOLD"})
                qa.call("/api/holdem/seat", tok, method="DELETE")
            time.sleep(1.5)
        raise RuntimeError(f"{timeout}s 안에 못 비움: {pend}")
    finally:
        for t, c in toks.values():
            try: qa.rest_logout(t, c)
            except OSError: pass


_adm = {}


def list_tables():
    """방 목록(UI 와 같은 순서). 착석 중인 계정이 핸드 중에 부르면 서버가 409 HAND_IN_PROGRESS 를 줘서 qaadmin 토큰으로 읽는다"""
    if "t" not in _adm: _adm["t"] = qa.rest_login(qa.ADMIN)[0]
    s, d = qa.call("/api/holdem/tables", _adm["t"]); return d["content"] if s == 200 else []

def nickname(uid):
    """userId -> 닉네임(화면에 보이는 이름). qaadmin 토큰으로 읽는다"""
    if "t" not in _adm: _adm["t"] = qa.rest_login(qa.ADMIN)[0]
    return qa.call(f"/api/users/{uid}", _adm["t"])[1]["nickname"]

# ---------------------------------------------------------------- 덱 고정 (QA 서버 전용, 다음 핸드 1회)
CARD = re.compile(r"^[2-9TJQKA][shdc]$")

def next_deck(tid, hole_cards=None, board=()):
    """POST /api/admin/qa/holdem/tables/{tid}/next-deck. hole_cards={좌석번호:[c,c]}, board=[최대 5장]. 다음 핸드 시작 때 1회 적용
    (예약은 핸드 시작 전까지 남는다 — 핸드 진행 중에 걸면 그다음 핸드에 적용). 지정 안 한 자리는 무작위. 204 가 아니면 예외.
    qaadmin 토큰은 캐시하고 브라우저 사용자와 무관하다."""
    cards = [c for h in (hole_cards or {}).values() for c in h] + list(board)
    bad = [c for c in cards if not CARD.match(c)]
    if bad or len(set(cards)) != len(cards): raise ValueError(f"카드 형식/중복 오류: {bad or cards}")
    body = {"holeCards": {str(k): list(v) for k, v in (hole_cards or {}).items()}, "board": list(board)}
    for _ in range(2):
        if "t" not in _adm: _adm["t"] = qa.rest_login(qa.ADMIN)[0]
        s, d = qa.call(f"/api/admin/qa/holdem/tables/{tid}/next-deck", _adm["t"], body)
        if s == 401: _adm.clear(); continue  # 토큰 만료면 재로그인
        break
    if s != 204: raise RuntimeError(f"next-deck {s} {d}")

# 보드는 어떤 2장으로도 스트레이트·플러시가 안 되는 마른 보드. 패자 패는 보드와 랭크가 안 겹치는 무늬 같은 두 장(페어·스트레이트 불가)
_BOARD = ["Kc", "8d", "3h", "Js", "5c"]
_LOW = [r + s for s in "shdc" for r in "246T79"]

def _losers(seats):
    return {s: _LOW[2 * i:2 * i + 2] for i, s in enumerate(seats)}

def deck_showdown(winner_seat, seats=range(1, 10)):
    """winner_seat 이 AA 로 단독 승리(전원 쇼다운 가정 — 봇이 체크/콜). 나머지 좌석은 약한 하이카드"""
    others = [s for s in seats if s != winner_seat]
    return dict(hole_cards={winner_seat: ["As", "Ah"], **_losers(others)}, board=_BOARD)

def deck_split(split_seats, seats=range(1, 10)):
    """split_seats(2~4곳)가 A-Q 하이로 동률(칩 분할). 나머지는 약한 하이카드"""
    sp = list(split_seats); assert 2 <= len(sp) <= 4
    sa, sq = "shdc", "hdcs"
    hole = {s: ["A" + sa[i], "Q" + sq[i]] for i, s in enumerate(sp)}
    return dict(hole_cards={**hole, **_losers([s for s in seats if s not in sp])}, board=_BOARD)

def deck_hero_wins(hero_seat, seats=range(1, 10)):
    return deck_showdown(hero_seat, seats)




# ------------------------------------------------------------------ 브라우저 보조(Viewer 는 게임을 모른다 — 홀덤 화면 흐름은 여기)
def to_room_list(v, game=0):
    v.open_game(game); v.wait_scene("table_list.tscn", 15)
    v.wait_state(lambda s: not s["nodes"].get("RefreshButton", {}).get("disabled", True), 15, "방 목록 로드")


def open_room(v, index=0, key=None):
    """방 목록 index 번째(REST 목록 순서와 같다) 카드 -> 입장 패널(바이인 조회까지 끝나 참가 버튼이 풀릴 때까지). key 를 주면 그 카드 키를 누른다"""
    v.press(key or f"Rows/{index}")
    v.wait_state(lambda s: v.vis(s, "EntryPanel") and not s["nodes"]["EntryJoin"].get("disabled", True), 15, "입장 패널")


def spectate(v):
    v.press("EntryWatch"); v.wait_scene("table.tscn", 15)
    v.wait_state(lambda s: s["extra"].get("table_id") and v.vis(s, "JoinButton"), 15, "관전 상태")


def join(v, post_blind=True, timeout=30):
    """입장 패널의 "바로 참가" 를 체크하고(기본) 참가한다. 안 체크하면 서버가 SITTING_OUT 으로 두고 BB 가 돌아올 때까지(최대 9판) 딜인하지 않는다.
    착석하고 SITTING_OUT 이 아닐 때까지 확인한다"""
    if post_blind and not v.state()["nodes"]["EntryPostBlind"].get("pressed"): v.press("EntryPostBlind")
    v.press("EntryJoin"); v.wait_scene("table.tscn", 15)
    def ok(s):
        e = s["extra"]; me = e.get("my_seat_no", -1)
        seat = next((x for x in e.get("seats", []) if x["seat_no"] == me), None)
        return seat and seat["status"] != "SITTING_OUT"
    v.wait_state(ok, timeout, "히어로 착석+딜인")


def my_seat(v): return v.extra().get("my_seat_no", -1)
def back_to_list(v): v.press("BackButton"); v.wait_scene("table_list.tscn", 15)


def attach(v, bot, bots):
    """wait_state/wait_for 가 히어로 차례에 체크/콜을 자동으로 누르게 걸고, 공개 뷰 출처(bot)와 봇 목록을 기억한다"""
    v._bot, v._bots, v._pumped = bot, bots, {}; v.poll = lambda s: pump(v, s)


def pump(v, s=None):
    """히어로 차례면 체크/콜(브리지 상태로 판단). 메인 스레드에서만(playwright 제약). 같은 턴은 2초마다 재시도"""
    e = (s or v.state())["extra"]; me = e.get("my_seat_no", -1)
    if me != -1 and e.get("to_act_seat") == me and "FOLD" in e.get("available_actions", []):
        k = (me, e.get("street"), e.get("table_id"))
        if time.time() - v._pumped.get(k, 0) > 2:
            v._pumped[k] = time.time(); v.try_press("CheckCallButton")


def wait_for(v, pred, timeout=60, what="뷰 조건", pump_=True):
    """pred(봇의 공개 뷰) 가 참일 때까지 기다리며 히어로 차례를 처리"""
    def f():
        if pump_: pump(v)
        v.page.wait_for_timeout(80); return v._bot.view and pred(v._bot.view)
    return qa.wait_for(f, timeout, 0, what)


def wait_next_hand(v, timeout=60, pump=True):
    """지금 핸드가 끝나고 다음 핸드가 시작될 때까지(끝나길 기다리는 동안은 pump. 시작을 기다릴 땐 pump=False 면 첫 차례를 직접 볼 수 있다)"""
    if (v._bot.view or {}).get("handInProgress"): wait_for(v, lambda x: not x.get("handInProgress"), timeout, "핸드 종료")
    wait_for(v, lambda x: x.get("handInProgress"), timeout, "다음 핸드 시작", pump)


SCENARIOS = []
def scenario(name, limit=90):
    def d(f): f.limit = limit; SCENARIOS.append((name, f)); return f
    return d


ERR = {"TABLE_NAME_INVALID": "방 이름은 1~30자여야 합니다"}  # core/error_text.gd


def table(c, name, n_bots, buy_in=10000, policy=policy_check_call):
    """봇 n_bots 명(qauser2~)이 앉은 방. Autoplay 가 봇을 진행한다. -> (tid, bots, autoplay). 정리는 c 가 한다"""
    bots = [Bot(f"qauser{i}") for i in range(2, 2 + n_bots)]
    ap = Autoplay(bots, policy=policy) if policy else None
    c.on_cleanup(lambda: [ap and ap.stop(), *[b.stop() for b in bots]]); c.bots = getattr(c, "bots", []) + bots
    tid = bots[0].create_table(name, buy_in)
    for b in bots[1:]: b.sit(tid, buy_in)
    return tid, bots, ap


def hero(c, tid, bots, join_=True, buy_in=None):
    """qauser1 브라우저: 로그인 -> 방 목록 -> tid 카드 -> 참가/관전. 봇 뷰에 attach"""
    v = c.viewer(); v.login(); to_room_list(v); attach(v, bots[0], bots); enter(v, tid, join_, buy_in); return v


def enter(v, tid, do_join=True, buy_in=None):
    def card(s): return next((r for r in s["extra"].get("rooms", []) if r["table_id"] == tid), None)
    try: room = v.wait_state(card, 5, "방 카드")
    except TimeoutError: v.press("RefreshButton"); room = v.wait_state(card, 10, "방 카드(새로고침 후)")  # 방 목록 화면 상태는 bridge 의 rooms 가 기준
    open_room(v, key=room["card_key"])
    if do_join:
        if buy_in == "min": buy_in = v.state()["nodes"]["EntrySpin"]["min"]  # 재착석 의무로 하한이 계정마다 다르다
        if buy_in: v.set_value("EntrySpin", buy_in)
        v.last_buy_in = int(v.state()["nodes"]["EntrySpin"]["value"])
        join(v)
    else: spectate(v)


def occupied(host): return sorted(int(s["seatNo"]) for s in _seats(host.view))
def paid_seats(s):
    """보이는 Payout 라벨(+…)이 있는 좌석 번호 — 좌석 노드는 Seat1..9"""
    n = s["nodes"]; return sorted(i for i in range(1, 10) if n.get(f"Seat{i}/Payout", {}).get("visible") and n[f"Seat{i}/Payout"].get("text", "").startswith("+"))
def seat_nick(s, no): return next(x["nickname"] for x in s["extra"]["seats"] if x["seat_no"] == no)


def fixed_hand(v, host, tid, deck_fn):
    """deck_fn(좌석목록) 덱이 걸린 핸드(착석자 전원 ACTIVE)가 막 시작된 상태로 돌려준다. 시작 직후엔 pump 하지 않는다(첫 차례를 직접 보게)"""
    for _ in range(6):
        wait_for(v, lambda x: not x["handInProgress"], 60, "핸드 종료")
        next_deck(tid, **deck_fn(occupied(host)))
        wait_next_hand(v, pump=False)
        if all(x["status"] == "ACTIVE" for x in _seats(host.view)): return
    raise RuntimeError("전원 ACTIVE 인 핸드를 못 잡음")


def hero_turn(s):
    e = s["extra"]; return e["my_seat_no"] != -1 and e["to_act_seat"] == e["my_seat_no"] and "FOLD" in e["available_actions"]


def rejoin(v):
    """관전 중 JoinButton -> 착석 팝업 -> 확인 -> 착석"""
    v.press("JoinButton"); v.wait_state(lambda s: not s["nodes"]["SitPopupOk"].get("disabled", True) and v.vis(s, "SitPopup"), 15, "착석 팝업")
    if not v.state()["nodes"]["PostBlindCheck"].get("pressed"): v.press("PostBlindCheck")
    v.press("SitPopupOk"); v.wait_state(lambda s: s["extra"]["my_seat_no"] != -1, 30, "재착석")


def in_hand_active(s):
    e = s["extra"]; me = e["my_seat_no"]
    return me != -1 and e["hand_in_progress"] and any(x["seat_no"] == me and x["status"] == "ACTIVE" for x in e["seats"])


# ------------------------------------------------------------------ 시나리오
@scenario("방 만들기(검증 오류 + 성공)", 60)
def s2(c):
    v = c.viewer(); v.login(); v.open_game(0); v.wait_scene("table_list.tscn", 15)
    def loaded(s):  # 바이인 범위가 오기 전에는 만들기가 막혀 있어야 한다(관측하는 모든 스냅샷에서)
        n = s["nodes"]; info = v.text(s, "BuyInInfo")
        assert info or n["CreateButton"].get("disabled"), "바이인 로드 전인데 CreateButton 이 켜져 있다"
        return info and not n["CreateButton"].get("disabled")
    v.wait_state(loaded, 15, "바이인 로드 후 CreateButton 활성")
    v.press("OpenCreateButton"); v.wait_state(lambda s: v.vis(s, "CreatePanel"), 10, "만들기 패널")
    for bad in ("", "   "):  # 길이 31 은 NameEdit.max_length=30 이 잘라 낸다
        v.set_text("NameEdit", bad); v.press("CreateButton")
        s = v.wait_state(lambda s: v.vis(s, "CreateErrorLabel") and s, 10, "방 이름 오류")
        assert v.text(s, "CreateErrorLabel") == ERR["TABLE_NAME_INVALID"], f"{bad!r}: {v.text(s, 'CreateErrorLabel')!r}"
        assert v.scene() == "table_list.tscn", "검증 실패인데 화면이 바뀌었다"
    v.set_text("NameEdit", "QA스위트"); v.press("CreateButton"); v.wait_scene("table.tscn", 15)
    v.wait_state(lambda s: s["extra"].get("my_seat_no", -1) != -1, 30, "방장 착석")


@scenario("입장 패널: 관전 / 바이인 참가", 90)
def s3(c):
    tid, bots, _ = table(c, "S3", 1)
    v = c.viewer(); v.login(); to_room_list(v); enter(v, tid, do_join=False)
    s = v.state(); e = s["extra"]
    assert e["table_id"] == tid and e["my_seat_no"] == -1, f"관전인데 my_seat_no={e['my_seat_no']}"
    assert v.vis(s, "JoinButton") and not v.vis(s, "SitPopup"), "관전: 참가 버튼이 안 보이거나 팝업이 떠 있다"
    back_to_list(v); enter(v, tid, do_join=True, buy_in="min")
    s = v.state(); e = s["extra"]; me = next(x for x in e["seats"] if x["seat_no"] == e["my_seat_no"])
    assert not v.vis(s, "SitPopup"), "참가 뒤 착석 팝업이 떴다"
    assert v.last_buy_in - 400 <= me["stack"] <= v.last_buy_in, f"바이인 {v.last_buy_in} 인데 스택 {me['stack']}"  # 블라인드만큼은 빠질 수 있다


@scenario("고정 덱 한 판 vs 봇", 120)
def s4(c):
    tid, bots, _ = table(c, "S4", 2); host = bots[0]
    v = hero(c, tid, bots); me = my_seat(v); nick = nickname(host.hero_uid(bots))
    fixed_hand(v, host, tid, lambda seats: deck_hero_wins(me, seats))
    s = v.wait_state(lambda s: hero_turn(s) and s, 30, "히어로 차례", pump=False)
    assert all(v.vis(s, k) for k in ("FoldButton", "CheckCallButton", "ActionBar")), "행동 버튼이 안 보인다"
    assert sorted(s["extra"]["my_hole_cards"]) == ["Ah", "As"], f"홀카드 {s['extra']['my_hole_cards']}"
    assert v.text(s, "CheckCallButton") and not s["nodes"]["CheckCallButton"].get("disabled"), "체크/콜 버튼 문구/상태"
    v.press("CheckCallButton"); n0 = len(host.results)
    s = v.wait_state(lambda s: s["extra"]["winners"] and s, 60, "결과(승자)")  # 한 스냅샷에서 전부 판정한다(결과는 금방 지나간다)
    assert [w["seat_no"] for w in s["extra"]["winners"]] == [me], f"승자 {s['extra']['winners']} (기대 좌석 {me})"
    assert paid_seats(s) == [me], f"지급액이 보이는 좌석 {paid_seats(s)} (기대 {me})"
    assert seat_nick(s, me) == nick and nick in v.text(s, "BoardLabel"), f"결과 문구에 {nick!r} 없음: {seat_nick(s, me)!r} / {v.text(s, 'BoardLabel')!r}"
    r = wait_result(host, n0, 5); assert [p["seatNo"] for p in r["payouts"]] == [me], f"서버 결과 {r['payouts']}"
    s = v.wait_state(lambda s: ("다음 판" in v.text(s, "StatusLabel") or s["extra"]["next_hand_seconds"] >= 0) and s, 15, "다음 판 카운트다운", pump=False)
s4.sizes = ("d",)


@scenario("폴드 승리 -> 패 보여주기 버튼", 120)
def s5(c):
    tid, bots, _ = table(c, "S5", 1, policy=policy_fold); host = bots[0]
    v = hero(c, tid, bots); me = my_seat(v)
    s = v.wait_state(lambda s: v.vis(s, "ShowHandButton") and s, 60, "패 보여주기 버튼")  # 봇이 폴드 -> 히어로 폴드 승
    e = s["extra"]
    assert [w["seat_no"] for w in e["winners"]] == [me] and not e["hand_in_progress"], f"폴드 승 조건: {e['winners']} 진행={e['hand_in_progress']}"
    assert not host.results[-1]["shownHands"], "폴드 종료인데 shownHands 가 비어 있지 않다"
    n = len(host.results); v.press("ShowHandButton")
    qa.wait_for(lambda: any(h["seatNo"] == me for r in host.results[n - 1:] for h in r["shownHands"]), 5, what="shownHands 에 히어로")
s5.sizes = ("d",)


def _in_hand(c, name, n_bots=2):
    tid, bots, ap = table(c, name, n_bots); v = hero(c, tid, bots)
    v.wait_state(in_hand_active, 40, "히어로가 참가한 핸드"); return tid, bots, ap, v


@scenario("나가기 예약 3종(관전/방 나가기/새로고침)", 170)
def s6(c):
    tid, bots, ap, v = _in_hand(c, "S6")
    s = v.state(); assert v.text(s, "StandButton") == "핸드 후 관전" and v.text(s, "LeaveRoomButton") == "핸드 후 방 나가기", f"버튼 문구 {v.text(s, 'StandButton')!r}/{v.text(s, 'LeaveRoomButton')!r}"
    ap.slow(); v.press("StandButton"); s = v.wait_state(lambda s: v.vis(s, "CancelLeaveButton") and s, 10, "예약 취소 버튼"); ap.fast()
    assert "관전 예약됨" in v.text(s, "CancelLeaveButton"), v.text(s, "CancelLeaveButton")
    v.wait_state(lambda s: s["extra"]["my_seat_no"] == -1, 60, "핸드 후 일어섬")
    time.sleep(2); s = v.state()
    assert s["scene"].endswith("table.tscn") and v.vis(s, "JoinButton"), f"관전 후 화면 {s['scene']}"
    # 핸드 후 방 나가기
    rejoin(v); v.wait_state(in_hand_active, 40, "재참가 후 핸드"); ap.slow()
    v.press("LeaveRoomButton"); ap.fast(); v.wait_scene("table_list.tscn", 60)
    # 새로고침: 느린 봇 + 폴드로 핸드를 길게 둔다
    enter(v, tid, True)
    v.wait_state(in_hand_active, 60, "히어로 핸드")
    v.wait_state(lambda s: hero_turn(s) and s, 40, "히어로 차례", pump=False); ap.slow()  # 폴드 뒤 새로고침·재진입 동안 핸드가 살아 있게(얼리면 8초 차례 만료로 봇이 기립한다)
    v.press("FoldButton")
    v.press("LeaveRoomButton"); s = v.wait_state(lambda s: v.vis(s, "CancelLeaveButton") and s, 10, "예약 취소 버튼")
    assert "나가기 예약됨" in v.text(s, "CancelLeaveButton"), v.text(s, "CancelLeaveButton")
    v.reload(); v.wait_state(lambda s: s["scene"].endswith("lobby.tscn") or v.vis(s, "UsernameEdit"), 30, "새로고침 후 화면")  # 세션이 남아 있으면 로비, 아니면 로그인 폼
    if v.scene() == "login.tscn": v.login()
    v.open_game(0); s = v.wait_state(lambda s: s["scene"].endswith("table.tscn") and v.vis(s, "CancelLeaveButton") and s, 20, "재진입 시 예약 취소 버튼")
    assert "나가기 예약됨" in v.text(s, "CancelLeaveButton"), f"새로고침 뒤 문구 {v.text(s, 'CancelLeaveButton')!r}"
    ap.fast()
s6.sizes = ("d",)


@scenario("예약 취소 -> 핸드 후에도 착석", 100)
def s7(c):
    tid, bots, ap, v = _in_hand(c, "S7")
    ap.slow(); v.press("StandButton"); v.wait_state(lambda s: v.vis(s, "CancelLeaveButton"), 10, "예약 취소 버튼")
    v.press("CancelLeaveButton"); v.wait_state(lambda s: not v.vis(s, "CancelLeaveButton") and v.vis(s, "StandButton"), 10, "예약 취소됨"); ap.fast()
    v.wait_state(lambda s: not s["extra"]["hand_in_progress"], 60, "핸드 종료"); time.sleep(2); s = v.state()
    assert s["extra"]["my_seat_no"] != -1 and s["scene"].endswith("table.tscn"), f"취소했는데 일어섰다 seat={s['extra']['my_seat_no']}"
s7.sizes = ("d",)


@scenario("방이 닫히면 관전자는 목록으로", 90)
def s8(c):
    tid, bots, _ = table(c, "S8", 1, policy=None)
    v = c.viewer(); v.login(); to_room_list(v); enter(v, tid, do_join=False)
    assert bots[0].stand() in (200, 204), "방장 일어서기 실패"  # 빈 방은 서버가 15초 뒤 닫는다
    v.wait_scene("table_list.tscn", 60)
s8.sizes = ("d",)


@scenario("목록에 게임 중 표시", 90)
def s9(c):
    tid, bots, ap = table(c, "S9", 2)
    qa.wait_for(lambda: next((t for t in list_tables() if t["tableId"] == tid and t.get("handInProgress")), None), 30, what="목록의 handInProgress")
    ap.slow()  # 핸드를 길게 둔다(얼리면 8초 차례 만료로 봇이 기립한다). 다음 핸드가 빨리 끝나 UI 확인 전에 사라지는 것을 막는다
    v = c.viewer(); v.login(); to_room_list(v)
    s = v.wait_state(lambda s: any(r["table_id"] == tid for r in s["extra"].get("rooms", [])) and s, 15, "목록에 방")
    room = next(r for r in s["extra"]["rooms"] if r["table_id"] == tid)
    assert room["in_progress"], f"UI 목록 데이터에 게임 중 표시가 없다: {room}"
    v.press(room["card_key"])  # 눌러서 입장 패널이 열리는 카드까지 UI 데이터로 찾는다
    v.wait_state(lambda s: v.vis(s, "EntryPanel"), 15, "입장 패널"); ap.fast()
s9.sizes = ("d",)


QA_RESUME_GAP_S = 5  # core/stomp.gd RESUME_GAP_MS. 이보다 오래 정지했다 돌아오면 소켓을 한 번 교체해 구독 스냅샷으로 재동기화한다
QA_ROTATION_GRACE_S = 5  # 서버 app.auth.stomp-rotation-grace (qa 프로필 5s, 운영 30s). 숨은 탭 시나리오의 대기 시간은 이 값에 맞춘다


def _hidden_tab_setup(c, name):
    """A(로비) + B(같은 context, 홀덤 테이블 관전 = STOMP 소켓 열림, 소켓 OPEN/CLOSE 기록). UI 로그인. -> a, b, ws_events, bot(공개 뷰 출처)"""
    tid, bots, ap = table(c, name, 2)
    a = c.viewer(); a.login(); a.wait_state(lambda s: a.text(s, "BalanceLabel").strip() and s, 15, "A 잔액 표시")
    b = c.viewer(share=a); b.wait_scene("lobby.tscn", 30)
    ev = b.capture_ws_frames()  # 소켓은 테이블 진입 때 열린다 — 그 전에 건다
    to_room_list(b); enter(b, tid, do_join=False)
    qa.wait_for(lambda: (b.page.wait_for_timeout(50), any(e["dir"] == "OPEN" for e in ev))[1], 10, what="B STOMP 소켓 OPEN")
    a.refreshes = a.unauth = b.refreshes = b.unauth = 0
    return a, b, ev, bots[0]


def _hidden_tab_refresh(a, b, ev, bot, hold):
    """B 정지 -> A refresh -> 정지 중 B 의 JS 토큰 확인 -> hold 초 뒤 재개 -> A 갱신 시점부터 유예+3초(길게 정지했으면 재개 뒤 4초)가 지나도록 소켓 변화(짧게 정지면 없음, 5초 넘게 정지면 재개 뒤 교체 한 번). 관찰을 문자열 목록으로 돌려준다"""
    tail = lambda v: v.state()["token_tail"]; old = tail(a); notes = []
    b.pause(); t0 = time.time(); n0 = len(ev)
    a.page.evaluate("window.godotQa.refresh()")
    a.wait_state(lambda s: a.refreshes >= 1 and s, 15, "A refresh 응답")
    # 3) 정지 중에도 B 의 JS 토큰이 새 토큰
    qa.wait_for(lambda: (b.page.wait_for_timeout(50), a.page.evaluate("window.__auth.token") != "" and b.page.evaluate("window.__auth.token").endswith(tail(a)))[1], 5, what="정지 중 B JS 토큰 갱신")
    assert tail(a) != old and a.refreshes == 1, f"A 갱신 이상 refresh={a.refreshes}"
    notes.append(f"정지 중 B __auth.token 새 토큰 OK, B Api.access_token tail={'새' if tail(b) == tail(a) else '옛'}(브리지)")
    while time.time() - t0 < hold: b.page.wait_for_timeout(200)
    closed_paused = [round(e["t"] - t0, 1) for e in ev[n0:] if e["dir"] == "CLOSE"]
    notes.append(f"정지 {round(time.time() - t0, 1)}s 동안 소켓 CLOSE={closed_paused}")
    want_seq = (bot.view or {}).get("seq", 0)
    b.resume()
    # 4) 재개 뒤
    b.wait_state(lambda s: s["token_tail"] == tail(a) and s, 10, "재개 뒤 B 토큰 == A")
    while time.time() - t0 < max(QA_ROTATION_GRACE_S + 3, hold + 4): b.page.wait_for_timeout(200)
    sent = [e for e in ev[n0:] if e["dir"] == "SENT" and "/app/auth/refresh" in e["data"]]
    recv = [e for e in ev[n0:] if e["dir"] == "RECV" and "OK" in e["data"] and "auth" in e["data"]]
    changes = [(e["dir"], round(e["t"] - t0, 1)) for e in ev[n0:] if e["dir"] in ("OPEN", "CLOSE")]
    notes.append(f"인밴드 SEND={[round(e['t'] - t0, 1) for e in sent]} 응답={[round(e['t'] - t0, 1) for e in recv]} 소켓 OPEN/CLOSE={changes}")
    print("   [hidden-tab]", "; ".join(notes), flush=True)
    if hold <= QA_RESUME_GAP_S:
        assert not changes, "소켓이 바뀌었다/닫혔다: " + "; ".join(notes)
    else:  # 재개 뒤 make-before-break 교체가 정확히 한 번: 새 OPEN -> 옛 CLOSE, CLOSE 가 OPEN 보다 먼저 오면 끊김
        assert [d for d, _ in changes] == ["OPEN", "CLOSE"] and changes[0][1] >= hold - 0.5, "재개 뒤 OPEN->CLOSE 한 번이어야 한다: " + "; ".join(notes)
        # 재동기화: B 의 공개 뷰가 봇이 재개 시점에 이미 받은 최신 seq 를 따라잡았다(숨은 동안 놓친 상태 복구)
        qa.wait_for(lambda: (b.page.wait_for_timeout(100), b.state()["extra"]["last_public_seq"] >= want_seq)[1], 5, what=f"B 공개 뷰 seq >= {want_seq}")
    back_to_list(b)  # B 의 REST(방 목록) — 소켓 판정 뒤에(나가면 소켓을 의도해 닫는다)
    assert b.refreshes == 0 and a.refreshes == 1, f"refresh 요청 A={a.refreshes} B={b.refreshes} (A=1, B=0 이어야 한다)"
    assert tail(b) == tail(a) and b.unauth == 0 and a.unauth == 0, f"B REST 401 A={a.unauth} B={b.unauth} tail A={tail(a)} B={tail(b)}"


@scenario("숨은 탭 B: 정지 중 갱신, 3초 뒤 재개, 소켓 유지", 100)
def hidden_short(c):
    a, b, ev, bot = _hidden_tab_setup(c, "HS"); _hidden_tab_refresh(a, b, ev, bot, 3)
hidden_short.sizes = ("d",)


@scenario(f"숨은 탭 B: {QA_ROTATION_GRACE_S + 3}초 내내 정지, 재개 뒤 소켓 한 번 교체·재동기화", 100)
def hidden_long(c):
    a, b, ev, bot = _hidden_tab_setup(c, "HL"); _hidden_tab_refresh(a, b, ev, bot, QA_ROTATION_GRACE_S + 3)
hidden_long.sizes = ("d",)


@scenario("9석 테이블 렌더", 150)
def s10(c):
    tid, bots, _ = table(c, "S10", 8)
    v = hero(c, tid, bots)
    s = v.wait_state(lambda s: len(s["extra"]["seats"]) == 9 and s, 40, "9석 착석")
    names = [d["text"] for k, d in s["nodes"].items() if k.endswith("/NameLabel") and d["visible"] and d["text"]]
    assert len(names) == 9 and len(set(names)) == 9, f"보이는 이름 {names}"
    time.sleep(2)




def fail_snapshot(c):
    """시나리오 실패 진단: 봇들의 최신 공개 뷰 요약 + 최근 STOMP 메시지(suite.py 가 _fail.json 에 쓴다)"""
    out = []
    for b in getattr(c, "bots", []):
        v = b.view or b.last_view or {}  # 방이 닫혔으면 닫히기 직전 뷰
        out.append(dict(bot=b.user, uid=b.uid, table=b.tid, seq=v.get("seq"), handInProgress=v.get("handInProgress"), street=v.get("street"),
                        toActSeatNo=v.get("toActSeatNo"), buttonSeatNo=v.get("buttonSeatNo"), private=bool(b.private), results=len(b.results),
                        seats=[{k: s.get(k) for k in ("seatNo", "userId", "status", "stack", "presence", "connected")} for s in _seats(v)],
                        join_queue_events=b.events[-5:], log=list(b.log)))
    return out


cleanup = unseat_all  # 러너가 시작·매 시나리오 뒤에 부른다(모든 qa 계정을 미착석으로)
