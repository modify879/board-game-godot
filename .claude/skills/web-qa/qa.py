"""홀덤 라이브 QA 하네스 — 봇(REST+STOMP) + 덱 고정 + 헤드리스 브라우저. 동기 API, 표준 라이브러리 + playwright 만 쓴다.
사용 예: example_showdown_9.py. 실행은 `python -B`(스킬 폴더에 __pycache__ 가 남지 않게).

함정(겪은 것):
- 브라우저 사용자(예: qauser1)를 REST 로 로그인하지 않는다 — 브라우저의 refresh 세션이 무효화된다. 그 사용자의 착석은
  봇의 공개 뷰(bot.hero_uid(bots))로 확인한다. unseat_all() 은 REST 로그인하므로 브라우저를 닫은 뒤에 부른다.
- :8000/:8080 은 사용자 환경이다. 기본은 QA(:8001 → :8081). 다른 곳은 QA_WEB 로 명시하고 QA_ALLOW_NON_QA=1 도 준다.
- 시나리오 단계 전에 앉았는지 확인한다(wait_seated / viewer.join 뒤 bot.wait_for).
"""
import base64, hashlib, json, os, re, socket, struct, sys, threading, time, urllib.error, urllib.request
from urllib.parse import urlparse

sys.dont_write_bytecode = True  # 이 모듈 자신의 pyc 는 못 막는다 -> python -B / PYTHONDONTWRITEBYTECODE=1 + .gitignore

WEB = os.environ.get("QA_WEB", "http://localhost:8001")  # 클라이언트(nginx). API·WS 도 같은 origin
if urlparse(WEB).port in (8000, 8080) and not os.environ.get("QA_ALLOW_NON_QA"):
    raise SystemExit(f"{WEB} 는 QA 환경이 아니다(사용자가 쓰는 :8000/:8080). QA 는 http://localhost:8001")
PW = "qapass1234"
USERS = [f"qauser{i}" for i in range(1, 10)]
ADMIN = "qaadmin"
OUT = os.environ.get("QA_OUT", "/tmp/qa_out")
ARGS = ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",  # WebGL2
        "--disable-renderer-backgrounding", "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows"]

# ---------------------------------------------------------------- REST
def call(path, token=None, body=None, method=None, cookie=None):
    """(status, json|text|None). 오류 상태도 예외 없이 돌려준다"""
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    if cookie: h["Cookie"] = cookie
    r = urllib.request.Request(WEB + path, data=None if body is None else json.dumps(body).encode(), headers=h, method=method)
    try:
        x = urllib.request.urlopen(r, timeout=15)
    except urllib.error.HTTPError as e:
        x = e
    except OSError as e:
        return 0, str(e)
    d = x.read().decode()
    try: d = json.loads(d) if d else None
    except ValueError: pass
    return x.status, d


def rest_login(user, pw=PW):
    """(accessToken, refresh 쿠키). 같은 계정의 브라우저 세션을 쫓아내므로 브라우저 사용자에게 쓰지 않는다"""
    r = urllib.request.Request(WEB + "/api/auth/login", json.dumps({"username": user, "password": pw}).encode(),
                               {"Content-Type": "application/json"})
    try: x = urllib.request.urlopen(r, timeout=15)
    except urllib.error.HTTPError as e: raise SystemExit(f"로그인 실패 {user}: HTTP {e.code}. SKILL.md '테스트 계정' 참고")
    return json.load(x)["accessToken"], (x.headers.get("Set-Cookie") or "").split(";")[0]


def rest_logout(token, cookie=""):
    call("/api/auth/logout", token, {}, cookie=cookie)


def wait_for(pred, timeout=30, interval=0.1, what="조건"):
    """pred() 가 참 값을 돌려줄 때까지. 시간 초과면 TimeoutError"""
    t = time.time()
    while time.time() - t < timeout:
        v = pred()
        if v: return v
        time.sleep(interval)
    raise TimeoutError(f"{timeout}s 안에 {what} 안 됨")


