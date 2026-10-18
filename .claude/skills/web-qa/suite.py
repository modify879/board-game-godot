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
login_lobby.limit = 45


def discover(game=None):
    """-> [(번호, 게임, 이름, fn)], [모듈]"""
    mods, rows = [], [("", "로그인 -> 로비", login_lobby)]
    for path in sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "games", "*.py"))):
        name = os.path.basename(path)[:-3]
        if name.startswith("_") or (game and name != game): continue
        m = importlib.import_module(f"games.{name}"); mods.append(m)
        rows += [(name, n, f) for n, f in m.SCENARIOS]
    if game: rows = rows[1:]
    return [(i, g, n, f) for i, (g, n, f) in enumerate(rows, 1)], mods


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
    total = round(time.time() - t_all, 1); ok = all(r["result"] == "PASS" for r in rows)
    qa.print_table(rows, "폰 390x844" if a.phone else "데스크톱 1280x720", total)
    json.dump(dict(size=size, total_seconds=total, ok=ok, scenarios=rows), open(a.json, "w"), ensure_ascii=False, indent=1)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
