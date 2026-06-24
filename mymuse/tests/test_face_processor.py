from pathlib import Path

from PIL import Image

from modules.face_processor import FaceProcessor
from modules.scanner import ImageEntry


def _save_blank_image(path: Path, size=(200, 200)):
    Image.new("RGB", size, color="black").save(path)


def test_face_aware_crop_returns_square_image():
    fp = FaceProcessor(target_resolution=64)
    img = Image.new("RGB", (200, 200), color="white")
    bbox = (50, 50, 100, 100)
    cropped = fp._face_aware_crop(img, bbox)
    assert cropped.width == cropped.height


def test_resize_square_produces_target_resolution():
    fp = FaceProcessor(target_resolution=64)
    img = Image.new("RGB", (200, 300), color="white")
    resized = fp._resize_square(img)
    assert resized.size == (64, 64)


def test_opencv_detect_returns_none_for_blank_image(tmp_path):
    fp = FaceProcessor()
    path = tmp_path / "blank.jpg"
    _save_blank_image(path)
    import cv2

    img_bgr = cv2.imread(str(path))
    bbox = fp._opencv_detect(img_bgr)
    assert bbox is None


def test_process_with_face_filter_false_skips_model_load(tmp_path):
    path = tmp_path / "blank.jpg"
    _save_blank_image(path)
    entries = [ImageEntry(src_path=path, stem="blank")]

    fp = FaceProcessor(target_resolution=64, face_filter=False)
    results, skipped = fp.process(entries)

    assert fp._app is None
    assert skipped == 0
    assert len(results) == 1
    assert results[0].stem == "blank"
    assert results[0].caption == ""
    assert results[0].pil_image.size == (64, 64)


def test_process_counts_unreadable_image_as_skipped(tmp_path):
    path = tmp_path / "not_an_image.jpg"
    path.write_text("not a real image", encoding="utf-8")
    entries = [ImageEntry(src_path=path, stem="not_an_image")]

    fp = FaceProcessor(face_filter=False)
    results, skipped = fp.process(entries)

    assert results == []
    assert skipped == 1
