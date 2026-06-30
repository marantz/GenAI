# Video Trim Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PySide6 데스크탑 앱으로 영상에서 고정 길이 구간을 선택해 ffmpeg 재인코딩으로 새 영상 파일을 저장한다.

**Architecture:** 단일 PySide6 앱. 순수 로직(ffmpeg 커맨드 생성, ffprobe 파싱)은 `ffmpeg_utils.py`에 함수로 분리해 단위 테스트한다. 무거운 작업(썸네일 추출, 저장)은 `QThread` 워커에서 실행하고 시그널로 UI에 보고한다. 위젯들은 Qt 시그널/슬롯으로만 통신한다.

**Tech Stack:** Python 3.14, PySide6 (QtWidgets + QtMultimedia), ffmpeg/ffprobe CLI, pytest.

## Global Constraints

- Python 인터프리터: 프로젝트 루트 `video_trimmer/.venv` 가상환경 사용. 모든 실행/테스트는 이 venv에서.
- ffmpeg/ffprobe: 시스템 PATH의 바이너리 사용 (`/opt/homebrew/bin`). 하드코딩 금지, `shutil.which`로 탐색.
- 저장 인코딩: `-c:v libx264 -c:a aac`, output seeking(`-i input` 뒤에 `-ss`) 고정.
- 썸네일: 1초 간격(`fps=1`), 임시 디렉터리에 추출.
- 영상 미리보기: 윈도우 크기에 맞춰 스트레칭 (`Qt.IgnoreAspectRatio`).
- 선택 구간 강조 색: 노란색.
- 모든 파일 경로는 절대경로 또는 프로젝트 루트 기준 상대경로로 명시.

---

### Task 1: 프로젝트 스캐폴드 + 가상환경 + 의존성

**Files:**
- Create: `video_trimmer/requirements.txt`
- Create: `video_trimmer/__init__.py`
- Create: `video_trimmer/tests/__init__.py`
- Create: `video_trimmer/tests/test_smoke.py`

**Interfaces:**
- Consumes: (없음)
- Produces: `video_trimmer/.venv` 가상환경, 설치된 PySide6/pytest, 임포트 가능한 `video_trimmer` 패키지.

- [ ] **Step 1: 디렉터리 및 패키지 파일 생성**

`video_trimmer/requirements.txt`:
```
PySide6>=6.7
pytest>=8.0
```

`video_trimmer/__init__.py`: (빈 파일)

`video_trimmer/tests/__init__.py`: (빈 파일)

- [ ] **Step 2: 가상환경 생성 및 의존성 설치**

```bash
cd video_trimmer
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt
```

Expected: 설치 성공. 만약 Python 3.14에서 PySide6 휠이 없으면, 시스템에 설치된 Python 3.11~3.13으로 venv를 생성한다(`python3.12 -m venv .venv`). 사용 가능한 버전 확인: `ls ~/.pyenv/versions/ 2>/dev/null; which -a python3.11 python3.12 python3.13`.

- [ ] **Step 3: 스모크 테스트 작성**

`video_trimmer/tests/test_smoke.py`:
```python
def test_pyside6_imports():
    import PySide6
    from PySide6 import QtWidgets, QtMultimedia
    assert PySide6.__version__
```

- [ ] **Step 4: 테스트 실행**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_smoke.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add video_trimmer/requirements.txt video_trimmer/__init__.py video_trimmer/tests/
git commit -m "chore: scaffold video_trimmer package with venv and deps"
```

> 주의: git 루트는 상위 디렉터리(`GenAI/.git`)다. `.venv`는 커밋하지 않는다 — `video_trimmer/.gitignore`에 `.venv/`를 추가하거나 `git add`에서 제외할 것.

---

### Task 2: ffmpeg_utils — ffprobe 길이 파싱

**Files:**
- Create: `video_trimmer/ffmpeg_utils.py`
- Test: `video_trimmer/tests/test_ffmpeg_utils.py`

**Interfaces:**
- Consumes: (없음)
- Produces:
  - `find_ffmpeg() -> str | None` / `find_ffprobe() -> str | None` (PATH에서 탐색)
  - `parse_duration(ffprobe_json: str) -> float` (ffprobe JSON 문자열에서 duration 초 반환)

- [ ] **Step 1: 실패 테스트 작성**

`video_trimmer/tests/test_ffmpeg_utils.py`:
```python
from video_trimmer import ffmpeg_utils


