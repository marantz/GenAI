#!/bin/bash
#
# LinkedIn 영상 다운로드 스크립트
# 사용법: ./download_linkedin_video.sh
#

DOWNLOAD_DIR="$HOME/Downloads"

# yt-dlp 설치 확인
if ! command -v yt-dlp &>/dev/null; then
    echo "yt-dlp이 설치되어 있지 않습니다."
    read -rp "brew로 설치하시겠습니까? (y/n): " answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        brew install yt-dlp
    else
        echo "yt-dlp 설치 후 다시 실행해주세요."
        echo "  brew install yt-dlp"
        exit 1
    fi
fi

# URL 입력
echo "==========================================="
echo "  LinkedIn 영상 다운로드"
echo "==========================================="
read -rp "LinkedIn URL을 입력하세요: " url

if [[ -z "$url" ]]; then
    echo "URL이 입력되지 않았습니다."
    exit 1
fi

echo ""
echo "다운로드 경로: $DOWNLOAD_DIR"
echo "다운로드 중..."
echo ""

yt-dlp \
    --no-check-certificates \
    -o "$DOWNLOAD_DIR/%(title).80s.%(ext)s" \
    --merge-output-format mp4 \
    "$url"

if [[ $? -eq 0 ]]; then
    echo ""
    echo "다운로드 완료! 저장 경로: $DOWNLOAD_DIR"
else
    echo ""
    echo "다운로드 실패. 쿠키가 필요할 수 있습니다."
    echo "LinkedIn 로그인이 필요한 영상이라면 아래 방법을 시도하세요:"
    echo ""
    echo "1. 브라우저에서 LinkedIn에 로그인"
    echo "2. 아래 명령어로 재시도:"
    echo "   yt-dlp --cookies-from-browser chrome \"$url\""
    exit 1
fi
