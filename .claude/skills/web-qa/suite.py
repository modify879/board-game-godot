"""QA 시나리오 러너(게임 무관). 한 명령 -> 표(PASS/FAIL). 스크린샷·사람 판단 없음(브리지 상태와 봇 데이터를 assert).
사용: <venv>/bin/python -B suite.py [--phone] [--game holdem] [--only 1,4] [--shots] [--json 경로]   (QA :8001 만 쓴다)
시나리오: 이 파일의 공용(로그인·로비) + games/*.py 의 SCENARIOS = [(이름, fn)] (fn(c) 가 assert, fn.limit = 제한초 기본 90).
모듈에 cleanup() 이 있으면 시작 때 부르고, 시나리오 정리는 c.on_cleanup(fn) 으로 등록한다. 번호는 공용 -> games/ 알파벳 순으로 1부터."""
import argparse, glob, importlib, json, os, signal, sys, time, traceback
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright
import qa


def login_lobby(c):
    v = c.viewer(); v.wait_scene("login.tscn", 30)
    v.set_text("UsernameEdit", "qauser1"); v.set_text("PasswordEdit", "wrong-pass-1"); v.press("LoginButton")
    s = v.wait_state(lambda s: v.vis(s, "ErrorLabel") and s, 15, "로그인 오류")
    assert v.text(s, "ErrorLabel"), "잘못된 비밀번호인데 오류 문구가 비어 있다"
    v.set_text("PasswordEdit", qa.PW); v.press("LoginButton"); v.wait_scene("lobby.tscn", 20)
    s = v.wait_state(lambda s: v.text(s, "BalanceLabel").strip() and s, 15, "잔액 표시")
    assert v.text(s, "NicknameLabel").strip(), "닉네임 라벨이 비었다"
    assert any(ch.isdigit() for ch in v.text(s, "BalanceLabel")), f"잔액 문구: {v.text(s, 'BalanceLabel')!r}"
    assert v.vis(s, "GameList/0"), "게임 카드가 안 보인다"
    s = v.wait_state(lambda s: s.get("env") == "qa" and s, 5, "QA 서버 환경(server-info)")  # 요청이 비동기라 잠깐 기다린다
    assert s.get("env_badge_visible"), "QA 환경인데 QA 서버 배지가 안 보인다"
login_lobby.limit = 45


def tab_token_share(c):
    """같은 context 의 두 탭이 access 토큰을 공유한다: 새 탭은 refresh 없이 들어오고, 한 탭의 갱신이 다른 탭에 전파되고, 로그아웃도 전파된다"""
    a = c.viewer(); a.wait_scene("login.tscn", 30)
    a.set_text("UsernameEdit", "qauser1"); a.set_text("PasswordEdit", qa.PW); a.press("LoginButton"); a.wait_scene("lobby.tscn", 20)
    a.wait_state(lambda s: a.text(s, "BalanceLabel").strip() and s, 15, "A 잔액 표시")
    a.refreshes = a.unauth = 0  # 로그인 화면의 자동 로그인 시도(401)는 기준에서 뺀다
    tail = lambda v: v.state()["token_tail"]
    def wallet_roundtrip(v):  # 로비에서 REST 를 부르는 화면 전환 하나 -> 다시 로비
        v.press("WalletButton"); v.wait_scene("wallet.tscn", 15); v.page.wait_for_timeout(1500)
        v.press("BackButton"); v.wait_scene("lobby.tscn", 15)
    # 1) B 는 refresh 없이 로비, 토큰 같음
    b = c.viewer(share=a); b.wait_scene("lobby.tscn", 30)
    assert b.refreshes == 0, f"B 가 refresh 를 {b.refreshes}번 보냈다(토큰을 받아야 한다)"
    assert tail(a) and tail(a) == tail(b), f"토큰 불일치 A={tail(a)} B={tail(b)}"
    # 2) B 를 연 뒤에도 A 의 REST 가 성공
    wallet_roundtrip(a)
    assert a.unauth == 0 and b.unauth == 0, f"401 A={a.unauth} B={b.unauth}"
    # 3) A 갱신 -> refresh 1건, B 토큰이 바뀌고 B 의 REST 도 성공
    old = tail(a)
    a.page.evaluate("window.godotQa.refresh()")
    b.wait_state(lambda s: s["token_tail"] != old and s, 15, "B 토큰 갱신")
    assert tail(a) == tail(b), f"갱신 뒤 불일치 A={tail(a)} B={tail(b)}"
    assert a.refreshes + b.refreshes == 1, f"refresh 요청 A={a.refreshes} B={b.refreshes} (합 1이어야 한다)"
    wallet_roundtrip(b)
    assert a.unauth == 0 and b.unauth == 0, f"갱신 뒤 401 A={a.unauth} B={b.unauth}"
    # 4) A 로그아웃 -> B 로그인 화면
    a.press("LogoutButton"); a.wait_scene("login.tscn", 15); b.wait_scene("login.tscn", 15)