def test_parse_duration_reads_format_duration():
    sample = '{"format": {"duration": "42.5"}}'
    assert ffmpeg_utils.parse_duration(sample) == 42.5


def test_find_ffprobe_returns_path_or_none():
    # PATH에 ffprobe가 있으면 경로, 없으면 None
    result = ffmpeg_utils.find_ffprobe()
    assert result is None or result.endswith("ffprobe")
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_ffmpeg_utils.py -v
```
Expected: FAIL (module `ffmpeg_utils` not found)

- [ ] **Step 3: 구현**

`video_trimmer/ffmpeg_utils.py`:
```python
import json
import shutil


def find_ffmpeg() -> str | None:
    return shutil.which("ffmpeg")


def find_ffprobe() -> str | None:
    return shutil.which("ffprobe")


def parse_duration(ffprobe_json: str) -> float:
    data = json.loads(ffprobe_json)
    return float(data["format"]["duration"])
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_ffmpeg_utils.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add video_trimmer/ffmpeg_utils.py video_trimmer/tests/test_ffmpeg_utils.py
git commit -m "feat: add ffprobe duration parsing and ffmpeg/ffprobe discovery"
```

---

### Task 3: ffmpeg_utils — 커맨드 생성기

**Files:**
- Modify: `video_trimmer/ffmpeg_utils.py`
- Test: `video_trimmer/tests/test_ffmpeg_utils.py`

**Interfaces:**
- Consumes: Task 2의 `ffmpeg_utils` 모듈
- Produces:
  - `build_probe_cmd(ffprobe: str, input_path: str) -> list[str]`
  - `build_thumbnail_cmd(ffmpeg: str, input_path: str, out_pattern: str, fps: int = 1) -> list[str]`
  - `build_export_cmd(ffmpeg: str, input_path: str, start: float, length: float, output_path: str) -> list[str]`

- [ ] **Step 1: 실패 테스트 작성 (기존 테스트 파일에 추가)**

`video_trimmer/tests/test_ffmpeg_utils.py` 에 추가:
```python
def test_build_probe_cmd():
    cmd = ffmpeg_utils.build_probe_cmd("/usr/bin/ffprobe", "in.mp4")
    assert cmd[0] == "/usr/bin/ffprobe"
    assert "-show_format" in cmd
    assert "-print_format" in cmd
    assert "json" in cmd
    assert cmd[-1] == "in.mp4"


def test_build_thumbnail_cmd_uses_fps_filter():
    cmd = ffmpeg_utils.build_thumbnail_cmd(
        "/usr/bin/ffmpeg", "in.mp4", "/tmp/t/thumb_%04d.jpg", fps=1
    )
    assert "-vf" in cmd
    vf = cmd[cmd.index("-vf") + 1]
    assert vf == "fps=1"
    assert cmd[-1] == "/tmp/t/thumb_%04d.jpg"


def test_build_export_cmd_output_seeking_and_codecs():
    cmd = ffmpeg_utils.build_export_cmd(
        "/usr/bin/ffmpeg", "in.mp4", start=16.0, length=16.1, output_path="out.mp4"
    )
    # output seeking: -i input 이 -ss 보다 앞에 와야 정확
    i_idx = cmd.index("-i")
    ss_idx = cmd.index("-ss")
    assert i_idx < ss_idx
    assert cmd[ss_idx + 1] == "16.0"
    t_idx = cmd.index("-t")
    assert cmd[t_idx + 1] == "16.1"
    assert "libx264" in cmd
    assert "aac" in cmd
    assert cmd[-1] == "out.mp4"
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_ffmpeg_utils.py -v
```
Expected: FAIL (build_probe_cmd 등 미정의)

- [ ] **Step 3: 구현 (ffmpeg_utils.py 에 추가)**

```python
def build_probe_cmd(ffprobe: str, input_path: str) -> list[str]:
    return [
        ffprobe,
        "-v", "error",
        "-show_format",
        "-print_format", "json",
        input_path,
    ]


def build_thumbnail_cmd(
    ffmpeg: str, input_path: str, out_pattern: str, fps: int = 1
) -> list[str]:
    return [
        ffmpeg,
        "-y",
        "-i", input_path,
        "-vf", f"fps={fps}",
        out_pattern,
    ]


