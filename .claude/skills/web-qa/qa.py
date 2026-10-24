"""라이브 QA 하네스(게임 무관) — REST·STOMP 클라이언트 + 브리지(window.godotQa)로 모는 헤드리스 브라우저 + 시나리오 실행 컨텍스트.
게임 전용 코드(봇 행동·덱 고정·시나리오)는 games/<game>.py. 동기 API, 표준 라이브러리 + playwright 만 쓴다. 실행은 `python -B`.

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
        x = urllib.request.urlopen(r, timeout=30)
    except urllib.error.HTTPError as e:
        x = e
    except OSError as e:
        return 0, str(e)
    try: d = x.read().decode()
    except OSError as e: return 0, f"{method or 'POST' if body is not None else 'GET'} {path}: {e}"
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



class Client:
    """로그인한 계정 + STOMP 연결. 게임 봇은 이걸 상속해 on_message(헤더, JSON) 를 구현한다"""
    def __init__(self, user):
        self.user = user
        self.token, self.cookie = rest_login(user)
        pl = self.token.split(".")[1]; self.uid = int(json.loads(base64.urlsafe_b64decode(pl + "=" * (-len(pl) % 4)))["sub"])
        self.ws = _WS(self._on)
        self.ws.send(f"CONNECT\naccept-version:1.2\nhost:{urlparse(WEB).hostname}\nheart-beat:0,0\nAuthorization:Bearer {self.token}\n\n\0")
    def subscribe(self, sid, dest): self.ws.send(f"SUBSCRIBE\nid:{sid}\ndestination:{dest}\n\n\0")
    def unsubscribe(self, sid): self.ws.send(f"UNSUBSCRIBE\nid:{sid}\n\n\0")
    def _on(self, m):
        if not m.startswith("MESSAGE"): return
        h, _, b = m.partition("\n\n")
        try: d = json.loads(b.rstrip("\0"))
        except ValueError: return
        self.on_message(h, d)
    def on_message(self, h, d): pass
    def stop(self): self.ws.close(); rest_logout(self.token, self.cookie)

# ---------------------------------------------------------------- 브라우저
SIZES = {"d": (1280, 720, 1), "p": (390, 844, 2)}  # 데스크톱 / 폰(DPR2)
# 알려진 무해한 콘솔 오류: 첫 로드의 refresh 쿠키 없음 401, 서버가 의도해 내는 409(HAND_IN_PROGRESS 등) 리소스 로드 로그
BENIGN = re.compile(r"Failed to load resource: the server responded with a status of (401|409)")


class Viewer:
    """헤드리스 Chromium 한 사용자. 사용자마다 별도 launch(쿠키 분리). window.godotQa(core/qa_bridge.gd) 로 상태를 읽고 키로 누른다 —
    좌표 클릭 없음. 스크린샷은 shots=True 일 때만 찍는다(디자인 확인용).
    with sync_playwright() as p: Viewer(p, 'qauser1', 'd')"""
    def __init__(self, p, user, size="d", name=None, shots=False, speed=None, share=None):
        """share=다른 Viewer 면 그 브라우저 context 에서 페이지(탭)만 더 연다 — 쿠키·BroadcastChannel·locks 를 공유한다"""
        w, h, dpr = SIZES[size]; self.user, self.size, self.shots, self.speed = user, size, shots, speed
        self.name = name or f"{user}_{size}" + ("_tab2" if share else "")
        self.share = share
        self.browser = share.browser if share else p.chromium.launch(args=ARGS)
        self.context = share.context if share else self.browser.new_context(viewport={"width": w, "height": h}, device_scale_factor=dpr)
        self.page = self.context.new_page()
        self.refreshes = self.unauth = 0  # /api/auth/refresh 응답 수, 401 응답 수(탭 간 토큰 공유 점검)
        self.page.on("response", self._count)
        self.poll = None  # 게임 모듈이 거는 훅(state) — wait_state 가 폴링마다 부른다
        self.errors = []  # 콘솔 error/warning + pageerror (BENIGN 제외)
        self.page.on("console", lambda m: self.errors.append((m.type, m.text[:200])) if m.type in ("error", "warning") and not BENIGN.search(m.text) else None)
        self.page.on("pageerror", lambda e: self.errors.append(("pageerror", str(e)[:200])))
        os.makedirs(OUT, exist_ok=True)

    # --- 브리지 ---
    def open(self):
        """?qa=1(+qa_speed) 로 열고 브리지가 생길 때까지 기다린다"""
        self.page.goto(WEB + "/?qa=1" + (f"&qa_speed={self.speed}" if self.speed else ""))
        self.page.wait_for_function("window.godotQa", timeout=60000)
    def state(self):
        """{scene, nodes:{key:{type,visible,text,disabled,pressed,value,...}}, extra:{...}}"""
        return json.loads(self.page.evaluate("window.godotQa.state()"))
    def _call(self, js, *a): return json.loads(self.page.evaluate(js, list(a)))
    def try_press(self, key):
        """한 번 눌러 본다 -> {ok, error}"""
        return self._call("a => window.godotQa.press(a[0])", key)
    def _retry(self, js, key, val, timeout=10):
        last = {}
        def f():
            last.update(self._call(js, key, val)); return last["ok"]
        try: wait_for(f, timeout, 0.1, key)
        except TimeoutError: raise TimeoutError(f"{key} 설정 실패: {last.get('error')}")
    def set_text(self, key, text): self._retry("a => window.godotQa.set_text(a[0], a[1])", key, text)
    def set_value(self, key, v): self._retry("a => window.godotQa.set_value(a[0], a[1])", key, v)
    def wait_state(self, pred, timeout=15, what="화면 상태", pump=True):
        """pred(state) 가 참 값을 돌려줄 때까지 ~100ms 폴링(그 값을 돌려준다). 시간 초과면 TimeoutError.
        pump=True 면 폴링하면서 self.poll(state) 훅을 부른다(게임 모듈이 거는 자동 진행, 예: 히어로 차례에 체크/콜). 직접 보려면 pump=False"""
        def f():
            s = self.state()
            if pump and self.poll: self.poll(s)
            return pred(s)
        return wait_for(f, timeout, 0.1, what)
    def press(self, key, timeout=10):
        """키가 보이고 활성될 때까지 기다렸다 누른다. 안 되면 예외(마지막 오류 포함)"""
        last = {}
        def f():
            last.update(self.try_press(key)); return last["ok"]
        try: wait_for(f, timeout, 0.1, f"{key} 누르기")
        except TimeoutError: raise TimeoutError(f"{key} 를 못 누름: {last.get('error')}")
    def scene(self): return self.state()["scene"].rsplit("/", 1)[-1]
    def wait_scene(self, name, timeout=15): return self.wait_state(lambda s: s["scene"].endswith(name), timeout, f"씬 {name}")
    def extra(self): return self.state()["extra"]
    @staticmethod
    def vis(s, key): return bool(s["nodes"].get(key, {}).get("visible"))
    @staticmethod
    def text(s, key): return s["nodes"].get(key, {}).get("text", "")

    # --- 흐름 ---
    def open_game(self, game=0):
        """로비의 게임 카드를 번호(0부터) 또는 제목(부분 일치)으로 눌러 게임 첫 화면으로"""
        if isinstance(game, str):
            s = self.state(); game = next(i for i in range(20) if game in s["nodes"].get(f"GameList/{i}", {}).get("text", "") + str(s["nodes"].get(f"GameList/{i}", {}).get("text")))
        self.press(f"GameList/{game}")
    def login(self, user=None, pw=PW):
        if self.page.url in ("", "about:blank"): self.open()
        self.wait_scene("login.tscn", 30)
        self.set_text("UsernameEdit", user or self.user); self.set_text("PasswordEdit", pw); self.press("LoginButton")
        self.wait_scene("lobby.tscn", 20)
    def reload(self):
        self.page.reload(); self.page.wait_for_function("window.godotQa", timeout=60000)

    # --- 스크린샷(shots=True 일 때만. 디자인 확인용) ---
    def stable(self, timeout=15):
        """연속 스크린샷이 같아질 때까지(애니메이션·로딩 대기)"""
        prev, t = None, time.time()
        while time.time() - t < timeout:
            hh = hashlib.md5(self.page.screenshot()).hexdigest()
            if hh == prev: return
            prev = hh; self.page.wait_for_timeout(300)
    def screenshot(self, name, settle=True, force=False):
        """shots 가 꺼져 있으면(force 아님) 아무것도 안 하고 None"""
        if not (self.shots or force): return None
        path = f"{OUT}/{name}.png"
        if settle: self.stable()
        self.page.screenshot(path=path); return path
    def frames(self, name, seconds, fps=8):
        """seconds 동안 jpg 프레임 + t.json([[번호, 경과초]]) 저장. attach() 했으면 매 프레임 pump() 하고, 뷰에 result 가 처음 보인 프레임을 {name}_result.png 로 남긴다"""
        d = f"{OUT}/frames/{name}"; os.makedirs(d, exist_ok=True); t0 = time.time(); out = []; got = False
        while time.time() - t0 < seconds:
            t = time.time(); bot = getattr(self, "_bot", None)
            if self.poll: self.poll(self.state())
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
    def _count(self, r):
        if "/api/auth/refresh" in r.url: self.refreshes += 1
        if r.status == 401: self.unauth += 1
    # --- 숨은 탭 흉내: requestAnimationFrame 콜백을 큐에 쌓아 Godot 메인 루프를 세운다(JS 이벤트·BroadcastChannel·브리지 호출은 그대로 돈다) ---
    _PAUSE_JS = """(() => { if (window.__qaResume) return; const raf = window.requestAnimationFrame.bind(window); let q = [];
        window.requestAnimationFrame = cb => { if (window.__qaPause) { q.push(cb); return 0; } return raf(cb); };
        window.__qaQueued = () => q.length;
        window.__qaResume = () => { window.__qaPause = false; const x = q; q = []; x.forEach(cb => raf(cb)); }; })()"""
    def pause(self):
        """메인 루프를 세운다(큐에 콜백이 쌓일 때까지 확인)"""
        self.page.evaluate(self._PAUSE_JS); self.page.evaluate("window.__qaPause = true")
        wait_for(lambda: self.page.evaluate("window.__qaQueued()") > 0, 5, 0.1, "rAF 정지(큐 적재)")
    def resume(self): self.page.evaluate("window.__qaResume()")
    def close(self): self.page.close() if self.share else self.browser.close()


class Ctx:
    """시나리오 하나의 자원 묶음. 러너가 끝나면 cleanup() — 뷰어 닫기 -> 등록한 정리 함수(봇 정지·착석 해제 등) 순"""
    def __init__(self, p, size, shots, speed):
        self.p, self.size, self.shots, self.speed = p, size, shots, speed
        self.viewers, self.closers = [], []
    def viewer(self, user="qauser1", share=None):
        v = Viewer(self.p, user, self.size, shots=self.shots, speed=self.speed, share=share); self.viewers.append(v); v.open(); return v
    def on_cleanup(self, fn): self.closers.append(fn)
    def errors(self): return [e for v in self.viewers for e in v.errors]
    def cleanup(self):
        for v in self.viewers:
            try: v.close()
            except Exception: pass
        for fn in self.closers:  # 브라우저를 닫은 뒤에 — 게임 쪽 정리가 REST 로그인하면 세션을 쫓아낸다
            fn()


def print_table(rows, label, total):
    print(f"\n{'#':>2}  {'결과':<5}{'초':>6}  시나리오 [{label}]")
    for r in rows: print(f"{r['n']:>2}  {r['result']:<5}{r['seconds']:>6}  {r['name']}" + (f"\n        -> {r['reason']}" if r["reason"] else ""))
    skip = sum(r["result"] == "SKIP" for r in rows)
    print(f"합계 {sum(r['result'] == 'PASS' for r in rows)}/{len(rows) - skip} 통과" + (f", {skip} SKIP" if skip else "") + f", {total}s")


