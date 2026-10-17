---
name: web-qa
description: Godot Web 빌드 화면을 실제 브라우저(헤드리스 Chromium, 사용자 Chrome 은 건드리지 않음)로 확인하거나, QA 서버에 봇 여러 명을 붙여 라이브 시나리오(홀덤 착석·쇼다운·나가기 예약 등)를 테스트할 때 쓴다.
---

# Web QA

**라이브 테스트는 `qa.py` 를 쓴다. 새 하네스를 처음부터 만들지 않는다. 부족한 기능은 `qa.py` 에 더한다.**
(예전에 하네스를 매번 새로 짜서 시나리오 하나에 30~70분이 걸렸다. `qa.py` 를 import 하면 몇 분이다.)

## 환경

- 라이브 테스트는 QA 전용: 클라이언트 `http://localhost:8001`(nginx, CLAUDE.md 명령) → QA 서버 :8081. API·WS 는 같은 origin(8001)으로 간다. `qa.py` 는 :8000/:8080(사용자 환경)을 거부한다
- QA 서버는 서버 세션이 별도 워크트리 `~/IdeaProjects/board-game-qa` 에서 `./gradlew qaBootRun` 으로 띄운다(이 저장소에서 띄우지 않는다, 라이브 테스트 중 재기동하지 않는다)
- QA 서버: 다음 판 1초, 턴 8초, 빈 방 15초. 별도 DB·Redis. 계정 qauser1~9·qaadmin, 비밀번호 `qapass1234`, qauser 지갑 10,000,000
- 코드와 같은 시점의 Web 빌드가 8001 에 서빙돼야 한다(CLAUDE.md 빌드 명령, `.gz` 재압축 포함)

## 1회 설정 (sudo 불필요)

```bash
uv venv <dir>/v && uv pip install -p <dir>/v/bin/python playwright
<dir>/v/bin/python -m playwright install chromium
<dir>/v/bin/python -B .claude/skills/web-qa/example_showdown_9.py <출력 디렉터리> d   # 동작 확인(약 2분)
```

`-B`(또는 `PYTHONDONTWRITEBYTECODE=1`) 로 실행한다. 폴더의 `.gitignore` 가 `__pycache__` 를 막는다. 봇·REST·STOMP·덱 고정은 표준 라이브러리만 쓴다(playwright 는 브라우저 부분만).

## 쓰는 법 — `import qa` (동기 API, 예: example_showdown_9.py)

| 하고 싶은 것 | 호출 |
|---|---|
| 봇 | `b = qa.Bot("qauser2")` → `tid = b.create_table(이름, 바이인)` / `b.sit(tid, 바이인)` / `b.stand()` / `b.reserve_leave("SPECTATE"\|"LEAVE")` / `b.cancel_reservation()` / `b.act("RAISE_TO", n)`. `b.view`(공개)·`b.private`·`b.results` 는 STOMP 로 갱신, `b.wait_for(lambda v: ..., 초)` |
| 봇 자동 진행 | `ap = qa.Autoplay(bots, policy=qa.policy_check_call, skip=())` (`policy_fold`, `raise_to(n)` 또는 `(bot, view)` 함수). 브라우저 사용자는 `viewer.pump()`(메인 스레드) |
| 정리 | 끝에 `qa.unseat_all()` — qa 계정 전부를 미착석으로. 브라우저를 닫은 뒤에 부른다 |
| 덱 고정 | `qa.next_deck(tid, hole_cards={좌석:["As","Ah"]}, board=[...])`, 프리셋 `qa.deck_showdown(승자좌석)`·`deck_split([좌석,...])`·`deck_hero_wins(좌석)` (`**` 로 풀어 넘긴다) |
| 브라우저 | `v = qa.Viewer(p, "qauser1", "d"\|"p")` → `v.login()` `v.to_room_list()` `v.open_room(index)` `v.spectate()`/`v.join()` → `v.screenshot(이름)` `v.frames(이름, 초)` `v.capture_ws_frames()` `v.errors`(콘솔) `qa.sheet(p, 이름)`(프레임 격자) |
| 기다리기 | `qa.wait_for(pred, 초)`, `qa.wait_next_hand(bot)`, `qa.wait_result(bot, since)` |

