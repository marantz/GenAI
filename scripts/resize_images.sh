#!/bin/bash

##############################################################################
# Image Resizer Script
# 현재 디렉토리의 모든 이미지를 비율을 유지하며 최대 크기로 리사이징합니다.
#
# 사용법:
#   ./resize_images.sh [최대크기] [출력디렉토리]
#
# 예제:
#   ./resize_images.sh           # 최대 1024px로 resize 디렉토리에 저장
#   ./resize_images.sh 2048      # 최대 2048px로 resize 디렉토리에 저장
#   ./resize_images.sh 1024 output # 최대 1024px로 output 디렉토리에 저장
##############################################################################

# 기본값 설정
MAX_SIZE=${1:-1024}      # 기본 1024px
OUTPUT_DIR=${2:-resize}  # 기본 resize 디렉토리

# 지원하는 이미지 확장자
IMAGE_EXTENSIONS=("jpg" "jpeg" "png" "JPG" "JPEG" "PNG" "gif" "GIF")

echo "========================================"
echo "Image Resizer"
echo "========================================"
echo "Max Size: ${MAX_SIZE}px (maintaining aspect ratio)"
echo "Output Directory: ${OUTPUT_DIR}"
echo "========================================"

# 출력 디렉토리 생성
mkdir -p "$OUTPUT_DIR"

# 처리된 이미지 카운터
count=0

# 각 확장자별로 이미지 처리
for ext in "${IMAGE_EXTENSIONS[@]}"; do
  for img in *."$ext"; do
    # 파일이 실제로 존재하는지 확인 (glob이 매칭되지 않으면 패턴 자체가 반환됨)
    if [ -f "$img" ]; then
      echo ""
      echo "Processing: $img"

      # 원본 크기 가져오기
      width=$(sips -g pixelWidth "$img" | tail -1 | awk '{print $2}')
      height=$(sips -g pixelHeight "$img" | tail -1 | awk '{print $2}')

      # 리사이징 (비율 유지하며 최대 크기 제한)
      # -Z 옵션: 가로/세로 중 큰 쪽을 기준으로 비율을 유지하며 리사이징
      sips -Z "$MAX_SIZE" "$img" --out "$OUTPUT_DIR/$img" > /dev/null 2>&1

      if [ $? -eq 0 ]; then
        # 리사이징된 이미지의 크기 확인
        new_width=$(sips -g pixelWidth "$OUTPUT_DIR/$img" | tail -1 | awk '{print $2}')
        new_height=$(sips -g pixelHeight "$OUTPUT_DIR/$img" | tail -1 | awk '{print $2}')
        echo "  ✓ Original: ${width}x${height} -> Resized: ${new_width}x${new_height}"
        count=$((count + 1))
      else
        echo "  ✗ Failed to resize $img"
      fi
    fi
  done
done

echo ""
echo "========================================"
if [ $count -eq 0 ]; then
  echo "No images found in the current directory."
else
  echo "Done! $count image(s) resized."
  echo "Resized images are in the '$OUTPUT_DIR' directory."
fi
echo "========================================"