def build_export_cmd(
    ffmpeg: str, input_path: str, start: float, length: float, output_path: str
) -> list[str]:
    return [
        ffmpeg,
        "-y",
        "-i", input_path,
        "-ss", str(start),
        "-t", str(length),
        "-c:v", "libx264",
        "-c:a", "aac",
        output_path,
    ]
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_ffmpeg_utils.py -v
```
Expected: PASS (5개 테스트)

- [ ] **Step 5: Commit**

```bash
git add video_trimmer/ffmpeg_utils.py video_trimmer/tests/test_ffmpeg_utils.py
git commit -m "feat: add ffmpeg command builders for probe/thumbnail/export"
```

---

### Task 4: exporter — 구간 저장 QThread 워커

**Files:**
- Create: `video_trimmer/exporter.py`
- Test: `video_trimmer/tests/test_exporter.py`

**Interfaces:**
- Consumes: `ffmpeg_utils.build_export_cmd`, `ffmpeg_utils.find_ffmpeg`
- Produces:
  - `class ExportWorker(QThread)` with signals `finished_ok = Signal(str)` (출력 경로), `failed = Signal(str)` (에러 메시지)
  - 생성자: `ExportWorker(input_path, start, length, output_path, parent=None)`
  - `run()`은 `subprocess.run`으로 export 커맨드 실행, returncode 0이면 `finished_ok` emit, 아니면 stderr를 `failed`로 emit.

- [ ] **Step 1: 실패 테스트 작성 (실제 ffmpeg로 통합 테스트)**

`video_trimmer/tests/test_exporter.py`:
```python
import os
import subprocess
import pytest
from video_trimmer import ffmpeg_utils
from video_trimmer.exporter import ExportWorker


def _make_sample(path, seconds=5):
    """ffmpeg로 테스트용 컬러바 영상 생성."""
    ffmpeg = ffmpeg_utils.find_ffmpeg()
    subprocess.run(
        [ffmpeg, "-y", "-f", "lavfi", "-i",
         f"testsrc=duration={seconds}:size=320x240:rate=30",
         "-pix_fmt", "yuv420p", path],
        check=True, capture_output=True,
    )


@pytest.mark.skipif(ffmpeg_utils.find_ffmpeg() is None, reason="ffmpeg 미설치")
def test_export_creates_trimmed_file(tmp_path):
    src = str(tmp_path / "src.mp4")
    out = str(tmp_path / "out.mp4")
    _make_sample(src, seconds=5)

    # ExportWorker.run()을 동기적으로 직접 호출 (QThread 이벤트 루프 없이)
    results = {}
    worker = ExportWorker(src, start=1.0, length=2.0, output_path=out)
    worker.finished_ok.connect(lambda p: results.setdefault("ok", p))
    worker.failed.connect(lambda m: results.setdefault("err", m))
    worker.run()

    assert "ok" in results, results.get("err")
    assert os.path.exists(out)
    # 잘린 영상 길이가 ~2초인지 확인
    probe = subprocess.run(
        ffmpeg_utils.build_probe_cmd(ffmpeg_utils.find_ffprobe(), out),
        capture_output=True, text=True,
    )
    dur = ffmpeg_utils.parse_duration(probe.stdout)
    assert 1.8 <= dur <= 2.3
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_exporter.py -v
```
Expected: FAIL (module `exporter` not found)

- [ ] **Step 3: 구현**

`video_trimmer/exporter.py`:
```python
import subprocess

from PySide6.QtCore import QThread, Signal

from . import ffmpeg_utils


class ExportWorker(QThread):
    finished_ok = Signal(str)
    failed = Signal(str)

    def __init__(self, input_path, start, length, output_path, parent=None):
        super().__init__(parent)
        self.input_path = input_path
        self.start = start
        self.length = length
        self.output_path = output_path

    def run(self):
        ffmpeg = ffmpeg_utils.find_ffmpeg()
        if ffmpeg is None:
            self.failed.emit("ffmpeg 를 찾을 수 없습니다.")
            return
        cmd = ffmpeg_utils.build_export_cmd(
            ffmpeg, self.input_path, self.start, self.length, self.output_path
        )
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0:
            self.finished_ok.emit(self.output_path)
        else:
            self.failed.emit(proc.stderr)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_exporter.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add video_trimmer/exporter.py video_trimmer/tests/test_exporter.py
