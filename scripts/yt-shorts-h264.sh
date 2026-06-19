#!/usr/bin/env bash
#
# yt-shorts-h264.sh — YouTube Shorts(또는 일반 영상)를 다운로드하여
#                     H264(avc1) 비디오 + AAC 오디오의 MP4로 저장합니다.
#
# 전략:
#   1) YouTube에 H264 포맷이 있으면 그대로 받아 mp4로 합칩니다(화질 손실 없음).
#   2) 받은 영상이 H264가 아닐 때(VP9/AV1)만 ffmpeg로 H264/AAC 재인코딩합니다.
#   3) 즉, 꼭 필요할 때만 재인코딩하여 시간/화질을 아낍니다.
#
# 사용법:
#   ./yt-shorts-h264.sh <URL> [URL2 ...]
#   ./yt-shorts-h264.sh -o ~/Downloads <URL>
#   ./yt-shorts-h264.sh -f <URL>     # 항상 H264로 강제 재인코딩
#
# 필요: yt-dlp, ffmpeg  (brew install yt-dlp ffmpeg)

set -euo pipefail

OUTDIR="."
FORCE_REENCODE=0
CRF=18          # 재인코딩 화질(낮을수록 고화질, 18~23 권장)
PRESET="slow"  # 재인코딩 속도/압축 트레이드오프

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '1d'
  exit "${1:-0}"
}

# ---- 인자 파싱 ----
URLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUTDIR="$2"; shift 2 ;;
    -f|--force)  FORCE_REENCODE=1; shift ;;
    -h|--help)   usage 0 ;;
    -*)          echo "알 수 없는 옵션: $1" >&2; usage 1 ;;
    *)           URLS+=("$1"); shift ;;
  esac
done

[[ ${#URLS[@]} -eq 0 ]] && { echo "URL을 하나 이상 지정하세요." >&2; usage 1; }

# ---- 의존성 확인 ----
for bin in yt-dlp ffmpeg ffprobe; do
  command -v "$bin" >/dev/null 2>&1 || { echo "오류: '$bin' 이(가) 필요합니다. 'brew install yt-dlp ffmpeg'" >&2; exit 1; }
done

mkdir -p "$OUTDIR"
OUT_TMPL="$OUTDIR/%(title).200B [%(id)s].%(ext)s"

# 받은 mp4가 H264가 아니면 H264/AAC로 재인코딩
reencode_to_h264() {
  local f="$1"
  local vcodec
  vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
                   -of default=nw=1:nk=1 "$f")

  if [[ "$FORCE_REENCODE" -eq 0 && "$vcodec" == "h264" ]]; then
    echo "  · 이미 H264입니다 — 재인코딩 생략"
    return
  fi

  echo "  · 비디오 코덱이 '$vcodec' → H264로 재인코딩"
  local tmp="${f%.*}.h264.mp4"
  ffmpeg -y -loglevel warning -stats -i "$f" \
    -c:v libx264 -preset "$PRESET" -crf "$CRF" \
    -c:a aac -b:a 192k \
    -movflags +faststart \
    "$tmp"
  mv -f "$tmp" "$f"
}

for url in "${URLS[@]}"; do
  echo "▶ 처리 중: $url"

  # H264(avc1) 우선 선택 → 없으면 최선 포맷. mp4 컨테이너로 합치되 재인코딩은 안 함.
  # 최종 파일 경로를 stdout으로 받아 캡처한다.
  filepath=$(
    yt-dlp \
      -f "bv*[vcodec^=avc1]+ba[ext=m4a]/bv*[vcodec^=avc1]+ba/bv*+ba/b" \
      --merge-output-format mp4 \
      --no-simulate --print after_move:filepath \
      -o "$OUT_TMPL" \
      "$url"
  )

  if [[ -z "$filepath" || ! -f "$filepath" ]]; then
    echo "  ! 다운로드 결과 파일을 찾지 못했습니다: $url" >&2
    continue
  fi

  reencode_to_h264 "$filepath"
  echo "✓ 완료: $filepath"
  echo
done

echo "모든 작업이 끝났습니다. 저장 위치: $OUTDIR"
