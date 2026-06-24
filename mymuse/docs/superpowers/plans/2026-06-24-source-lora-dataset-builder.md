# source → lora 데이터셋 빌더 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `source/<model>/<person>/` 의 원본 사진을 `lora/<model>/<person>/dataset/`에 ai-toolkit 규격(jpg+txt 페어)으로 증분 변환하고, 같은 디렉토리에 Z-Image-Turbo LoRA 학습용 YAML config를 매 실행마다 갱신하는 CLI 도구를 만든다.

**Architecture:** `prepare_dataset.py`가 5개의 독립 모듈(scanner, face_processor, captioner, dataset_builder, config_generator)을 순서대로 호출한다. 각 모듈은 단일 책임을 가지며 순수 함수/작은 클래스로 구성해 모킹 없이 단위 테스트 가능하게 한다. 증분 처리는 출력 디렉토리에 이미 존재하는 `.jpg` stem과 비교해 신규 이미지만 골라내는 방식으로 구현한다(별도 manifest 파일 없음).

**Tech Stack:** Python 3.12, OpenCV, Pillow, InsightFace(CPU), PyYAML, pytest.

## Global Constraints

- 캡션은 `simple` 고정: `"{trigger_word}, photo of a person, natural lighting, sharp focus on face, portrait"` (Florence-2/manual 모드 없음)
- 얼굴 감지: InsightFace `buffalo_l` + `providers=["CPUExecutionProvider"]` 우선, `insightface` 미설치 시 OpenCV Haar Cascade로 자동 폴백
- 출력 파일명은 원본 파일명을 sanitize한 stem 사용 (순차 번호 금지) — 증분 추가 시 기존 파일을 절대 건드리지 않음
- YAML의 `datasets[0].folder_path`는 **로컬(Mac) 절대경로**를 그대로 기록 (원격 서버 경로 추정 안 함)
- `trigger_word` 기본값: `"quahand {person}"`, `lora_name` 기본값: `"{person}_zimage_lora"`
- 디렉토리 매핑: `source/<model>/<person>/` → 데이터셋 `lora/<model>/<person>/dataset/`, config `lora/<model>/<person>/<lora_name>.yaml`
- `/source/`, `/lora/`는 git에 커밋되지 않아야 함
- 학습은 별도 CUDA 서버에서 수행 — 이 코드는 전처리만 담당, 학습 실행 코드는 범위 밖

---

### Task 1: 프로젝트 골격 + scanner 모듈

**Files:**
- Create: `modules/__init__.py` (빈 파일)
- Create: `modules/scanner.py`
- Create: `tests/__init__.py` (빈 파일)
- Create: `tests/test_scanner.py`
- Create: `requirements.txt`
- Create: `requirements-dev.txt`
- Modify: `../.gitignore` (git 루트가 `mymuse/`의 상위 디렉토리이며, 이미 `prompts/instagram/users/` 같은 서브프로젝트별 항목을 담은 루트 `.gitignore`가 존재함 — 새 파일을 만들지 말고 여기에 섹션을 추가한다)

**주의:** 이 태스크의 모든 상대 경로(`modules/`, `tests/`, `requirements*.txt`)는 `mymuse/` 디렉토리 기준이다. `.gitignore`만 예외로, git 저장소 루트(`mymuse/`의 부모 디렉토리)에 있는 기존 파일을 수정한다.

**Interfaces:**
- Produces: `modules.scanner.sanitize_stem(name: str) -> str`
- Produces: `modules.scanner.ImageEntry` dataclass with fields `src_path: Path`, `stem: str`
- Produces: `modules.scanner.ImageScanner(source_dir: Path, dataset_dir: Path)` with method `scan_new() -> list[ImageEntry]`
- Produces: `modules.scanner.SUPPORTED_EXTS = {".jpg", ".jpeg", ".png"}`

- [ ] **Step 1: 디렉토리/패키지 골격 생성**

```bash
mkdir -p modules tests
touch modules/__init__.py tests/__init__.py
```

- [ ] **Step 2: requirements.txt / requirements-dev.txt / .gitignore 작성**

`requirements.txt`:
```txt
torch
opencv-python
Pillow
pyyaml
rich
tqdm
onnxruntime
insightface
```

`requirements-dev.txt`:
```txt
pytest
```

