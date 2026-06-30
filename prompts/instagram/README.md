# 인스타 이미지 VLM 분석기

하위 사용자 폴더의 이미지를 vLLM(OpenAI 호환) VLM으로 분석해서, **여성 사진만** 골라
얼굴 생김새를 제외한 **배경 묘사 + 몸매/의상 + 찍힌 포즈**를 자연스러운 한국어 **한 줄**
설명으로 `instagram.txt` 에 누적합니다.

생성된 캡션은 `enhance.py` 로 이미지 생성용 영문 프롬프트로 강화할 수 있습니다.

## 전체 워크플로우

```
1. save-insta-images.sh   ← cmux 브라우저로 인스타 이미지 수집 → users/<user>/
2. analyze.py             ← VLM으로 이미지 분석 → instagram.txt (한국어 캡션)
3. (번역)                 ← instagram_en.txt 준비 (영문 번역본)
4. enhance.py             ← 영문 캡션을 이미지 생성 프롬프트로 강화 → *.enhanced.txt
```

## 폴더 구조

```
prompts/instagram/
├── analyze.py                    # VLM 분석 스크립트
├── enhance.py                    # 캡션 → 이미지 생성 프롬프트 강화
├── enhance.config.json           # enhance.py 설정 (API key 등, .gitignore 제외)
├── enhance.config.example.json   # 설정 예시
├── save-insta-images.sh          # 이미지 수집 스크립트 (cmux 브라우저 사용)
├── setup.sh                      # pyenv 가상환경 생성 + 의존성 설치
├── requirements.txt
├── lists.txt                     # 처리 목록 (추적됨)
├── instagram.txt                 # 한국어 캡션 결과 (추적됨)
├── instagram_en.txt              # 영문 캡션 (추적됨)
├── instagram_en.enhanced.txt     # 강화된 영문 프롬프트 (추적됨)
└── users/                        # 수집 이미지 — .gitignore 로 제외
    ├── bella_luccini/
    └── ...
```

## 설치 (pyenv + virtualenv)

```bash
bash setup.sh   # pyenv 가상환경 insta_vlm 생성 + 의존성 설치 + .python-version 고정
```

---

## 1단계: 이미지 수집 — `save-insta-images.sh`

cmux 브라우저(WKWebView)에 이미 로그인된 인스타 세션을 그대로 이용해
페이지에서 이미지를 수집한다. 별도 HTTP 클라이언트를 쓰지 않으므로 봇 탐지를 우회한다.

```bash
# 새 탭을 띄워 프로필을 수집
./save-insta-images.sh https://www.instagram.com/<user>/

# 이미 열린 인스타 탭에서 수집
./save-insta-images.sh

# 특정 surface 지정
SURFACE=surface:2 ./save-insta-images.sh
```

### 환경변수 옵션

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `OUT_BASE` | `<스크립트 위치>/users` | 이미지 저장 루트 |
| `SCROLL_STEP_PX` | `400` | 한 번에 스크롤할 픽셀 (작을수록 가상화 누락↓) |
| `SCROLL_ROUNDS` | 자동 산출 | 최대 스크롤 횟수 (게시물 수 기반 자동 계산, 최대 800) |
| `MIN_IMG_WIDTH` | `150` | 이 폭(px) 미만 아이콘류 제외 |
| `DL_DELAY_MIN` | `1` | 이미지 사이 최소 지연(초) |
| `DL_DELAY_MAX` | `3` | 이미지 사이 최대 지연(초) |

---

## 2단계: VLM 분석 — `analyze.py`

### 동작

- `users/` 아래 각 하위 폴더를 인스타 사용자로 간주
- `lists.txt` 에 처리한 `사용자/이미지명` 을 기록 (여성/비여성 모두) → 재실행 시 **미처리만** 처리
- 여성 사진의 설명만 `instagram.txt` 에 한 줄씩 append (CR/LF·연속공백은 단일 공백으로 축약)
- 추론 실패(서버 오류 등)는 `lists.txt` 에 기록하지 않아 다음 실행에서 자동 재시도

