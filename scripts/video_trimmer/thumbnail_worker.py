"""썸네일 추출 워커. ffmpeg로 1초 간격 프레임을 임시 폴더에 추출한다."""

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