# ---------------------------------------------------------------- 최소 WebSocket (표준 라이브러리)
class _WS:
    def __init__(self, on_text):
        u = urlparse(WEB); self.s = socket.create_connection((u.hostname, u.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /ws HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.f = self.s.makefile("rb"); line = self.f.readline()
        if b" 101 " not in line: raise RuntimeError("WS 업그레이드 실패: " + line.decode())
        while self.f.readline() not in (b"\r\n", b""): pass
        self.s.settimeout(None); self.on_text = on_text; self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def send(self, text):
        b = text.encode(); n = len(b); mask = os.urandom(4)
        hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0xFE]) + struct.pack(">H", n) if n < 65536 else bytes([0xFF]) + struct.pack(">Q", n))
        with self.lock: self.s.sendall(hdr + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(b)))

    def _read(self):
        buf = b""
        try:
            while True:
                h = self.f.read(2)
                if len(h) < 2: return
                op, n = h[0] & 15, h[1] & 127
                if n == 126: n = struct.unpack(">H", self.f.read(2))[0]
                elif n == 127: n = struct.unpack(">Q", self.f.read(8))[0]
                data = self.f.read(n)
                if op == 8: return
                if op == 9:  # ping -> pong(마스크 필요)
                    m = os.urandom(4)
                    with self.lock: self.s.sendall(bytes([0x8A, 0x80 | len(data)]) + m + bytes(c ^ m[i % 4] for i, c in enumerate(data)))
                elif op in (0, 1):
                    buf += data
                    if h[0] & 0x80: self.on_text(buf.decode()); buf = b""
        except (OSError, ValueError): pass

    def close(self):
        try: self.s.close()
        except OSError: pass


# ---------------------------------------------------------------- 봇
def _seats(v): return [s for s in (v or {}).get("seats", []) if s]


