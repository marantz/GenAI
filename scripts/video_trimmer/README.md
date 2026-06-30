# Video Trim Tool

영상에서 고정 길이 구간을 선택해 새 영상으로 저장하는 PySide6 데스크탑 앱.

## 기능
- 윈도우 크기에 맞춰 스트레칭되는 상단 영상 미리보기
- 하단 전체 영상 1초 간격 썸네일 스트립 + 노란색 선택 구간
- 고정 길이(예 16.1초) 입력 후 드래그로 시작점 이동
- ffmpeg 재인코딩으로 정확한 구간을 새 mp4 로 저장

## 설치
```bash
cd video_trimmer
python3 -m venv .venv          # Python 3.11~3.13 권장
.venv/bin/pip install -r requirements.txt
```
ffmpeg/ffprobe 가 PATH 에 있어야 합니다 (`brew install ffmpeg`).

## 실행
패키지 부모 디렉터리(`scripts/`)에서 실행합니다:
```bash
cd ..    # scripts/
video_trimmer/.venv/bin/python -m video_trimmer
```

## 사용법
1. 「열기」로 영상 선택
2. 「길이(초)」에 구간 길이 입력 (예 16.1)
3. 하단 노란색 타임라인을 드래그해 시작점 이동
4. 「재생」/「일시정지」로 미리보기
5. 「구간 저장」으로 새 mp4 생성

## 테스트
상위 디렉터리(`scripts/`)에서 패키지 임포트가 되도록 실행합니다:
```bash
cd ..    # scripts/
QT_QPA_PLATFORM=offscreen video_trimmer/.venv/bin/python -m pytest video_trimmer/tests -v
```
