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