git 루트의 기존 `.gitignore` (`/Users/marantz/Sources/ZY_Tools/GenAI/.gitignore`) 끝에 추가:
```

# mymuse 데이터셋 작업 디렉토리 (repo 동기화 제외)
mymuse/source/
mymuse/lora/
```

- [ ] **Step 3: 의존성 설치**

```bash
pip3 install -r requirements-dev.txt
```

Expected: pytest가 설치됨 (다른 패키지는 Task 5에서 face_processor 작성 시 설치).

- [ ] **Step 4: scanner 테스트 작성 (실패 상태)**

`tests/test_scanner.py`:
```python
from pathlib import Path

import pytest
from PIL import Image

from modules.scanner import ImageEntry, ImageScanner, sanitize_stem


def test_sanitize_stem_lowercases_and_replaces_spaces():
    assert sanitize_stem("2026-06-14 184017 ZIT_0001") == "2026_06_14_184017_zit_0001"


def test_sanitize_stem_strips_leading_trailing_underscores():
    assert sanitize_stem("ZIT-121358_00008_") == "zit_121358_00008"


def _make_image(path: Path):
    Image.new("RGB", (4, 4), color="red").save(path)


def test_scan_new_returns_all_entries_when_dataset_empty(tmp_path):
    source_dir = tmp_path / "source"
    dataset_dir = tmp_path / "dataset"
    source_dir.mkdir()
    _make_image(source_dir / "photo one.png")
    _make_image(source_dir / "photo two.png")

    scanner = ImageScanner(source_dir, dataset_dir)
    entries = scanner.scan_new()

    assert {e.stem for e in entries} == {"photo_one", "photo_two"}
    assert all(isinstance(e, ImageEntry) for e in entries)


def test_scan_new_skips_entries_already_in_dataset(tmp_path):
    source_dir = tmp_path / "source"
    dataset_dir = tmp_path / "dataset"
    source_dir.mkdir()
    dataset_dir.mkdir()
    _make_image(source_dir / "photo one.png")
    _make_image(source_dir / "photo two.png")
    # "photo one" already processed
    (dataset_dir / "photo_one.jpg").write_bytes(b"fake")
    (dataset_dir / "photo_one.txt").write_text("caption")

    scanner = ImageScanner(source_dir, dataset_dir)
    entries = scanner.scan_new()

    assert [e.stem for e in entries] == ["photo_two"]


def test_scan_new_ignores_unsupported_extensions(tmp_path):
    source_dir = tmp_path / "source"
    dataset_dir = tmp_path / "dataset"
    source_dir.mkdir()
    _make_image(source_dir / "photo.png")
    (source_dir / "notes.txt").write_text("not an image")

    scanner = ImageScanner(source_dir, dataset_dir)
    entries = scanner.scan_new()

    assert [e.stem for e in entries] == ["photo"]


def test_scan_new_raises_when_source_dir_missing(tmp_path):
    scanner = ImageScanner(tmp_path / "missing", tmp_path / "dataset")
    with pytest.raises(FileNotFoundError):
        scanner.scan_new()
```

- [ ] **Step 5: 테스트 실행 → 실패 확인**

```bash
python3 -m pytest tests/test_scanner.py -v
```

Expected: FAIL (`ModuleNotFoundError: No module named 'modules.scanner'`)

- [ ] **Step 6: scanner.py 구현**

`modules/scanner.py`:
```python
"""Scan source/<model>/<person>/ directories and sanitize filenames into dataset-safe stems."""

import re
from dataclasses import dataclass
from pathlib import Path

SUPPORTED_EXTS = {".jpg", ".jpeg", ".png"}


@dataclass
class ImageEntry:
    src_path: Path
    stem: str


def sanitize_stem(name: str) -> str:
    lowered = name.lower()
    sanitized = re.sub(r"[^a-z0-9]+", "_", lowered)
    return sanitized.strip("_")


class ImageScanner:
    def __init__(self, source_dir: Path, dataset_dir: Path):
        self.source_dir = source_dir
        self.dataset_dir = dataset_dir

    def scan_new(self) -> list[ImageEntry]:
        if not self.source_dir.exists():
            raise FileNotFoundError(f"source directory not found: {self.source_dir}")

        existing_stems = set()
        if self.dataset_dir.exists():
            existing_stems = {p.stem for p in self.dataset_dir.glob("*.jpg")}

        entries = []
        for path in sorted(self.source_dir.iterdir()):
            if path.suffix.lower() not in SUPPORTED_EXTS:
                continue
            stem = sanitize_stem(path.stem)
            if stem in existing_stems:
                continue
            entries.append(ImageEntry(src_path=path, stem=stem))
        return entries
```

