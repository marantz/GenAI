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
