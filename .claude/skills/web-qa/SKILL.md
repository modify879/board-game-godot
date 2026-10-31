---
name: web-qa
description: Godot Web 빌드 화면을 실제 브라우저(헤드리스 Chromium, 사용자 Chrome 은 건드리지 않음)로 확인하거나, QA 서버에 봇 여러 명을 붙여 라이브 시나리오(홀덤 착석·쇼다운·나가기 예약 등)를 테스트할 때 쓴다.
---

# Web QA

**테스트는 `run_all.sh` 로 돌린다(헤드리스 전부 + 바뀌었으면 Web 빌드 + 시나리오 → 표와 소요 시간, 약 3~4분). 한 게임만: `run_all.sh --game holdem`, 일부만: `--only 4,5`(번호는 시나리오가 늘면 밀린다 — run 표에서 확인). 시나리오는 데스크톱 → 폰 순으로 두 번 도는데 폰은 화면 배치 시나리오만 돌고 `fn.sizes = ("d",)` 인 것은 SKIP 이다. 한 크기만: `--desktop` 또는 `--phone`.
새 시나리오는 해당 게임의 `games/<game>.py` 에 함수로 더한다(공용 로그인·로비는 `suite.py`). 스크린샷은 디자인을 볼 때만(`--shots`). 새 하네스를 처음부터 만들지 않는다.**

구성: `qa.py` = 게임 무관(REST·STOMP·Viewer 브리지·Ctx). `games/holdem.py` = 홀덤 봇·덱 고정·화면 흐름 보조·시나리오. `suite.py` = 러너(시나리오 발견, 표·JSON `$QA_OUT/suite.json`, 시나리오별 제한시간·콘솔 오류 수집).

## 게임 추가 시

- `games/<game>.py` 를 만들고 `SCENARIOS = [(이름, fn(c)), ...]`(fn.limit = 제한초, 선택 `fn.sizes = ("d",)` = 그 크기에서만 실행·나머지는 SKIP, 선택 `cleanup()`)를 노출한다. 봇·REST 보조도 거기에 둔다
- 그 게임 씬에 `qa_state()` 를 둔다(브리지 `extra`). 헤드리스 테스트는 `games/<game>/test_*.gd|tscn` 에 두면 run_all.sh 가 자동으로 집는다
- 서버 쪽 QA 보조(덱 고정 같은)는 게임별로 서버에 있다. 계정 상태 초기화는 `POST /api/admin/qa/reset {"usernames":[...]}`(qaadmin, QA 전용, 204 — 재착석 의무·대기 중 입출금 요청을 지우고 지갑을 10,000,000 으로. 앉아 있는 계정이 있으면 409 ALREADY_SEATED). 홀덤 `cleanup()` 이 시작·매 시나리오 뒤에 `unseat_all` 다음 모든 qa 계정에 부른다(`H.reset_accounts`)

## 환경

- 라이브 테스트는 QA 전용: 클라이언트 `http://localhost:8001`(nginx, CLAUDE.md 명령) → QA 서버 :8081. API·WS 는 같은 origin(8001)으로 간다. `qa.py` 는 :8000/:8080(사용자 환경)을 거부한다
- 두 서버(:8080 기본, :8081 qa 프로필)는 서버 세션이 서버 저장소 메인 트리에서 `./gradlew bootRun`(QA 는 `--args='--spring.profiles.active=qa'`)으로 띄운다. 이 저장소에서 띄우지 않고, 재기동이 필요하면 서버 세션에 요청한다. `GET /api/server-info` 가 `{"environment":"qa"}` 면 QA 서버다
- 서버는 DevTools 라 서버 저장소에서 빌드하면 몇 초씩 자동 재시작한다. 긴 QA(run_all.sh 등)를 돌리기 전에 서버 세션에 시작을 알려 빌드를 미루게 하고, 끝나면 끝났다고 알린다
- QA 서버: 다음 판 1초, 턴 8초, 빈 방 15초, 소켓 유예 5초(`app.auth.stomp-rotation-grace`). 계정 qauser1~9·qaadmin, 비밀번호 `qapass1234`, qauser 지갑 10,000,000
- 코드와 같은 시점의 Web 빌드가 8001 에 서빙돼야 한다(CLAUDE.md 빌드 명령, `.gz` 재압축 포함)