- [ ] **Step 7: 테스트 실행 → 통과 확인**

```bash
python3 -m pytest tests/test_scanner.py -v
```

Expected: 6 passed

- [ ] **Step 8: 커밋**

```bash
git add modules/__init__.py modules/scanner.py tests/__init__.py tests/test_scanner.py requirements.txt requirements-dev.txt ../.gitignore
git commit -m "feat: add source scanner with incremental skip logic"
```

(CWD가 `mymuse/`이므로 `../.gitignore`는 git 루트의 기존 `.gitignore`를 가리킨다.)

---

### Task 2: captioner 모듈

**Files:**
- Create: `modules/captioner.py`
- Create: `tests/test_captioner.py`

**Interfaces:**
- Consumes: 없음 (순수 함수)
- Produces: `modules.captioner.build_caption(trigger_word: str) -> str`

- [ ] **Step 1: 테스트 작성**

`tests/test_captioner.py`:
```python
from modules.captioner import build_caption


def test_build_caption_starts_with_trigger_word():
    caption = build_caption("quahand sara")
    assert caption.startswith("quahand sara, ")


def test_build_caption_exact_format():
    assert build_caption("quahand sara") == (
        "quahand sara, photo of a person, natural lighting, sharp focus on face, portrait"
    )
```

- [ ] **Step 2: 테스트 실행 → 실패 확인**

```bash
python3 -m pytest tests/test_captioner.py -v
```

Expected: FAIL (`ModuleNotFoundError: No module named 'modules.captioner'`)

- [ ] **Step 3: captioner.py 구현**

`modules/captioner.py`:
```python
"""Build the fixed 'simple' caption used for Z-Image-Turbo face LoRA training."""


def build_caption(trigger_word: str) -> str:
    return f"{trigger_word}, photo of a person, natural lighting, sharp focus on face, portrait"
```

- [ ] **Step 4: 테스트 실행 → 통과 확인**

```bash
python3 -m pytest tests/test_captioner.py -v
```

Expected: 2 passed

- [ ] **Step 5: 커밋**

```bash
git add modules/captioner.py tests/test_captioner.py
git commit -m "feat: add fixed simple caption builder"
```

---

### Task 3: dataset_builder 모듈

**Files:**
- Create: `modules/dataset_builder.py`
- Create: `tests/test_dataset_builder.py`

**Interfaces:**
- Consumes: 없음 (PIL.Image만 사용)
- Produces: `modules.dataset_builder.ProcessedImage` dataclass with fields `src_path: Path`, `stem: str`, `pil_image: Image.Image`, `caption: str = ""`
- Produces: `modules.dataset_builder.DatasetBuilder(dataset_dir: Path)` with method `save(images: list[ProcessedImage]) -> tuple[int, int]` (반환값: `(saved, failed)`)

- [ ] **Step 1: 테스트 작성**

`tests/test_dataset_builder.py`:
```python
from pathlib import Path

from PIL import Image

from modules.dataset_builder import DatasetBuilder, ProcessedImage


def _processed(stem: str, caption: str = "caption text") -> ProcessedImage:
    img = Image.new("RGB", (8, 8), color="blue")
    return ProcessedImage(src_path=Path(f"/tmp/{stem}.png"), stem=stem, pil_image=img, caption=caption)


def test_save_writes_jpg_and_txt_pair(tmp_path):
    builder = DatasetBuilder(tmp_path / "dataset")
    saved, failed = builder.save([_processed("photo_one", "quahand sara, portrait")])

    assert saved == 1
    assert failed == 0
    assert (tmp_path / "dataset" / "photo_one.jpg").exists()
    assert (tmp_path / "dataset" / "photo_one.txt").read_text(encoding="utf-8") == "quahand sara, portrait"


def test_save_creates_dataset_dir_if_missing(tmp_path):
    dataset_dir = tmp_path / "nested" / "dataset"
    DatasetBuilder(dataset_dir)
    assert dataset_dir.exists()


def test_save_returns_zero_counts_for_empty_input(tmp_path):
    builder = DatasetBuilder(tmp_path / "dataset")
    saved, failed = builder.save([])
    assert (saved, failed) == (0, 0)


def test_save_multiple_images_counts_all(tmp_path):
    builder = DatasetBuilder(tmp_path / "dataset")
    images = [_processed("a"), _processed("b"), _processed("c")]
    saved, failed = builder.save(images)
    assert (saved, failed) == (3, 0)
```

