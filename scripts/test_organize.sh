#!/bin/bash
set -euo pipefail

SCRIPT="$(dirname "$0")/organize_files.sh"
TESTDIR="${TMPDIR:-/tmp}/test_organize_$$_$(date +%s)"
mkdir -p "$TESTDIR"
PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS+1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL+1)); }

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

# 테스트용 파일 생성
touch "$TESTDIR/photo.JPG"
touch "$TESTDIR/report.pdf"
touch "$TESTDIR/Makefile"
touch "$TESTDIR/archive.tar.gz"
mkdir "$TESTDIR/subdir"
touch "$TESTDIR/subdir/ignored.txt"  # 하위 디렉토리 파일은 무시

echo "=== Dry-run 테스트 ==="
output="$("$SCRIPT" -n "$TESTDIR")"

echo "$output" | grep -qi "photo.jpg" && pass "dry-run: jpg 파일 감지" || fail "dry-run: jpg 파일 감지"
echo "$output" | grep -qi "report.pdf" && pass "dry-run: pdf 파일 감지" || fail "dry-run: pdf 파일 감지"
echo "$output" | grep -qi "Makefile" && pass "dry-run: no_ext 파일 감지" || fail "dry-run: no_ext 파일 감지"
echo "$output" | grep -q "ignored.txt" && fail "dry-run: 하위 디렉토리 파일 무시 실패" || pass "dry-run: 하위 디렉토리 파일 무시"

echo ""
echo "=== 실제 이동 테스트 ==="
"$SCRIPT" "$TESTDIR" > /dev/null

[[ ! -f "$TESTDIR/photo.JPG" ]] && pass "원본 파일 이동됨" || fail "원본 파일 이동 실패"
[[ -d "$TESTDIR/jpg" ]] && pass "jpg 디렉토리 생성" || fail "jpg 디렉토리 미생성"
[[ -d "$TESTDIR/pdf" ]] && pass "pdf 디렉토리 생성" || fail "pdf 디렉토리 미생성"
[[ -d "$TESTDIR/no_ext" ]] && pass "no_ext 디렉토리 생성" || fail "no_ext 디렉토리 미생성"
[[ -d "$TESTDIR/gz" ]] && pass "gz 디렉토리 생성" || fail "gz 디렉토리 미생성"
[[ -f "$TESTDIR/subdir/ignored.txt" ]] && pass "하위 디렉토리 파일 보존" || fail "하위 디렉토리 파일 사라짐"

# 닷파일 테스트
echo ""
echo "=== 닷파일 테스트 ==="
touch "$TESTDIR/.env"
"$SCRIPT" "$TESTDIR" > /dev/null
[[ -d "$TESTDIR/no_ext" ]] && pass ".env 파일 → no_ext 디렉토리" || fail ".env 파일 → no_ext 디렉토리"

# 충돌 테스트
echo ""
echo "=== 충돌 처리 테스트 ==="
YEAR_MONTH="$(date +%Y/%m)"
existing_dir="$TESTDIR/txt/$YEAR_MONTH"
mkdir -p "$existing_dir"
touch "$existing_dir/collision.txt"
touch "$TESTDIR/collision.txt"
"$SCRIPT" "$TESTDIR" > /dev/null
count="$(ls "$existing_dir"/collision*.txt 2>/dev/null | wc -l | tr -d ' ')"
[[ "$count" -eq 2 ]] && pass "충돌 파일 timestamp suffix 처리" || fail "충돌 파일 처리 실패 (파일 수: $count)"

echo ""
echo "=== 결과: PASS=$PASS, FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