```bash
python analyze.py
```

### 옵션 / 환경변수

| 옵션 | 환경변수 | 기본값 | 설명 |
|------|----------|--------|------|
| `--base-url` | `VLM_BASE_URL` | `http://192.168.11.126:8000/v1` | vLLM 서버 주소 |
| `--model` | `VLM_MODEL` | `nvidia/diffusiongemma-26B-A4B-it-NVFP4` | 사용할 VLM 모델 |
| `--api-key` | `VLM_API_KEY` | `EMPTY` | API 키 (로컬 서버는 임의값) |
| `--root` | - | `<스크립트 위치>/users` | 이미지 루트 디렉토리 |
| `--max-size` | - | `1024` | 이미지 긴 변 최대 픽셀 |
| `--focus` | - | `default` | 묘사 초점 (아래 참고) |
| `--max-tokens` | - | `512` | 응답 최대 토큰 (`clothing` 모드 시 1024+ 권장) |
| `--lists` | - | `<스크립트 위치>/lists.txt` | 처리 목록 파일 |
| `--output` | - | `<스크립트 위치>/instagram.txt` | 캡션 출력 파일 |

**`--focus` 모드:**

| 값 | 설명 |
|----|------|
| `default` | 배경·몸매·의상·포즈를 한 문단으로 묘사 |
| `clothing` | 색상·소재·실루엣·패턴·디자인 디테일(주름/플리츠 등)을 패션 카탈로그 수준으로 상세 묘사 |

```bash
# 기본 (배경·몸매·의상·포즈)
python analyze.py --model nvidia/diffusiongemma-26B-A4B-it-NVFP4 --max-size 768

# 의상 상세 묘사 모드
python analyze.py --focus clothing --max-tokens 1024

# VLM 서버 주소 변경
VLM_BASE_URL=http://10.0.0.5:8000/v1 python analyze.py
```

---

## 4단계: 프롬프트 강화 — `enhance.py`

캡션 파일의 각 줄을 OpenAI 호환 API로 보내 이미지 생성용 영문 프롬프트로 변환한다.
결과는 `<입력>.enhanced.txt` 에 저장하고, 터미널에 원본(좌)↔변환본(우) 2단 비교를 출력한다.
중간에 중단해도 진행분은 즉시 파일에 기록되며, `--resume` 으로 이어서 처리할 수 있다.

```bash
# 기본: instagram_en.txt → instagram_en.enhanced.txt
python enhance.py instagram_en.txt

# 출력 파일 지정
python enhance.py instagram_en.txt -o out.txt

# 앞 20줄만 테스트
python enhance.py instagram_en.txt --range 1-20

# 중단 후 이어서 처리
python enhance.py instagram_en.txt --resume
```

### 설정 — `enhance.config.json`

`enhance.config.example.json` 을 복사해서 편집한다.

```json
{
  "base_url": "https://your-openai-compatible-server/v1",
  "api_key": "sk-...",
  "model": "gpt-4o-mini",
  "temperature": 0.7
}
```

우선순위: **CLI 인자 > enhance.config.json > .env / 환경변수**

### 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `input` | `prompt.txt` | 입력 파일 (positional) |
| `-o / --output` | `<입력>.enhanced.txt` | 출력 파일 |
| `--config` | `enhance.config.json` | 설정 JSON 파일 |
| `--instruction-file` | - | 내장 지시문 대신 쓸 외부 지시문 파일 |
| `--model` | config 값 | 모델명 (config 덮어쓰기) |
| `--base-url` | config 값 | API base URL (config 덮어쓰기) |
| `--api-key` | config 값 | API key (config 덮어쓰기) |
| `--temperature` | config 값 | temperature (config 덮어쓰기) |
| `--range` | 전체 | 처리할 라인 범위, 1-based (예: `1-20`, `5`) |
| `--resume` | - | 기존 출력 파일 이어쓰기 (완료 줄 건너뜀) |
| `--no-color` | - | ANSI 색상 끄기 |