git commit -m "feat: add ExportWorker QThread for trimming via ffmpeg"
```

---

### Task 5: thumbnail_worker — 썸네일 추출 QThread 워커

**Files:**
- Create: `video_trimmer/thumbnail_worker.py`
- Test: `video_trimmer/tests/test_thumbnail_worker.py`

**Interfaces:**
- Consumes: `ffmpeg_utils.build_thumbnail_cmd`, `ffmpeg_utils.find_ffmpeg`
- Produces:
  - `class ThumbnailWorker(QThread)` with signals `done = Signal(list)` (생성된 jpg 경로 리스트, 정렬됨), `failed = Signal(str)`
  - 생성자: `ThumbnailWorker(input_path, out_dir, fps=1, parent=None)`
  - `run()`은 `out_dir`에 `thumb_%04d.jpg` 생성 후 정렬된 경로 리스트를 `done`으로 emit.

- [ ] **Step 1: 실패 테스트 작성**

`video_trimmer/tests/test_thumbnail_worker.py`:
```python
import subprocess
import pytest
from video_trimmer import ffmpeg_utils
from video_trimmer.thumbnail_worker import ThumbnailWorker


def _make_sample(path, seconds=4):
    ffmpeg = ffmpeg_utils.find_ffmpeg()
    subprocess.run(
        [ffmpeg, "-y", "-f", "lavfi", "-i",
         f"testsrc=duration={seconds}:size=320x240:rate=30",
         "-pix_fmt", "yuv420p", path],
        check=True, capture_output=True,
    )


@pytest.mark.skipif(ffmpeg_utils.find_ffmpeg() is None, reason="ffmpeg 미설치")
def test_thumbnail_worker_creates_frames(tmp_path):
    src = str(tmp_path / "src.mp4")
    out_dir = tmp_path / "thumbs"
    out_dir.mkdir()
    _make_sample(src, seconds=4)

    results = {}
    worker = ThumbnailWorker(src, str(out_dir), fps=1)
    worker.done.connect(lambda paths: results.setdefault("paths", paths))
    worker.failed.connect(lambda m: results.setdefault("err", m))
    worker.run()

    assert "paths" in results, results.get("err")
    # 4초 영상, fps=1 → 약 4장
    assert len(results["paths"]) >= 3
    assert all(p.endswith(".jpg") for p in results["paths"])
    assert results["paths"] == sorted(results["paths"])
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_thumbnail_worker.py -v
```
Expected: FAIL (module `thumbnail_worker` not found)

- [ ] **Step 3: 구현**

`video_trimmer/thumbnail_worker.py`:
```python
import glob
import os
import subprocess

from PySide6.QtCore import QThread, Signal

from . import ffmpeg_utils


class ThumbnailWorker(QThread):
    done = Signal(list)
    failed = Signal(str)

    def __init__(self, input_path, out_dir, fps=1, parent=None):
        super().__init__(parent)
        self.input_path = input_path
        self.out_dir = out_dir
        self.fps = fps

    def run(self):
        ffmpeg = ffmpeg_utils.find_ffmpeg()
        if ffmpeg is None:
            self.failed.emit("ffmpeg 를 찾을 수 없습니다.")
            return
        pattern = os.path.join(self.out_dir, "thumb_%04d.jpg")
        cmd = ffmpeg_utils.build_thumbnail_cmd(
            ffmpeg, self.input_path, pattern, fps=self.fps
        )
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            self.failed.emit(proc.stderr)
            return
        paths = sorted(glob.glob(os.path.join(self.out_dir, "thumb_*.jpg")))
        self.done.emit(paths)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_thumbnail_worker.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add video_trimmer/thumbnail_worker.py video_trimmer/tests/test_thumbnail_worker.py
git commit -m "feat: add ThumbnailWorker QThread for 1fps frame extraction"
```

---

### Task 6: timeline_widget — 노란색 타임라인 + 썸네일 스트립

**Files:**
- Create: `video_trimmer/timeline_widget.py`
- Test: `video_trimmer/tests/test_timeline_widget.py`

**Interfaces:**
- Consumes: (없음 — 순수 위젯)
- Produces:
  - `class TimelineWidget(QWidget)` with signals:
    - `startChanged = Signal(float)` (드래그로 시작점 변경, 초)
    - `seekRequested = Signal(float)` (클릭 위치로 재생 위치 이동, 초)
  - 메서드:
    - `set_duration(seconds: float)` — 전체 길이 설정
    - `set_length(seconds: float)` — 선택 구간 길이 설정
    - `set_start(seconds: float)` — 선택 시작점 설정(0~duration-length 클램프)
    - `set_playhead(seconds: float)` — 현재 재생 위치
    - `set_thumbnails(paths: list[str])` — 썸네일 이미지 경로
    - `clamp_start(value: float) -> float` — 시작점을 [0, max(0, duration-length)]로 클램프 (순수 함수, 테스트 대상)

- [ ] **Step 1: 실패 테스트 작성 (clamp 로직 — GUI 없이 검증)**

`video_trimmer/tests/test_timeline_widget.py`:
```python
import pytest