화면 크기: `d` 1280x720, `p` 390x844 DPR2. 버튼 좌표는 `qa.POS[크기]` 한 곳에만 있다 — 레이아웃이 바뀌면 거기서 고친다.

### 덱 고정(QA 서버 전용)

`POST /api/admin/qa/holdem/tables/{id}/next-deck`, qaadmin 토큰(`next_deck` 이 캐시). 다음 핸드 1회에만 적용되고 예약은 핸드가 시작될 때까지 남는다 — 핸드 진행 중에 걸면 그다음 판에 적용. 카드는 `2-9TJQKA` + `shdc`, 중복 불가. 204 성공, 400 잘못된 입력. 딜 순서: 버튼 다음 참가 좌석부터, 보드는 번 없이 플랍·턴·리버. 프리셋은 쇼다운 전원 참여(봇 체크/콜)를 가정한다. 적용 여부는 `bot.results[-1]` 의 `shownHands`·`payouts` 로 확인한다.

## 함정 (겪은 것)

- **브라우저 사용자를 REST 로 로그인하지 않는다**(refresh 세션이 무효화된다). 그 사용자의 착석은 봇의 공개 뷰로 확인한다(`bot.hero_uid(bots)`). `unseat_all()` 은 REST 로그인하므로 브라우저를 닫은 뒤에
- 시나리오 단계 전에 실제로 앉았는지 확인한다(공개 뷰에 userId 가 보일 때까지 `wait_for`)
- 착석 중인 계정이 핸드 중에 `GET /api/holdem/tables` 를 부르면 409 HAND_IN_PROGRESS — 목록은 `qa.list_tables()`(qaadmin 토큰)
- 봇이 행동하지 않으면 턴 8초 타임아웃으로 자동 폴드·퇴장하고 방이 닫힌다 — 브라우저 단계 전에 `Autoplay` 를 먼저 켠다
- 바이인이 하한(4,000)이면 몇 판 뒤 파산해 자리가 빈다 — 봇은 큰 바이인으로(예: 10,000)
- playwright 동기 API 는 다른 스레드에서 못 쓴다 — 브라우저 조작은 메인 스레드, 봇은 `Autoplay` 스레드
- 결과 화면은 다음 판 시작(1초)까지만 보인다 — `frames()` 가 결과가 처음 보인 프레임을 `{이름}_result.png` 로 남긴다
- Godot 캔버스는 DOM 이 없어 좌표 클릭 + `keyboard.type`. 대기는 sleep 대신 `v.stable()`(연속 스크린샷이 같아질 때까지)
- 일어난 뒤 재착석하면 재착석 의무로 바이인이 올라갈 수 있다. 핸드 중 일어서기는 즉시 퇴장이 아니라 나가기 예약이다
- 실제 GPU 없음(SwiftShader), IME 없음(한글 직접 입력 불가)

## 테스트 단계

- 1단계(매 변경): 헤드리스 자체 점검 — `test_core`·`test_holdem`·`test_table`·`test_layout`(CLAUDE.md 명령어). 배치 겹침은 `test_layout` 으로 확인하고 스크린샷으로 대신하지 않는다
- 2단계(바뀐 화면만): 라이브는 바뀐 시나리오만, 한 크기로(레이아웃을 바꿨으면 폰·데스크톱 둘 다)
- 3단계(출시 전만): 전체 통합 시나리오
- 계정은 에이전트끼리 나눠 쓴다. 스크린샷은 직접 Read 로 본다

## 테스트 계정 재생성

QA DB 를 초기화하면 계정이 사라진다. 시드는 서버 저장소 `scripts/qa-seed.sh`(멱등, :8081 전용). 직접 만들려면: 가입 `POST /api/users` `{username, password, passwordConfirm, nickname}`(닉네임=username); 첫 관리자는 `users.role` 을 DB 에서 'ADMIN' 으로(서버 세션에 요청); 칩은 관리자 `POST /api/admin/wallets/{userId}/adjustments {amount, reason}` + `Idempotency-Key`(QA DB 안에서는 승인 없이 해도 된다). uid 는 재생성하면 바뀐다 — 하드코딩하지 말고 로그인 JWT 의 `sub` 를 읽는다(`Bot.uid`).
