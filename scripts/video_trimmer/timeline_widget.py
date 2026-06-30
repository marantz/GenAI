"""하단 타임라인 위젯. 전체 영상 썸네일 스트립 위에 노란색 선택 구간을 표시하고,
드래그로 시작점을 이동한다. 현재 재생 위치는 흰색 세로선(playhead)으로 표시.
"""

from PySide6.QtCore import Qt, Signal, QRectF
from PySide6.QtGui import QPainter, QColor, QPixmap
from PySide6.QtWidgets import QWidget


class TimelineWidget(QWidget):
    startChanged = Signal(float)
    seekRequested = Signal(float)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumHeight(90)
        self.duration = 0.0
        self.length = 0.0
        self.start = 0.0
        self.playhead = 0.0
        self._thumbs: list[QPixmap] = []
        self._dragging = False
        self._drag_offset = 0.0

    # --- 설정 메서드 ---
    def set_duration(self, seconds: float):
        self.duration = max(0.0, seconds)
        self.start = self.clamp_start(self.start)
        self.update()

    def set_length(self, seconds: float):
        self.length = max(0.0, seconds)
        self.start = self.clamp_start(self.start)
        self.update()

    def set_start(self, seconds: float):
        self.start = self.clamp_start(seconds)
        self.startChanged.emit(self.start)
        self.update()

    def set_playhead(self, seconds: float):
        self.playhead = seconds
        self.update()

    def set_thumbnails(self, paths: list[str]):
        self._thumbs = [QPixmap(p) for p in paths]
        self.update()

    # --- 순수 로직 ---
    def clamp_start(self, value: float) -> float:
        max_start = max(0.0, self.duration - self.length)
        return min(max(0.0, value), max_start)

    def _x_to_time(self, x: float) -> float:
        if self.width() == 0 or self.duration == 0:
            return 0.0
        return (x / self.width()) * self.duration

    def _time_to_x(self, t: float) -> float:
        if self.duration == 0:
            return 0.0
        return (t / self.duration) * self.width()

    # --- 마우스 ---
    def mousePressEvent(self, event):
        t = self._x_to_time(event.position().x())
        if self.start <= t <= self.start + self.length:
            self._dragging = True
            self._drag_offset = t - self.start
        else:
            self.seekRequested.emit(t)

    def mouseMoveEvent(self, event):
        if self._dragging:
            t = self._x_to_time(event.position().x())
            self.set_start(t - self._drag_offset)

    def mouseReleaseEvent(self, event):
        self._dragging = False

    # --- 렌더링 ---
    def paintEvent(self, event):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(30, 30, 30))
        if self._thumbs:
            w = self.width() / len(self._thumbs)
            for i, pix in enumerate(self._thumbs):
                if not pix.isNull():
                    target = QRectF(i * w, 0, w, self.height())
                    p.drawPixmap(target, pix, QRectF(pix.rect()))
        if self.duration > 0 and self.length > 0:
            x0 = self._time_to_x(self.start)
            x1 = self._time_to_x(self.start + self.length)
            sel = QRectF(x0, 0, x1 - x0, self.height())
            p.fillRect(sel, QColor(255, 230, 0, 80))
            pen = p.pen()
            pen.setColor(QColor(255, 230, 0))
            pen.setWidth(3)
            p.setPen(pen)
            p.drawRect(sel)
        if self.duration > 0:
            px = self._time_to_x(self.playhead)
            p.setPen(QColor(255, 255, 255))
            p.drawLine(int(px), 0, int(px), self.height())
        p.end()
