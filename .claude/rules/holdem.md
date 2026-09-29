---
paths: ["games/holdem/**"]
---

# holdem

`games/holdem` 파일을 건드릴 때만 로드된다. 범용 규칙은 `CLAUDE.md` 에 있다.

- 행동(착석·베팅 등)은 REST 로 보낸다. STOMP 는 수신 전용이다 — 서버에 `@MessageMapping` 이 없다
- 개인 채널은 `/user/queue/...` 로만 구독한다. 원시 `/queue` 구독은 서버가 거부하고, ERROR 후 연결이 끊긴다(자동 재연결도 멈춘다)
- 서버 메시지의 `seq` 는 테이블 단위로 단조 증가한다. 마지막으로 반영한 값보다 작은 `seq` 는 버린다 — 순서가 뒤바뀌어 온다
- 서버 JSON 숫자는 `float` 로 온다. `seatNo`·`userId`·`tableId` 를 `in`·`has()`·Dictionary 키로 쓸 때는 `int()` 로 바꾼다(한 번 틀렸다)
- 참가는 대기열이다 — `/user/queue/holdem/join-queue` 를 먼저 구독하고 POST 한다(`SEATED` 가 202 응답보다 먼저 올 수 있다)
- 연결이 끊기면 대기열에서 빠진다 — 재연결 후 앉아 있지 않으면 다시 요청한다
- 취소 응답이 `JOIN_REQUEST_NOT_FOUND` 면 이미 앉았거나 이미 빠진 것이다 — 착석 여부는 공개 뷰로 판단한다
- 액션 문자열은 대문자 `FOLD`·`CHECK`·`CALL`·`RAISE_TO`(+`raiseToAmount`). 턴 마감 시각은 오지 않는다 — 카운트다운은 `toActSeatNo` 가 바뀐 시점부터 60초로 어림한다.
- 다음 판 카운트다운은 `nextHandInMs`(남은 ms, null = 없음)를 받은 순간의 `Time.get_ticks_msec()` 기준으로 센다. OS 시계를 쓰지 않는다. 착석할 때마다 서버가 5초로 다시 건다 — 새 뷰마다 다시 맞춘다