- [ ] **Step 2: 테스트 실행 → 실패 확인**

```bash
python3 -m pytest tests/test_dataset_builder.py -v
```

Expected: FAIL (`ModuleNotFoundError: No module named 'modules.dataset_builder'`)

- [ ] **Step 3: dataset_builder.py 구현**

`modules/dataset_builder.py`:
```python
"""Persist processed images + captions as ai-toolkit image/caption pairs."""

from dataclasses import dataclass
from pathlib import Path

from PIL import Image


@dataclass
class ProcessedImage:
    src_path: Path
    stem: str
    pil_image: Image.Image
    caption: str = ""


class DatasetBuilder:
    def __init__(self, dataset_dir: Path):
        self.dataset_dir = dataset_dir
        self.dataset_dir.mkdir(parents=True, exist_ok=True)

    def save(self, images: list[ProcessedImage]) -> tuple[int, int]:
        saved = 0
        failed = 0
        for img in images:
            try:
                img_path = self.dataset_dir / f"{img.stem}.jpg"
                txt_path = self.dataset_dir / f"{img.stem}.txt"
                img.pil_image.convert("RGB").save(img_path, "JPEG", quality=95, subsampling=0)
                txt_path.write_text(img.caption, encoding="utf-8")
                saved += 1
            except Exception:
                failed += 1
        return saved, failed
```

- [ ] **Step 4: 테스트 실행 → 통과 확인**

```bash
python3 -m pytest tests/test_dataset_builder.py -v
```

Expected: 4 passed

- [ ] **Step 5: 커밋**

```bash
git add modules/dataset_builder.py tests/test_dataset_builder.py
git commit -m "feat: add dataset builder for image/caption pairs"
```

---

### Task 4: config_generator 모듈

**Files:**
- Create: `modules/config_generator.py`
- Create: `tests/test_config_generator.py`

**Interfaces:**
- Consumes: 없음
- Produces: `modules.config_generator.build_config(*, lora_name: str, trigger_word: str, dataset_dir: Path, lora_rank: int = 64, steps: int = 4000, target_resolution: int = 1024) -> dict`
- Produces: `modules.config_generator.save_config(output_path: Path, cfg: dict) -> None`

- [ ] **Step 1: 테스트 작성**

`tests/test_config_generator.py`:
```python
from pathlib import Path

import yaml

from modules.config_generator import build_config, save_config


def test_build_config_sets_trigger_word_and_rank():
    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("/tmp/dataset"),
        lora_rank=32,
        steps=3000,
        target_resolution=512,
    )
    process = cfg["config"]["process"][0]
    assert process["trigger_word"] == "quahand sara"
    assert process["network"]["linear"] == 32
    assert process["network"]["linear_alpha"] == 32
    assert process["train"]["steps"] == 3000
    assert process["sample"]["width"] == 512


def test_build_config_dataset_folder_path_is_absolute_string():
    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("relative/dataset"),
    )
    folder_path = cfg["config"]["process"][0]["datasets"][0]["folder_path"]
    assert Path(folder_path).is_absolute()


def test_build_config_uses_zimage_turbo_model_settings():
    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("/tmp/dataset"),
    )
    model = cfg["config"]["process"][0]["model"]
    assert model["name_or_path"] == "Tongyi-MAI/Z-Image-Turbo"
    assert model["arch"] == "zimage"


def test_save_config_writes_readable_yaml(tmp_path):
    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("/tmp/dataset"),
    )
    out_path = tmp_path / "sara_zimage_lora.yaml"
    save_config(out_path, cfg)

    loaded = yaml.safe_load(out_path.read_text(encoding="utf-8"))
    assert loaded["config"]["name"] == "sara_zimage_lora"
```

- [ ] **Step 2: 테스트 실행 → 실패 확인**

```bash
python3 -m pytest tests/test_config_generator.py -v
```

Expected: FAIL (`ModuleNotFoundError: No module named 'modules.config_generator'`)

- [ ] **Step 3: config_generator.py 구현**

