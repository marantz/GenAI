# Z-Image-Turbo LoRA 학습 데이터 준비 툴 설계

## 1. Executive Summary

`ai-toolkit` (ostris)의 데이터셋 규격(`image.jpg` + `image.txt` 쌍)에 맞춰, Z-Image-Turbo 얼굴 일관성 LoRA 학습에 최적화된 **대화형 데이터셋 빌더**를 설계한다. CLI argument로 디렉토리를 직접 지정하거나, 대화형 탐색으로 소스 이미지 폴더를 선택할 수 있으며, 얼굴 감지 → 크롭/리사이즈 → 캡션 자동 생성 → YAML config 출력까지 일괄 처리한다.

---

## 2. 데이터셋 규격 (ai-toolkit 기준)

```
dataset/
├── image001.jpg    ← 원본 또는 전처리된 이미지 (jpg/jpeg/png)
├── image001.txt    ← 캡션 (trigger word 포함)
├── image002.jpg
├── image002.txt
└── ...
```

- 이미지 파일과 동일한 이름의 `.txt` 파일이 캡션을 담으며, `[trigger]` 키워드를 캡션에 포함하면 config의 `trigger_word`로 자동 치환된다.
- 이미지는 자동으로 리사이즈 및 버킷팅되므로 사전 크롭/리사이즈가 필수는 아니지만, 지원 포맷은 jpg/jpeg/png이며 webp는 이슈가 있다.
- Z-Image-Turbo 얼굴 LoRA 기준 권장 데이터셋: **70~80장 고화질 사진**, 캡션은 단순하게 유지 — 모델이 일관된 특징을 자동으로 학습한다.
- 단, 소규모 고품질 큐레이션 기준으로 1024×1024 이미지 9장만으로도 빠른 개인화 실험이 가능했다는 보고가 있으나, 이는 최소치이며 얼굴 일관성에는 더 많은 데이터가 권장된다.

---

## 3. 툴 아키텍처

```
prepare_dataset.py
│
├── [CLI Mode]  --data-dir /path/to/images
│                --output-dir /path/to/dataset
│                --trigger-word "ohwx person"
│                --subject-name "my_character"
│
└── [Interactive Mode]  (argument 없이 실행)
    └── 대화형 탐색 → 설정 수집 → 자동 처리
```

---

## 4. 전체 코드

### 4.1 디렉토리 구조

```
project/
├── prepare_dataset.py       ← 메인 진입점
├── modules/
│   ├── __init__.py
│   ├── cli.py               ← argument 파싱 & 대화형 UI
│   ├── scanner.py           ← 디렉토리 탐색 & 이미지 수집
│   ├── face_processor.py    ← 얼굴 감지 & 크롭/리사이즈
│   ├── captioner.py         ← 자동 캡션 생성 (Florence-2 / JoyCaption)
│   ├── dataset_builder.py   ← 최종 데이터셋 조립
│   └── config_generator.py  ← ai-toolkit YAML config 생성
├── requirements.txt
└── output/                  ← 생성된 데이터셋 & config 저장
```

---

### 4.2 `requirements.txt`

```txt
torch>=2.1.0
torchvision
opencv-python
Pillow>=10.0
insightface          # ArcFace 기반 얼굴 감지 (고정밀)
onnxruntime-gpu      # insightface 백엔드
transformers>=4.40   # Florence-2 캡셔닝
accelerate
tqdm
pyyaml
rich                 # 터미널 UI (대화형 모드)
inquirer             # 대화형 선택 메뉴
```

---

### 4.3 `prepare_dataset.py` (메인 진입점)