tab_token_share.limit = 90
tab_token_share.sizes = ("d",)


def tab_other_account(c):
    """세션 없는 탭은 다른 탭의 토큰을 무시하고, 다른 탭이 다른 계정으로 로그인하면 세션 있는 탭이 그 계정의 로비로 간다"""
    a = c.viewer(); a.wait_scene("login.tscn", 30); b = c.viewer(share=a); b.wait_scene("login.tscn", 30)
    b.wait_state(lambda s: b.vis(s, "UsernameEdit") and s, 15, "B 로그인 폼(자동 로그인 시도 끝)")  # 끝나기 전에 A 가 로그인하면 B 는 ask 로 A 토큰을 받는다(정상 동작)
    tail = lambda v: v.state()["token_tail"]
    a.set_text("UsernameEdit", "qauser1"); a.set_text("PasswordEdit", qa.PW); a.press("LoginButton"); a.wait_scene("lobby.tscn", 20)
    a.wait_state(lambda s: a.text(s, "NicknameLabel").startswith("QA유저1") and s, 15, "A 닉네임 QA유저1")
    b.page.wait_for_timeout(1500)  # 전파가 도착할 시간
    assert b.scene() == "login.tscn" and not tail(b), f"세션 없는 B 가 A 토큰을 받았다 scene={b.scene()} tail={tail(b)!r} B.refreshes={b.refreshes} A.refreshes={a.refreshes}"
    b.set_text("UsernameEdit", "qauser2"); b.set_text("PasswordEdit", qa.PW); b.press("LoginButton"); b.wait_scene("lobby.tscn", 20)
    a.wait_state(lambda s: a.text(s, "NicknameLabel").startswith("QA유저2") and s, 15, "A 가 QA유저2 로비로")
    assert a.scene() == "lobby.tscn" and tail(a) and tail(a) == tail(b), f"토큰 불일치 A={tail(a)} B={tail(b)}"
tab_other_account.limit = 60
tab_other_account.sizes = ("d",)


def hidden_tabs_new_tab(c):
    """A·B 둘 다 숨은 탭(루프 정지)이어도 새 탭 C 는 refresh 없이 로비로 들어온다(JS 가 ask 에 답한다)"""
    a = c.viewer(); a.wait_scene("login.tscn", 30)
    a.set_text("UsernameEdit", "qauser1"); a.set_text("PasswordEdit", qa.PW); a.press("LoginButton"); a.wait_scene("lobby.tscn", 20)
    a.wait_state(lambda s: a.text(s, "BalanceLabel").strip() and s, 15, "A 잔액 표시")
    b = c.viewer(share=a); b.wait_scene("lobby.tscn", 30)
    a.refreshes = a.unauth = b.refreshes = b.unauth = 0
    a.pause(); b.pause()
    cc = c.viewer(share=a); cc.wait_scene("lobby.tscn", 30)
    ta = a.page.evaluate("window.__auth.token")
    assert cc.refreshes == 0 and a.refreshes + b.refreshes == 0, f"refresh 요청 A={a.refreshes} B={b.refreshes} C={cc.refreshes} (0 이어야 한다)"
    assert cc.state()["token_tail"] == ta[-8:], f"토큰 불일치 C={cc.state()['token_tail']} A={ta[-8:]}"
    cc.wait_state(lambda s: cc.text(s, "BalanceLabel").strip() and s, 15, "C 잔액 표시(REST 성공)")
    assert cc.unauth == 0, f"C 401 {cc.unauth}건"
hidden_tabs_new_tab.limit = 60
hidden_tabs_new_tab.sizes = ("d",)  # 숨은 탭 시나리오는 데스크톱만(폰 크기에선 의미 없이 느리다)


COMMON = [("", "로그인 -> 로비", login_lobby), ("", "탭 간 토큰 공유", tab_token_share), ("", "다른 계정 로그인 전파", tab_other_account),
          ("", "숨은 탭 둘 + 새 탭", hidden_tabs_new_tab)]


