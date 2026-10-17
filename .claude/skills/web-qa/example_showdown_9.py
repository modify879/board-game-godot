"""9인 쇼다운: qauser1(브라우저, 좌석 9) + 봇 8. 덱을 고정해 옆·아래 좌석이 이기는 판과 두 좌석이 비기는 판을 만들고
결과 화면·칩 푸시 프레임을 캡처한다. 사용: <venv>/bin/python -B example_showdown_9.py [출력 디렉터리] [d|p]   (QA :8001 만 쓴다)"""
import os, sys
os.environ.setdefault("QA_OUT", sys.argv[1] if len(sys.argv) > 1 else "/tmp/qa_out")
from playwright.sync_api import sync_playwright
import qa


def play_fixed(v, host, tid, deck, tag):
    """deck 이 걸린 핸드(참가자 9명 전원)를 시작시켜 리버부터 프레임을 찍고 결과를 돌려준다"""
    for _ in range(5):
        qa.next_deck(tid, **deck); v.wait_next_hand()                   # 예약 → 현재 판이 끝나고 다음 판이 시작될 때 적용
        if sum(1 for s in host.view["seats"] if s and s["status"] == "ACTIVE") == 9: break
        v.wait_for(lambda x: not x["handInProgress"], 60, "핸드 종료")     # 9명이 아니면 이 판은 흘려보내고 다시 예약
    else: raise RuntimeError("9명이 모두 참가한 핸드가 안 잡힌다: %s" % [(x["seatNo"], x["status"]) for x in host.view["seats"] if x])
    v.wait_for(lambda x: x["street"] == "RIVER", 60, "리버"); n = len(host.results)
    v.frames(f"{tag}_{v.size}", 12)                                    # 프레임(+ t.json) 과 결과가 처음 보인 {이름}_result.png
    return qa.wait_result(host, n)


def main(size):
    bots = [qa.Bot(f"qauser{i}") for i in range(2, 10)]
    host, ap = bots[0], None
    try:
        tid = host.create_table("SHOWDOWN9", 10000)
        for b in bots[1:]: b.sit(tid, 10000)                            # 좌석 1~8 (join-queue 구독은 Bot 이 한다)
        ap = qa.Autoplay(bots)                                          # 봇은 체크/콜 — 브라우저 단계 동안 턴 타임아웃이 안 나게 먼저
        with sync_playwright() as p:
            v = qa.Viewer(p, "qauser1", size); v.attach(host, bots)
            v.login(); v.to_room_list(); v.open_room([t["tableId"] for t in qa.list_tables()].index(tid)); v.join()
            v.wait_for(lambda x: host.hero_uid(bots) and sum(1 for s in x["seats"] if s) == 9, 30, "히어로 착석")  # 봇의 공개 뷰로 확인
            for tag, deck in (("side7", qa.deck_showdown(7)), ("bottom8", qa.deck_showdown(8)), ("split35", qa.deck_split([3, 5]))):
                print(tag, play_fixed(v, host, tid, deck, tag)["payouts"])  # 히어로(9) 기준 오른쪽 옆·아래 오른쪽 단독 승, 3·5 분할
            print("console", v.errors); v.close()                       # 첫 로드 401 1건은 정상(refresh 쿠키 없음)
    finally:
        if ap: ap.stop()
        for b in bots: b.stop()
        qa.unseat_all()                                                 # 브라우저를 닫은 뒤에 — REST 로그인이 세션을 쫓아낸다


if __name__ == "__main__":
    main(sys.argv[2] if len(sys.argv) > 2 else "d")
