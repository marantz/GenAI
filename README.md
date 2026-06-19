# GenAI Tools

생성형 AI 작업에 쓰는 유틸리티 스크립트와 프롬프트 파이프라인을 모아둔 디렉토리입니다.
이 문서만 보면 어떤 툴이 어디에 있고 무엇을 하는지 알 수 있습니다.

## 디렉토리 구조

```
GenAI/
├── .gitignore          # users/ 이미지·로그·캐시 등 동기화 제외 설정
├── scripts/            # 단독 실행형 셸 유틸리티 (영상/이미지/백업/네트워크)
└── prompts/
    └── instagram/      # 인스타 이미지 수집 + VLM 분석 파이프라인
        └── users/      # 수집 이미지 (.gitignore 로 제외 — repo 에 동기화 안 됨)
```

---

## scripts/ — 셸 유틸리티

각각 독립적으로 실행 가능한 macOS/bash 스크립트입니다.

| 스크립트 | 하는 일 | 사용법 | 필요 도구 |
|----------|---------|--------|-----------|
| `yt-shorts-h264.sh` | YouTube Shorts/영상을 H264(avc1) + AAC MP4로 다운로드. H264 포맷이 있으면 무손실로 받고, VP9/AV1일 때만 ffmpeg로 재인코딩 | `./yt-shorts-h264.sh <URL> [URL2 ...]`<br>`-o <dir>` 출력 경로, `-f` 항상 강제 재인코딩 | yt-dlp, ffmpeg |
| `download_linkedin_video.sh` | LinkedIn 영상을 `~/Downloads` 에 다운로드 (URL 대화형 입력) | `./download_linkedin_video.sh` | yt-dlp |
| `resize_images.sh` | 현재 디렉토리의 이미지를 비율 유지하며 최대 크기로 리사이징 | `./resize_images.sh [최대크기=1024] [출력디렉토리=resize]` | ImageMagick (sips/convert) |
| `organize_files.sh` | 디렉토리 파일을 확장자별 하위 폴더로 정리. `-n` dry-run, `-r` 재귀 | `./organize_files.sh [-n] [-r] <디렉토리>` | bash |
| `test_organize.sh` | `organize_files.sh` 의 테스트 스위트 (dry-run/실이동 검증) | `./test_organize.sh` | bash |
| `rsync_backup.sh` | 외장 디스크 간 rsync 백업 (최대 5회 재시도, 로그 기록). 소스/대상 경로는 스크립트 상단에서 설정 | `./rsync_backup.sh` | rsync |
| `scan_ssh_hosts.sh` | 현재 WiFi 서브넷(/24)에서 SSH(22번 포트)가 열린 호스트 스캔 | `./scan_ssh_hosts.sh` | bash, nc |

> `rsync_backup.sh` 는 `SOURCE`/`DEST`/`LOG_FILE` 경로가 스크립트에 하드코딩되어 있으니 사용 전 수정하세요.

---

## prompts/instagram/ — 인스타 이미지 VLM 분석 파이프라인

인스타그램 사용자 이미지를 수집한 뒤, vLLM(OpenAI 호환) VLM으로 분석하여
**여성 사진만** 골라 얼굴 생김새를 제외한 **배경 + 몸매/의상 + 포즈**를
자연스러운 한국어 한 줄 설명으로 누적합니다. (VLM 학습용 캡션 데이터 생성 목적)

### 구성 요소

| 파일 | 역할 |
|------|------|
| `save-insta-images.sh` | cmux 브라우저(WKWebView)의 로그인 세션 안에서 in-page `fetch()` 로 현재 보이는 인스타 이미지를 저장 (봇 탐지 우회). `users/<사용자>/` 폴더로 수집 |
| `analyze.py` | 사용자 폴더의 이미지를 VLM으로 분석 → 여성 사진 설명을 `instagram.txt` 에 한 줄씩 append |
| `setup.sh` | pyenv 가상환경 `insta_vlm` 생성 + 의존성 설치 + `.python-version` 고정 |
| `requirements.txt` | 의존성 (`openai`, `Pillow`) |
| `lists.txt` | 처리한 `사용자/이미지명` 기록 (재실행 시 미처리분만 처리) |
| `instagram.txt` | 결과 캡션 누적 파일 |
| `users/<사용자명>/` | 수집된 이미지 폴더 (예: `users/bella_luccini/` …) — `.gitignore` 로 제외 |
| `README.md` | 인스타 분석기 상세 문서 |

### 빠른 시작

```bash
cd prompts/instagram
bash setup.sh                 # 가상환경 + 의존성 설치
./save-insta-images.sh https://www.instagram.com/<user>/   # 이미지 수집 → users/<user>/ (선택)
python analyze.py             # users/ 분석 → instagram.txt 누적
```

주요 옵션/환경변수 (`analyze.py`):

| 옵션 | 환경변수 | 기본값 |
|------|----------|--------|
| `--base-url` | `VLM_BASE_URL` | `http://192.168.11.126:8000/v1` |
| `--model` | `VLM_MODEL` | `nvidia/diffusiongemma-26B-A4B-it-NVFP4` |
| `--api-key` | `VLM_API_KEY` | `EMPTY` |
| `--max-size` | – | `1024` (이미지 긴 변 최대 픽셀) |

자세한 내용은 [`prompts/instagram/README.md`](prompts/instagram/README.md) 참고.