```python
#!/usr/bin/env python3
"""
Z-Image-Turbo LoRA Dataset Preparation Tool
- ai-toolkit (ostris) 규격에 맞는 학습 데이터셋 생성
- 얼굴 감지 / 크롭 / 캡션 자동화
- 대화형 또는 CLI argument 모드 지원
"""

import sys
import argparse
from pathlib import Path
from modules.cli import InteractiveCLI
from modules.scanner import ImageScanner
from modules.face_processor import FaceProcessor
from modules.captioner import AutoCaptioner
from modules.dataset_builder import DatasetBuilder
from modules.config_generator import ConfigGenerator
from rich.console import Console
from rich.panel import Panel

console = Console()


def parse_args():
    parser = argparse.ArgumentParser(
        description="Z-Image-Turbo LoRA Dataset Preparation Tool"
    )
    parser.add_argument(
        "--data-dir", "-d",
        type=str,
        default=None,
        help="소스 이미지가 있는 디렉토리 경로 (미지정시 대화형 모드)"
    )
    parser.add_argument(
        "--output-dir", "-o",
        type=str,
        default="./output/dataset",
        help="출력 데이터셋 저장 경로 (기본값: ./output/dataset)"
    )
    parser.add_argument(
        "--trigger-word", "-t",
        type=str,
        default=None,
        help="LoRA trigger word (예: 'ohwx person', 'sks woman')"
    )
    parser.add_argument(
        "--subject-name", "-n",
        type=str,
        default=None,
        help="학습 대상 이름 (config 파일명 및 캡션에 사용)"
    )
    parser.add_argument(
        "--min-face-size",
        type=int,
        default=64,
        help="최소 얼굴 크기 픽셀 (기본값: 64)"
    )
    parser.add_argument(
        "--target-resolution",
        type=int,
        default=1024,
        help="출력 이미지 해상도 (기본값: 1024)"
    )
    parser.add_argument(
        "--face-crop-padding",
        type=float,
        default=1.8,
        help="얼굴 크롭 패딩 비율 (기본값: 1.8 = 얼굴 영역의 1.8배)"
    )
    parser.add_argument(
        "--caption-mode",
        type=str,
        choices=["auto", "florence2", "simple", "manual"],
        default="auto",
        help="캡션 생성 방식 (기본값: auto)"
    )
    parser.add_argument(
        "--no-face-filter",
        action="store_true",
        help="얼굴 감지 필터링 비활성화 (모든 이미지 포함)"
    )
    parser.add_argument(
        "--lora-name",
        type=str,
        default=None,
        help="LoRA 모델 이름 (ai-toolkit config에 사용)"
    )
    parser.add_argument(
        "--lora-rank",
        type=int,
        default=64,
        help="LoRA rank (기본값: 64, Z-Image-Turbo 얼굴 권장)"
    )
    parser.add_argument(
        "--steps",
        type=int,
        default=4000,
        help="학습 스텝 수 (기본값: 4000)"
    )
    return parser.parse_args()


def main():
    console.print(Panel.fit(
        "[bold cyan]Z-Image-Turbo LoRA Dataset Preparation Tool[/bold cyan]\n"
        "[dim]ai-toolkit (ostris) 규격 데이터셋 자동 생성기[/dim]",
        border_style="cyan"
    ))

    args = parse_args()

    # ── 대화형 모드: argument 미지정시 ──────────────────────────────────
    if args.data_dir is None:
        cli = InteractiveCLI()
        config = cli.run()  # 사용자와 대화 후 설정 반환
    else:
        config = {
            "data_dir": Path(args.data_dir),
            "output_dir": Path(args.output_dir),
            "trigger_word": args.trigger_word or "ohwx person",
            "subject_name": args.subject_name or "subject",
            "lora_name": args.lora_name or args.subject_name or "my_zimage_lora",
            "min_face_size": args.min_face_size,
            "target_resolution": args.target_resolution,
            "face_crop_padding": args.face_crop_padding,
            "caption_mode": args.caption_mode,
            "face_filter": not args.no_face_filter,
            "lora_rank": args.lora_rank,
            "steps": args.steps,
        }

    # ── Pipeline 실행 ──────────────────────────────────────────────────
    console.print("\n[bold green]▶ Step 1/5  이미지 스캔[/bold green]")
    scanner = ImageScanner(config)
    images = scanner.scan()

    console.print(f"\n[bold green]▶ Step 2/5  얼굴 감지 & 품질 필터링[/bold green]")
    face_proc = FaceProcessor(config)
    valid_images = face_proc.process(images)

    console.print(f"\n[bold green]▶ Step 3/5  이미지 전처리 (크롭/리사이즈)[/bold green]")
    processed = face_proc.crop_and_resize(valid_images)

    console.print(f"\n[bold green]▶ Step 4/5  캡션 생성[/bold green]")
    captioner = AutoCaptioner(config)
    captioned = captioner.generate(processed)

    console.print(f"\n[bold green]▶ Step 5/5  데이터셋 & Config 저장[/bold green]")
    builder = DatasetBuilder(config)
    builder.build(captioned)

    gen = ConfigGenerator(config)
    gen.save()

    console.print(Panel.fit(
        f"[bold green]✅ 완료![/bold green]\n"
        f"데이터셋: [cyan]{config['output_dir']}[/cyan]\n"
        f"Config:   [cyan]{config['output_dir'].parent / 'config'}/[/cyan]",
        border_style="green"
    ))


if __name__ == "__main__":
    main()
```

---

### 4.4 `modules/cli.py` (대화형 모드)

