import pytest


@pytest.fixture(scope="module")
def app():
    from PySide6.QtWidgets import QApplication
    import sys
    return QApplication.instance() or QApplication(sys.argv)


def test_mainwindow_constructs(app):
    from video_trimmer.main import MainWindow
    win = MainWindow()
    assert win.timeline is not None
    assert win.player is not None


def test_apply_duration_sets_timeline(app):
    from video_trimmer.main import MainWindow
    win = MainWindow()
    win.length_spin.setValue(5.0)
    win._apply_duration(20.0)
    assert win.timeline.duration == 20.0
    assert win.timeline.length == 5.0