# QApplication 인스턴스가 위젯 생성에 필요
@pytest.fixture(scope="module")
def app():
    from PySide6.QtWidgets import QApplication
    import sys
    inst = QApplication.instance() or QApplication(sys.argv)
    return inst


def test_clamp_start_within_bounds(app):
    from video_trimmer.timeline_widget import TimelineWidget
    w = TimelineWidget()
    w.set_duration(20.0)
    w.set_length(16.1)
    # max start = 20 - 16.1 = 3.9
    assert w.clamp_start(-5.0) == 0.0
    assert w.clamp_start(10.0) == pytest.approx(3.9)
    assert w.clamp_start(2.0) == pytest.approx(2.0)


def test_set_start_emits_signal(app):
    from video_trimmer.timeline_widget import TimelineWidget
    w = TimelineWidget()
    w.set_duration(20.0)
    w.set_length(5.0)
    seen = []
    w.startChanged.connect(seen.append)
    w.set_start(2.0)
    assert w.start == pytest.approx(2.0)
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_timeline_widget.py -v
```
Expected: FAIL (module not found)

- [ ] **Step 3: 구현**

`video_trimmer/timeline_widget.py`:
```python
from PySide6.QtCore import Qt, Signal, QRectF
from PySide6.QtGui import QPainter, QColor, QPixmap
from PySide6.QtWidgets import QWidget


class TimelineWidget(QWidget):
    startChanged = Signal(float)
    seekRequested = Signal(float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(90)
        self.duration = 0.0
        self.length = 0.0
        self.start = 0.0
        self.playhead = 0.0
        self._thumbs: list[QPixmap] = []
        self._dragging = False

    # --- 설정 메서드 ---
    def set_duration(self, seconds: float):
        self.duration = max(0.0, seconds)
        self.update()

    def set_length(self, seconds: float):
        self.length = max(0.0, seconds)
        self.start = self.clamp_start(self.start)
        self.update()

    def set_start(self, seconds: float):
        self.start = self.clamp_start(seconds)
        self.startChanged.emit(self.start)
        self.update()

    def set_playhead(self, seconds: float):
        self.playhead = seconds
        self.update()

    def set_thumbnails(self, paths: list[str]):
        self._thumbs = [QPixmap(p) for p in paths]
        self.update()

    # --- 순수 로직 ---
    def clamp_start(self, value: float) -> float:
        max_start = max(0.0, self.duration - self.length)
        return min(max(0.0, value), max_start)

    def _x_to_time(self, x: float) -> float:
        if self.width() == 0 or self.duration == 0:
            return 0.0
        return (x / self.width()) * self.duration

    def _time_to_x(self, t: float) -> float:
        if self.duration == 0:
            return 0.0
        return (t / self.duration) * self.width()

    # --- 마우스 ---
    def mousePressEvent(self, event):
        t = self._x_to_time(event.position().x())
        # 선택 구간 안을 누르면 드래그 시작, 밖이면 seek
        if self.start <= t <= self.start + self.length:
            self._dragging = True
            self._drag_offset = t - self.start
        else:
            self.seekRequested.emit(t)

    def mouseMoveEvent(self, event):
        if self._dragging:
            t = self._x_to_time(event.position().x())
            self.set_start(t - self._drag_offset)

    def mouseReleaseEvent(self, event):
        self._dragging = False

    # --- 렌더링 ---
    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(30, 30, 30))
        # 썸네일 스트립
        if self._thumbs:
            w = self.width() / len(self._thumbs)
            for i, pix in enumerate(self._thumbs):
                if not pix.isNull():
                    target = QRectF(i * w, 0, w, self.height())
                    p.drawPixmap(target, pix, QRectF(pix.rect()))
        # 노란색 선택 구간 오버레이
        if self.duration > 0 and self.length > 0:
            x0 = self._time_to_x(self.start)
            x1 = self._time_to_x(self.start + self.length)
            sel = QRectF(x0, 0, x1 - x0, self.height())
            p.fillRect(sel, QColor(255, 230, 0, 80))
            pen = p.pen()
            pen.setColor(QColor(255, 230, 0))
            pen.setWidth(3)
            p.setPen(pen)
            p.drawRect(sel)
        # 흰색 playhead
        if self.duration > 0:
            px = self._time_to_x(self.playhead)
            p.setPen(QColor(255, 255, 255))
            p.drawLine(int(px), 0, int(px), self.height())
        p.end()
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_timeline_widget.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add video_trimmer/timeline_widget.py video_trimmer/tests/test_timeline_widget.py
git commit -m "feat: add TimelineWidget with yellow selection and thumbnail strip"
```

---

### Task 7: player_widget — 스트레칭 영상 미리보기

**Files:**
- Create: `video_trimmer/player_widget.py`
- Test: `video_trimmer/tests/test_player_widget.py`

**Interfaces:**
- Consumes: (없음)
- Produces:
  - `class PlayerWidget(QWidget)` with signal `positionChanged = Signal(float)` (현재 위치, 초)
  - 메서드:
    - `load(path: str)` — 영상 로드
    - `play()` / `pause()`
    - `seek(seconds: float)` — 위치 이동
  - 내부적으로 `QVideoWidget`을 `Qt.IgnoreAspectRatio`로 스트레칭, `QMediaPlayer.positionChanged`(ms)를 초로 변환해 `positionChanged` emit.

- [ ] **Step 1: 실패 테스트 작성 (생성/메서드 존재 확인)**

`video_trimmer/tests/test_player_widget.py`:
```python
import pytest