class Bot:
    """REST 로 행동하고 STOMP 로 공개·개인 뷰를 받는다(holdem.md: 행동=REST, STOMP=수신 전용).
    join-queue 는 연결 직후 구독해 두고 POST 한다. 개인 큐는 공개 뷰에 내가 앉아 있을 때만 구독한다."""

    def __init__(self, user):
        self.user = user; self.view = None; self.results = []; self.private = None; self.events = []; self.tid = None
        self.token, self.cookie = rest_login(user)
        pl = self.token.split(".")[1]; self.uid = int(json.loads(base64.urlsafe_b64decode(pl + "=" * (-len(pl) % 4)))["sub"])
        self._priv = False
        self.ws = _WS(self._on)
        self.ws.send(f"CONNECT\naccept-version:1.2\nhost:{urlparse(WEB).hostname}\nheart-beat:0,0\nAuthorization:Bearer {self.token}\n\n\0")
        self.ws.send("SUBSCRIBE\nid:jq\ndestination:/user/queue/holdem/join-queue\n\n\0")

    def _on(self, m):
        if not m.startswith("MESSAGE"): return
        h, _, b = m.partition("\n\n")
        try: d = json.loads(b.rstrip("\0"))
        except ValueError: return
        if "/user/queue/tables/" in h: self.private = d
        elif "/topic/tables/" in h:
            if d.get("type") == "TABLE_CLOSED": self.view = None; return
            if "seq" in d and d.get("seq", 0) >= (self.view or {}).get("seq", -1):  # seq 가 줄어든 메시지는 버린다
                self.view = d; self._sync_private()
                if d.get("result") and (not self.results or self.results[-1] != d["result"]): self.results.append(d["result"])
        else: self.events.append(d)

    def _sync_private(self):
        me = self.my_seat()
        if me and not self._priv:
            self._priv = True; self.ws.send(f"SUBSCRIBE\nid:pv{self.tid}\ndestination:/user/queue/tables/{self.tid}\n\n\0")
        elif not me and self._priv:
            self._priv = False; self.ws.send(f"UNSUBSCRIBE\nid:pv{self.tid}\n\n\0"); self.private = None

    def watch(self, tid):
        """공개 토픽 구독(관전). 이미 구독 중이면 무시"""
        if self.tid != tid:
            self.tid = tid; self.view = None
            self.ws.send(f"SUBSCRIBE\nid:pb{tid}\ndestination:/topic/tables/{tid}\n\n\0")

    def stop(self):
        self.ws.close(); rest_logout(self.token, self.cookie)

    # --- 뷰 ---
    def seat_of(self, uid): return next((s for s in _seats(self.view) if int(s["userId"]) == uid), None)
    def my_seat(self): return self.seat_of(self.uid)
    def hero_uid(self, bots):
        """뷰에서 봇이 아닌 첫 착석자의 userId — 브라우저 사용자(REST 로그인 없이 알아낸다)"""
        ids = {b.uid for b in bots}
        return next((int(s["userId"]) for s in _seats(self.view) if int(s["userId"]) not in ids), None)
    def wait_for(self, pred, timeout=30, what="뷰 조건"):
        """pred(public_view) 가 참 값을 돌려줄 때까지"""
        return wait_for(lambda: self.view and pred(self.view), timeout, what=what)

    # --- 행동 ---
    def _buy_in(self, path, want):
        """원하는 바이인(없으면 하한)을 서버 범위로 맞춘다. 나간 지 30분 안이면 나간 금액만큼 하한이 올라간다(obligation)"""
        r = call(path, self.token)[1]; return min(max(want or r["minBuyIn"], r["minBuyIn"]), r["maxBuyIn"])
    def create_table(self, name, buy_in=None):
        """만든 사람이 서버에서 바로 착석한다. 201 뒤 공개 토픽 구독"""
        bi = self._buy_in("/api/holdem/buy-in", buy_in)
        s, d = call("/api/holdem/tables", self.token, {"name": name, "buyIn": bi})
        if s not in (200, 201): raise RuntimeError(f"방 생성 {s} {d}")
        self.watch(d["tableId"]); self.wait_for(lambda v: self.my_seat(), 15, "방장 착석"); return d["tableId"]
    def sit(self, tid, buy_in=None, wait=True):
        """바이인(기본 하한)으로 참가. 핸드 중이면 대기열이라 다음 판에 앉는다"""
        self.watch(tid)
        bi = self._buy_in(f"/api/holdem/tables/{tid}/buy-in", buy_in)
        s, d = call(f"/api/holdem/tables/{tid}/seats", self.token, {"buyIn": bi, "postBlindImmediately": False})
        if s >= 300: raise RuntimeError(f"{self.user} 착석 {s} {d}")
        if wait: self.wait_for(lambda v: self.my_seat(), 60, f"{self.user} 착석")
    def stand(self): return call("/api/holdem/seat", self.token, method="DELETE")[0]  # 핸드 중 202(예약)
    def reserve_leave(self, after="SPECTATE"): return call(f"/api/holdem/seat?after={after}", self.token, method="DELETE")[0]
    def cancel_reservation(self): return call("/api/holdem/seat/leave-reservation", self.token, method="DELETE")[0]
    def act(self, action, amount=None):
        b = {"action": action}
        if amount: b["raiseToAmount"] = amount
        return call(f"/api/holdem/tables/{self.tid}/hands/actions", self.token, b)[0]
    def to_act(self):
        v = self.view or {}
        return bool(v.get("handInProgress") and v.get("toActSeatNo") is not None and self.my_seat()
                    and int(self.my_seat()["seatNo"]) == int(v["toActSeatNo"]))


def policy_check_call(bot, v):  # 기본: 체크, 안 되면 콜, 그것도 안 되면 폴드
    for a in ("CHECK", "CALL", "FOLD"):
        if bot.act(a) < 300: return
def policy_fold(bot, v): bot.act("FOLD")
def raise_to(n):  # 첫 행동에 n 으로 레이즈, 안 되면 기본 정책
    return lambda bot, v: bot.act("RAISE_TO", n) < 300 or policy_check_call(bot, v)


class Autoplay:
    """백그라운드 스레드: 자기 차례인 봇(skip 제외)이 policy(bot, view) 로 행동. 브라우저 사용자는 Viewer.pump() 가 맡는다
    (playwright 동기 API 는 다른 스레드에서 못 쓴다)"""
    def __init__(self, bots, policy=policy_check_call, skip=()):
        self.bots, self.policy, self.skip, self.on = bots, policy, set(skip), True
        self.acted = set(); threading.Thread(target=self._run, daemon=True).start()
    def stop(self): self.on = False
    def _run(self):
        while self.on:
            try:
                v = next((b.view for b in self.bots if b.view), None)
                if v and v.get("handInProgress") and v.get("toActSeatNo") is not None:
                    n = int(v["toActSeatNo"]); s = next((x for x in _seats(v) if int(x["seatNo"]) == n), None)
                    bot = next((b for b in self.bots if s and b.uid == int(s["userId"])), None)
                    if bot and bot.user not in self.skip and (n, v["seq"]) not in self.acted:
                        self.acted.add((n, v["seq"])); self.policy(bot, v)
            except Exception as e: print("autoplay", e)
            time.sleep(0.25)


