# board-game-godot

`~/IdeaProjects/board-game`(Kotlin/Spring 게임 서버)의 Godot 클라이언트. 여러 게임을 한 프로젝트에 담는다.
Godot 4.7 / GDScript / 출시 대상 Web / Compatibility 렌더러. 이 문서는 어기면 실제로 깨지는 것만 담는다.

## 명령어

Godot 은 PATH 에 없다. 프로젝트 루트에서 `--path .` 로 실행한다.

```bash
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --import                            # 임포트·캐시 갱신
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --script res://core/test_core.gd    # 자체 점검 (exit 0 = 통과)
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --script res://games/holdem/test_holdem.gd   # 홀덤 자체 점검
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . res://games/holdem/test_table.tscn             # 홀덤 테이블 상태 점검(autoload 필요해 씬으로 실행)
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . res://games/holdem/test_layout.tscn            # 홀덤 테이블 배치 겹침 점검(폰·데스크톱, 2·9인)
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --quit-after 120                    # 메인 씬 로드 확인
rm -f build/web/index.{wasm,pck,js}.gz && /mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --export-release "Web" build/web/index.html && gzip -kf9 build/web/index.{wasm,pck,js}   # Web 빌드 + 미리 압축. 꼭 함께 — nginx gzip_static 은 .gz 가 있으면 그것을 보내 옛 빌드가 나간다
.claude/skills/web-qa/run_all.sh   # 전체 점검: 헤드리스 전부 + (바뀌었으면) Web 빌드 + QA 시나리오(:8001). 끝에 표와 소요 시간. QA 시나리오는 데스크톱 → 폰 순으로 돌되 폰은 화면 배치 시나리오만(`--desktop`·`--phone` 이면 그 크기만). 한 게임만: run_all.sh --game holdem / 일부만: --only 4,5(번호는 시나리오가 늘면 밀린다)
(cd deploy && SERVER_UPSTREAM=$(hostname -I | awk '{print $1}'):8080 docker compose up -d)              # http://localhost:8000 (같은 origin 프록시)
(cd deploy && WEB_PORT=8001 SERVER_UPSTREAM=$(hostname -I | awk '{print $1}'):8081 docker compose -p board-game-qa-web up -d)   # QA 전용 http://localhost:8001 → QA 서버 :8081(짧은 대기). 사용자용 :8000 과 분리
```

nginx(`deploy`) 컨테이너는 사용자가 계속 띄워 두고 쓴다. 검증이 끝나도 `docker compose down`·`docker rm`·`stop` 하지 않는다 — 내려가 있으면 위 명령으로 다시 띄운다

Godot 인자는 따로 넘긴다 — `"--script res://..."` 처럼 한 문자열로 묶이면 Godot 이 옵션을 무시하고 메인 씬을 띄워 끝나지 않는다

WSL 에서 `timeout`·`kill` 로 끊어도 Windows `Godot.exe` 는 남는다 — 끊었으면 `tasklist.exe | grep -i godot` 로 확인하고 `taskkill.exe /PID <id> /F` 로 끝낸다(run_all.sh 는 시간 초과 때 헤드리스 Godot 을 스스로 정리한다)

서버 코드는 이 저장소에서 고치지 않는다. 띄워야 하면 서버 저장소에서 `./gradlew bootRun`.

## 구조

```
res://
├── core/          autoload(Api, Stomp) + 공용 UI(ui/theme.tres). 게임 코드를 참조하지 않는다
├── auth/          로그인·회원가입
├── lobby/         로비
├── admin/         관리자 화면(입출금 승인·잔액 조정·회원 관리). 관리자에게만 로비에 보인다
└── games/<game>/  게임별 씬·스크립트·에셋. 이 폴더만 떼면 게임 하나가 빠진다
```

영역 전용 규칙은 `.claude/rules/` 에 있고 그 영역 파일을 건드릴 때만 로드된다(`core`·`holdem`). 게임을 추가하면 `.claude/rules/<game>.md`(`paths: ["games/<game>/**"]`)를 따로 만든다.

## 규칙

1. 게임 간 공유는 없다. 게임 폴더끼리 참조하지 않고, `core` 에 게임 개념(카드·칩·좌석)을 넣지 않는다.
   같은 이름의 스크립트가 두 게임에 있는 것은 중복이 아니다
2. 오류는 서버 `errorCode` 로만 판단하고, 문구는 클라이언트가 만든다(`ErrorText.of(code)`).
   서버 응답의 `title` 을 화면에 띄우지 않는다. 새 errorCode 를 다루면 `core/error_text.gd` 에 문구를 추가한다
3. 입력 규칙은 서버가 최종 판단한다. 클라이언트는 같은 규칙을 사용성용으로 미리 검사해 요청 전에 같은 errorCode 문구를 보인다 — 규칙은 core/input_rules.gd(게임 규칙은 각 게임 폴더)에 모으고 서버 파일:라인을 주석으로 단다. 서버 errorCode 처리는 그대로 두고, 서버 규칙이 바뀌면 함께 고친다. 로그인은 형식 검사하지 않는다(서버가 형식 오류도 LOGIN_FAILED 로 감춘다)
4. autoload 는 `Api`, `Stomp` 둘뿐이다. 늘리지 않는다. 화면 전환은 `get_tree().change_scene_to_file()`
5. UI 는 모두 `core/ui/theme.tres`(Pretendard) 를 거친다. Web 은 기본 폰트에 한글이 없고 시스템 폰트 대체도 안 된다
6. C# 을 쓰지 않는다(Web 내보내기 불가). 3D 는 쓰되 Forward+ 전용 기능(SDFGI·SSAO·SSR·볼류메트릭 포그)에 기대지 않는다

## git flow

`master`(배포·태그) ← `release/*` ← `develop` ← `feature/*`. `hotfix/*` 는 `master` 에서 분기해 양쪽에 병합.

- `master` 에 직접 커밋하지 않는다
- 작업 브랜치는 **항상 `feature/` 로 시작한다** — 버그 수정·리팩터링·문서도 예외 없다. 그 뒤에 영역 접두를 붙인다(`feature/auth-signup`, `feature/holdem-table`)
- 커밋은 Conventional Commits + 영역 스코프(`feat(lobby): ...`, 스코프는 `core`·`auth`·`lobby`·`admin`·게임 이름)
- `master` 는 아직 초기 커밋뿐이다 — 에이전트 worktree 격리(`isolation: worktree`)는 `master` 기준으로 만들어지므로, 그 안에서 작업하면 먼저 `develop` 에서 브랜치를 다시 따야 한다(아니면 옛 코드 위에서 작업해 병합 때 충돌한다)