def discover(game=None):
    """-> [(번호, 게임, 이름, fn)], [모듈]"""
    mods, rows = [], list(COMMON)
    for path in sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "games", "*.py"))):
        name = os.path.basename(path)[:-3]
        if name.startswith("_") or (game and name != game): continue
        m = importlib.import_module(f"games.{name}"); mods.append(m)
        rows += [(name, n, f) for n, f in m.SCENARIOS]
    if game: rows = rows[len(COMMON):]
    return [(i, g, n, f) for i, (g, n, f) in enumerate(rows, 1)], mods


def dump_fail(c, mods, n, why):
    """실패 진단 -> $QA_OUT/<n>_fail.json: 열린 뷰어마다 브리지 state() + 게임 모듈의 fail_snapshot(c)(있으면)"""
    d = dict(reason=why, viewers={}, game=[])
    for v in c.viewers:
        try: d["viewers"][v.name] = v.state()
        except BaseException as e: d["viewers"][v.name] = f"state 실패: {e}"
    for m in mods:
        if hasattr(m, "fail_snapshot"): d["game"] += m.fail_snapshot(c)
    json.dump(d, open(f"{qa.OUT}/{n}_fail.json", "w"), ensure_ascii=False, indent=1, default=str)


class Timebox(Exception): pass
def _alarm(*_): raise Timebox()


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--phone", action="store_true"); ap.add_argument("--only", default="")
    ap.add_argument("--game", default=""); ap.add_argument("--shots", action="store_true"); ap.add_argument("--speed", type=float, default=None)
    ap.add_argument("--json", default=f"{qa.OUT}/suite.json"); a = ap.parse_args()
    size = "p" if a.phone else "d"; only = {int(x) for x in a.only.split(",") if x}
    allsc, mods = discover(a.game or None)
    todo = [x for x in allsc if not only or x[0] in only]
    rows = []; signal.signal(signal.SIGALRM, _alarm); t_all = time.time(); os.makedirs(qa.OUT, exist_ok=True)
    for m in mods:
        if hasattr(m, "cleanup"): m.cleanup()
    with sync_playwright() as p:
        for n, game, name, f in todo:
            if size not in getattr(f, "sizes", ("d", "p")):
                rows.append(dict(n=n, game=game or "-", name=name, result="SKIP", seconds=0, reason="")); print(f"{n:>2} SKIP {name}", flush=True); continue
            c = qa.Ctx(p, size, a.shots, a.speed); t0 = time.time(); why = ""; limit = getattr(f, "limit", 90)
            try:  # 이전 시나리오가 남긴 착석이 연쇄 실패를 만들지 않게 시작도 깨끗하게(자기 제한시간이 있다)
                for m in mods:
                    if hasattr(m, "cleanup"): m.cleanup()
            except BaseException as e: print(f"시작 정리 실패: {e}", flush=True)
            signal.alarm(limit)
            try: f(c)
            except Timebox: why = f"시간 초과 {limit}s"
            except BaseException as e:
                tb = traceback.extract_tb(e.__traceback__)[-1]
                why = f"{type(e).__name__}: {e} ({tb.name}:{tb.lineno})".replace("\n", " ")[:300]
            finally:
                signal.alarm(0)
            if why and not why.startswith("정리"):
                try: dump_fail(c, mods, n, why)
                except BaseException as e: print(f"진단 저장 실패: {e}", flush=True)
            errs = c.errors()
            if not why and errs: why = f"콘솔 오류 {len(errs)}건: {errs[0]}"
            elif why and errs: why += f" | 콘솔 {errs[0]}"
            try:
                c.cleanup()
                for m in mods:  # 게임별 정리(홀덤: 모든 qa 계정 미착석) — 시나리오가 뭘 했든 다음 시나리오는 깨끗한 상태에서
                    if hasattr(m, "cleanup"): m.cleanup()
            except BaseException as e: why = why or f"정리 실패: {e}"
            rows.append(dict(n=n, game=game or "-", name=name, result="FAIL" if why else "PASS", seconds=round(time.time() - t0, 1), reason=why))
            print(f"{n:>2} {rows[-1]['result']} {rows[-1]['seconds']:>5}s {name} {why}", flush=True)
    total = round(time.time() - t_all, 1); ok = all(r["result"] != "FAIL" for r in rows)
    qa.print_table(rows, "폰 390x844" if a.phone else "데스크톱 1280x720", total)
    json.dump(dict(size=size, total_seconds=total, ok=ok, scenarios=rows), open(a.json, "w"), ensure_ascii=False, indent=1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