def wait_next_hand(bot, timeout=60):
    """지금 핸드가 끝나고 다음 핸드가 시작(handInProgress 가 false -> true)될 때까지. 뷰에 핸드 번호가 없다"""
    if (bot.view or {}).get("handInProgress"): bot.wait_for(lambda v: not v.get("handInProgress"), timeout, "핸드 종료")
    bot.wait_for(lambda v: v.get("handInProgress"), timeout, "다음 핸드 시작")


def wait_result(bot, since=0, timeout=60):
    """bot.results[since] 가 생길 때까지 기다려 돌려준다. result = {payouts[{seatNo,userId,amount}], shownHands[{seatNo,holeCards,category}]}.
    다음 판이 빨리 시작해 뷰의 result 가 사라져도 bot.results 에 남는다 — 쓰기 전에 since=len(bot.results) 를 잡아 둔다"""
    return wait_for(lambda: len(bot.results) > since and bot.results[since], timeout, what="핸드 결과")


def unseat_all(users=USERS, timeout=90):
    """모든 qa 계정을 미착석으로 만든다(대기열 취소 + 폴드/일어서기 반복). REST 로그인하므로 브라우저를 닫은 뒤에 부른다."""
    toks = {u: rest_login(u) for u in users}
    try:
        def left(u):
            s, d = call("/api/holdem/me/seat", toks[u][0])
            if s == 200 and d: return d["tableId"]  # 204 = 미착석
        t0 = time.time()
        while time.time() - t0 < timeout:
            pend = {u: left(u) for u in users}; pend = {u: t for u, t in pend.items() if t}
            if not pend: return
            for u, tid in pend.items():
                tok = toks[u][0]
                call(f"/api/holdem/tables/{tid}/seats/request", tok, method="DELETE")
                call(f"/api/holdem/tables/{tid}/hands/actions", tok, {"action": "FOLD"})
                call("/api/holdem/seat", tok, method="DELETE")
            time.sleep(1.5)
        raise RuntimeError(f"{timeout}s 안에 못 비움: {pend}")
    finally:
        for t, c in toks.values(): rest_logout(t, c)


_adm = {}


def list_tables():
    """방 목록(UI 와 같은 순서). 착석 중인 계정이 핸드 중에 부르면 서버가 409 HAND_IN_PROGRESS 를 줘서 qaadmin 토큰으로 읽는다"""
    if "t" not in _adm: _adm["t"] = rest_login(ADMIN)[0]
    s, d = call("/api/holdem/tables", _adm["t"]); return d["content"] if s == 200 else []

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
        if "t" not in _adm: _adm["t"] = rest_login(ADMIN)[0]
        s, d = call(f"/api/admin/qa/holdem/tables/{tid}/next-deck", _adm["t"], body)
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


# ---------------------------------------------------------------- 브라우저
SIZES = {"d": (1280, 720, 1), "p": (390, 844, 2)}  # 데스크톱 / 폰(DPR2)
# 좌표 표(화면 크기별). 레이아웃이 바뀌면 스크린샷에서 다시 잰다. 모두 CSS px
POS = {
    "d": dict(login_user=(640, 275), login_pw=(640, 334), lobby_enter=(640, 308), room_row0=(640, 154), room_pitch=74,
              entry_spectate=(542, 476), entry_join=(737, 476), back=(72, 40),
              fold=(424, 623), call=(640, 623), raise_=(856, 623), half=(356, 567), pot=(426, 567), allin=(492, 567),
              after_spectate=(498, 684), cancel_reserve=(589, 684), after_leave=(659, 684)),
    "p": dict(login_user=(195, 370), login_pw=(195, 417), lobby_enter=(195, 246), room_row0=(195, 123), room_pitch=59,
              entry_spectate=(102, 808), entry_join=(286, 808), back=(103, 32),
              fold=(70, 766), call=(195, 766), raise_=(318, 766), half=(42, 722), pot=(97, 722), allin=(150, 722),
              after_spectate=(82, 815), cancel_reserve=(200, 815), after_leave=(210, 815)),
}