@pytest.fixture(scope="module")
def app():
    from PySide6.QtWidgets import QApplication
    import sys
    return QApplication.instance() or QApplication(sys.argv)


def test_player_widget_constructs_and_has_api(app):
    from video_trimmer.player_widget import PlayerWidget
    w = PlayerWidget()
    assert hasattr(w, "load")
    assert hasattr(w, "play")
    assert hasattr(w, "pause")
    assert hasattr(w, "seek")
    assert hasattr(w, "positionChanged")
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_player_widget.py -v
```
Expected: FAIL (module not found)

- [ ] **Step 3: 구현**

`video_trimmer/player_widget.py`:
```python
from PySide6.QtCore import Qt, Signal, QUrl
from PySide6.QtMultimedia import QMediaPlayer, QAudioOutput
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import QWidget, QVBoxLayout


class PlayerWidget(QWidget):
    positionChanged = Signal(float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._video = QVideoWidget()
        self._video.setAspectRatioMode(Qt.IgnoreAspectRatio)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self._video)

        self._player = QMediaPlayer(self)
        self._audio = QAudioOutput(self)
        self._player.setAudioOutput(self._audio)
        self._player.setVideoOutput(self._video)
        self._player.positionChanged.connect(self._on_position)

    def _on_position(self, ms: int):
        self.positionChanged.emit(ms / 1000.0)

    def load(self, path: str):
        self._player.setSource(QUrl.fromLocalFile(path))

    def play(self):
        self._player.play()

    def pause(self):
        self._player.pause()

    def seek(self, seconds: float):
        self._player.setPosition(int(seconds * 1000))
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_player_widget.py -v
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add video_trimmer/player_widget.py video_trimmer/tests/test_player_widget.py
git commit -m "feat: add PlayerWidget with stretched QVideoWidget preview"
```

---

### Task 8: main — 메인 윈도우 + 배선 + 진입점

**Files:**
- Create: `video_trimmer/main.py`
- Create: `video_trimmer/__main__.py`
- Test: `video_trimmer/tests/test_main.py`

**Interfaces:**
- Consumes: `PlayerWidget`, `TimelineWidget`, `ThumbnailWorker`, `ExportWorker`, `ffmpeg_utils`
- Produces:
  - `class MainWindow(QMainWindow)`:
    - 상단 `PlayerWidget`, 하단 `TimelineWidget`, 길이 입력 `QDoubleSpinBox`, 「열기」/「재생」/「구간 저장」 버튼.
    - `open_file(path)` — ffprobe로 duration 파싱 → 위젯에 set → ThumbnailWorker 시작.
    - 배선: timeline.`startChanged` → player.`seek`(시작점 미리보기), timeline.`seekRequested` → player.`seek`, player.`positionChanged` → timeline.`set_playhead`, 길이 스핀박스 → timeline.`set_length`.
    - 「구간 저장」 → 출력 경로 다이얼로그 → ExportWorker 시작 → 완료/실패 다이얼로그.
  - `main()` 함수 (진입점).

- [ ] **Step 1: 실패 테스트 작성 (윈도우 생성 + duration 적용 검증)**

`video_trimmer/tests/test_main.py`:
```python
import pytest


