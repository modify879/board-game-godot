---
paths: ["games/holdem/**"]
---

# holdem

`games/holdem` 파일을 건드릴 때만 로드된다. 범용 규칙은 `CLAUDE.md` 에 있다.

- 행동(착석·베팅 등)은 REST 로 보낸다. STOMP 는 수신 전용이다 — 서버에 `@MessageMapping` 이 없다
- 개인 채널은 `/user/queue/...` 로만 구독한다. 원시 `/queue` 구독은 서버가 거부하고, ERROR 후 연결이 끊긴다(자동 재연결도 멈춘다)
- 서버 메시지의 `seq` 는 테이블 단위로 단조 증가한다. 마지막으로 반영한 값보다 작은 `seq` 는 버린다 — 순서가 뒤바뀌어 온다
- 서버 JSON 숫자는 `float` 로 온다. `seatNo`·`userId` 를 `in`·`has()`·Dictionary 키로 쓸 때는 `int()` 로 바꾼다(`pendingSeatNos` 에서 한 번 틀렸다)
