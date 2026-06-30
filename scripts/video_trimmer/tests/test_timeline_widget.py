import pytest


@pytest.fixture(scope="module")
def app():
    from PySide6.QtWidgets import QApplication
    import sys
    return QApplication.instance() or QApplication(sys.argv)


def test_clamp_start_within_bounds(app):
    from video_trimmer.timeline_widget import TimelineWidget
    w = TimelineWidget()
    w.set_duration(20.0)
    w.set_length(16.1)
    # max start = 20 - 16.1 = 3.9
    assert w.clamp_start(-5.0) == 0.0
    assert w.clamp_start(10.0) == pytest.approx(3.9)
    assert w.clamp_start(2.0) == pytest.approx(2.0)


def test_set_start_emits_signal(app):
    from video_trimmer.timeline_widget import TimelineWidget
    w = TimelineWidget()
    w.set_duration(20.0)
    w.set_length(5.0)
    seen = []
    w.startChanged.connect(seen.append)
    w.set_start(2.0)
    assert w.start == pytest.approx(2.0)
    assert seen == [pytest.approx(2.0)]
