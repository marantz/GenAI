import os
import subprocess

import pytest

from video_trimmer import ffmpeg_utils
from video_trimmer.exporter import ExportWorker


def test_start_method_not_shadowed_by_attribute():
    # 회귀 방지: self.start 속성이 QThread.start() 메서드를 덮어쓰면 안 된다.
    worker = ExportWorker("in.mp4", start=1.0, length=2.0, output_path="out.mp4")
    assert callable(worker.start)
    assert worker.start_time == 1.0
    assert worker.clip_length == 2.0


def _make_sample(path, seconds=5):
    """ffmpeg로 테스트용 컬러바 영상 생성."""
    ffmpeg = ffmpeg_utils.find_ffmpeg()
    subprocess.run(
        [ffmpeg, "-y", "-f", "lavfi", "-i",
         f"testsrc=duration={seconds}:size=320x240:rate=30",
         "-pix_fmt", "yuv420p", path],
        check=True, capture_output=True,
    )


@pytest.mark.skipif(ffmpeg_utils.find_ffmpeg() is None, reason="ffmpeg 미설치")
def test_export_creates_trimmed_file(tmp_path):
    src = str(tmp_path / "src.mp4")
    out = str(tmp_path / "out.mp4")
    _make_sample(src, seconds=5)

    results = {}
    worker = ExportWorker(src, start=1.0, length=2.0, output_path=out)
    worker.finished_ok.connect(lambda p: results.setdefault("ok", p))
    worker.failed.connect(lambda m: results.setdefault("err", m))
    worker.run()

    assert "ok" in results, results.get("err")
    assert os.path.exists(out)
    probe = subprocess.run(
        ffmpeg_utils.build_probe_cmd(ffmpeg_utils.find_ffprobe(), out),
        capture_output=True, text=True,
    )
    dur = ffmpeg_utils.parse_duration(probe.stdout)
    assert 1.8 <= dur <= 2.3
