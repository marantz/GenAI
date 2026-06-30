from video_trimmer import ffmpeg_utils


def test_parse_duration_reads_format_duration():
    sample = '{"format": {"duration": "42.5"}}'
    assert ffmpeg_utils.parse_duration(sample) == 42.5


def test_find_ffprobe_returns_path_or_none():
    result = ffmpeg_utils.find_ffprobe()
    assert result is None or result.endswith("ffprobe")


def test_build_probe_cmd():
    cmd = ffmpeg_utils.build_probe_cmd("/usr/bin/ffprobe", "in.mp4")
    assert cmd[0] == "/usr/bin/ffprobe"
    assert "-show_format" in cmd
    assert "-print_format" in cmd
    assert "json" in cmd
    assert cmd[-1] == "in.mp4"


def test_build_thumbnail_cmd_uses_fps_filter():
    cmd = ffmpeg_utils.build_thumbnail_cmd(
        "/usr/bin/ffmpeg", "in.mp4", "/tmp/t/thumb_%04d.jpg", fps=1
    )
    assert "-vf" in cmd
    vf = cmd[cmd.index("-vf") + 1]
    assert vf == "fps=1"
    assert cmd[-1] == "/tmp/t/thumb_%04d.jpg"


def test_build_export_cmd_output_seeking_and_codecs():
    cmd = ffmpeg_utils.build_export_cmd(
        "/usr/bin/ffmpeg", "in.mp4", start=16.0, length=16.1, output_path="out.mp4"
    )
    i_idx = cmd.index("-i")
    ss_idx = cmd.index("-ss")
    assert i_idx < ss_idx
    assert cmd[ss_idx + 1] == "16.0"
    t_idx = cmd.index("-t")
    assert cmd[t_idx + 1] == "16.1"
    assert "libx264" in cmd
    assert "aac" in cmd
    assert cmd[-1] == "out.mp4"