```python
"""
대화형 CLI: 디렉토리 탐색 → 설정 수집
argument 없이 실행할 때 사용자와 텍스트 기반 대화로 설정을 완성
"""

from pathlib import Path
from rich.console import Console
from rich.table import Table
from rich.prompt import Prompt, Confirm, IntPrompt
from rich.panel import Panel
import os

console = Console()


class InteractiveCLI:

    def run(self) -> dict:
        console.print("\n[bold yellow]대화형 모드로 실행됩니다.[/bold yellow]")
        
        # 1. 소스 이미지 디렉토리 선택
        data_dir = self._select_data_dir()
        
        # 2. 출력 디렉토리
        output_dir = self._select_output_dir()
        
        # 3. 학습 대상 정보
        subject_name = Prompt.ask(
            "\n[cyan]학습 대상 이름을 입력하세요[/cyan] (예: john_doe, my_character)",
            default="subject"
        )
        
        # 4. Trigger Word
        console.print(
            "\n[dim]Trigger word는 학습 후 이 LoRA를 활성화하는 키워드입니다.[/dim]\n"
            "[dim]기존 단어와 충돌하지 않는 고유한 문자열을 권장합니다.[/dim]"
        )
        trigger_word = Prompt.ask(
            "[cyan]Trigger word[/cyan]",
            default=f"ohwx {subject_name}"
        )

        # 5. 캡션 방식
        console.print("\n[cyan]캡션 생성 방식을 선택하세요:[/cyan]")
        console.print("  [bold]1[/bold] auto      - GPU 있으면 Florence-2, 없으면 simple")
        console.print("  [bold]2[/bold] florence2 - Florence-2 VLM 자동 캡션 (권장, GPU 필요)")
        console.print("  [bold]3[/bold] simple    - trigger word만 포함한 단순 캡션")
        console.print("  [bold]4[/bold] manual    - 캡션을 직접 입력")
        caption_choice = Prompt.ask("선택", choices=["1","2","3","4"], default="1")
        caption_mode = {"1":"auto","2":"florence2","3":"simple","4":"manual"}[caption_choice]

        # 6. 얼굴 필터
        face_filter = Confirm.ask(
            "\n[cyan]얼굴이 없는 이미지를 자동으로 제외할까요?[/cyan]",
            default=True
        )

        # 7. 이미지 해상도
        resolution = IntPrompt.ask(
            "\n[cyan]출력 이미지 해상도[/cyan] (512 / 768 / 1024)",
            default=1024
        )

        # 8. LoRA 설정
        console.print("\n[bold cyan]── LoRA 학습 설정 ──────────────────[/bold cyan]")
        lora_name = Prompt.ask(
            "[cyan]LoRA 모델 이름[/cyan]",
            default=f"{subject_name}_zimage_v1"
        )
        lora_rank = IntPrompt.ask(
            "[cyan]LoRA rank[/cyan] (얼굴 품질에 64 권장, VRAM 부족시 32)",
            default=64
        )
        steps = IntPrompt.ask(
            "[cyan]학습 스텝 수[/cyan] (기본 4000, 소량 데이터는 3000)",
            default=4000
        )

        # ── 설정 확인 요약 ────────────────────────────────────────────
        self._show_summary({
            "data_dir": data_dir,
            "output_dir": output_dir,
            "subject_name": subject_name,
            "trigger_word": trigger_word,
            "caption_mode": caption_mode,
            "face_filter": face_filter,
            "target_resolution": resolution,
            "lora_name": lora_name,
            "lora_rank": lora_rank,
            "steps": steps,
        })

        if not Confirm.ask("\n[bold green]이 설정으로 진행할까요?[/bold green]", default=True):
            console.print("[yellow]다시 시작합니다...[/yellow]")
            return self.run()

        return {
            "data_dir": Path(data_dir),
            "output_dir": Path(output_dir),
            "subject_name": subject_name,
            "trigger_word": trigger_word,
            "lora_name": lora_name,
            "min_face_size": 64,
            "target_resolution": resolution,
            "face_crop_padding": 1.8,
            "caption_mode": caption_mode,
            "face_filter": face_filter,
            "lora_rank": lora_rank,
            "steps": steps,
        }

    def _select_data_dir(self) -> str:
        """하위 디렉토리 탐색 & 선택"""
        current = Path.cwd()
        
        while True:
            console.print(f"\n[bold]현재 위치:[/bold] [cyan]{current}[/cyan]")
            
            # 하위 항목 나열
            entries = self._list_directory(current)
            
            if not entries:
                console.print("[yellow]하위 디렉토리가 없습니다.[/yellow]")
            else:
                table = Table(show_header=True, header_style="bold magenta")
                table.add_column("#", width=4)
                table.add_column("이름")
                table.add_column("타입", width=8)
                table.add_column("이미지 수", width=10)

                for i, entry in enumerate(entries, 1):
                    img_count = self._count_images(current / entry["name"]) if entry["is_dir"] else "-"
                    table.add_row(
                        str(i),
                        entry["name"],
                        "[blue]DIR[/blue]" if entry["is_dir"] else "FILE",
                        str(img_count)
                    )
                console.print(table)

            console.print("\n[dim]입력 옵션:[/dim]")
            console.print("  [bold]숫자[/bold]    - 해당 디렉토리로 이동")
            console.print("  [bold]p[/bold]       - 상위 디렉토리로")
            console.print("  [bold]here[/bold]    - 현재 디렉토리를 소스로 선택")
            console.print("  [bold]경로 직접 입력[/bold] - 절대/상대 경로")

            img_count_here = self._count_images(current)
            console.print(f"\n[dim]현재 디렉토리 이미지: {img_count_here}장[/dim]")

            choice = Prompt.ask("[cyan]선택[/cyan]").strip()

            if choice.lower() == "here":
                if img_count_here == 0:
                    console.print("[red]현재 디렉토리에 이미지가 없습니다.[/red]")
                    continue
                return str(current)

            elif choice.lower() == "p":
                current = current.parent
                continue

            elif choice.isdigit():
                idx = int(choice) - 1
                if 0 <= idx < len(entries) and entries[idx]["is_dir"]:
                    current = current / entries[idx]["name"]
                else:
                    console.print("[red]유효하지 않은 선택입니다.[/red]")

            else:
                # 직접 경로 입력
                p = Path(choice)
                if not p.is_absolute():
                    p = current / p
                if p.is_dir():
                    return str(p)
                else:
                    console.print(f"[red]존재하지 않는 경로: {p}[/red]")

    def _select_output_dir(self) -> str:
        default = "./output/dataset"
        path = Prompt.ask(
            "\n[cyan]출력 데이터셋 저장 경로[/cyan]",
            default=default
        )
        Path(path).mkdir(parents=True, exist_ok=True)
        return path

    def _list_directory(self, path: Path) -> list:
        try:
            return [
                {"name": e.name, "is_dir": e.is_dir()}
                for e in sorted(path.iterdir())
                if not e.name.startswith(".")
            ]
        except PermissionError:
            return []

    def _count_images(self, path: Path) -> int:
        if not path.is_dir():
            return 0
        return sum(
            1 for f in path.iterdir()
            if f.suffix.lower() in {".jpg", ".jpeg", ".png"}
        )

    def _show_summary(self, config: dict):
        table = Table(title="설정 요약", show_header=False, box=None)
        table.add_column("항목", style="cyan", width=20)
        table.add_column("값", style="white")
        for k, v in config.items():
            table.add_row(k, str(v))
        console.print(Panel(table, border_style="cyan"))
```