`modules/config_generator.py`:
```python
"""Build and persist the ai-toolkit YAML training config for a Z-Image-Turbo face LoRA."""

from pathlib import Path

import yaml


def build_config(
    *,
    lora_name: str,
    trigger_word: str,
    dataset_dir: Path,
    lora_rank: int = 64,
    steps: int = 4000,
    target_resolution: int = 1024,
) -> dict:
    return {
        "job": "extension",
        "config": {
            "name": lora_name,
            "process": [{
                "type": "sd_trainer",
                "training_folder": "output",
                "device": "cuda:0",
                "trigger_word": trigger_word,
                "network": {
                    "type": "lora",
                    "linear": lora_rank,
                    "linear_alpha": lora_rank,
                },
                "save": {
                    "dtype": "float16",
                    "save_every": 250,
                    "max_step_saves_to_keep": 6,
                },
                "datasets": [{
                    "folder_path": str(dataset_dir.resolve()),
                    "caption_ext": "txt",
                    "caption_dropout_rate": 0.05,
                    "cache_latents_to_disk": True,
                    "resolution": [512, 768, target_resolution],
                }],
                "train": {
                    "batch_size": 1,
                    "steps": steps,
                    "gradient_accumulation_steps": 1,
                    "train_unet": True,
                    "train_text_encoder": False,
                    "gradient_checkpointing": True,
                    "noise_scheduler": "flowmatch",
                    "optimizer": "adamw8bit",
                    "lr": 0.0002,
                    "weight_decay": 0.0001,
                    "timestep_type": "sigmoid",
                },
                "model": {
                    "name_or_path": "Tongyi-MAI/Z-Image-Turbo",
                    "arch": "zimage",
                    "assistant_lora_path": (
                        "ostris/zimage_turbo_training_adapter/"
                        "zimage_turbo_training_adapterV2.safetensors"
                    ),
                    "quantize": True,
                },
                "sample": {
                    "sampler": "flowmatch",
                    "sample_every": 250,
                    "width": target_resolution,
                    "height": target_resolution,
                    "prompts": [
                        f"{trigger_word}, portrait photo, natural lighting, sharp focus",
                        f"{trigger_word}, outdoor photo, casual wear, smiling",
                        f"{trigger_word}, close-up face, studio lighting",
                    ],
                    "seed": 42,
                    "guidance_scale": 1,
                    "sample_steps": 8,
                },
            }],
        },
        "meta": {
            "name": "[name]",
            "version": "1.0",
        },
    }


def save_config(output_path: Path, cfg: dict) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        yaml.dump(cfg, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
```

- [ ] **Step 4: 테스트 실행 → 통과 확인**

```bash
python3 -m pytest tests/test_config_generator.py -v
```

Expected: 4 passed

- [ ] **Step 5: 커밋**

```bash
git add modules/config_generator.py tests/test_config_generator.py
git commit -m "feat: add ai-toolkit YAML config generator"
```

---

### Task 5: face_processor 모듈

**Files:**
- Create: `modules/face_processor.py`
- Create: `tests/test_face_processor.py`

**Interfaces:**
- Consumes: `modules.scanner.ImageEntry` (Task 1), `modules.dataset_builder.ProcessedImage` (Task 3)
- Produces: `modules.face_processor.FaceProcessor(min_face_size: int = 64, crop_padding: float = 1.8, target_resolution: int = 1024, face_filter: bool = True)` with method `process(entries: list[ImageEntry]) -> tuple[list[ProcessedImage], int]` (반환값: `(kept, skipped_count)`, `caption`은 빈 문자열로 둔 채 반환 — 캡션 부여는 CLI 단계 책임)

- [ ] **Step 1: pip install insightface 확인**

```bash
pip3 show insightface || pip3 install insightface
python3 -c "import insightface; print(insightface.__version__)"
```

Expected: 버전 문자열 출력 (이미 Task 1에서 requirements.txt에 추가했으므로 미설치 시 여기서 설치)

- [ ] **Step 2: 테스트 작성**

