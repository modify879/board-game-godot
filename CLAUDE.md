# board-game-godot

`~/IdeaProjects/board-game`(Kotlin/Spring 게임 서버)의 Godot 클라이언트. 여러 게임을 한 프로젝트에 담는다.
Godot 4.7 / GDScript / 출시 대상 Web / Compatibility 렌더러. 이 문서는 어기면 실제로 깨지는 것만 담는다.

## 명령어

Godot 은 PATH 에 없다. 프로젝트 루트에서 `--path .` 로 실행한다.

```bash
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --import                            # 임포트·캐시 갱신
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --script res://core/test_core.gd    # 자체 점검 (exit 0 = 통과)
/mnt/c/Users/jsm/.godot/Godot.exe --headless --path . --quit-after 120                    # 메인 씬 로드 확인
```

서버 코드는 이 저장소에서 고치지 않는다. 띄워야 하면 서버 저장소에서 `./gradlew bootRun`.

## 구조

```
res://
├── core/          autoload(Api, Stomp) + 공용 UI(ui/theme.tres). 게임 코드를 참조하지 않는다
├── auth/          로그인·회원가입
├── lobby/         로비
└── games/<game>/  게임별 씬·스크립트·에셋. 이 폴더만 떼면 게임 하나가 빠진다
```

영역 전용 규칙은 `.claude/rules/` 에 있고 그 영역 파일을 건드릴 때만 로드된다(`core`·`games`).

## 규칙

1. 게임 간 공유는 없다. 게임 폴더끼리 참조하지 않고, `core` 에 게임 개념(카드·칩·좌석)을 넣지 않는다.
   같은 이름의 스크립트가 두 게임에 있는 것은 중복이 아니다
2. 오류는 서버 `errorCode` 로만 판단하고, 문구는 클라이언트가 만든다(`ErrorText.of(code)`).
   서버 응답의 `title` 을 화면에 띄우지 않는다. 새 errorCode 를 다루면 `core/error_text.gd` 에 문구를 추가한다
3. 입력 규칙(아이디·닉네임·비밀번호 형식)은 서버에만 있다. 클라이언트에서 다시 검증하지 않는다 — 안내 문구만 둔다
4. autoload 는 `Api`, `Stomp` 둘뿐이다. 늘리지 않는다. 화면 전환은 `get_tree().change_scene_to_file()`
5. UI 는 모두 `core/ui/theme.tres`(Pretendard) 를 거친다. Web 은 기본 폰트에 한글이 없고 시스템 폰트 대체도 안 된다
6. C# 을 쓰지 않는다(Web 내보내기 불가). 3D 는 쓰되 Forward+ 전용 기능(SDFGI·SSAO·SSR·볼류메트릭 포그)에 기대지 않는다

## git flow

`master`(배포·태그) ← `release/*` ← `develop` ← `feature/*`. `hotfix/*` 는 `master` 에서 분기해 양쪽에 병합.

- `master` 에 직접 커밋하지 않는다
- 작업 브랜치는 **항상 `feature/` 로 시작한다** — 버그 수정·리팩터링·문서도 예외 없다. 그 뒤에 영역 접두를 붙인다(`feature/auth-signup`, `feature/holdem-table`)
- 커밋은 Conventional Commits + 영역 스코프(`feat(lobby): ...`, 스코프는 `core`·`auth`·`lobby`·게임 이름)
