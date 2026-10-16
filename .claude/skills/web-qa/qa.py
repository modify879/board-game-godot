"""Godot Web 빌드 브라우저 QA 헬퍼(playwright + 표준 라이브러리). 사용 예는 example_two_players.py"""
import base64, hashlib, json, time, urllib.error, urllib.request

WEB = "http://localhost:8000"
API = "http://localhost:8080"
PW = "qapass1234"
ARGS = ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",  # WebGL2
        "--disable-renderer-backgrounding", "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows"]

# 1280x800 기준. 레이아웃이 바뀌면 스크린샷에서 다시 잰다
XY = {
    "login_user": (640, 350), "login_pw": (640, 395),
    "lobby_holdem": (640, 434),
    "sit": (37, 767),                                # 테이블 하단 앉기/일어서기 쪽
    "sit_ok_a": (612, 495), "sit_ok_b": (612, 477),  # 앉기 팝업 확인: y 가 둘 사이에서 움직여 둘 다 클릭
    "stand": (55, 767),                              # 일어서기 (핸드 중이면 나가기 예약)
    "reserve": (77, 767),                            # 예약/취소 토글
    "show_hand_gone": (124, 767),                    # 좌석이 없어진 뒤 패 보여주기
    "fold": (37, 715),
    "room_name": (500, 85), "room_create": (1222, 85),
    "room_list_btn": (1224, 33), "room_first_join": (1242, 160),
    "back_to_list": (60, 33), "history": (1131, 33),
}


async def launch(p):
    return await p.chromium.launch(args=ARGS)


async def new_page(browser):
    return await browser.new_page(viewport={"width": 1280, "height": 800})


async def stable(page, path=None, timeout=15):
    """연속 스크린샷이 같아질 때까지 기다린다. path 가 있으면 마지막 장을 저장"""
    prev, t = None, time.time()
    while time.time() - t < timeout:
        h = hashlib.md5(await page.screenshot()).hexdigest()
        if h == prev:
            break
        prev = h
        await page.wait_for_timeout(300)
    if path:
        await page.screenshot(path=path)


async def click(page, x, y, path=None):
    await page.mouse.click(x, y)
    await page.wait_for_timeout(200)
    await stable(page, path)


async def login(page, user, pw=PW):
    await page.goto(WEB)
    await page.wait_for_timeout(3000)  # wasm 로딩
    await stable(page)
    await page.mouse.click(*XY["login_user"]); await page.keyboard.type(user, delay=20)
    await page.mouse.click(*XY["login_pw"]); await page.keyboard.type(pw, delay=20)
    await page.keyboard.press("Enter")
    await page.wait_for_timeout(1500)
    await stable(page)


async def side_by_side(browser, paths, out):
    """PNG 여러 장을 가로로 붙인다. PIL 대신 playwright 로 HTML 을 렌더해 캡처"""
    imgs = "".join('<img style="width:640px;height:400px" src="data:image/png;base64,%s">'
                   % base64.b64encode(open(p, "rb").read()).decode() for p in paths)
    pg = await browser.new_page(viewport={"width": 640 * len(paths), "height": 400})
    await pg.set_content('<body style="margin:0;display:flex">' + imgs + "</body>")
    await pg.screenshot(path=out)
    await pg.close()


def _req(path, token=None, body=None, cookie=None, method=None):
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    if cookie: h["Cookie"] = cookie
    r = urllib.request.Request(API + path, data=None if body is None else json.dumps(body).encode(),
                               headers=h, method=method)
    try:
        return urllib.request.urlopen(r)
    except urllib.error.HTTPError as e:
        return e


def rest_login(user, pw=PW):
    """(accessToken, refresh 쿠키). 같은 계정의 브라우저 세션을 쫓아내므로 브라우저를 닫은 뒤에 쓴다"""
    r = _req("/api/auth/login", body={"username": user, "password": pw})
    ck = (r.headers.get("Set-Cookie") or "").split(";")[0]
    if r.status != 200: raise SystemExit(f"로그인 실패 {user}: HTTP {r.status}. check_accounts() 로 계정을 확인한다")
    return json.load(r)["accessToken"], ck


def rest_get(token, path):
    r = _req(path, token)
    return r.status if r.status >= 400 else json.load(r)  # 오류면 상태코드


def rest_logout(token, cookie=""):
    _req("/api/auth/logout", token, {}, cookie)


def check_accounts(users=("qauser1", "qauser2", "qaadmin")):
    """테스트 계정이 없거나 비밀번호가 다르면 즉시 종료. 성공한 계정은 바로 로그아웃"""
    bad = []
    for u in users:
        r = _req("/api/auth/login", body={"username": u, "password": PW})
        if r.status != 200:
            bad.append(u)
        else:
            rest_logout(json.load(r)["accessToken"], (r.headers.get("Set-Cookie") or "").split(";")[0])
    if bad:
        raise SystemExit(f"테스트 계정 로그인 실패: {', '.join(bad)} - 계정이 없거나 비밀번호가 다르다. "
                         "SKILL.md 의 '테스트 계정 재생성' 참고")
