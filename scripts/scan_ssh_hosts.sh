#!/bin/bash

# SSH 포트 스캔 스크립트
# WiFi 네트워크에서 SSH(22번 포트)가 열려있는 호스트를 검색합니다.

# 색상 정의
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "SSH 호스트 스캔 시작"
echo "=========================================="

# 현재 WiFi IP 주소 가져오기
WIFI_IP=$(ipconfig getifaddr en0)

if [ -z "$WIFI_IP" ]; then
    echo -e "${RED}WiFi가 연결되어 있지 않습니다. en0 인터페이스를 확인해주세요.${NC}"
    exit 1
fi

echo -e "${YELLOW}현재 WiFi IP: $WIFI_IP${NC}"

# IP 범위 계산 (기본 /24 네트워크)
NETWORK_PREFIX=$(echo $WIFI_IP | cut -d. -f1-3)
echo -e "${YELLOW}스캔 범위: $NETWORK_PREFIX.1-254${NC}"
echo "=========================================="

# SSH 포트가 열려있는 호스트를 저장할 배열
declare -a SSH_HOSTS

# 타임아웃 설정 (초)
TIMEOUT=1

# 네트워크 스캔
echo "스캔 중... (시간이 걸릴 수 있습니다)"

for i in {1..254}; do
    IP="$NETWORK_PREFIX.$i"

    # 진행상황 표시 (10개마다)
    if [ $((i % 10)) -eq 0 ]; then
        echo -n "."
    fi

    # nc를 사용하여 SSH 포트(22) 확인
    # -z: 스캔 모드, -w: 타임아웃, -G: 연결 타임아웃
    if nc -z -w $TIMEOUT -G $TIMEOUT $IP 22 2>/dev/null; then
        SSH_HOSTS+=("$IP")
        echo ""
        echo -e "${GREEN}[발견] $IP - SSH 포트 열림${NC}"
    fi
done

echo ""
echo "=========================================="
echo "스캔 완료"
echo "=========================================="

# 결과 출력
if [ ${#SSH_HOSTS[@]} -eq 0 ]; then
    echo -e "${RED}SSH가 열려있는 호스트를 찾지 못했습니다.${NC}"
else
    echo -e "${GREEN}SSH가 열려있는 호스트 목록:${NC}"
    for host in "${SSH_HOSTS[@]}"; do
        echo "  - $host"

        # 호스트 이름 확인 시도
        HOSTNAME=$(host $host 2>/dev/null | grep "domain name pointer" | cut -d' ' -f5 | sed 's/\.$//')
        if [ ! -z "$HOSTNAME" ]; then
            echo "    (호스트명: $HOSTNAME)"
        fi
    done
    echo ""
    echo -e "${YELLOW}총 ${#SSH_HOSTS[@]}개의 호스트 발견${NC}"
fi

echo "=========================================="