class Viewer:
    """헤드리스 Chromium 한 사용자. 사용자마다 별도 launch(쿠키 분리). with sync_playwright() as p: Viewer(p, 'qauser1', 'd')"""
    def __init__(self, p, user, size="d", name=None):
        w, h, dpr = SIZES[size]; self.user, self.size, self.pos = user, size, POS[size]; self.name = name or f"{user}_{size}"
        self.browser = p.chromium.launch(args=ARGS)
        self.page = self.browser.new_page(viewport={"width": w, "height": h}, device_scale_factor=dpr)
        self.errors = []  # 콘솔 error/warning + pageerror. 첫 로드의 401(refresh 쿠키 없음) 1건은 정상
        self.page.on("console", lambda m: self.errors.append((m.type, m.text[:200])) if m.type in ("error", "warning") else None)
        self.page.on("pageerror", lambda e: self.errors.append(("pageerror", str(e)[:200])))
        os.makedirs(OUT, exist_ok=True)

    def click(self, key, wait=500):
        x, y = self.pos[key] if isinstance(key, str) else key
        self.page.mouse.click(x, y); self.page.wait_for_timeout(wait)
    def type_at(self, key, text): self.click(key, 100); self.page.keyboard.type(text, delay=20)
    def stable(self, timeout=15):
        """연속 스크린샷이 같아질 때까지(애니메이션·로딩 대기)"""
        prev, t = None, time.time()
        while time.time() - t < timeout:
            hh = hashlib.md5(self.page.screenshot()).hexdigest()
            if hh == prev: return
            prev = hh; self.page.wait_for_timeout(300)

    def login(self):
        self.page.goto(WEB); self.page.wait_for_timeout(3000); self.stable()  # wasm 로딩
        self.type_at("login_user", self.user); self.type_at("login_pw", PW); self.page.keyboard.press("Enter")
        self.page.wait_for_timeout(1500); self.stable()
    def to_room_list(self): self.click("lobby_enter", 2000); self.stable()
    def open_room(self, index=0):
        """방 목록 index 번째(REST 목록 순서와 같다) 카드 → 입장 패널. 화면 밖으로 밀린 행은 못 누른다(방 6개 이하로)"""
        x, y = self.pos["room_row0"]; self.click((x, y + self.pos["room_pitch"] * index), 1500)
    def spectate(self): self.click("entry_spectate", 2500); self.stable()
    def join(self): self.click("entry_join", 3500); self.stable()  # 바이인 기본값으로 참가(두 번째 팝업 없음)
    def act_call(self): self.click("call", 100)  # 체크/콜 버튼(같은 자리)
    def attach(self, bot, bots):
        """pump()/wait_for()/frames() 가 쓸 공개 뷰 출처(bot)와 봇 목록. 봇이 아닌 착석자 = 이 브라우저 사용자"""
        self._bot, self._bots, self._pumped = bot, bots, set()
    def pump(self):
        """브라우저 사용자(봇이 아닌 착석자)의 차례면 체크/콜 클릭. 메인 스레드에서만(playwright 제약)"""
        v = self._bot.view or {}
        if not (v.get("handInProgress") and v.get("toActSeatNo") is not None): return
        s = next((x for x in _seats(v) if int(x["seatNo"]) == int(v["toActSeatNo"])), None)
        if s and int(s["userId"]) not in {b.uid for b in self._bots} and (s["seatNo"], v["seq"]) not in self._pumped:
            self._pumped.add((s["seatNo"], v["seq"])); self.act_call()
    def wait_next_hand(self, timeout=60):
        """qa.wait_next_hand 와 같지만 기다리는 동안 사용자 차례를 pump() 한다(안 그러면 턴 타임아웃으로 사용자가 퇴장한다)"""
        if (self._bot.view or {}).get("handInProgress"): self.wait_for(lambda v: not v.get("handInProgress"), timeout, "핸드 종료")
        self.wait_for(lambda v: v.get("handInProgress"), timeout, "다음 핸드 시작")
    def wait_for(self, pred, timeout=60, what="뷰 조건"):
        """pred(공개 뷰) 가 참일 때까지 기다리며 pump() 로 사용자 차례를 처리"""
        def f():
            self.pump(); self.page.wait_for_timeout(100); return self._bot.view and pred(self._bot.view)
        return wait_for(f, timeout, 0, what)
    def act_fold(self): self.click("fold", 100)
    def back_to_list(self): self.click("back", 2000)

    def screenshot(self, name, settle=True):
        """settle=False 는 즉시 한 장(결과 화면처럼 금방 지나가는 상태용 — 다음 판이 1초 뒤 시작한다)"""
        path = f"{OUT}/{name}.png"
        if settle: self.stable()
        self.page.screenshot(path=path); return path
    def frames(self, name, seconds, fps=8):
        """seconds 동안 jpg 프레임 + t.json([[번호, 경과초]]) 저장(실제 타임스탬프). 프레임 수는 캡처 속도(보통 6~10fps)에 좌우된다.
        attach() 했으면 매 프레임 pump() 하고, 뷰에 result 가 처음 보인 프레임을 {name}_result.png 로 따로 남긴다(결과 상태는 금방 지나간다)"""
        d = f"{OUT}/frames/{name}"; os.makedirs(d, exist_ok=True); t0 = time.time(); out = []; got = False
        while time.time() - t0 < seconds:
            t = time.time(); bot = getattr(self, "_bot", None)
            if bot: self.pump()
            self.page.screenshot(path=f"{d}/{len(out):03d}.jpg", type="jpeg", quality=60)
            if bot and not got and (bot.view or {}).get("result"):
                got = True; self.page.screenshot(path=f"{OUT}/{name}_result.png")
            out.append((len(out), round(t - t0, 2))); time.sleep(max(0, 1 / fps - (time.time() - t)))
        json.dump(out, open(f"{d}/t.json", "w")); return out
    def capture_ws_frames(self):
        """CDP 로 이 페이지의 WebSocket 프레임(송수신)을 시각 포함해 모은다. 돌려준 리스트에 {t, dir, data} 가 쌓인다(앞 300자)"""
        ev = []; c = self.page.context.new_cdp_session(self.page); c.send("Network.enable")
        for name, d in (("webSocketFrameSent", "SENT"), ("webSocketFrameReceived", "RECV")):
            c.on(f"Network.{name}", lambda e, d=d: ev.append(dict(t=time.time(), dir=d, data=e["response"]["payloadData"][:300])))
        c.on("Network.webSocketCreated", lambda e: ev.append(dict(t=time.time(), dir="OPEN", data=e["url"])))
        c.on("Network.webSocketClosed", lambda e: ev.append(dict(t=time.time(), dir="CLOSE", data="")))
        return ev
    def close(self): self.browser.close()


