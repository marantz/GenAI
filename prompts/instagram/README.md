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
├── js/
│   └── collect.js                # 브라우저에서 실행되는 수집 로직 (Node 테스트 가능하게 분리)
├── tests/                        # 단위 테스트 (아래 "테스트" 절 참고)
│   ├── collect.test.js
│   ├── fake-dom.js
│   ├── test_analyze.py
│   └── test_enhance.py
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

수집은 두 단계로 진행된다:

1. **그리드 스크롤** — 프로필 그리드를 천천히 스크롤하며 각 게시물의 **퍼머링크 + 커버 이미지**를
   누적 수집한다. Instagram 그리드는 화면 밖 `<img>`를 DOM에서 제거(가상화)하므로 끝에서 한 번만
   모으면 마지막 화면분만 잡힌다 — 그래서 매 스크롤마다 누적한다. `naturalWidth`(로드 완료 여부)에는
   의존하지 않고 `srcset` 속성만으로 판단하므로, 아직 로딩 중인 이미지의 URL도 놓치지 않는다.
2. **게시물 확장(기본 켜짐, `EXPAND_POSTS=1`)** — 각 게시물 퍼머링크를 열어 캐러셀(여러 장 게시물)의
   **다음 버튼을 끝까지 눌러** 모든 슬라이드를 수집한다. 그리드 커버 이미지는 게시물의 "첫 장"만
   보여주므로, 이 단계 없이는 캐러셀의 2번째 사진부터 영구적으로 누락된다.

다운로드 단계는 실패 시 지수 백오프로 재시도하고, 응답이 비정상적으로 작으면(차단/placeholder 의심)
재시도하며, 연속 실패가 누적되면 잠시 쉬었다가 재개한다(차단 회피).

```bash
# 새 탭을 띄워 프로필을 수집
./save-insta-images.sh https://www.instagram.com/<user>/

# 이미 열린 인스타 탭에서 수집
./save-insta-images.sh

# 특정 surface 지정
SURFACE=surface:2 ./save-insta-images.sh

# 라이브 브라우저 없이 설정/스크립트만 점검 (cmux 실행파일, collect.js 문법)
./save-insta-images.sh --selftest
```

### 환경변수 옵션

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `OUT_BASE` | `<스크립트 위치>/users` | 이미지 저장 루트 |
| `SCROLL_STEP_PX` | `400` | 한 번에 스크롤할 픽셀 (작을수록 가상화 누락↓) |
| `SCROLL_ROUNDS` | 자동 산출 | 최대 스크롤 횟수 (게시물 수 기반 자동 계산, 최대 800) |
| `MIN_IMG_WIDTH` | `150` | 커버 이미지의 srcset 최대 폭(px)이 이보다 작으면 제외(정보 없으면 포함) |
| `DL_DELAY_MIN` / `DL_DELAY_MAX` | `1` / `3` | 이미지 다운로드 사이 지연(초) |
| `EXPAND_POSTS` | `1` | 각 게시물을 열어 캐러셀 전체 슬라이드를 수집 (0=그리드 커버만) |
| `INCLUDE_REELS` | `0` | 1이면 `/reel/` 게시물도 열어서 확장(기본은 그리드 썸네일만) |
| `MAX_POSTS` | `0`(무제한) | 게시물 확장 개수 제한 (테스트용) |
| `MAX_CAROUSEL_SLIDES` | `20` | 캐러셀 1개당 "다음" 클릭 최대 횟수(무한루프 방지) |
| `POST_DELAY_MIN` / `POST_DELAY_MAX` | `2` / `4` | 게시물 사이 지연(초) |
| `POST_WAIT_TIMEOUT_MS` | `8000` | 게시물 페이지 로딩 대기 타임아웃 |
| `FETCH_RETRIES` | `3` | 이미지 1장 다운로드 실패 시 재시도 횟수 |
| `FETCH_RETRY_BASE_SEC` | `2` | 재시도 대기(초, 회차마다 배가) |
| `MIN_BYTES` | `2000` | 응답이 이보다 작으면 차단/placeholder 의심 → 재시도 |
| `CONSEC_FAIL_BREAK` / `CONSEC_FAIL_SLEEP` | `6` / `30` | 연속 실패 이 횟수 이상 시 이 초만큼 휴식(서킷브레이커) |

캐러셀 확장 로직(다음 버튼 탐색, srcset 최고해상도 선택, 퍼머링크 분류 등)은
`js/collect.js`에 분리되어 있으며 `tests/collect.test.js`로 단위 테스트된다.

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

---

## 테스트

라이브 Instagram 세션이 필요 없는 부분(순수 로직)은 전부 단위 테스트로 커버되어 있다.
실제 브라우저/네트워크가 필요한 수집 자체는 사람이 직접 확인해야 한다(아래 "수동 점검" 참고).

```bash
# JS: collect.js (srcset 파싱, 퍼머링크 분류, 캐러셀 다음 버튼 탐색 등) — Node 내장 테스트 러너, 의존성 없음
node --test tests/*.test.js

# Python: analyze.py / enhance.py 순수 함수 — stdlib unittest, pytest 불필요
python3 -m unittest discover -s tests -p "test_*.py" -v

# 셸 문법 검사 + 라이브 브라우저 없이 가능한 점검
bash -n save-insta-images.sh
./save-insta-images.sh --selftest
```

Python 테스트는 `openai`/`Pillow`가 설치되어 있지 않아도 동작한다(테스트 안에서 최소 스텁을 주입해
`analyze.py` import만 성립시키고, 실제로 검증하는 대상은 문자열/파일 처리 같은 순수 로직이다).
실제 VLM 호출을 검증하려면 `insta_vlm` pyenv 가상환경(`bash setup.sh`)에서 `python analyze.py`를
직접 실행해야 한다.

### 수동 점검 (실제 Instagram 세션 필요)

`js/collect.js`의 DOM 함수는 실제 Instagram 페이지 구조에 의존하므로, 아래 항목은 라이브 세션에서
직접 확인한다 — Instagram이 마크업을 바꾸면 셀렉터가 깨질 수 있다는 뜻이므로 주기적으로 재확인한다.

- 사진 여러 장(캐러셀) 게시물 하나를 열어 `EXPAND_POSTS=1`로 실행 → 모든 슬라이드가 `users/<user>/`에
  저장되는지 확인 (그리드 커버 1장만 저장되면 캐러셀 확장이 깨진 것)
- `MAX_POSTS=3` 정도로 제한해 짧게 실행하며 로그에서 "슬라이드 N장 확인"이 실제 게시물의 사진 수와
  맞는지 확인
- 실패/재시도 로그(`시도 N/최종 실패`)가 과도하게 뜨면 `DL_DELAY_*`, `POST_DELAY_*`를 늘려 속도를 낮춘다
