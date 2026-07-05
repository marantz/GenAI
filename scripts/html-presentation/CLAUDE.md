# CLAUDE.md — Source-to-Presentation Generator

이 문서는 지정된 디렉토리(주로 git 프로젝트)의 소스 코드, README, 구조를 분석하여
**짙은 청색 톤의 단일 HTML5 프레젠테이션**으로 시각화하는 작업을 위한 프로젝트 지침이다.
Claude Code는 이 문서를 프로젝트 루트의 컨텍스트로 항상 읽고 아래 규칙을 따른다.

---

## 1. 목적 (Objective)

사용자가 디렉토리 경로를 지정하면:

1. 해당 디렉토리가 git 프로젝트인지 확인하고 프로젝트명을 추출한다 (`git remote`, `.git/config`, 또는 폴더명 순으로 fallback).
2. 소스 구조, README, 주요 알고리즘/모듈을 분석한다.
3. 분석 결과를 **브라우저에서 바로 열 수 있는 단일 HTML 프레젠테이션**으로 생성한다.
4. 결과물은 프로젝트명을 딴 하위 디렉토리에 저장한다.

이 결과물은 내부 기술 리뷰, 투자/의사결정 보고, 신규 합류자 온보딩에 재사용 가능한
**프레젠테이션 자산(asset)**으로 취급한다 (일회성 산출물 아님).

---

## 2. 입력 → 출력 디렉토리 규칙

```
<현재 작업 디렉토리>/
└── presentations/
    └── <project-name>/
        ├── index.html      # 진입점 (더블클릭/브라우저 오픈으로 바로 실행)
        ├── style.css
        ├── main.js
        ├── data.json       # (선택) 소스 트리/분석 데이터 캐시
        └── assets/         # (선택) 아이콘, 다이어그램 등
```

- `<project-name>` 은 지정 디렉토리의 git 프로젝트명을 사용한다 (kebab-case로 정규화).
- 동일 프로젝트를 재생성할 경우 `presentations/<project-name>/` 을 덮어쓴다 (버전 관리 필요 시 `--archive` 옵션으로 이전 산출물을 `_archive/<timestamp>/` 로 이동 후 재생성).
- HTML/CSS/JS는 **외부 CDN 없이 완전 self-contained**하게 구성한다 (오프라인 환경, 폐쇄망 배포 대응). 부득이 폰트/아이콘이 필요하면 인라인 SVG 또는 시스템 폰트로 대체한다.
- 파일은 로컬 `file://` 프로토콜로 열어도 동작해야 한다 (module import, fetch 등 CORS 이슈 유발 요소 금지 — `data.json`도 fetch 대신 JS 파일에 인라인 상수로 임베드하는 것을 기본으로 한다).

---

## 3. 디자인 시스템 — 컬러 팔레트

기본 테마는 짙은 청색(dark navy) 계열로 고정한다. CSS 변수로 선언하여 프로젝트별 커스터마이징이 가능하도록 한다.

```css
:root {
  --color-bg-deepest: #35374B;   /* 최하단 배경, 페이지 기본 바탕 */
  --color-bg-panel:   #344955;   /* 카드/패널/섹션 배경 */
  --color-accent-mid: #50727B;   /* 보조 강조, 라인, 트리 커넥터 */
  --color-accent-lt:  #78A083;   /* 포인트 컬러, 강점/하이라이트, 호버 상태 */

  --color-text-primary:   #EAF1F1;
  --color-text-secondary: #B9C6C6;
  --color-text-muted:     #8B9A9A;

  --font-mono: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  --font-sans: -apple-system, 'Segoe UI', 'Pretendard', sans-serif;
}
```

- `--color-bg-deepest` : body/전체 배경
- `--color-bg-panel` : 슬라이드/카드/코드블록 배경
- `--color-accent-mid` : 트리 연결선, 보더, 비활성 강조
- `--color-accent-lt` : CTA, 강점 태그, 활성 노드, 호버/포커스 상태 (톤 온 톤 대비 확보)
- 팔레트는 옵션 인자로 오버라이드 가능해야 한다 (예: 사용자가 다른 4색 hex 세트를 주면 동일 변수명에 매핑).
- 대비(contrast)는 WCAG AA 이상을 목표로 하되, 프레젠테이션 특성상 시각적 몰입감(다크 테마, 은은한 글로우/그라데이션)을 우선한다.

---

## 4. 콘텐츠 구조 (필수 섹션)

생성되는 프레젠테이션은 아래 섹션을 스크롤 또는 슬라이드 내비게이션(화살표/키보드/스와이프)으로 구성한다.

1. **Cover** — 프로젝트명, 한 줄 태그라인, 언어/스택 배지
2. **Overview** — README 기반 요약 (목적, 문제정의, 사용 대상)
3. **Source Tree** — 디렉토리/파일 구조를 CSS 기반 동적 트리로 시각화 (§5 참조)
4. **Architecture / Main Algorithm** — 핵심 로직 흐름을 다이어그램(SVG/CSS)으로 표현
5. **Key Features** — 기능별 카드 그리드, 각 카드에 근거 코드/파일 경로 명시
6. **Why It Was Built / Strengths** — 설계 의도 및 차별점 분석 (§6 참조)
7. **Tech Stack & Dependencies** — 언어, 프레임워크, 외부 의존성 목록
8. **Closing / Next Steps** — 개선 여지, 로드맵, 리스크 (README/이슈/TODO 기반)

섹션은 `<section class="slide" id="...">` 단위로 분리하고, `main.js`가 네비게이션(진행 인디케이터, 키보드 화살표, 스와이프)을 제어한다.