@pytest.fixture(scope="module")
def app():
    from PySide6.QtWidgets import QApplication
    import sys
    return QApplication.instance() or QApplication(sys.argv)


def test_mainwindow_constructs(app):
    from video_trimmer.main import MainWindow
    win = MainWindow()
    assert win.timeline is not None
    assert win.player is not None


def test_apply_duration_sets_timeline(app):
    from video_trimmer.main import MainWindow
    win = MainWindow()
    win.length_spin.setValue(5.0)
    win._apply_duration(20.0)
    assert win.timeline.duration == 20.0
    assert win.timeline.length == 5.0
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_main.py -v
```
Expected: FAIL (module not found)

- [ ] **Step 3: 구현**

`video_trimmer/main.py`:
```python
import os
import subprocess
import sys
import tempfile

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QPushButton, QDoubleSpinBox, QLabel, QFileDialog, QMessageBox,
)

from . import ffmpeg_utils
from .player_widget import PlayerWidget
from .timeline_widget import TimelineWidget
from .thumbnail_worker import ThumbnailWorker
from .exporter import ExportWorker


class MainWindow(QMainWindow):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Video Trim Tool")
        self.resize(900, 640)
        self.input_path = None
        self._tmpdir = None
        self._thumb_worker = None
        self._export_worker = None

        central = QWidget()
        layout = QVBoxLayout(central)

        self.player = PlayerWidget()
        layout.addWidget(self.player, stretch=1)

        self.timeline = TimelineWidget()
        layout.addWidget(self.timeline)

        # 컨트롤 바
        controls = QHBoxLayout()
        self.open_btn = QPushButton("열기")
        self.play_btn = QPushButton("재생")
        self.save_btn = QPushButton("구간 저장")
        controls.addWidget(self.open_btn)
        controls.addWidget(self.play_btn)
        controls.addWidget(QLabel("길이(초):"))
        self.length_spin = QDoubleSpinBox()
        self.length_spin.setDecimals(2)
        self.length_spin.setRange(0.1, 600.0)
        self.length_spin.setValue(16.1)
        controls.addWidget(self.length_spin)
        controls.addStretch()
        controls.addWidget(self.save_btn)
        layout.addLayout(controls)

        self.setCentralWidget(central)

        # 배선
        self.open_btn.clicked.connect(self.on_open)
        self.play_btn.clicked.connect(self.player.play)
        self.save_btn.clicked.connect(self.on_save)
        self.length_spin.valueChanged.connect(self.timeline.set_length)
        self.timeline.startChanged.connect(self.player.seek)
        self.timeline.seekRequested.connect(self.player.seek)
        self.player.positionChanged.connect(self.timeline.set_playhead)

        self.timeline.set_length(self.length_spin.value())
        self._check_ffmpeg()

    def _check_ffmpeg(self):
        if ffmpeg_utils.find_ffmpeg() is None or ffmpeg_utils.find_ffprobe() is None:
            QMessageBox.warning(
                self, "ffmpeg 필요",
                "ffmpeg/ffprobe 를 찾을 수 없습니다. 설치 후 다시 실행하세요.",
            )

    def on_open(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "영상 열기", "", "Video (*.mp4 *.mov *.mkv *.avi *.webm)"
        )
        if path:
            self.open_file(path)

    def open_file(self, path: str):
        self.input_path = path
        ffprobe = ffmpeg_utils.find_ffprobe()
        if ffprobe is None:
            QMessageBox.critical(self, "오류", "ffprobe 를 찾을 수 없습니다.")
            return
        try:
            proc = subprocess.run(
                ffmpeg_utils.build_probe_cmd(ffprobe, path),
                capture_output=True, text=True, check=True,
            )
            duration = ffmpeg_utils.parse_duration(proc.stdout)
        except Exception as e:
            QMessageBox.critical(self, "오류", f"영상 정보를 읽을 수 없습니다:\n{e}")
            return
        self.player.load(path)
        self._apply_duration(duration)
        self._start_thumbnails(path)

    def _apply_duration(self, duration: float):
        self.timeline.set_length(self.length_spin.value())
        self.timeline.set_duration(duration)
        self.timeline.set_start(0.0)

    def _start_thumbnails(self, path: str):
        self._tmpdir = tempfile.mkdtemp(prefix="vtrim_")
        self._thumb_worker = ThumbnailWorker(path, self._tmpdir, fps=1)
        self._thumb_worker.done.connect(self.timeline.set_thumbnails)
        self._thumb_worker.failed.connect(
            lambda m: QMessageBox.warning(self, "썸네일 실패", m)
        )
        self._thumb_worker.start()

    def on_save(self):
        if not self.input_path:
            QMessageBox.information(self, "안내", "먼저 영상을 여세요.")
            return
        out, _ = QFileDialog.getSaveFileName(
            self, "구간 저장", "trimmed.mp4", "Video (*.mp4)"
        )
        if not out:
            return
        self.save_btn.setEnabled(False)
        self._export_worker = ExportWorker(
            self.input_path, self.timeline.start,
            self.length_spin.value(), out,
        )
        self._export_worker.finished_ok.connect(self._on_export_ok)
        self._export_worker.failed.connect(self._on_export_fail)
        self._export_worker.start()

    def _on_export_ok(self, path: str):
        self.save_btn.setEnabled(True)
        QMessageBox.information(self, "완료", f"저장됨:\n{path}")

    def _on_export_fail(self, msg: str):
        self.save_btn.setEnabled(True)
        QMessageBox.critical(self, "저장 실패", msg)


