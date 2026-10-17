---
paths: ["games/holdem/**"]
---

# holdem

`games/holdem` 파일을 건드릴 때만 로드된다. 범용 규칙은 `CLAUDE.md` 에 있다.

- 행동(착석·베팅 등)은 REST 로 보낸다. STOMP 는 수신 전용이다 — 서버에 `@MessageMapping` 이 없다
- 개인 채널은 `/user/queue/...` 로만 구독한다. 원시 `/queue` 구독은 서버가 거부하고, ERROR 후 연결이 끊긴다(자동 재연결도 멈춘다)
- 서버 메시지의 `seq` 는 테이블 단위로 단조 증가한다. 마지막으로 반영한 값보다 작은 `seq` 는 버린다 — 순서가 뒤바뀌어 온다
- 서버 JSON 숫자는 `float` 로 온다. `seatNo`·`userId`·`tableId` 를 `in`·`has()`·Dictionary 키로 쓸 때는 `int()` 로 바꾼다
- 참가는 대기열이다 — `/user/queue/holdem/join-queue` 를 먼저 구독하고 POST 한다(`SEATED` 가 202 응답보다 먼저 올 수 있다)
- 방 생성은 서버가 만든 사람을 바로 대기열에 넣는다 — `seats` 를 따로 부르지 않는다. STOMP 연결·join-queue 구독 뒤에 POST 하고, 201 전에 온 join-queue 이벤트는 모아 뒀다 tableId 를 안 뒤 처리한다
- join-queue 는 구독할 때 현재 상태(POSITION·SEATED)를 스냅샷으로 다시 보낸다 — SEATED 는 두 번 올 수 있다. DROPPED 는 다시 오지 않으므로 방 생성 뒤 5초간 이벤트가 없고 앉지 않았으면 `me/seat`(204 = 미착석)으로 확인한다
- 공개 토픽에 `type: "TABLE_CLOSED"`(seq 없음)가 오면 목록으로 돌아간다 — 공개 뷰보다 먼저 분기한다 — 테이블 화면의 요청이 `TABLE_NOT_FOUND` 를 받아도 똑같이 한다
- 연결이 끊기면 대기열에서 빠진다 — 재연결 후 앉아 있지 않으면 다시 요청한다
- 개인 큐는 공개 뷰가 앉은 것으로 보일 때만 구독하고, 앉지 않은 것으로 보이면 해제한다(일어설 때 미리 끊지 않는다 — DELETE 가 실패하면 홀카드를 잃는다). 연결이 끊기면 지우고 재연결 뒤 공개 스냅샷으로 다시 구독한다. 서버는 미착석 SUBSCRIBE 를 조용히 무시하고 기억하지 않는다 — 다시 앉으면 새 SUBSCRIBE 가 필요하다
- 취소 응답이 `JOIN_REQUEST_NOT_FOUND` 면 이미 앉았거나 이미 빠진 것이다 — 착석 여부는 공개 뷰로 판단한다
- 액션 문자열은 대문자 `FOLD`·`CHECK`·`CALL`·`RAISE_TO`(+`raiseToAmount`). 턴 남은 시간은 공개 뷰의 `turnRemainingMs`(ms) — 받은 순간부터 `Time.get_ticks_msec()` 로 센다(OS 시계 아님). null 이면 타이머 없음(숨김), 키가 없으면(옛 서버) `toActSeatNo` 가 바뀐 시점부터 30초로 어림한다.
- 다음 판 카운트다운은 `nextHandInMs`(남은 ms, null = 없음)를 받은 순간의 `Time.get_ticks_msec()` 기준으로 센다. OS 시계를 쓰지 않는다. 착석할 때마다 서버가 5초로 다시 건다 — 새 뷰마다 다시 맞춘다
- 바이인은 사용자가 고른다(100 단위, 기본 20BB~100BB = 4,000~20,000). 범위·지갑은 `GET /api/holdem/tables/{id}/buy-in`(방 만들기는 `GET /api/holdem/buy-in`)이 준다 — 나간 지 30분 이내면 나간 금액만큼 하한(100BB 넘으면 상한도)이 올라가고, 지갑이 하한에 못 미치면 `obligationExpiresAt` 까지 못 앉는다(시각을 안내). 착석·방 생성 본문에 `buyIn` 이 필수다. 재시도·재연결 재요청은 같은 `buyIn` 을 보낸다(`last_buy_in`). 서버 순서는 단위 → 범위 → 지갑이고 `Rules.buy_in` 이 같은 순서로 미리 검사한다
- 지갑→스택 자동 합산은 없다. 칩 추가는 `POST /api/holdem/seat/chips {amount}`(204) — 핸드 사이(카운트다운 포함)에만, 스택+추가 ≤ 100BB, 서버 순서는 핸드 중 → 단위 → 범위 → 지갑. 성공하면 서버가 공개 뷰를 다시 방송하므로 스택을 로컬에서 고치지 않는다
- 패 보여 주기: 모두 폴드해 이긴 사람만, 핸드가 끝난 뒤 다음 판 전에 한 번 `POST /api/holdem/tables/{id}/hands/show`(본문 없음, 204). 버튼은 결과가 있고 `shownHands` 가 비었고(폴드 종료) 내 지급액이 있고(`payouts` 에서 내 userId 로 찾는다 — 좌석이 아니므로 나가기 예약으로 자리가 비어도 버튼이 남는다) `handInProgress` 가 false 일 때만 보인다. 성공하면 공개 뷰의 `shownHands` 에 내가 들어와 조건이 꺼진다. `category` 는 null 일 수 있다(프리플랍 종료). 결과의 좌석이 지금 비어 있으면(승자가 나가기 예약으로 일어섬) 그래도 결과·패를 그린다 — 다른 사람이 앉아 있을 때만 막는다. 오류 `SHOW_NOT_ALLOWED`·`HAND_IN_PROGRESS`
- join-queue `DROPPED` 의 `INSUFFICIENT_BALANCE` 는 대기열 입장(착석) 때 지갑이 모자란 것이다 — 오류로 보인다
- 핸드 기록: 내 기록 `GET /api/holdem/me/hands?page=&size=`(최신순, 내 홀카드는 항상, 남의 것은 `shown=true` 일 때만 아니면 null → "비공개"), 관리자 `GET /api/admin/holdem/hands?userId=&tableId=&page=&size=`(마스킹 없음, 비관리자는 `ACCESS_DENIED`). 기록은 90일 보관. 닉네임은 기록에 없어 `GET /api/users/{id}` 로 묻고 화면 동안 캐시하며, 조회가 실패하면 이름 없이 보인다. 관리자 화면은 `res://games/holdem/admin_hand_history.tscn`(`hand_history.tscn` 상속, `admin=true`)이고 admin 은 경로 문자열로만 연다. 필터는 빈 칸이면 생략하고, 정수가 아닐 때만 `REQUEST_INVALID`(0·음수는 서버가 받으므로 막지 않는다)
- 나가기 예약: 핸드 중 `DELETE /api/holdem/seat?after=SPECTATE|LEAVE`(생략 = SPECTATE, 옛 서버는 쿼리를 무시) 는 202(본문 없음, 반복해도 같고 종류만 바뀐다 — 핸드 밖은 `after` 무시하고 204)다. 버튼은 "핸드 후 관전"(SPECTATE)·"핸드 후 방 나가기"(LEAVE)이고 로컬 상태는 고치지 않는다. 취소는 `DELETE /api/holdem/seat/leave-reservation`(204, 예약이 없어도 204, 미착석 `NOT_SEATED`, 종류도 지운다). 공개 뷰 `seats[].leaveReserved`(옛 서버는 키 없음 → `get("leaveReserved", false)`)가 UI 를 바꾼다 — 내 좌석이 예약이면 일어서기 대신 `CancelLeaveButton`, 좌석 패널에 "일어서기 예약"(내 것은 의도에 따라 "관전 예약"/"나가기 예약"). 종류는 개인 뷰 `leaveReservation`(null|"SPECTATE"|"LEAVE")이 주며 핸드 참가자에게만 온다 — 키가 있으면 그 값을, 없으면(옛 서버·핸드 중 앉은 사람) 메모리 의도 `leave_room_after_stand` 를 쓴다. 일어선 뒤엔 개인 뷰가 오지 않으므로 마지막 값으로 정하고, 공개 뷰가 내가 미착석이라고 보일 때 의도가 LEAVE 면 목록으로 간다. 서버는 핸드 정산·취소 때 일반 일어서기와 똑같이 실행하고 예약은 DB 에 저장돼 앱을 닫아도 남는다
