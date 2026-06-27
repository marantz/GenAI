# Video Trim Tool — 설계 문서

작성일: 2026-06-27

## 개요

영상의 타임라인에서 정해진 길이(예: 16초, 16.1초)의 구간을 선택해
새로운 영상 파일로 저장하는 간단한 데스크탑 UI 앱.

- 플랫폼/스택: **PySide6 데스크탑 앱** (QtMultimedia 재생) + **ffmpeg/ffprobe** CLI
- 대상 OS: macOS (개발 환경 darwin, ffmpeg는 `/opt/homebrew/bin/ffmpeg`)

## 요구사항

1. 영상 타임라인을 정해진 시간(예: 16, 16.1초) 길이로 구간을 결정하여 해당 구간만 저장
2. 초단위 프레임 미리보기 기능
3. 화면 위에는 윈도우 사이즈에 맞게 스트레칭되는 영상 미리보기 프레임
4. 하단에는 프레임을 미리 보면서 이동하는 노란색 타임라인
5. 구간이 완전히 선택되면 저장하여 새로운 영상 파일 생성

## 핵심 결정 사항

- **구간 지정 방식**: 고정 길이 + 시작점 이동. 사용자가 구간 길이(예 16.1초)를
  입력하고, 노란색 타임라인을 좌우로 드래그하면 그 길이만큼의 창이 따라감.
  끝점은 `start + length`로 자동 계산.
- **썸네일 범위**: 전체 영상을 1초 간격 썸네일 스트립으로 표시하고,
  선택된 구간은 노란색 오버레이로 강조.
- **저장 인코딩**: ffmpeg `libx264` 재인코딩 (정확한 컷). 16.1초 같은
  정밀 구간을 프레임 단위로 정확히 잘라내기 위함.

## 아키텍처 / 모듈 구성

단일 PySide6 앱이지만 책임별로 파일을 분리한다. 각 위젯은 Qt 시그널/슬롯으로만
통신하여 독립적으로 이해·테스트 가능하게 한다.

```
video_trimmer/
├── main.py              # 앱 진입점, 메인 윈도우 부팅, 시그널 배선
├── player_widget.py     # 상단 영상 미리보기 (스트레칭 재생)
├── timeline_widget.py   # 하단 노란색 타임라인 + 썸네일 스트립
├── thumbnail_worker.py  # ffmpeg로 1초 간격 썸네일 추출 (QThread)
├── exporter.py          # ffmpeg로 구간 재인코딩 저장 (QThread)
└── ffmpeg_utils.py      # ffmpeg/ffprobe 경로 확인 및 커맨드 생성 헬퍼
```

### 컴포넌트 동작

**상단 — 영상 미리보기 (`player_widget.py`)**
- `QVideoWidget` + `QMediaPlayer`.
- `setAspectRatioMode(Qt.IgnoreAspectRatio)`로 윈도우 리사이즈 시 꽉 채워 스트레칭.
- 재생/일시정지, 현재 위치 표시. 타임라인과 위치 양방향 동기화.

**하단 — 타임라인 (`timeline_widget.py`)**
- 커스텀 `QWidget`에 `paintEvent`로 직접 렌더링:
  - 배경: 1초 간격 썸네일 스트립 (가로 나열)
  - 노란색 오버레이: 선택 구간 `[start, start+length]` 강조
  - 흰색 세로선: 현재 재생 위치(playhead)
- 마우스 드래그 → 시작점 이동 → `startChanged(float)` 시그널 emit. 구간 길이는 고정.
- 스핀박스로 구간 길이(예 16.1초) 입력 → `lengthChanged(float)`.

**썸네일 추출 (`thumbnail_worker.py`)**
- 영상 로드 시 `QThread`에서 `ffmpeg -i input -vf fps=1 thumb_%04d.jpg` 실행.
- 스크래치 임시 폴더에 저장. 완료된 썸네일부터 타임라인에 점진적으로 표시.

**저장 (`exporter.py`)**
- `ffmpeg -ss {start} -i input -t {length} -c:v libx264 -c:a aac output.mp4`
  (정확도를 위해 `-ss`를 입력 파일 뒤에 배치 — output seeking).
- `QThread`에서 실행. 진행률/완료/실패 시그널. 완료 후 저장 경로 안내.

## 데이터 / 상태 흐름

```
파일 열기
  → ffprobe로 duration 획득
  → 썸네일 추출 시작 (백그라운드)
  → 플레이어에 로드
사용자 조작
  → 구간 길이 입력 (예 16.1초)
  → 타임라인 드래그로 시작점 이동 (창이 따라감)
"구간 저장" 클릭
  → exporter (백그라운드 재인코딩)
  → 새 mp4 파일 생성 + 완료 안내
```

## 에러 처리

- **ffmpeg/ffprobe 미설치**: 시작 시 점검 후 안내 다이얼로그 표시, 기능 비활성화.
- **구간이 영상 끝 초과**: 시작점을 `duration - length`로 자동 클램프.
- **지원 안 되는 코덱/파일**: 로드 실패 메시지 다이얼로그.
- **저장 실패 (ffmpeg 비정상 종료)**: ffmpeg stderr를 다이얼로그에 표시.

## 테스트 전략

- `ffmpeg_utils`와 `exporter`의 **커맨드 생성 로직을 순수 함수로 분리**하여
  단위 테스트한다. 실제 ffmpeg 호출 없이 생성된 인자 리스트를 검증.
  - 예: `build_export_cmd(input, start=16.0, length=16.1, output)` 가
    올바른 `-ss / -t / -c:v libx264` 인자를 만드는지 확인.
- 짧은 샘플 mp4로 통합 스모크 테스트 1개 (실제 ffmpeg 실행 → 출력 파일
  존재 및 duration 검증).

## 범위 밖 (YAGNI)

- 다중 구간 선택 / 배치 저장
- 영상 효과, 필터, 트랜지션
- 가변 길이 자유 구간 (시작/끝 각각 지정) — 이번엔 고정 길이만
- 스트림 복사(-c copy) 모드 — 정확도 우선으로 재인코딩만
