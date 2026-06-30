import subprocess

import pytest

from video_trimmer import ffmpeg_utils
from video_trimmer.thumbnail_worker import ThumbnailWorker


def _make_sample(path, seconds=4):
    ffmpeg = ffmpeg_utils.find_ffmpeg()
    subprocess.run(
        [ffmpeg, "-y", "-f", "lavfi", "-i",
         f"testsrc=duration={seconds}:size=320x240:rate=30",
         "-pix_fmt", "yuv420p", path],
        check=True, capture_output=True,
    )


@pytest.mark.skipif(ffmpeg_utils.find_ffmpeg() is None, reason="ffmpeg 미설치")
def test_thumbnail_worker_creates_frames(tmp_path):
    src = str(tmp_path / "src.mp4")
    out_dir = tmp_path / "thumbs"
    out_dir.mkdir()
    _make_sample(src, seconds=4)

    results = {}
    worker = ThumbnailWorker(src, str(out_dir), fps=1)
    worker.done.connect(lambda paths: results.setdefault("paths", paths))
    worker.failed.connect(lambda m: results.setdefault("err", m))
    worker.run()

    assert "paths" in results, results.get("err")
    assert len(results["paths"]) >= 3
    assert all(p.endswith(".jpg") for p in results["paths"])
    assert results["paths"] == sorted(results["paths"])
