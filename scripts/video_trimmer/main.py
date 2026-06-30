"""메인 윈도우: 상단 영상 미리보기 + 하단 노란색 타임라인 + 컨트롤 바.

위젯/워커를 시그널·슬롯으로 배선하고, 영상 열기·썸네일 추출·구간 저장을 조율한다.
"""

import subprocess
import sys
import tempfile

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QPushButton, QDoubleSpinBox, QLabel, QFileDialog, QMessageBox,
)

from . import ffmpeg_utils
from .player_widget import PlayerWidget
from .timeline_widget import TimelineWidget
from .thumbnail_worker import ThumbnailWorker
from .exporter import ExportWorker


class MainWindow(QMainWindow):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Video Trim Tool")
        self.resize(900, 640)
        self.input_path = None
        self._tmpdir = None
        self._thumb_worker = None
        self._export_worker = None

        central = QWidget()
        layout = QVBoxLayout(central)

        self.player = PlayerWidget()
        layout.addWidget(self.player, stretch=1)

        self.timeline = TimelineWidget()
        layout.addWidget(self.timeline)

        controls = QHBoxLayout()
        self.open_btn = QPushButton("열기")
        self.play_btn = QPushButton("재생")
        self.pause_btn = QPushButton("일시정지")
        self.save_btn = QPushButton("구간 저장")
        controls.addWidget(self.open_btn)
        controls.addWidget(self.play_btn)
        controls.addWidget(self.pause_btn)
        controls.addWidget(QLabel("길이(초):"))
        self.length_spin = QDoubleSpinBox()
        self.length_spin.setDecimals(2)
        self.length_spin.setRange(0.1, 600.0)
        self.length_spin.setValue(16.1)
        controls.addWidget(self.length_spin)
        controls.addStretch()
        controls.addWidget(self.save_btn)
        layout.addLayout(controls)

        self.setCentralWidget(central)

        # 배선
        self.open_btn.clicked.connect(self.on_open)
        self.play_btn.clicked.connect(self.player.play)
        self.pause_btn.clicked.connect(self.player.pause)
        self.save_btn.clicked.connect(self.on_save)
        self.length_spin.valueChanged.connect(self.timeline.set_length)
        self.timeline.startChanged.connect(self.player.seek)
        self.timeline.seekRequested.connect(self.player.seek)
        self.player.positionChanged.connect(self.timeline.set_playhead)

        self.timeline.set_length(self.length_spin.value())
        self._check_ffmpeg()

    def _check_ffmpeg(self):
        if ffmpeg_utils.find_ffmpeg() is None or ffmpeg_utils.find_ffprobe() is None:
            QMessageBox.warning(
                self, "ffmpeg 필요",
                "ffmpeg/ffprobe 를 찾을 수 없습니다. 설치 후 다시 실행하세요.",
            )

    def on_open(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "영상 열기", "", "Video (*.mp4 *.mov *.mkv *.avi *.webm)"
        )
        if path:
            self.open_file(path)

    def open_file(self, path: str):
        self.input_path = path
        ffprobe = ffmpeg_utils.find_ffprobe()
        if ffprobe is None:
            QMessageBox.critical(self, "오류", "ffprobe 를 찾을 수 없습니다.")
            return
        try:
            proc = subprocess.run(
                ffmpeg_utils.build_probe_cmd(ffprobe, path),
                capture_output=True, text=True, check=True,
            )
            duration = ffmpeg_utils.parse_duration(proc.stdout)
        except Exception as e:
            QMessageBox.critical(self, "오류", f"영상 정보를 읽을 수 없습니다:\n{e}")
            return
        self.player.load(path)
        self._apply_duration(duration)
        self._start_thumbnails(path)

    def _apply_duration(self, duration: float):
        self.timeline.set_length(self.length_spin.value())
        self.timeline.set_duration(duration)
        self.timeline.set_start(0.0)

    def _start_thumbnails(self, path: str):
        self._tmpdir = tempfile.mkdtemp(prefix="vtrim_")
        self._thumb_worker = ThumbnailWorker(path, self._tmpdir, fps=1)
        self._thumb_worker.done.connect(self.timeline.set_thumbnails)
        self._thumb_worker.failed.connect(
            lambda m: QMessageBox.warning(self, "썸네일 실패", m)
        )
        self._thumb_worker.start()

    def on_save(self):
        if not self.input_path:
            QMessageBox.information(self, "안내", "먼저 영상을 여세요.")
            return
        out, _ = QFileDialog.getSaveFileName(
            self, "구간 저장", "trimmed.mp4", "Video (*.mp4)"
        )
        if not out:
            return
        self.save_btn.setEnabled(False)
        self._export_worker = ExportWorker(
            self.input_path, self.timeline.start,
            self.length_spin.value(), out,
        )
        self._export_worker.finished_ok.connect(self._on_export_ok)
        self._export_worker.failed.connect(self._on_export_fail)
        self._export_worker.start()

    def _on_export_ok(self, path: str):
        self.save_btn.setEnabled(True)
        QMessageBox.information(self, "완료", f"저장됨:\n{path}")

    def _on_export_fail(self, msg: str):
        self.save_btn.setEnabled(True)
        QMessageBox.critical(self, "저장 실패", msg)


def main():
    app = QApplication(sys.argv)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())