## 1회 설정 (sudo 불필요)

`run_all.sh` 가 `~/.cache/web-qa-venv`(playwright + chromium)를 없으면 만든다. 직접 쓰려면 `QA_PY=<python>`. 스크립트는 `python -B` 로 실행한다(`.gitignore` 가 `__pycache__` 를 막는다).

## 쓰는 법 (Python, 동기 API — 예: example_showdown_9.py)

| 하고 싶은 것 | 호출 |
|---|---|
| 봇(홀덤) | `b = H.Bot("qauser2")` → `tid = b.create_table(이름, 바이인)` / `b.sit(tid, 바이인)` / `b.stand()` / `b.act("RAISE_TO", n)`. `b.view`·`b.private`·`b.results` 는 STOMP 로 갱신, `b.wait_for(lambda v: ..., 초)` (`H` = `from games import holdem as H`) |
| 봇 자동 진행 | `H.Autoplay(bots, policy=H.policy_check_call, skip=())` (`policy_fold`, 런타임에 `ap.policy` 교체 가능) |
| 덱 고정 | `H.next_deck(tid, hole_cards={좌석:["As","Ah"]}, board=[...])`, 프리셋 `H.deck_showdown`·`deck_split`·`deck_hero_wins` |
| 브라우저 | `v = qa.Viewer(p, "qauser1", "d"\|"p")` → `v.open()` → `v.state()`·`v.press(키)`·`v.set_text`·`v.set_value`·`v.wait_state(pred, 초)`·`v.login()`·`v.open_game(번호\|제목)`. 홀덤 흐름은 `H.to_room_list(v)`·`H.open_room`·`H.join`·`H.spectate`. 콘솔 오류는 `v.errors` |
| 같은 브라우저 context 의 두 번째 탭 | `b = c.viewer(share=v)`(이름에 `_tab2`) — 쿠키·`BroadcastChannel`·locks 를 공유한다. 닫을 때 브라우저는 그대로 |
| 숨은 탭 흉내 | `v.pause()` / `v.resume()` — rAF 만 세워 메인 루프를 멈춘다(JS 이벤트·`BroadcastChannel` 은 돈다) |
| 토큰 공유 점검 | `v.refreshes`(`/api/auth/refresh` 응답 수)·`v.unauth`(401 수), 브리지 `godotQa.refresh()`(`Api._refresh()` 호출)·`state().token_tail`(access 끝 8자), 테이블 `extra.last_public_seq` |
| 정리 | 시나리오는 `c.on_cleanup(fn)` 으로 등록(러너가 브라우저를 닫은 뒤 부른다). 직접 쓸 땐 `H.unseat_all()` |

화면 크기: `d` 1280x720, `p` 390x844 DPR2. 좌표는 쓰지 않는다 — 전부 브리지 키다. 코드로 만든 이름 없는 Label 은 브리지 nodes 에 안 나온다 — 화면이 `qa_state()` 로 주는 `extra` 를 쓴다(예: 방 목록 `extra.rooms[].in_progress`·`card_key`, 테이블 `extra.seats`). 없으면 그 화면에 `qa_state()` 를 더한다.

### 홀덤 뷰 계약 (결과 판정할 때)

`pots` = 이미 거둔 칩의 팟 층이다(진행 중 스트리트 베팅·콜 못 받은 초과분은 빠진다). 마지막 스트리트 베팅은 결과 프레임에서 합쳐지고, 콜 못 받은 초과분은 그 좌석에 돌려준다 — 지급 합 == `pot`. 그래서 결과 판정은 결과 프레임(seq 가 가장 큰, `result` 가 있는 프레임)으로 하고 폴링으로 직전 뷰를 잡지 않는다(메시지가 순서가 뒤바뀌어 오니 수신 훅에서 seq 가 큰 것만). `AllInButton` 은 슬라이더만 최대로 옮기고 보내는 것은 `RaiseButton` 이다("올인 N").

### 덱 고정(QA 서버 전용)

