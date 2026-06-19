#!/bin/bash
set -euo pipefail

# ── 사용법 ────────────────────────────────────────────────
usage() {
    echo "사용법: $0 [-n] [-r] <디렉토리>"
    echo "  -n   Dry-run (실제 이동 없이 미리보기)"
    echo "  -r   재귀 모드 (하위 디렉토리 파일도 정리)"
    exit 1
}

# ── 인자 파싱 ─────────────────────────────────────────────
DRY_RUN=false
RECURSIVE=false

while getopts ":nr" opt; do
    case $opt in
        n) DRY_RUN=true ;;
        r) RECURSIVE=true ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -ne 1 ]] && usage

TARGET_DIR="$1"

# ── 디렉토리 검증 ─────────────────────────────────────────
if [[ ! -d "$TARGET_DIR" ]]; then
    echo "오류: '$TARGET_DIR' 디렉토리가 존재하지 않습니다." >&2
    exit 1
fi

TARGET_DIR="${TARGET_DIR%/}"  # 후행 슬래시 제거

# ── OS 감지 ───────────────────────────────────────────────
OS_TYPE="$(uname -s)"

# ── mtime 추출: YYYY/MM 형식 반환 ────────────────────────
get_year_month() {
    local file="$1"
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        stat -f "%Sm" -t "%Y/%m" "$file"
    else
        date -d "$(stat -c "%y" "$file")" "+%Y/%m"
    fi
}

# ── 확장자 추출: 없으면 "no_ext" 반환 ────────────────────
# 참고: .tar.gz 같은 복합 확장자는 마지막 확장자(gz)만 사용
get_extension() {
    local filename="$(basename "$1")"
    # 점으로 시작하는 파일은 확장자 없음으로 처리
    if [[ "$filename" == .* ]]; then
        echo "no_ext"
        return
    fi
    local ext="${filename##*.}"
    if [[ "$ext" == "$filename" || -z "$ext" ]]; then
        echo "no_ext"
    else
        echo "$ext" | tr "[:upper:]" "[:lower:]"  # 소문자 변환
    fi
}

# ── 충돌 방지 목적지 경로 계산 ────────────────────────────
# 목적지에 동일 파일명 존재 시 _타임스탬프 suffix 추가
resolve_dest() {
    local dest_dir="$1"
    local filename="$(basename "$2")"
    local dest="$dest_dir/$filename"

    if [[ ! -e "$dest" ]]; then
        echo "$dest"
        return
    fi

    local base="${filename%.*}"
    local ext="${filename##*.}"
    local ts="$(date +%Y%m%d%H%M%S)"

    if [[ "$base" == "$filename" ]]; then
        # 확장자 없는 파일
        echo "$dest_dir/${filename}_${ts}"
    else
        echo "$dest_dir/${base}_${ts}.${ext}"
    fi
}

# ── 파일 이동 (dry-run 지원) ──────────────────────────────
move_file() {
    local src="$1"
    local dest="$2"

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] mv \"$src\" → \"$dest\""
    else
        mv "$src" "$dest"
        echo "이동: $(basename "$src") → $dest"
    fi
}

# ── 단일 파일 처리 ────────────────────────────────────────
process_file() {
    local filepath="$1"

    ext="$(get_extension "$filepath")"
    ym="$(get_year_month "$filepath")"
    dest_dir="$TARGET_DIR/$ext/$ym"

    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$dest_dir"
    fi

    dest="$(resolve_dest "$dest_dir" "$filepath")"
    move_file "$filepath" "$dest"
    moved=$((moved + 1))
}

# ── 메인 처리 ─────────────────────────────────────────────
echo "========================================"
echo "파일 정리 시작: $(date)"
[[ "$DRY_RUN" == true ]]    && echo "[DRY-RUN 모드 — 실제 이동 없음]"
[[ "$RECURSIVE" == true ]]  && echo "[재귀 모드 — 하위 디렉토리 포함]"
echo "========================================"

moved=0

if [[ "$RECURSIVE" == true ]]; then
    while IFS= read -r -d '' filepath; do
        # 파일이 이미 사라진 경우 건너뜀 (이동 중 연동 파일이 삭제되는 경우 등)
        [[ -f "$filepath" ]] || continue
        # macOS AppleDouble 리소스 포크 파일 건너뜀 (._filename)
        [[ "$(basename "$filepath")" == ._* ]] && continue
        # 이미 정리된 파일 건너뜀: <ext>/YYYY/MM/ 패턴
        rel_path="${filepath#$TARGET_DIR/}"
        if [[ "$rel_path" =~ ^[^/]+/[0-9]{4}/[0-9]{2}/ ]]; then
            continue
        fi
        process_file "$filepath"
    done < <(find "$TARGET_DIR" -type f -print0)
else
    for filepath in "$TARGET_DIR"/*; do
        [[ -f "$filepath" ]] || continue
        # macOS AppleDouble 리소스 포크 파일 건너뜀 (._filename)
        [[ "$(basename "$filepath")" == ._* ]] && continue
        process_file "$filepath"
    done
fi

# ── 빈 디렉토리 정리 (깊이 우선 — 연쇄 삭제 지원) ────────
# -depth: 하위 디렉토리부터 처리하여 부모도 비면 연쇄 삭제
# rmdir 성공 여부로 비어있는지 판단 (실패 = 비어있지 않음, 건너뜀)
removed_dirs=0
if [[ "$DRY_RUN" == true ]]; then
    while IFS= read -r -d '' dir; do
        [[ -z "$(ls -A "$dir" 2>/dev/null)" ]] || continue
        echo "[DRY-RUN] rmdir \"$dir\""
        removed_dirs=$((removed_dirs + 1))
    done < <(find "$TARGET_DIR" -mindepth 1 -depth -type d -print0)
else
    while IFS= read -r -d '' dir; do
        if rmdir "$dir" 2>/dev/null; then
            echo "삭제: $dir"
            removed_dirs=$((removed_dirs + 1))
        fi
    done < <(find "$TARGET_DIR" -mindepth 1 -depth -type d -print0)
fi

echo "========================================"
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] 이동 예정: $moved 개 파일, 빈 디렉토리 삭제 예정: $removed_dirs 개"
else
    echo "완료: $moved 개 파일 처리됨, 빈 디렉토리 $removed_dirs 개 삭제"
fi
echo "========================================"