`tests/test_face_processor.py`:
```python
from pathlib import Path

from PIL import Image

from modules.face_processor import FaceProcessor
from modules.scanner import ImageEntry


def _save_blank_image(path: Path, size=(200, 200)):
    Image.new("RGB", size, color="black").save(path)


def test_face_aware_crop_returns_square_image():
    fp = FaceProcessor(target_resolution=64)
    img = Image.new("RGB", (300, 300), color="white")
    cropped = fp._face_aware_crop(img, (100, 100, 150, 150))
    assert cropped.width == cropped.height


def test_resize_square_outputs_target_resolution():
    fp = FaceProcessor(target_resolution=64)
    img = Image.new("RGB", (300, 200), color="white")
    resized = fp._resize_square(img)
    assert resized.size == (64, 64)


def test_opencv_detect_returns_none_on_blank_image():
    import cv2
    import numpy as np

    fp = FaceProcessor()
    blank = np.zeros((200, 200, 3), dtype=np.uint8)
    assert fp._opencv_detect(blank) is None


def test_process_with_face_filter_disabled_keeps_all_entries(tmp_path):
    img_path = tmp_path / "photo.png"
    _save_blank_image(img_path)
    entries = [ImageEntry(src_path=img_path, stem="photo")]

    fp = FaceProcessor(face_filter=False, target_resolution=32)
    processed, skipped = fp.process(entries)

    assert skipped == 0
    assert len(processed) == 1
    assert processed[0].stem == "photo"
    assert processed[0].pil_image.size == (32, 32)


def test_process_skips_unreadable_image(tmp_path):
    bad_path = tmp_path / "broken.png"
    bad_path.write_bytes(b"not a real png")
    entries = [ImageEntry(src_path=bad_path, stem="broken")]

    fp = FaceProcessor(face_filter=False)
    processed, skipped = fp.process(entries)

    assert processed == []
    assert skipped == 1
```

- [ ] **Step 3: 테스트 실행 → 실패 확인**

```bash
python3 -m pytest tests/test_face_processor.py -v
```

Expected: FAIL (`ModuleNotFoundError: No module named 'modules.face_processor'`)

- [ ] **Step 4: face_processor.py 구현**

`modules/face_processor.py`:
```python
"""Face detection (InsightFace CPU, OpenCV Haar Cascade fallback) and face-aware crop/resize."""

from typing import Optional

import cv2
from PIL import Image

from .dataset_builder import ProcessedImage
from .scanner import ImageEntry


class FaceProcessor:
    def __init__(
        self,
        min_face_size: int = 64,
        crop_padding: float = 1.8,
        target_resolution: int = 1024,
        face_filter: bool = True,
    ):
        self.min_face_size = min_face_size
        self.crop_padding = crop_padding
        self.target_resolution = target_resolution
        self.face_filter = face_filter
        self._app = None

    def process(self, entries: list[ImageEntry]) -> tuple[list[ProcessedImage], int]:
        if self.face_filter:
            self._load_model()

        results = []
        skipped = 0
        for entry in entries:
            img_bgr = cv2.imread(str(entry.src_path))
            if img_bgr is None:
                skipped += 1
                continue
            pil_img = Image.fromarray(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))

            if not self.face_filter:
                results.append(ProcessedImage(entry.src_path, entry.stem, self._resize_square(pil_img)))
                continue

            bbox = self._detect_primary_face(img_bgr)
            if bbox is None:
                skipped += 1
                continue

            x1, y1, x2, y2 = bbox
            if (x2 - x1) < self.min_face_size or (y2 - y1) < self.min_face_size:
                skipped += 1
                continue

            cropped = self._face_aware_crop(pil_img, bbox)
            results.append(ProcessedImage(entry.src_path, entry.stem, self._resize_square(cropped)))

        return results, skipped

    def _load_model(self):
        if self._app is not None:
            return
        try:
            from insightface.app import FaceAnalysis

            self._app = FaceAnalysis(name="buffalo_l", providers=["CPUExecutionProvider"])
            self._app.prepare(ctx_id=-1, det_size=(640, 640))
        except ImportError:
            self._app = "opencv_fallback"

    def _detect_primary_face(self, img_bgr) -> Optional[tuple]:
        if self._app == "opencv_fallback":
            return self._opencv_detect(img_bgr)
        faces = self._app.get(img_bgr)
        if not faces:
            return None
        bboxes = [tuple(map(int, f.bbox)) for f in faces]
        return max(bboxes, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]))

    def _opencv_detect(self, img_bgr) -> Optional[tuple]:
        gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
        cascade = cv2.CascadeClassifier(
            cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
        )
        faces = cascade.detectMultiScale(gray, 1.1, 5)
        if len(faces) == 0:
            return None
        bboxes = [(x, y, x + w, y + h) for x, y, w, h in faces]
        return max(bboxes, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]))

    def _face_aware_crop(self, pil_img: Image.Image, bbox: tuple) -> Image.Image:
        W, H = pil_img.size
        x1, y1, x2, y2 = bbox
        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
        crop_size = max(x2 - x1, y2 - y1) * self.crop_padding
        half = crop_size / 2

        top = max(0, int(cy - half))
        bottom = min(H, int(cy + half * 1.3))
        left = max(0, int(cx - half))
        right = min(W, int(cx + half))

        side = min(bottom - top, right - left)
        return pil_img.crop((left, top, left + side, top + side))

    def _resize_square(self, pil_img: Image.Image) -> Image.Image:
        return pil_img.resize((self.target_resolution, self.target_resolution), Image.LANCZOS)
```

