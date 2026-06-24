"""Tests for modules.scanner"""

import pytest
from pathlib import Path
from PIL import Image

from modules.scanner import sanitize_stem, ImageEntry, ImageScanner, SUPPORTED_EXTS


def _make_image(path: Path):
    """Helper: create a minimal valid image file."""
    img = Image.new("RGB", (10, 10), color="red")
    img.save(path)


def test_sanitize_stem_lowercase():
    assert sanitize_stem("Photo") == "photo"


def test_sanitize_stem_spaces_to_underscores():
    assert sanitize_stem("photo one") == "photo_one"


def test_sanitize_stem_multiple_spaces():
    assert sanitize_stem("photo  two") == "photo_two"


def test_sanitize_stem_strips_leading_trailing_underscores():
    assert sanitize_stem("_photo_") == "photo"


def test_sanitize_stem_combined():
    assert sanitize_stem("_Photo One_") == "photo_one"


def test_sanitize_stem_replaces_hyphens_and_other_punctuation():
    assert sanitize_stem("ZIT-121358_00008_") == "zit_121358_00008"


def test_sanitize_stem_does_not_truncate_interior_dots():
    assert sanitize_stem("IMG.2024.01.15") == "img_2024_01_15"


def test_scan_new_finds_supported_images(tmp_path):
    source_dir = tmp_path / "source"
    dataset_dir = tmp_path / "dataset"
    source_dir.mkdir()
    dataset_dir.mkdir()

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
