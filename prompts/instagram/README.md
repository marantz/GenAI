# 인스타 이미지 VLM 분석기

하위 사용자 폴더의 이미지를 vLLM(OpenAI 호환) VLM으로 분석해서, **여성 사진만** 골라
얼굴 생김새를 제외한 **배경 묘사 + 몸매/의상 + 찍힌 포즈**를 자연스러운 한국어 **한 줄**
설명으로 `instagram.txt` 에 누적합니다.

## 폴더 구조

수집한 이미지는 `users/<사용자>/` 아래에 둡니다. 이 디렉토리는 용량이 크고
repo 에 동기화하면 안 되므로 최상위 `.gitignore` 로 제외됩니다.

```
prompts/instagram/
├── analyze.py            # VLM 분석 스크립트
├── save-insta-images.sh  # 이미지 수집 스크립트 (기본 저장 위치: users/)
├── lists.txt             # 처리 목록 (추적됨)
├── instagram.txt         # 결과 캡션 (추적됨)
├── instagram_en.txt      # 영문 캡션 (추적됨)
└── users/                # 수집 이미지 — .gitignore 로 제외
    ├── ericsun_syc/
    ├── minadori222/
    └── ...
```

## 동작

- `users/` 아래 각 하위 폴더(`ericsun_syc/`, `minadori222/` ...)를 인스타 사용자로 간주
- `lists.txt` 에 처리한 `사용자/이미지명` 을 기록 (여성/비여성 모두) → 재실행 시 **미처리만** 처리
- 여성 사진의 설명만 `instagram.txt` 에 한 줄씩 append (CR/LF·연속공백은 단일 공백으로 축약)
- 추론 실패(서버 오류 등)는 `lists.txt` 에 기록하지 않아 다음 실행에서 자동 재시도

## 설치 (pyenv + virtualenv)

```bash
bash setup.sh        # pyenv 가상환경 insta_vlm 생성 + 의존성 설치 + .python-version 고정
```

## 실행

```bash
python analyze.py
```

### 옵션 / 환경변수

| 옵션 | 환경변수 | 기본값 |
|------|----------|--------|
| `--base-url` | `VLM_BASE_URL` | `http://192.168.11.126:8000/v1` |
| `--model`    | `VLM_MODEL`    | `nvidia/diffusiongemma-26B-A4B-it-NVFP4` |
| `--api-key`  | `VLM_API_KEY`  | `EMPTY` |
| `--root`     | -              | `<스크립트 위치>/users` |
| `--max-size` | -              | `1024` (이미지 긴 변 최대 픽셀) |
| `--lists`    | -              | `<스크립트 위치>/lists.txt` |
| `--output`   | -              | `<스크립트 위치>/instagram.txt` |

예:

```bash
python analyze.py --model nvidia/diffusiongemma-26B-A4B-it-NVFP4 --max-size 768
```