- [ ] **Step 5: 테스트 실행 → 통과 확인**

```bash
python3 -m pytest tests/test_face_processor.py -v
```

Expected: 5 passed

- [ ] **Step 6: 커밋**

```bash
git add modules/face_processor.py tests/test_face_processor.py requirements.txt
git commit -m "feat: add InsightFace/OpenCV face detection and crop pipeline"
```

---

### Task 6: CLI 진입점 (prepare_dataset.py)

**Files:**
- Create: `prepare_dataset.py`
- Create: `tests/test_prepare_dataset.py`

**Interfaces:**
- Consumes: `ImageScanner.scan_new`, `FaceProcessor.process`, `build_caption`, `DatasetBuilder.save`, `build_config`, `save_config` (모두 이전 태스크에서 정의)
- Produces: `prepare_dataset.build_paths(repo_root: Path, model: str, person: str) -> dict` (CLI 로직에서 분리해 테스트 가능하게 만든 경로 계산 함수), `prepare_dataset.main()`

- [ ] **Step 1: 경로 계산 함수에 대한 테스트 작성**

`tests/test_prepare_dataset.py`:
```python
from pathlib import Path

from prepare_dataset import build_paths


def test_build_paths_maps_source_to_lora_dataset_and_config():
    paths = build_paths(Path("/repo"), "Z-Image-Turbo", "sara")

    assert paths["source_dir"] == Path("/repo/source/Z-Image-Turbo/sara")
    assert paths["dataset_dir"] == Path("/repo/lora/Z-Image-Turbo/sara/dataset")
    assert paths["config_path"] == Path("/repo/lora/Z-Image-Turbo/sara/sara_zimage_lora.yaml")
    assert paths["lora_name"] == "sara_zimage_lora"
    assert paths["trigger_word"] == "quahand sara"
```

- [ ] **Step 2: 테스트 실행 → 실패 확인**

```bash
python3 -m pytest tests/test_prepare_dataset.py -v
```

Expected: FAIL (`ModuleNotFoundError: No module named 'prepare_dataset'`)

- [ ] **Step 3: prepare_dataset.py 구현**

