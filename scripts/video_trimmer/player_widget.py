"""상단 영상 미리보기 위젯. 원본 비율을 유지하며 윈도우 안에 맞춰 재생한다."""

from PySide6.QtCore import Qt, Signal, QUrl
from PySide6.QtMultimedia import QMediaPlayer, QAudioOutput
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import QWidget, QVBoxLayout


class PlayerWidget(QWidget):
    positionChanged = Signal(float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._video = QVideoWidget()
        self._video.setAspectRatioMode(Qt.KeepAspectRatio)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self._video)

        self._player = QMediaPlayer(self)
        self._audio = QAudioOutput(self)
        self._player.setAudioOutput(self._audio)
        self._player.setVideoOutput(self._video)
        self._player.positionChanged.connect(self._on_position)

    def _on_position(self, ms: int):
        self.positionChanged.emit(ms / 1000.0)

    def load(self, path: str):
        self._player.setSource(QUrl.fromLocalFile(path))

    def play(self):
        self._player.play()

    def pause(self):
        self._player.pause()

    def seek(self, seconds: float):
        self._player.setPosition(int(seconds * 1000))
