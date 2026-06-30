"""구간 저장 워커. ffmpeg 재인코딩을 백그라운드 스레드에서 실행한다."""

import subprocess

from PySide6.QtCore import QThread, Signal

from . import ffmpeg_utils


class ExportWorker(QThread):
    finished_ok = Signal(str)
    failed = Signal(str)

    def __init__(self, input_path, start, length, output_path, parent=None):
        super().__init__(parent)
        # NOTE: QThread.start() 메서드와 충돌하므로 start/length 속성은
        # 접두사를 붙여 보관한다.
        self.input_path = input_path
        self.start_time = start
        self.clip_length = length
        self.output_path = output_path

    def run(self):
        ffmpeg = ffmpeg_utils.find_ffmpeg()
        if ffmpeg is None:
            self.failed.emit("ffmpeg 를 찾을 수 없습니다.")
            return
        cmd = ffmpeg_utils.build_export_cmd(
            ffmpeg, self.input_path, self.start_time, self.clip_length,
            self.output_path,
        )
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0:
            self.finished_ok.emit(self.output_path)
        else:
            self.failed.emit(proc.stderr)
