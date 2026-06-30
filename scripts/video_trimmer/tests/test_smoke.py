def test_pyside6_imports():
    import PySide6
    from PySide6 import QtWidgets, QtMultimedia
    assert PySide6.__version__