---

### 4.5 `modules/scanner.py` (이미지 스캔)

```python
"""
소스 디렉토리에서 지원 포맷 이미지를 수집
"""

from pathlib import Path
from dataclasses import dataclass
from rich.console import Console
from tqdm import tqdm

console = Console()
SUPPORTED_EXTS = {".jpg", ".jpeg", ".png"}


@dataclass
class ImageEntry:
    src_path: Path
    stem: str


class ImageScanner:

    def __init__(self, config: dict):
        self.config = config
        self.data_dir = Path(config["data_dir"])

    def scan(self) -> list[ImageEntry]:
        if not self.data_dir.exists():
            console.print(f"[red]디렉토리 없음: {self.data_dir}[/red]")
            raise FileNotFoundError(self.data_dir)

        images = []
        for path in sorted(self.data_dir.iterdir()):
            if path.suffix.lower() in SUPPORTED_EXTS:
                images.append(ImageEntry(src_path=path, stem=path.stem))

        console.print(
            f"  [green]발견된 이미지:[/green] {len(images)}장 "
            f"[dim]({self.data_dir})[/dim]"
        )

        if len(images) == 0:
            console.print(
                "[yellow]⚠ 이미지가 없습니다. 경로를 확인하세요.[/yellow]"
            )

        return images
```

---

### 4.6 `modules/face_processor.py` (얼굴 감지 & 크롭)