---

## 5. 소스 구조 시각화 (CSS 기반 동적 트리)

- 파일시스템을 재귀적으로 스캔하여 트리 데이터를 구성한다 (`node_modules`, `.git`, 빌드 산출물, `venv` 등 노이즈 디렉토리는 기본 제외 목록으로 필터링).
- 트리는 **순수 CSS + 최소 JS**로 렌더링한다:
  - 들여쓰기/커넥터 라인은 `::before`/`::after` 가상요소와 `border-left`로 구현
  - 접기/펼치기는 `<details>/<summary>` 또는 `checkbox hack` + CSS로 구현 (JS 의존 최소화 원칙)
  - 파일 타입별 아이콘/색상은 확장자 기반 CSS 클래스(`.ext-py`, `.ext-ts`, `.ext-md` 등)로 매핑
  - 노드 호버 시 `--color-accent-lt`로 하이라이트, 클릭 시 우측/하단 패널에 해당 파일 요약(주석 기반 설명 또는 상위 20라인 미리보기) 표시
- 대형 저장소의 경우 depth 제한(기본 4단계) 및 "더보기" 인터랙션을 둔다. 파일 수가 많으면 트리 대신 **treemap(용량/라인수 기준 사각형 타일)** 대체 뷰 옵션을 제공한다.

---

## 6. 분석 방법론 — "강점 및 설계 의도" 도출 기준

임의로 미사여구를 만들지 않고, 아래 근거 기반으로만 서술한다:

| 분석 항목 | 근거 소스 |
|---|---|
| 왜 만들었는가 | README 목적/배경 서술, 커밋 메시지 초기 이력, 이슈/PR 제목 패턴 |
| 강점 | 코드 구조의 재사용성(모듈화 정도), 테스트 커버리지, 의존성 최소화, 에러 처리 패턴, 성능 관련 코드(캐싱/배치/비동기 처리) |
| 아키텍처 선택 이유 | 프레임워크/라이브러리 선정과 실제 사용 패턴의 일치도, 설정 파일(config)에서 드러나는 운영 고려사항 |
| 리스크/한계 | TODO/FIXME 주석, 하드코딩된 값, 테스트 부재 영역, 미완성 브랜치 |

- 근거 없는 추정은 "가정(Assumption)"으로 명시적으로 라벨링한다 (Executive Summary 스타일: Fact vs Assumption vs Recommendation 구분).
- 강점은 최대 4~6개로 압축하여 카드화하고, 각 카드에 "근거 파일/라인" 배지를 붙인다.

---

## 7. 기술 구현 가이드라인

- **HTML**: 시맨틱 태그(`<section>`, `<article>`, `<nav>`) 사용, 접근성(aria-label) 최소 적용.
- **CSS**: CSS 변수 + `clamp()` 기반 반응형 타이포그래피, `prefers-reduced-motion` 대응(과도한 트랜지션 비활성화 옵션).
- **JS**: 프레임워크 없이 vanilla JS 권장 (배포 단순성, `file://` 호환성). 상태는 단일 객체(`state`)로 관리.
- **데이터 임베딩**: 소스 스캔 결과(트리, 통계, README 파싱 결과)는 빌드 타임에 JSON으로 생성 후 `main.js` 상단에 `const SOURCE_DATA = {...}` 형태로 인라인 삽입 (fetch 오류 방지).
- **다이어그램**: 알고리즘 흐름도는 SVG path를 CSS `stroke-dasharray` 애니메이션으로 그려지는 효과 적용 가능 (과하지 않게, 톤은 `--color-accent-mid`/`--color-accent-lt` 사용).
- **성능**: 단일 페이지 로드 5MB 이하 목표, 이미지 대신 SVG/CSS 우선.

---

## 8. 작업 절차 (Claude Code 실행 순서)

1. 사용자가 지정한 디렉토리 경로 확인 → 존재 여부/git 여부 검증
2. `git config --get remote.origin.url` 또는 폴더명으로 `<project-name>` 확정
3. 디렉토리 트리 스캔 (노이즈 제외) + README 파싱 + 주요 파일(엔트리포인트, 설정파일) 식별
4. §6 기준에 따라 강점/설계의도 분석 초안 작성 (Fact/Assumption 구분)
5. `presentations/<project-name>/` 생성, `index.html` / `style.css` / `main.js` 작성
6. 로컬에서 `file://.../index.html` 오픈 기준으로 렌더링 검증 (콘솔 에러 없는지 확인)
7. 산출물 경로와 함께 요약 리포트(분석한 강점/가정 목록) 텍스트로 함께 제공

---

## 9. 커스터마이징 옵션 (사용자가 명시할 수 있는 파라미터)

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--theme` | `#35374B,#344955,#50727B,#78A083` | 4색 팔레트 오버라이드 |
| `--depth` | 4 | 트리 시각화 최대 depth |
| `--exclude` | node_modules,.git,dist,build,venv,__pycache__ | 스캔 제외 패턴 |
| `--nav` | scroll | `scroll` \| `slide` 프레젠테이션 내비게이션 방식 |
| `--archive` | false | 재생성 시 이전 산출물 아카이브 여부 |

---

## 10. 금지 사항

- 외부 CDN/네트워크 요청에 의존하는 렌더링 금지 (오프라인 동작 필수).
- 근거 없는 정성적 찬사("혁신적인", "완벽한" 등) 남발 금지 — 반드시 코드/문서 근거 병기.
- 원본 README/코드 주석의 장문 인용(15단어 이상) 금지 — 반드시 재서술(paraphrase).
- `presentations/` 외부 경로에 임의로 파일 생성 금지.