def sheet(p, name, start=0, end=None, step=1, cols=4, width=480):
    """frames(name) 로 저장한 프레임을 시각 라벨 붙은 격자 한 장({OUT}/{name}_sheet.png)으로 합친다(PIL 없이 playwright 렌더)"""
    d = f"{OUT}/frames/{name}"; t = dict(json.load(open(f"{d}/t.json")))
    idx = [i for i in range(start, end if end is not None else len(t), step) if i in t]
    cells = "".join('<div style="position:relative"><img style="width:%dpx;display:block" src="data:image/jpeg;base64,%s">'
                    '<b style="position:absolute;left:4px;top:2px;color:#ff0;font:12px monospace">#%d %.2fs</b></div>'
                    % (width, base64.b64encode(open(f"{d}/{i:03d}.jpg", "rb").read()).decode(), i, t[i]) for i in idx)
    b = p.chromium.launch(); pg = b.new_page(viewport={"width": width * cols, "height": 400})
    pg.set_content(f'<body style="margin:0;display:grid;grid-template-columns:repeat({cols},{width}px);gap:2px;background:#000">{cells}</body>')
    pg.screenshot(path=f"{OUT}/{name}_sheet.png", full_page=True); b.close(); return f"{OUT}/{name}_sheet.png"


def side_by_side(browser, paths, out):
    """PNG 여러 장을 가로로 붙인다(PIL 없이 playwright 로 렌더)"""
    imgs = "".join('<img style="height:400px" src="data:image/png;base64,%s">' % base64.b64encode(open(p, "rb").read()).decode() for p in paths)
    pg = browser.new_page(viewport={"width": 1600, "height": 400}); pg.set_content('<body style="margin:0;display:flex">' + imgs + "</body>")
    pg.screenshot(path=out, full_page=True); pg.close()
