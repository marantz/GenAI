#!/bin/bash

SOURCE="/Volumes/EXT_1TB/"
DEST="/Volumes/EXT_4TB/"
LOG_FILE="/Users/marantz/rsync_backup.log"
ERROR_LOG="/Users/marantz/rsync_errors.log"

echo "========================================" | tee -a "$LOG_FILE"
echo "rsync 백업 시작: $(date)" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"

# 최대 재시도 횟수
MAX_RETRIES=5
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
    echo "" | tee -a "$LOG_FILE"
    echo "시도 #$((retry_count + 1)) - $(date)" | tee -a "$LOG_FILE"
    echo "----------------------------------------" | tee -a "$LOG_FILE"

    # rsync 실행
    rsync -rlDvh \
        --progress \
        --partial \
        --ignore-errors \
        --exclude='DOWNs/' \
        --exclude='OLDs/' \
        --log-file="$LOG_FILE" \
        "$SOURCE" "$DEST" 2>> "$ERROR_LOG"

    rsync_exit_code=$?

    echo "" | tee -a "$LOG_FILE"
    echo "rsync 종료 코드: $rsync_exit_code" | tee -a "$LOG_FILE"

    # rsync 종료 코드 확인
    # 0 = 성공
    # 23 = 일부 파일 전송 불가 (에러가 있지만 계속 진행)
    # 24 = 소스 파일이 사라짐
    if [ $rsync_exit_code -eq 0 ]; then
        echo "✓ 모든 파일이 성공적으로 복사되었습니다!" | tee -a "$LOG_FILE"
        break
    elif [ $rsync_exit_code -eq 23 ] || [ $rsync_exit_code -eq 24 ]; then
        echo "⚠ 일부 파일에서 에러 발생. 재시도합니다..." | tee -a "$LOG_FILE"
        retry_count=$((retry_count + 1))
        if [ $retry_count -ge $MAX_RETRIES ]; then
            echo "✗ 최대 재시도 횟수($MAX_RETRIES)에 도달했습니다." | tee -a "$LOG_FILE"
            echo "에러 로그를 확인하세요: $ERROR_LOG" | tee -a "$LOG_FILE"
        else
            echo "3초 후 재시도합니다..." | tee -a "$LOG_FILE"
            sleep 3
        fi
    else
        echo "✗ rsync 실행 중 치명적인 오류 발생 (종료 코드: $rsync_exit_code)" | tee -a "$LOG_FILE"
        echo "에러 로그를 확인하세요: $ERROR_LOG" | tee -a "$LOG_FILE"
        break
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "rsync 백업 완료: $(date)" | tee -a "$LOG_FILE"
echo "========================================" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "로그 파일: $LOG_FILE"
echo "에러 로그: $ERROR_LOG"