`POST /api/admin/qa/holdem/tables/{id}/next-deck`, qaadmin 토큰(`next_deck` 이 캐시). 다음 핸드 1회에만 적용되고 예약은 핸드가 시작될 때까지 남는다 — 핸드 진행 중에 걸면 그다음 판에 적용. 카드는 `2-9TJQKA` + `shdc`, 중복 불가. 204 성공, 400 잘못된 입력. 딜 순서: 버튼 다음 참가 좌석부터, 보드는 번 없이 플랍·턴·리버. 프리셋은 쇼다운 전원 참여(봇 체크/콜)를 가정한다. 적용 여부는 `bot.results[-1]` 의 `shownHands`·`payouts` 로 확인한다.

## 함정 (겪은 것)

- **브라우저 사용자를 REST 로 로그인하지 않는다**(refresh 세션이 무효화된다). 그 사용자의 착석은 봇의 공개 뷰로 확인한다(`bot.hero_uid(bots)`). `unseat_all()` 은 REST 로그인하므로 브라우저를 닫은 뒤에
- 시나리오 단계 전에 실제로 앉았는지 확인한다(공개 뷰에 userId 가 보일 때까지 `wait_for`)
- 착석 중인 계정이 핸드 중에 `GET /api/holdem/tables` 를 부르면 409 HAND_IN_PROGRESS — 목록은 `qa.list_tables()`(qaadmin 토큰)
- 봇이 행동하지 않으면 턴 8초 타임아웃으로 자동 폴드·퇴장하고 방이 닫힌다 — 브라우저 단계 전에 `Autoplay` 를 먼저 켠다
- 바이인이 하한(4,000)이면 몇 판 뒤 파산해 자리가 빈다 — 봇은 큰 바이인으로(예: 10,000)
- playwright 동기 API 는 다른 스레드에서 못 쓴다 — 브라우저 조작은 메인 스레드, 봇은 `Autoplay` 스레드
- 결과 화면은 다음 판 시작(1초)까지만 보인다 — 한 `state()` 스냅샷에서 전부 판정한다
- 서버 타이머가 풀리기를 오래 기다리지 않는다 — 상태 때문에 막히면 바로 실패하고 보고한다
- 시나리오는 한 번에 한 개씩, 같은 qa 계정을 쓰므로 병렬로 돌리지 않는다. 재착석 의무로 시나리오 안에서 바이인 하한이 올라갈 수 있다(시작 때는 `cleanup()` 의 리셋으로 같다) — 바이인은 `EntrySpin` 의 min/기본값을 쓴다. 방 목록 로드(`BuyInInfo`)가 끝나기 전에 만들면 서버가 거부한다
- 착석 중 `GameList` 로 목록에 들어가면 곧바로 테이블로 보낸다(앱 동작) — 새로고침 뒤 재진입 확인에 쓴다
- Godot 캔버스는 DOM 이 없다 — 브리지 키로 누르고 `wait_state` 로 기다린다(sleep·스크린샷 비교 금지)
- 홀덤 행동 버튼은 고정 자리다 — `FoldButton`·`CheckActionButton`·`CallButton`·`RaiseButton`·`AllInButton`(못 쓰는 것은 숨기지 않고 disabled). 체크/콜은 `extra.available_actions` 의 `CHECK`/`CALL` 로 고른다(`H.check_or_call`). 일어서기·방 나가기·예약 취소는 `BackButton` 을 눌러 연 `LeaveMenu` 의 `MenuSpectate`·`MenuLeave`·`MenuCancelReservation`·`MenuClose` 다(`H.open_leave_menu`·`H.menu_press`). 예약되면 `BackButton` 문구가 "관전 예약됨"/"나가기 예약됨" 이다. 관전 중 `BackButton` 은 곧바로 목록. 칩 추가는 `AddChipsButton`("+ 칩"; 데스크톱은 히어로 닉네임 줄 오른쪽 끝, 폰은 히어로 캡슐 왼쪽). 판 사이에는 히어로의 스택 라벨을 눌러도 연다
- 일어난 뒤 재착석하면 재착석 의무로 바이인이 올라갈 수 있다. 핸드 중 일어서기는 즉시 퇴장이 아니라 나가기 예약이다
- 실제 GPU 없음(SwiftShader), IME 없음(한글 직접 입력 불가)
- `qa_speed`(기본 4)는 `Engine.time_scale` 이라 `create_timer`·`HTTPRequest.timeout` 도 그만큼 빨라진다 — QA 에서 HTTP 타임아웃(result=13)은 15초가 아니라 약 4초에 난다. 실측 시간이 필요하면 `--speed 1`
- 실패하면 `$QA_OUT/<번호>_fail.json`(기본 `/tmp/qa_out`)에 열린 탭마다 브리지 `state()` 와 게임 스냅샷이 남는다 — 다음 실행이 덮어쓰니 먼저 본다