`prepare_dataset.py`:
```python
#!/usr/bin/env python3
"""CLI entry point: builds an ai-toolkit dataset + YAML config for one source/<model>/<person>/ pair."""

import argparse
from pathlib import Path

from modules.captioner import build_caption
from modules.config_generator import build_config, save_config
from modules.dataset_builder import DatasetBuilder
from modules.face_processor import FaceProcessor
from modules.scanner import ImageScanner

REPO_ROOT = Path(__file__).resolve().parent


def build_paths(repo_root: Path, model: str, person: str, trigger_word: str | None = None) -> dict:
    person_dir = repo_root / "lora" / model / person
    lora_name = f"{person}_zimage_lora"
    return {
        "source_dir": repo_root / "source" / model / person,
        "person_dir": person_dir,
        "dataset_dir": person_dir / "dataset",
        "config_path": person_dir / f"{lora_name}.yaml",
        "lora_name": lora_name,
        "trigger_word": trigger_word or f"quahand {person}",
    }


def parse_args():
    parser = argparse.ArgumentParser(
        description="source/<model>/<person>/ 의 원본 사진을 ai-toolkit LoRA 데이터셋으로 증분 변환한다"
    )
    parser.add_argument("--model", "-m", required=True, help="source/<model>/ 디렉토리 이름 (예: Z-Image-Turbo)")
    parser.add_argument("--person", "-p", required=True, help="source/<model>/<person>/ 디렉토리 이름 (예: sara)")
    parser.add_argument("--trigger-word", default=None, help="기본값: 'quahand <person>'")
    parser.add_argument("--lora-rank", type=int, default=64)
    parser.add_argument("--steps", type=int, default=4000)
    parser.add_argument("--target-resolution", type=int, default=1024)
    parser.add_argument("--min-face-size", type=int, default=64)
    parser.add_argument("--face-crop-padding", type=float, default=1.8)
    parser.add_argument("--no-face-filter", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    paths = build_paths(REPO_ROOT, args.model, args.person, args.trigger_word)

    scanner = ImageScanner(paths["source_dir"], paths["dataset_dir"])
    new_entries = scanner.scan_new()
    print(f"신규 이미지: {len(new_entries)}장")

    if new_entries:
        face_proc = FaceProcessor(
            min_face_size=args.min_face_size,
            crop_padding=args.face_crop_padding,
            target_resolution=args.target_resolution,
            face_filter=not args.no_face_filter,
        )
        processed, skipped = face_proc.process(new_entries)
        print(f"얼굴 감지 통과: {len(processed)}장 / 제외: {skipped}장")

        caption = build_caption(paths["trigger_word"])
        for img in processed:
            img.caption = caption

        builder = DatasetBuilder(paths["dataset_dir"])
        saved, failed = builder.save(processed)
        print(f"저장 완료: {saved}장 / 실패: {failed}장")
    else:
        print("신규 이미지가 없습니다. 기존 데이터셋을 그대로 둡니다.")

    cfg = build_config(
        lora_name=paths["lora_name"],
        trigger_word=paths["trigger_word"],
        dataset_dir=paths["dataset_dir"],
        lora_rank=args.lora_rank,
        steps=args.steps,
        target_resolution=args.target_resolution,
    )
    save_config(paths["config_path"], cfg)
    print(f"Config 갱신: {paths['config_path']}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: 테스트 실행 → 통과 확인**

```bash
python3 -m pytest tests/test_prepare_dataset.py -v
```

Expected: 1 passed

- [ ] **Step 5: 전체 단위 테스트 스위트 실행**

```bash
python3 -m pytest tests/ -v
```

Expected: 모든 테스트 통과 (Task 1~6에서 작성한 테스트 전부)

- [ ] **Step 6: 커밋**

```bash
git add prepare_dataset.py tests/test_prepare_dataset.py
git commit -m "feat: add prepare_dataset CLI entry point"
```

---

### Task 7: 실데이터 통합 실행 및 검증

**Files:** 없음 (실행/검증만, 코드 변경 없음)

**Interfaces:** 없음

- [ ] **Step 1: 의존성 전체 설치 확인**

```bash
pip3 install -r requirements.txt -r requirements-dev.txt
```

Expected: 에러 없이 완료 (이미 설치된 패키지는 스킵)

- [ ] **Step 2: 실제 sara 데이터셋으로 1차 실행**

```bash
python3 prepare_dataset.py --model Z-Image-Turbo --person sara
```

Expected: `신규 이미지: N장` (N = 현재 `source/Z-Image-Turbo/sara/`의 파일 수, `ls source/Z-Image-Turbo/sara | wc -l`로 사전 확인), 얼굴 감지 통과/제외 카운트 출력, `저장 완료: N장`, `Config 갱신: .../lora/Z-Image-Turbo/sara/sara_zimage_lora.yaml` 출력

- [ ] **Step 3: 출력 결과 확인**

```bash
ls lora/Z-Image-Turbo/sara/dataset | head -5
cat lora/Z-Image-Turbo/sara/sara_zimage_lora.yaml
```

Expected: `dataset/`에 `.jpg`+`.txt` 페어가 쌍을 이루어 존재, yaml의 `trigger_word: quahand sara`, `folder_path`가 로컬 절대경로로 채워져 있음

- [ ] **Step 4: 증분 동작 확인 (재실행 시 신규 0장)**

```bash
python3 prepare_dataset.py --model Z-Image-Turbo --person sara
```

Expected: `신규 이미지: 0장`, `신규 이미지가 없습니다. 기존 데이터셋을 그대로 둡니다.`, 그러나 yaml은 여전히 갱신됨 (`Config 갱신: ...` 출력)

- [ ] **Step 5: git에 source/lora가 잡히지 않는지 확인**

```bash
git status --short
```

Expected: `source/`, `lora/` 디렉토리 변경 사항이 전혀 나타나지 않음 (`.gitignore`에 의해 무시됨)