```python
"""
InsightFace(ArcFace) 기반 얼굴 감지, 품질 필터링, 크롭/리사이즈

Z-Image-Turbo 얼굴 LoRA 핵심 요구사항:
- 얼굴이 명확하게 보이는 이미지만 포함
- 1024x1024 기준 얼굴이 프레임의 1/4 이상 차지
- 다중 얼굴 이미지는 경고 후 사용자 선택
"""

from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional
import cv2
import numpy as np
from PIL import Image
from rich.console import Console
from rich.prompt import Confirm
from tqdm import tqdm

console = Console()


@dataclass
class ProcessedImage:
    src_path: Path
    stem: str
    pil_image: Image.Image
    face_count: int = 0
    face_bbox: Optional[tuple] = None   # (x1, y1, x2, y2) in original coords
    quality_score: float = 1.0


class FaceProcessor:

    def __init__(self, config: dict):
        self.config = config
        self.min_face_size = config.get("min_face_size", 64)
        self.padding = config.get("face_crop_padding", 1.8)
        self.target_res = config.get("target_resolution", 1024)
        self.face_filter = config.get("face_filter", True)
        self._app = None  # lazy load

    def _load_model(self):
        """InsightFace 모델 lazy load"""
        if self._app is None:
            try:
                import insightface
                from insightface.app import FaceAnalysis
                self._app = FaceAnalysis(
                    name="buffalo_l",
                    providers=["CUDAExecutionProvider", "CPUExecutionProvider"]
                )
                self._app.prepare(ctx_id=0, det_size=(640, 640))
                console.print("  [green]InsightFace 모델 로드 완료[/green]")
            except ImportError:
                console.print(
                    "  [yellow]insightface 미설치. OpenCV Haar Cascade로 대체합니다.[/yellow]"
                )
                self._app = "opencv_fallback"

    def process(self, images) -> list[ProcessedImage]:
        """얼굴 감지 및 품질 필터링"""
        if self.face_filter:
            self._load_model()

        results = []
        skipped = 0

        for entry in tqdm(images, desc="얼굴 감지"):
            img_bgr = cv2.imread(str(entry.src_path))
            if img_bgr is None:
                console.print(f"  [red]읽기 실패: {entry.src_path.name}[/red]")
                continue

            pil_img = Image.fromarray(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))

            if not self.face_filter:
                results.append(ProcessedImage(
                    src_path=entry.src_path,
                    stem=entry.stem,
                    pil_image=pil_img,
                    face_count=0
                ))
                continue

            # 얼굴 감지
            faces, bbox = self._detect_faces(img_bgr)
            face_count = len(faces)

            # 얼굴 없음 → 제외
            if face_count == 0:
                console.print(f"  [dim]SKIP (얼굴 없음): {entry.src_path.name}[/dim]")
                skipped += 1
                continue

            # 다중 얼굴 경고
            if face_count > 1:
                console.print(
                    f"  [yellow]⚠ 다중 얼굴 {face_count}개: {entry.src_path.name}[/yellow]"
                )
                # 가장 큰 얼굴(주 피사체)을 선택
                bbox = self._select_largest_face(faces)

            # 최소 크기 필터
            x1, y1, x2, y2 = bbox
            face_w, face_h = x2 - x1, y2 - y1
            if face_w < self.min_face_size or face_h < self.min_face_size:
                console.print(f"  [dim]SKIP (얼굴 너무 작음): {entry.src_path.name}[/dim]")
                skipped += 1
                continue

            results.append(ProcessedImage(
                src_path=entry.src_path,
                stem=entry.stem,
                pil_image=pil_img,
                face_count=face_count,
                face_bbox=bbox
            ))

        console.print(
            f"\n  통과: [green]{len(results)}장[/green] / "
            f"제외: [red]{skipped}장[/red]"
        )
        return results

    def crop_and_resize(self, images: list[ProcessedImage]) -> list[ProcessedImage]:
        """얼굴 중심 크롭 + 목표 해상도 리사이즈"""
        processed = []
        for img in tqdm(images, desc="크롭/리사이즈"):
            if img.face_bbox is None:
                # face_filter=False 이거나 감지 실패 → 그대로 리사이즈
                resized = self._resize_square(img.pil_image)
            else:
                cropped = self._face_aware_crop(img.pil_image, img.face_bbox)
                resized = self._resize_square(cropped)

            img.pil_image = resized
            processed.append(img)
        return processed

    # ── 내부 유틸 ────────────────────────────────────────────────────────

    def _detect_faces(self, img_bgr):
        """얼굴 감지. InsightFace 또는 OpenCV fallback."""
        if self._app == "opencv_fallback":
            return self._opencv_detect(img_bgr)

        faces = self._app.get(img_bgr)
        if not faces:
            return [], None

        bboxes = []
        for face in faces:
            x1, y1, x2, y2 = map(int, face.bbox)
            bboxes.append((x1, y1, x2, y2))

        return bboxes, bboxes[0]

    def _opencv_detect(self, img_bgr):
        gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
        cascade = cv2.CascadeClassifier(
            cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
        )
        faces = cascade.detectMultiScale(gray, 1.1, 5)
        if len(faces) == 0:
            return [], None
        bboxes = [(x, y, x+w, y+h) for x, y, w, h in faces]
        return bboxes, bboxes[0]

    def _select_largest_face(self, bboxes: list) -> tuple:
        """가장 큰 얼굴 영역 선택 (주 피사체 기준)"""
        return max(bboxes, key=lambda b: (b[2]-b[0]) * (b[3]-b[1]))

    def _face_aware_crop(self, pil_img: Image.Image, bbox: tuple) -> Image.Image:
        """
        얼굴 bbox 중심으로 padding 비율만큼 확대 크롭.
        상반신이 보이도록 하단 패딩을 상단보다 크게 설정.
        """
        W, H = pil_img.size
        x1, y1, x2, y2 = bbox
        cx = (x1 + x2) / 2
        cy = (y1 + y2) / 2
        fw = x2 - x1
        fh = y2 - y1

        # 크롭 크기: 얼굴 크기 * padding
        crop_size = max(fw, fh) * self.padding
        half = crop_size / 2

        # 상반신 포함을 위해 하단 여유 추가 (1.3배)
        top    = max(0, int(cy - half))
        bottom = min(H, int(cy + half * 1.3))
        left   = max(0, int(cx - half))
        right  = min(W, int(cx + half))

        # 정사각형 보정
        side = min(bottom - top, right - left)
        cropped = pil_img.crop((left, top, left + side, top + side))
        return cropped

    def _resize_square(self, pil_img: Image.Image) -> Image.Image:
        return pil_img.resize(
            (self.target_res, self.target_res),
            Image.LANCZOS
        )
```

