---
paths: ["games/holdem/**"]
---

# holdem

`games/holdem` 파일을 건드릴 때만 로드된다. 범용 규칙은 `CLAUDE.md` 에 있다.

- 행동(착석·베팅 등)은 REST 로 보낸다. STOMP 는 수신 전용이다 — 서버에 `@MessageMapping` 이 없다
- 개인 채널은 `/user/queue/...` 로만 구독한다. 원시 `/queue` 구독은 서버가 거부하고, ERROR 후 연결이 끊긴다(자동 재연결도 멈춘다)
- 서버 메시지의 `seq` 는 테이블 단위로 단조 증가한다. 마지막으로 반영한 값보다 작은 `seq` 는 버린다 — 순서가 뒤바뀌어 온다
- 서버 JSON 숫자는 `float` 다 — `seatNo`·`userId`·`tableId` 는 `int()` 로 바꾼 뒤 비교·키로 쓴다(core.md)
- 참가는 대기열이다 — `/user/queue/holdem/join-queue` 를 먼저 구독하고 POST 한다(`SEATED` 가 202 응답보다 먼저 올 수 있다). 대기열이 가득 차면(테이블당 50명 초과, `app.holdem.join-queue-max-length`) 409 `JOIN_QUEUE_FULL`
- 방 생성은 서버가 만든 사람을 바로 대기열에 넣는다 — `seats` 를 따로 부르지 않는다. STOMP 연결·join-queue 구독 뒤에 POST 하고, 201 전에 온 join-queue 이벤트는 모아 뒀다 tableId 를 안 뒤 처리한다
- join-queue 는 구독할 때 현재 상태(POSITION·SEATED)를 스냅샷으로 다시 보낸다 — SEATED 는 두 번 올 수 있다. DROPPED 는 다시 오지 않으므로 `me/seat` 로 보충한다(204 = 미착석). `me/seat` 는 좌석만 본다(대기 중이어도 204) — 방 생성 뒤 5초간 이벤트가 없고 앉지 않았을 때, 탭 복귀(`Stomp.resumed`) 뒤엔 교체 후 2초 안에 POSITION·SEATED 가 없을 때만 확인한다
- 공개 토픽에 `type: "TABLE_CLOSED"`(seq 없음)가 오면 목록으로 돌아간다 — 공개 뷰보다 먼저 분기한다. 테이블 화면의 요청이 `TABLE_NOT_FOUND` 를 받아도 같다
- 연결이 끊기면 대기열에서 빠진다 — 재연결 후 앉아 있지 않으면 다시 요청한다
- 개인 큐는 공개 뷰가 앉은 것으로 보일 때만 구독하고, 앉지 않은 것으로 보이면 해제한다(일어설 때 미리 끊지 않는다 — DELETE 가 실패하면 홀카드를 잃는다). 연결이 끊기면 지우고 재연결 뒤 공개 스냅샷으로 다시 구독한다. 서버는 미착석 SUBSCRIBE 를 조용히 무시하고 기억하지 않는다 — 다시 앉으면 새 SUBSCRIBE 가 필요하다
- 취소 응답이 `JOIN_REQUEST_NOT_FOUND` 면 이미 앉았거나 이미 빠진 것이다 — 착석 여부는 공개 뷰로 판단한다
- join-queue `DROPPED` 의 `INSUFFICIENT_BALANCE` 는 착석 때 지갑이 모자란 것이다 — 오류로 보인다
- 액션 문자열은 대문자 `FOLD`·`CHECK`·`CALL`·`RAISE_TO`(+`raiseToAmount`)
- 시간은 `Time.get_ticks_msec()` 로 센다(OS 시계 아님) — 받은 순간부터 `turnRemainingMs`(공개 뷰, null = 타이머 없음)·`nextHandInMs`(null = 없음). 다음 판 카운트다운은 착석할 때마다 서버가 다시 걸므로(`app.holdem.next-hand-delay`, 지금 10초) 새 뷰마다 다시 맞춘다
- 바이인은 사용자가 고른다(100 단위, 기본 20BB~100BB). 범위·지갑은 `GET /api/holdem/tables/{id}/buy-in`(방 만들기는 `GET /api/holdem/buy-in`)이 준다 — 나간 지 30분 이내면 나간 금액만큼 하한(100BB 넘으면 상한도)이 올라가고, 지갑이 하한에 못 미치면 `obligationExpiresAt` 까지 못 앉는다. 착석·방 생성 본문에 `buyIn` 이 필수이고, 재시도·재연결 재요청은 같은 값을 보낸다(`last_buy_in`). 서버 검사 순서는 단위 → 범위 → 지갑이고 `Rules.buy_in` 이 같은 순서로 미리 검사한다
- 칩 추가는 `POST /api/holdem/seat/chips {amount}`(204) — 지갑→스택 자동 합산은 없다. 핸드 사이(카운트다운 포함)에만, 스택+추가 ≤ 100BB, 서버 순서는 핸드 중 → 단위 → 범위 → 지갑. 성공하면 서버가 공개 뷰를 다시 방송하므로 스택을 로컬에서 고치지 않는다
- 패 보여 주기 `POST /api/holdem/tables/{id}/hands/show`(204, 본문 없음)는 모두 폴드해 이긴 사람만, 핸드가 끝난 뒤 다음 판 전에 한 번 가능하다(`SHOW_NOT_ALLOWED`·`HAND_IN_PROGRESS`). 내 지급액은 `payouts` 에서 userId 로 찾는다 — 좌석이 아니므로 나가기 예약으로 자리가 비어도 버튼이 남는다. 결과의 좌석이 비어 있으면 그래도 결과·패를 그린다(다른 사람이 앉아 있을 때만 막는다). `category` 는 null 일 수 있다(프리플랍 종료)
- 핸드 기록: 내 기록 `GET /api/holdem/me/hands?page=&size=`(최신순, 남의 홀카드는 `shown=true` 일 때만 아니면 null → "비공개"), 관리자 `GET /api/admin/holdem/hands?userId=&tableId=&page=&size=`(마스킹 없음, 비관리자는 `ACCESS_DENIED`). 90일 보관. 닉네임은 기록에 없어 `GET /api/users/{id}` 로 묻는다(실패하면 이름 없이 보인다). 관리자 화면 `admin_hand_history.tscn` 은 경로 문자열로만 연다. 필터는 정수가 아닐 때만 `REQUEST_INVALID`(0·음수는 서버가 받는다)
- 나가기 예약: 핸드 중 `DELETE /api/holdem/seat?after=SPECTATE|LEAVE`(생략 = SPECTATE)는 202(본문 없음, 반복하면 종류만 바뀐다)다. 핸드 중이어도 그 판 참가자가 아니면(핸드 중 앉아 대기 중) 204 로 즉시 일어서고, 핸드 밖은 `after` 를 무시하고 204 다. 로컬 상태는 고치지 않는다 — 공개 뷰 `seats[].leaveReserved` 가 UI 를 바꾼다. 취소는 `DELETE /api/holdem/seat/leave-reservation`(204, 예약이 없어도 204, 미착석 `NOT_SEATED`, 종류도 지운다). 종류는 개인 뷰 `leaveReservation`(null|"SPECTATE"|"LEAVE")이 주며 핸드 참가자에게만 온다 — 없으면 메모리 의도 `leave_room_after_stand` 를 쓴다. 일어선 뒤엔 개인 뷰가 오지 않으므로 마지막 값으로 정하고, 공개 뷰가 내가 미착석이라고 보일 때 의도가 LEAVE 면 목록으로 간다. 예약은 서버 DB 에 저장돼 앱을 닫아도 남는다
- 방 목록 `GET /api/holdem/tables` 는 내가 앉은 테이블에 끝나지 않은 핸드가 있으면 409 `HAND_IN_PROGRESS` 다(서버 HoldemTableQueryService.kt:23 — 의도된 동작). 앉아 있어도 핸드가 없거나 미착석이면 200. 그래서 착석 중에는 클라이언트가 목록으로 가지 않는다(뒤로가기 비활성, 목록 진입 시 `me/seat` 로 테이블로 보냄)
- 좌석 `lastAction`(`FOLD`·`CHECK`·`CALL`·`RAISE_TO`, null = 이번 스트리트에 행동 없음)은 다음 스트리트 보드가 깔릴 때·새 판에 전원 null 로 초기화되고 블라인드는 null 이다. 정산 뒤엔 서버가 지우므로 `handInProgress` 일 때만 배지를 보인다. 올인은 자체 값이 없다 — 기존 ALL-IN 배지(`status == "ALL_IN"`)가 보이고 행동 배지는 그 액션을 보인다(서버 567ffbe, `presentation/ws/payload/TablePublicView.kt` 의 `SeatPublicView`). 문구는 `PublicView.action_label`
- 공개 뷰를 읽기만 하는 순수 계산(좌석 찾기·결과 주인 확인·스트리트 베팅·딜 순서 등)은 `public_view.gd`(정적 함수, autoload·Node 없이 인자만)에 두고 `test_holdem.gd` 에서 헤드리스로 점검한다. `table.gd` 에는 상태와 얇은 함수만 남긴다
- 블라인드 마커(SB·BB)는 공개 뷰 `smallBlindSeatNo`·`bigBlindSeatNo`(Int?, `buttonSeatNo` 바로 뒤)가 준다 — 이번 핸드에 실제로 블라인드를 낸 좌석이다. 헤즈업이면 버튼 == SB, 데드 스몰 블라인드면 `smallBlindSeatNo` 만 null, 핸드가 없으면 둘 다 null. 정산 방송(`handInProgress=false`)은 끝난 핸드 값을 그대로 싣고 이후 null 이므로 `handInProgress` 일 때만 보인다(`PublicView.blind_seats`). `buttonSeatNo` 도 핸드 중엔 그 핸드의 실제 버튼이다(서버 da4631d). 마커 자리는 딜러와 같은 `_place_marker` 가 이미 놓인 마커를 피해 고른다
