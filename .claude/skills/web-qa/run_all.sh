#!/usr/bin/env bash
# 전체 점검: 헤드리스 테스트(core/test_*.gd, games/*/test_*.gd|tscn 자동 발견) + (바뀌었으면) Web 빌드 + QA 시나리오(:8001).
# 사용: run_all.sh [--game 이름] [--only N,M] [--phone]   (인자는 suite.py 로 넘긴다. --game 이면 core + 그 게임의 헤드리스만)
set -u
cd "$(dirname "$0")/../../.."          # 프로젝트 루트
GODOT=/mnt/c/Users/jsm/.godot/Godot.exe
PY=${QA_PY:-$HOME/.cache/web-qa-venv/bin/python}
T0=$SECONDS; FAILED=()
if [ ! -x "$PY" ]; then
  uv venv "$(dirname "$(dirname "$PY")")" -q && uv pip install -q -p "$PY" playwright && "$PY" -m playwright install chromium || exit 2
fi

# 헤드리스: 순차 실행, 시간 초과(124)면 한 번 더
run() {  # 이름 인자...
  local name=$1; shift; local t=$SECONDS rc
  timeout 180 "$GODOT" --headless --path . "$@" >/tmp/qa_headless.log 2>&1; rc=$?
  if [ $rc -eq 124 ]; then timeout 180 "$GODOT" --headless --path . "$@" >/tmp/qa_headless.log 2>&1; rc=$?; fi
  if [ $rc -eq 0 ]; then echo "PASS  $name ($((SECONDS - t))s)"; else echo "FAIL  $name (exit $rc)"; tail -15 /tmp/qa_headless.log; FAILED+=("$name"); fi
}
GAME=""; prev=""; for a in "$@"; do [ "$prev" = --game ] && GAME=$a; case $a in --game=*) GAME=${a#--game=};; esac; prev=$a; done
G=${GAME:-*}   # --game 이면 core 와 그 게임의 테스트만
for f in core/test_*.gd games/$G/test_*.gd; do [ -e "$f" ] && [ ! -e "${f%.gd}.tscn" ] && run "$f" --script "res://$f"; done
for f in games/$G/test_*.tscn; do [ -e "$f" ] && run "$f" "res://$f"; done

# Web 빌드: 프로젝트 파일(build/·.godot/·.claude/ 제외)이 마지막 빌드(index.pck)보다 새로울 때만
if [ ! -e build/web/index.pck ] || [ -n "$(find . \( -path ./build -o -path ./.godot -o -path ./.claude -o -path ./.git \) -prune -o -type f -newer build/web/index.pck -print -quit)" ]; then
  t=$SECONDS; echo "Web 빌드 시작"
  rm -f build/web/index.{wasm,pck,js}.gz && "$GODOT" --headless --path . --export-release "Web" build/web/index.html >/tmp/qa_build.log 2>&1 \
    && gzip -kf9 build/web/index.{wasm,pck,js} && echo "PASS  Web 빌드 ($((SECONDS - t))s)" || { echo "FAIL  Web 빌드"; tail -15 /tmp/qa_build.log; FAILED+=("Web 빌드"); }
else echo "SKIP  Web 빌드(바뀐 파일 없음)"; fi

# QA 시나리오
t=$SECONDS; "$PY" -B .claude/skills/web-qa/suite.py "$@" || FAILED+=("QA 시나리오")
echo
echo "==== 요약: 총 $((SECONDS - T0))s (시나리오 $((SECONDS - t))s) — $([ ${#FAILED[@]} -eq 0 ] && echo 전부 통과 || echo "실패: ${FAILED[*]}")"
[ ${#FAILED[@]} -eq 0 ]