---

### 4.7 `modules/captioner.py` (캡션 자동 생성)

```python
"""
캡션 생성 전략:
- florence2 : Microsoft Florence-2-large-ft (VLM, DETAILED_CAPTION task)
- simple    : trigger word + 기본 설명자만
- manual    : 이미지별 사용자 직접 입력
- auto      : GPU 있으면 florence2, 없으면 simple

ai-toolkit 권장: 캡션은 단순하게. 
모델이 일관된 얼굴 특징을 자동 학습함.
"""

import torch
from pathlib import Path
from rich.console import Console
from rich.prompt import Prompt
from tqdm import tqdm

console = Console()


class AutoCaptioner:

    def __init__(self, config: dict):
        self.config = config
        self.trigger = config.get("trigger_word", "ohwx person")
        self.mode = config.get("caption_mode", "auto")
        self.subject = config.get("subject_name", "person")
        self._model = None
        self._processor = None

    def generate(self, images: list) -> list:
        """각 이미지에 캡션 문자열 추가 후 반환"""
        mode = self._resolve_mode()
        console.print(f"  캡션 모드: [cyan]{mode}[/cyan]")

        for img in tqdm(images, desc="캡션 생성"):
            if mode == "florence2":
                caption = self._florence2_caption(img.pil_image)
                # trigger word를 caption 앞에 주입
                img.caption = f"{self.trigger}, {caption}"

            elif mode == "simple":
                img.caption = self._simple_caption()

            elif mode == "manual":
                console.print(f"\n[cyan]{img.src_path.name}[/cyan]")
                img.pil_image.save("/tmp/_preview.jpg")
                console.print(f"  [dim]미리보기: /tmp/_preview.jpg[/dim]")
                img.caption = Prompt.ask(
                    f"  캡션 입력 (trigger '{self.trigger}' 포함 권장)",
                    default=self._simple_caption()
                )

        return images

    def _resolve_mode(self) -> str:
        if self.mode != "auto":
            return self.mode
        return "florence2" if torch.cuda.is_available() else "simple"

    def _simple_caption(self) -> str:
        """
        단순 캡션: trigger word + 일반 설명자
        Z-Image-Turbo 권장 방식 — 모델이 얼굴 특징을 스스로 학습
        """
        return (
            f"{self.trigger}, photo of a person, "
            "natural lighting, sharp focus on face, portrait"
        )

    def _load_florence2(self):
        if self._model is None:
            from transformers import AutoProcessor, AutoModelForCausalLM
            console.print("  [dim]Florence-2 모델 로딩...[/dim]")
            model_id = "microsoft/Florence-2-large-ft"
            self._processor = AutoProcessor.from_pretrained(
                model_id, trust_remote_code=True
            )
            self._model = AutoModelForCausalLM.from_pretrained(
                model_id,
                torch_dtype=torch.float16,
                trust_remote_code=True
            ).to("cuda")

    def _florence2_caption(self, pil_image) -> str:
        try:
            self._load_florence2()
            task = "<DETAILED_CAPTION>"
            inputs = self._processor(
                text=task,
                images=pil_image,
                return_tensors="pt"
            ).to("cuda", torch.float16)

            with torch.no_grad():
                ids = self._model.generate(
                    input_ids=inputs["input_ids"],
                    pixel_values=inputs["pixel_values"],
                    max_new_tokens=256,
                    num_beams=3
                )
            result = self._processor.batch_decode(ids, skip_special_tokens=False)[0]
            parsed = self._processor.post_process_generation(
                result, task=task,
                image_size=(pil_image.width, pil_image.height)
            )
            return parsed.get(task, "a portrait photo of a person").strip()

        except Exception as e:
            console.print(f"  [yellow]Florence-2 실패, simple 캡션으로 대체: {e}[/yellow]")
            return "photo of a person, portrait, natural lighting"
```

---

### 4.8 `modules/dataset_builder.py` (데이터셋 저장)

