---
paths: ["core/**"]
---

# core

`core` 파일을 건드릴 때만 로드된다. 범용 규칙은 `CLAUDE.md` 에 있다.

## 코드

- `api.gd`·`stomp.gd` 는 서로를 `get_node("/root/...")` 로 부른다 — autoload 이름을 직접 쓰면 `--script` 모드에서 컴파일이 깨진다
- 파싱 로직(프레임·쿠키·페이지·JWT)은 static 순수 함수로 두고 `test_core.gd` 에 검사를 추가한다
- **STOMP 프레임 끝의 NUL 은 바이트로 붙인다**(`encode`/`decode`). 문자열 안의 `"\u0000"` 은 잘려나가 서버가 프레임 끝을 못 찾는다
- Web 에서는 `HTTPRequest.accept_gzip` 을 끈다. 브라우저가 이미 푼 본문을 Godot 이 한 번 더 풀려다 `RESULT_BODY_DECOMPRESS_FAILED` 가 난다(nginx 가 JSON 을 gzip 으로 보낸다)

## 서버 계약에서 깨지기 쉬운 것

- 에러 응답은 ProblemDetail `{title,status,instance,errorCode,traceId}`. 401 은 만료·무효 구분 없이 `AUTHENTICATION_REQUIRED`
- 페이지 응답은 Spring Data `PagedModel`(HAL 아님): `{content:[...], page:{size,number,totalPages,totalElements}}`. 목록은 `Api.page_items()` 로 꺼낸다
- refresh 토큰은 `refresh_token` httpOnly 쿠키(`Path=/api/auth`)로만 온다. Web 은 브라우저가 처리하므로 토큰을 코드·디스크에 두지 않는다.
  데스크톱(개발용)만 `Set-Cookie` 를 직접 파싱해 `user://session.cfg` 에 둔다
- refresh 는 회전식이다. 동시에 두 번 보내면 방금 받은 토큰이 무효가 된다 — `_refresh()` 의 단일 비행을 우회하지 않는다
- `/me` 가 없다. 내 userId 는 access 토큰 JWT 의 `sub`(`Api.user_id`)
- 서버에 CORS·허용 origin 설정이 없다. Web 빌드는 같은 origin 프록시(`/` = 빌드, `/api`·`/ws` → 8080)로 서빙한다
- STOMP 는 raw WebSocket `/ws`(SockJS 아님). 인증은 CONNECT 프레임의 `Authorization` 헤더 — 브라우저 WebSocket 은 HTTP 헤더를 못 붙인다
- Godot `JSON.parse_string` 은 숫자를 전부 `float` 로 만든다(서버는 정수로 보낸다). `==` 는 int 와 맞지만 `in`·`Array.has()`·Dictionary 키는 타입까지 봐서 틀린다 — 비교·키로 쓰기 전에 `int()` 로 바꾼다
- 토큰 갱신(REST refresh)에 성공하면 옛 토큰의 소켓은 30초 뒤 닫힌다 — `Stomp` 가 `/app/auth/refresh` 로 연장한다, 실패하면 새 소켓을 먼저 연결하고 옛 소켓을 닫는다(대기열 유지)
- access 토큰은 exp 5분 전에 선제 갱신한다
- `/user/queue/auth` 는 Stomp 내부 채널이다
- `/api/auth/login`·`/api/auth/refresh` 에는 `Authorization` 헤더를 싣지 않는다(`Api.sends_bearer`). permitAll 이어도 서버 필터가 Bearer 를 검증해, 만료 토큰이 실리면 refresh 가 401 로 실패하고 로그인 화면으로 튕긴다
- STOMP heart-beat 는 `0,10000`(서버→클라이언트만)이다. 클라이언트 비트는 Web 가려진 탭에서 메인 루프가 멈춰 끊기고, 그러면 서버가 연결(대기열 자리)을 버린다
- refresh 실패는 4xx 만 세션 종료다. 네트워크 오류·5xx 는 세션을 두고 5초 뒤 재시도한다
- 선제 갱신은 `accessTokenExpiresInMs` 를 `Time.get_ticks_msec()` 로 센다(`_refresh_due_ticks`). `create_timer` 는 가려진 탭에서 멈춘 만큼 늦게 울리지만, 틱 비교는 탭 복귀 첫 프레임에 바로 갱신한다
- connect 직후 `_last_state` 는 CONNECTING 으로 둔다 — 즉시 거부되면 CLOSED→CLOSED 라 재연결이 멈춘다(실측)
