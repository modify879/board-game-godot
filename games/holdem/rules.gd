extends RefCounted
## 홀덤 입력 사전 검사(사용성용). 최종 판단은 서버가 한다 — 서버 규칙이 바뀌면 함께 고친다.
## 서버 경로는 서버 저장소 src/main/kotlin/com/jsm/boardgame/ 기준.

## 빅블라인드. 서버 고정값이고 착석 최소 바이인이다(지갑 잔액이 이보다 적으면 앉을 수 없다). holdem/domain/model/HoldemTable.kt:7-8,62-63, SeatRequester.kt:48-52
const BIG_BLIND := 200


## 방 이름: trim 후 코드포인트 1~30. 문제가 없으면 "", 있으면 errorCode. holdem/domain/model/HoldemTable.kt:232,240-242
static func table_name(table_name: String) -> String:
	var n := table_name.strip_edges().length()
	return "" if n >= 1 and n <= 30 else "TABLE_NAME_INVALID"