## QA 브리지 (`window.godotQa`, core/qa_bridge.gd)

좌표 클릭·스크린샷 대신 이름으로 상태를 읽고 버튼을 누른다. **Web 이고 URL 에 `qa=1` 이거나 포트가 8001 일 때만** 생긴다(8000 사용자 환경엔 없다). `qa_speed=N` 쿼리(기본 4)로 Engine.time_scale 을 올린다. 카운트다운은 `Time.get_ticks_msec` 라 영향 없다. 타이머는 영향을 받는다(함정 참고).

```python
page.wait_for_function("window.godotQa")
st = page.evaluate("JSON.parse(window.godotQa.state())")   # {scene, nodes:{key:{type,visible,text,disabled,pressed,value,min,max,rect}}, extra}
page.evaluate("window.godotQa.press('FoldButton')")          # -> JSON {"ok":bool,"error":str} (문자열). 토글은 뒤집고, 숨김·disabled·없음은 ok=false
page.evaluate("window.godotQa.set_text('UsernameEdit', 'qauser1')")   # LineEdit, text_changed 발생
page.evaluate("window.godotQa.set_value('RaiseSpin', 400)")           # Range/SpinBox
```

`state()` 최상위 `env`("qa"|"default", 앱 시작 때 `/api/server-info` 로 한 번 물음)·`env_badge_visible` — QA 환경이면 오른쪽 위에 "QA 서버" 배지(core/ui/env_badge.gd)가 떠 있다.

- 키: 고유 이름(`%`) Control 의 이름, 인스턴스된 씬 안은 `Seat3/NameLabel`(인스턴스된 씬 루트 이름이 앞에 붙는다). 이름 없는 보이는 Button 은 `<컨테이너키>/<순번>`(방 카드 `Rows/0`). 키 충돌은 `#2`
- `extra`: 씬 루트에 `qa_state()` 가 있으면 그 반환값(홀덤 테이블: table_id·my_seat_no·street·available_actions·seats·winners 등)
- 화면 전환 직후엔 state().scene 이 바뀔 때까지 기다린다

## 테스트 단계

- 1단계(매 변경): 헤드리스 자체 점검(CLAUDE.md 명령어). 배치 겹침은 `test_layout` 으로 확인하고 스크린샷으로 대신하지 않는다
- 2단계(바뀐 화면만): `run_all.sh --only N` 으로 바뀐 시나리오만, 레이아웃을 바꿨으면 폰·데스크톱 둘 다
- 3단계(출시 전): `run_all.sh` 전체
- 계정은 에이전트끼리 나눠 쓴다(같은 qa 계정으로 동시에 돌리지 않는다). 스크린샷은 `--shots` 로 찍고 디자인을 볼 때만 Read 로 본다

## 테스트 계정 재생성

QA DB 를 초기화하면 계정이 사라진다. 시드는 서버 저장소 `scripts/qa-seed.sh`(멱등, :8081 전용). 직접 만들려면: 가입 `POST /api/users` `{username, password, passwordConfirm, nickname}`(닉네임=username); 첫 관리자는 `users.role` 을 DB 에서 'ADMIN' 으로(서버 세션에 요청); 칩은 관리자 `POST /api/admin/wallets/{userId}/adjustments {amount, reason}` + `Idempotency-Key`(QA DB 안에서는 승인 없이 해도 된다). uid 는 재생성하면 바뀐다 — 하드코딩하지 말고 로그인 JWT 의 `sub` 를 읽는다(`Bot.uid`).