```python
"""
전처리 완료된 이미지 + 캡션을 ai-toolkit 규격으로 출력 디렉토리에 저장
image001.jpg + image001.txt 쌍
"""

from pathlib import Path
from rich.console import Console
from rich.table import Table
from tqdm import tqdm

console = Console()


class DatasetBuilder:

    def __init__(self, config: dict):
        self.output_dir = Path(config["output_dir"])
        self.output_dir.mkdir(parents=True, exist_ok=True)

    def build(self, images: list):
        saved = 0
        skipped = 0

        for i, img in enumerate(tqdm(images, desc="데이터셋 저장"), start=1):
            stem = f"image{i:04d}"
            img_path = self.output_dir / f"{stem}.jpg"
            txt_path = self.output_dir / f"{stem}.txt"

            # 이미지 저장 (JPEG quality=95)
            try:
                img.pil_image.convert("RGB").save(
                    img_path, "JPEG", quality=95, subsampling=0
                )
                # 캡션 저장
                caption = getattr(img, "caption", "")
                txt_path.write_text(caption, encoding="utf-8")
                saved += 1

            except Exception as e:
                console.print(f"  [red]저장 실패 {img.src_path.name}: {e}[/red]")
                skipped += 1

        # 요약 출력
        table = Table(title="데이터셋 생성 완료", show_header=False, box=None)
        table.add_column("항목", style="cyan")
        table.add_column("값", style="white")
        table.add_row("저장 완료", f"{saved}장")
        table.add_row("실패/건너뜀", f"{skipped}장")
        table.add_row("출력 경로", str(self.output_dir))
        console.print(table)
```

---

### 4.9 `modules/config_generator.py` (ai-toolkit YAML 생성)

```python
"""
ai-toolkit 규격의 학습 YAML config 자동 생성
Z-Image-Turbo 최적 설정값 적용:
- training_adapter: V2 (얼굴 품질 최적)
- lora_rank: 64 (피부 텍스처 표현에 필수)
- steps: 4000
- optimizer: adamw8bit
- timestep_type: sigmoid
"""

from pathlib import Path
import yaml
from rich.console import Console

console = Console()


class ConfigGenerator:

    def __init__(self, config: dict):
        self.config = config
        self.config_dir = Path(config["output_dir"]).parent / "config"
        self.config_dir.mkdir(parents=True, exist_ok=True)

    def save(self):
        cfg = self._build_config()
        out_path = self.config_dir / f"{self.config['lora_name']}.yaml"

        with open(out_path, "w", encoding="utf-8") as f:
            yaml.dump(cfg, f, allow_unicode=True, default_flow_style=False, sort_keys=False)

        console.print(f"  [green]Config 저장:[/green] {out_path}")
        self._print_next_steps(out_path)

    def _build_config(self) -> dict:
        rank = self.config.get("lora_rank", 64)
        steps = self.config.get("steps", 4000)
        dataset_path = str(self.config["output_dir"].resolve())
        lora_name = self.config.get("lora_name", "my_zimage_lora")
        trigger = self.config.get("trigger_word", "ohwx person")
        res = self.config.get("target_resolution", 1024)

        return {
            "job": "extension",
            "config": {
                "name": lora_name,
                "process": [{
                    "type": "sd_trainer",
                    "training_folder": "output",
                    "device": "cuda:0",
                    "trigger_word": trigger,

                    "network": {
                        "type": "lora",
                        "linear": rank,
                        "linear_alpha": rank,
                    },

                    "save": {
                        "dtype": "float16",       # Z-Image-Turbo: fp16 권장
                        "save_every": 250,
                        "max_step_saves_to_keep": 6,
                    },

                    "datasets": [{
                        "folder_path": dataset_path,
                        "caption_ext": "txt",
                        "caption_dropout_rate": 0.05,
                        "cache_latents_to_disk": True,
                        "resolution": [512, 768, res],
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
                        "timestep_type": "sigmoid",   # Z-Image-Turbo 중요 설정
                    },

                    "model": {
                        "name_or_path": "Tongyi-MAI/Z-Image-Turbo",
                        "arch": "zimage",
                        # V2 adapter: 얼굴 LoRA에 최적
                        "assistant_lora_path": (
                            "ostris/zimage_turbo_training_adapter/"
                            "zimage_turbo_training_adapterV2.safetensors"
                        ),
                        "quantize": True,
                    },

                    "sample": {
                        "sampler": "flowmatch",
                        "sample_every": 250,
                        "width": res,
                        "height": res,
                        "prompts": [
                            f"{trigger}, portrait photo, natural lighting, sharp focus",
                            f"{trigger}, outdoor photo, casual wear, smiling",
                            f"{trigger}, close-up face, studio lighting",
                        ],
                        "seed": 42,
                        "guidance_scale": 1,
                        "sample_steps": 8,
                    },
                }]
            },
            "meta": {
                "name": "[name]",
                "version": "1.0",
            }
        }

    def _print_next_steps(self, config_path: Path):
        console.print("\n[bold cyan]── 다음 단계 ─────────────────────────────────[/bold cyan]")
        console.print(f"  1. ai-toolkit 디렉토리로 이동")
        console.print(f"     [dim]cd /path/to/ai-toolkit[/dim]")
        console.print(f"  2. config 파일을 ai-toolkit/config/ 에 복사")
        console.print(f"     [dim]cp {config_path} ./config/[/dim]")
        console.print(f"  3. 학습 실행")
        console.print(f"     [dim]python run.py config/{config_path.name}[/dim]")
        console.print(f"  4. 학습 완료 후 inference 설정")
        console.print(f"     [dim]num_inference_steps=30, cfg_scale=2[/dim]")
        console.print(f"     [dim](또는 DistillPatch LoRA 추가 시 steps=8, cfg_scale=1)[/dim]")
```

