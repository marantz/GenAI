import pytest


@pytest.fixture(scope="module")
def app():
    from PySide6.QtWidgets import QApplication
    import sys
    return QApplication.instance() or QApplication(sys.argv)


def test_player_widget_constructs_and_has_api(app):
    from video_trimmer.player_widget import PlayerWidget
    w = PlayerWidget()
    assert hasattr(w, "load")
    assert hasattr(w, "play")
    assert hasattr(w, "pause")
    assert hasattr(w, "seek")
    assert hasattr(w, "positionChanged")
