#!/usr/bin/env bash
# pyenv 가상환경(insta_vlm)을 만들고 의존성을 설치한다.
set -euo pipefail

PYVER="${PYVER:-3.12.10}"
VENV="${VENV:-insta_vlm}"

cd "$(dirname "$0")"

# pyenv 초기화
if ! command -v pyenv >/dev/null 2>&1; then
  echo "pyenv 가 설치되어 있지 않습니다." >&2
  exit 1
fi
eval "$(pyenv init -)" 2>/dev/null || true

# 설치된 버전 목록을 한 번만 캡처 (pipefail + grep -q 의 SIGPIPE 오탐 방지)
VERSIONS="$(pyenv versions --bare)"

# 베이스 파이썬 버전 확보
if ! printf '%s\n' "$VERSIONS" | grep -qx "$PYVER"; then
  echo ">> $PYVER 설치 중..."
  pyenv install "$PYVER"
fi

# 가상환경 생성(이미 있으면 재사용)
if ! printf '%s\n' "$VERSIONS" | grep -qx "${PYVER}/envs/${VENV}"; then
  echo ">> 가상환경 ${VENV} 생성 중..."
  pyenv virtualenv "$PYVER" "$VENV"
fi

# 이 디렉토리에서 자동으로 venv 활성화되도록 .python-version 고정
pyenv local "$VENV"

echo ">> 의존성 설치 중..."
pip install --upgrade pip >/dev/null
pip install -r requirements.txt

echo ""
echo "완료. 실행:"
echo "  pyenv activate ${VENV}    # (선택) 또는 .python-version 자동 적용"
echo "  python analyze.py"