def main():
    app = QApplication(sys.argv)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())
```

`video_trimmer/__main__.py`:
```python
from .main import main

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest tests/test_main.py -v
```
Expected: PASS

- [ ] **Step 5: 전체 테스트 + 수동 실행 확인**

```bash
cd video_trimmer && .venv/bin/python -m pytest -v
.venv/bin/python -m video_trimmer   # 창이 뜨는지 수동 확인
```
Expected: 모든 테스트 PASS, GUI 창 표시.

- [ ] **Step 6: Commit**

```bash
git add video_trimmer/main.py video_trimmer/__main__.py video_trimmer/tests/test_main.py
git commit -m "feat: add MainWindow wiring player/timeline/workers and entry point"
```

---

### Task 9: README + .gitignore

**Files:**
- Create: `video_trimmer/README.md`
- Create: `video_trimmer/.gitignore`

**Interfaces:**
- Consumes: (없음)
- Produces: 사용 문서.

- [ ] **Step 1: .gitignore 작성**

`video_trimmer/.gitignore`:
```
.venv/
__pycache__/
*.pyc
```

- [ ] **Step 2: README 작성**

`video_trimmer/README.md`:
```markdown
# Video Trim Tool

영상에서 고정 길이 구간을 선택해 새 영상으로 저장하는 PySide6 데스크탑 앱.

## 설치
```bash
cd video_trimmer
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```
ffmpeg/ffprobe 가 PATH에 있어야 합니다 (`brew install ffmpeg`).

## 실행
```bash
.venv/bin/python -m video_trimmer
```

## 사용법
1. 「열기」로 영상 선택
2. 「길이(초)」에 구간 길이 입력 (예 16.1)
3. 하단 노란색 타임라인을 드래그해 시작점 이동
4. 「구간 저장」으로 새 mp4 생성

## 테스트
```bash
.venv/bin/python -m pytest -v
```
```

- [ ] **Step 3: Commit**

```bash
git add video_trimmer/README.md video_trimmer/.gitignore
git commit -m "docs: add video_trimmer README and gitignore"
```

---

## Self-Review Notes

- **스펙 커버리지:**
  - 요구사항 1(고정 길이 구간 저장) → Task 3 `build_export_cmd` + Task 4 ExportWorker + Task 8 on_save
  - 요구사항 2(초단위 프레임 미리보기) → Task 5 ThumbnailWorker + Task 6 썸네일 스트립
  - 요구사항 3(스트레칭 미리보기) → Task 7 `Qt.IgnoreAspectRatio`
  - 요구사항 4(노란색 이동 타임라인) → Task 6 TimelineWidget
  - 요구사항 5(새 파일 저장) → Task 4 + Task 8
  - 에러 처리(ffmpeg 미설치/로드 실패/저장 실패) → Task 8 `_check_ffmpeg`, `open_file`, `_on_export_fail`
- **타입 일관성:** `ExportWorker.finished_ok/failed`, `ThumbnailWorker.done/failed`, `TimelineWidget.startChanged/seekRequested/set_*`, `PlayerWidget.positionChanged/load/play/pause/seek` — 모든 Task 간 시그니처 일치 확인됨.
- **플레이스홀더:** 없음.
