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
        if self._app is None:
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

        bboxes = [tuple(map(int, face.bbox)) for face in faces]
        return max(bboxes, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]))

    def _opencv_detect(self, img_bgr) -> Optional[tuple]:
        gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
        cascade = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
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
