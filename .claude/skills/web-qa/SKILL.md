---
name: web-qa
description: Godot Web 빌드 화면을 실제 브라우저(헤드리스 Chromium, 사용자 Chrome 은 건드리지 않음)로 확인하거나, 개발 서버에 두 명 이상이 붙는 라이브 시나리오(홀덤 착석·나가기 예약 등)를 테스트할 때 쓴다.
---

# Web QA

헤드리스 Chromium(Playwright)으로 `http://localhost:8000` 의 Web 빌드를 조작·캡처한다. 헬퍼는 `qa.py`, 실행 예는 `example_two_players.py`.

## 테스트 단계

- 1단계(매 변경): 헤드리스 자체 점검 — `test_core`·`test_holdem`·`test_table`·`test_layout`(CLAUDE.md 명령어). 배치 겹침은 `test_layout` 으로 확인하고 스크린샷으로 대신하지 않는다
- 2단계(바뀐 화면만): 라이브는 바뀐 시나리오만, 한 크기로(레이아웃을 바꿨으면 폰·데스크톱 둘 다)
- 3단계(출시 전만): 전체 통합 시나리오
- 운영: 라이브 테스트 중 서버를 재기동하지 않는다. 같은 계정을 REST 로 따로 로그인하지 않는다(브라우저의 refresh 세션이 무효화된다 — 확인됨). 착석 여부는 봇의 공개 뷰로 확인한다. 계정은 에이전트끼리 나눠 쓴다
- 라이브 테스트는 QA 전용 환경에서 한다: 클라이언트 http://localhost:8001 (nginx, CLAUDE.md 명령) → QA 서버 :8081. 사용자는 :8000/:8080 을 직접 쓰므로 거기서 테스트하지 않는다
- QA 서버: 다음 판 1초, 턴 8초, 빈 방 15초. 별도 DB·Redis(compose 프로젝트 board-game-qa)라 :8080 과 상태를 공유하지 않는다
- QA 서버는 서버 세션이 별도 워크트리 ~/IdeaProjects/board-game-qa 에서 `SPRING_PROFILES_ACTIVE=qa ./gradlew bootRun` 으로 띄운다. 메인 서버 트리에서 bootRun 을 또 돌리지 않는다(:8080 의 build/ 를 다시 컴파일한다)
- QA 계정: qauser1~9·qaadmin, 비밀번호 qapass1234, qauser 지갑 10,000,000. 시드는 서버 저장소 scripts/qa-seed.sh(멱등, :8081 전용). QA DB 안에서는 지갑 충전을 승인 없이 해도 된다(:8080 계정은 여전히 승인 필요)

## 사전 조건

- nginx `http://localhost:8000`. 내려가 있으면 CLAUDE.md 의 `docker compose up -d` 명령으로 띄운다. **내리지 않는다**(`deploy-web-1`)
- 게임 서버 8080. `/api/holdem/buy-in` 이 401 이면 떠 있는 것. 없으면 서버 세션/사용자에게 요청(이 저장소에서 서버를 건드리지 않는다)
- 코드와 같은 시점의 Web 빌드(CLAUDE.md 빌드 명령, `.gz` 재압축 포함)

## 1회 설정 (sudo 불필요)

`<dir>` 은 세션 scratchpad. Python 3.12 는 ensurepip 이 없어 uv 로 venv 를 만든다.

```bash
uv venv <dir>/v && uv pip install -p <dir>/v/bin/python playwright
<dir>/v/bin/python -m playwright install chromium   # ~/.cache/ms-playwright 에 캐시
<dir>/v/bin/python -B .claude/skills/web-qa/example_two_players.py <출력 디렉터리>   # 동작 확인
```

시나리오 시작 때 `qa.check_accounts()` 를 먼저 부른다(계정이 없으면 바로 종료).

`-B`: `__pycache__` 가 스킬 폴더에 남지 않게 한다.

## 동작 방식

WSL 의 헤드리스 Chromium 이 localhost:8000 에 직접 붙는다. Godot 캔버스는 DOM 이 없어 1280x800 좌표 클릭 + `keyboard.type` 으로 조작하고, 대기는 sleep 대신 `stable`(연속 스크린샷이 같아질 때까지)을 쓴다.

계정마다 **별도 `chromium.launch()` 프로세스**를 쓴다(쿠키 분리라 세션 킥이 없다). "앱 종료"는 그 브라우저 `close()`. 한 컨텍스트에 두 계정을 넣지 않는다.

## 좌표

좌표는 `qa.XY`(1280x800). 레이아웃이 바뀌면 스크린샷에서 다시 잰다.

- 앉기 팝업의 확인 위치가 움직이므로 `sit_ok_a`/`sit_ok_b` 를 **둘 다** 클릭한다
- 내 차례 판별: 화면 (16,700,45x30) 영역의 밝기 범위가 40 초과면 폴드 버튼이 떠 있는 것

## 주의

- 턴 타이머 30초. 시간 초과는 자동 폴드 후 퇴장이므로 시나리오는 **스크립트 한 번에** 끝낸다(중간에 멈추고 생각하지 않는다)
- 방을 만들면 만든 사람이 자동 착석한다
- 핸드 중 일어서기 버튼은 즉시 퇴장이 아니라 나가기 예약이다(핸드 종료 후 일어남, 다시 누르면 취소)
- 일어난 뒤 재착석하면 재착석 의무로 바이인이 올라갈 수 있다
- 같은 계정으로 다른 곳에서 로그인하면 기존 브라우저 세션이 끊긴다. 브라우저를 닫은 뒤의 REST 조회는 무방하다

## 계정

qauser1·qauser2·qaadmin (재생성하면 uid 가 바뀐다). 비밀번호는 모두 `qapass1234`. qaadmin 지갑은 0 일 수 있다. 지갑 충전은 사용자 승인 없이 하지 않는다.

## 테스트 계정 재생성

서버 DB 를 초기화하면(`docker compose down -v`) 계정이 사라진다. `check_accounts` 가 실패하면 다음으로 만든다.

- 가입: `POST /api/users` `{username, password, passwordConfirm, nickname}`. qauser1·qauser2·qaadmin 모두 비밀번호 `qapass1234`, 닉네임은 username 과 같게
- 첫 관리자: 역할 API(`POST /api/admin/users/{id}/role {"role":"ADMIN"}`)도 관리자가 필요하므로 `users.role` 을 'ADMIN' 으로 DB 에서 직접 바꿔야 한다. 이 저장소는 서버 DB 를 건드리지 않으니 서버 세션/사용자에게 요청
- 칩: 관리자가 `POST /api/admin/wallets/{userId}/adjustments {amount, reason}` (`Idempotency-Key` 헤더 필수). 서버 데이터가 바뀌므로 사용자 승인 후에만
- uid 는 재생성하면 바뀐다. 하드코딩하지 말고 로그인 JWT 의 `sub` 나 API 로 읽는다

## 한계

실제 GPU 없음(SwiftShader), IME 없음(한글 직접 입력 불가), 좌표는 레이아웃 의존.

## 결과 확인

- 스크린샷은 직접 Read 로 본다(`side_by_side` 로 두 화면을 한 장에 합칠 수 있다)
- 수치는 REST(`rest_login`/`rest_get`)로 검증한다
- 끝나면 정리: 일어서기 → 로그아웃 → 브라우저 close → `rest_logout`
