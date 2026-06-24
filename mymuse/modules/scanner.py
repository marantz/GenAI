"""
Image scanner for incremental dataset processing.

Scans a source directory for new images and skips those already in the dataset.
"""

import re
from dataclasses import dataclass
from pathlib import Path
from typing import List


# Supported image extensions
SUPPORTED_EXTS = {".jpg", ".jpeg", ".png"}


def sanitize_stem(name: str) -> str:
    """Sanitize a bare stem by lowercasing, replacing non-alphanumeric chars with underscores, and stripping edges."""
    lowered = name.lower()
    sanitized = re.sub(r"[^a-z0-9]+", "_", lowered)
    return sanitized.strip("_")


@dataclass
class ImageEntry:
    """Represents a single image discovered in the source directory."""
    src_path: Path
    stem: str


class ImageScanner:
    """Scans source directory for images, skipping those already in dataset."""

    def __init__(self, source_dir: Path, dataset_dir: Path):
        """
        Initialize the scanner.

        Args:
            source_dir: Path to directory containing source images
            dataset_dir: Path to directory containing processed dataset
        """
        self.source_dir = Path(source_dir)
        self.dataset_dir = Path(dataset_dir)

    def scan_new(self) -> List[ImageEntry]:
        """
        Scan source directory and return only images not yet in dataset.

        Raises:
            FileNotFoundError: If source_dir does not exist

        Returns:
            List of ImageEntry objects for new images
        """
        if not self.source_dir.exists():
            raise FileNotFoundError(f"Source directory not found: {self.source_dir}")

        # Build set of stems already in dataset
        existing_stems = set()
        if self.dataset_dir.exists():
            for jpg_file in self.dataset_dir.glob("*.jpg"):
                existing_stems.add(jpg_file.stem)
            for jpeg_file in self.dataset_dir.glob("*.jpeg"):
                existing_stems.add(jpeg_file.stem)
            for png_file in self.dataset_dir.glob("*.png"):
                existing_stems.add(png_file.stem)

        # Scan source directory and collect new images
        entries = []
        for path in sorted(self.source_dir.iterdir()):
            # Skip non-files and unsupported extensions
            if not path.is_file() or path.suffix.lower() not in SUPPORTED_EXTS:
                continue

            # Sanitize stem and skip if already in dataset
            stem = sanitize_stem(path.stem)
            if stem in existing_stems:
                continue

            entries.append(ImageEntry(src_path=path, stem=stem))

        return entries