---

## 5. 실행 방법

### 5.1 CLI Mode (경로 직접 지정)

```bash
# 기본 실행
python prepare_dataset.py \
  --data-dir /data/photos/john \
  --output-dir ./output/john_dataset \
  --trigger-word "ohwx man" \
  --subject-name "john" \
  --lora-name "john_zimage_v1" \
  --lora-rank 64 \
  --steps 4000

# 저사양 GPU (24GB 이하) - 해상도 낮춤, rank 줄임
python prepare_dataset.py \
  -d /data/photos/jane \
  -o ./output/jane_dataset \
  -t "sks woman" \
  --lora-rank 32 \
  --target-resolution 512 \
  --steps 3000 \
  --caption-mode simple
```

### 5.2 대화형 Mode (argument 없이 실행)

```bash
python prepare_dataset.py
```

```
╭─ Z-Image-Turbo LoRA Dataset Preparation Tool ─╮
│  ai-toolkit (ostris) 규격 데이터셋 자동 생성기  │
╰────────────────────────────────────────────────╯

대화형 모드로 실행됩니다.

현재 위치: /home/user/projects
┌──┬──────────────┬──────┬────────┐
│ # │ 이름         │ 타입 │ 이미지수│
├──┼──────────────┼──────┼────────┤
│ 1 │ data         │ DIR  │ 0      │
│ 2 │ photos       │ DIR  │ 142    │
│ 3 │ experiments  │ DIR  │ 0      │
└──┴──────────────┴──────┴────────┘

선택: 2

현재 위치: /home/user/projects/photos
┌──┬─────────────┬──────┬────────┐
│ # │ 이름        │ 타입 │ 이미지수│
├──┼─────────────┼──────┼────────┤
│ 1 │ john        │ DIR  │ 83     │
│ 2 │ raw_mixed   │ DIR  │ 214    │
└──┴─────────────┴──────┴────────┘

현재 디렉토리 이미지: 142장
선택: 1

현재 위치: /home/user/projects/photos/john
현재 디렉토리 이미지: 83장
선택: here

학습 대상 이름을 입력하세요: john_doe
Trigger word [ohwx john_doe]: ohwx man
캡션 생성 방식 (1=auto): 1
얼굴이 없는 이미지를 자동으로 제외할까요? [Y/n]: Y
출력 이미지 해상도 [1024]: 1024
LoRA 모델 이름 [john_doe_zimage_v1]: 
LoRA rank [64]: 64
학습 스텝 수 [4000]: 4000
```

---

## 6. 얼굴 일관성 확보 전략 요약

| 처리 단계 | 방법 | 근거 |
|---|---|---|
| 얼굴 감지 | InsightFace ArcFace (buffalo_l) | 소형 얼굴, 측면, 조명 변화에 강인 |
| 다중 얼굴 | 가장 큰 얼굴(주 피사체) 자동 선택 | 배경 인물 혼입 방지 |
| 크롭 패딩 | 얼굴 영역 × 1.8배, 하단 1.3배 | 상반신 포함 → 자연스러운 portrait |
| 해상도 | 1024×1024 | Z-Image Turbo의 생성 강점에 맞는 해상도 |
| LoRA rank | 64 | 피부 텍스처 표현에 rank 16/32는 부족, 64 필수 |
| training adapter | V2 | V2 adapter가 더 정제된 결과물 제공 |
| precision | fp16 | Z-Image-Turbo 학습 및 생성 모두 fp16이 최적 |
| timestep_type | sigmoid | Z-Image-Turbo 학습에 중요한 설정 |
| inference 후처리 | DistillPatch LoRA 병용 | 표준 SFT 후 공식 DistillPatch LoRA를 추가 로드하면 8-step 가속 능력 복원 가능 (num_inference_steps=8, cfg_scale=1) |

---

## 7. 권장 데이터셋 구성 가이드라인

```
권장 이미지 수     : 70~80장 (최소 20장, 최적 70~80장)
해상도             : 1024×1024
조명               : 자연광 + 실내 다양
각도               : 정면(40%) / 측면(30%) / 3/4(30%)
표정               : 미소, 무표정, 다양하게
배경               : 단색 / 복잡한 배경 혼합
금지               : 워터마크, 과도한 보정, 다중 인물 주체 혼재
```

> **핵심 원칙**: 빠른 개인화에서는 대규모 노이즈 데이터보다 소규모 고품질 큐레이션이 더 효과적이다. 그리고 입력 사진이 흐리면 생성 결과도 흐리고, 선명한 고해상도 입력이 전문적인 결과물을 만든다.