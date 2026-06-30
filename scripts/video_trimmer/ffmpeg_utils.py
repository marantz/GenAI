"""ffmpeg/ffprobe 탐색 및 커맨드 생성 헬퍼 (순수 로직).

실제 프로세스 실행은 워커(QThread)와 main 에서 수행한다. 이 모듈은
바이너리 경로 탐색과 인자 리스트 생성, ffprobe 출력 파싱만 담당하여
ffmpeg 호출 없이 단위 테스트할 수 있게 한다.
"""

import json
import shutil


def find_ffmpeg() -> str | None:
    return shutil.which("ffmpeg")


def find_ffprobe() -> str | None:
    return shutil.which("ffprobe")


def parse_duration(ffprobe_json: str) -> float:
    data = json.loads(ffprobe_json)
    return float(data["format"]["duration"])


def build_probe_cmd(ffprobe: str, input_path: str) -> list[str]:
    return [
        ffprobe,
        "-v", "error",
        "-show_format",
        "-print_format", "json",
        input_path,
    ]


def build_thumbnail_cmd(
    ffmpeg: str, input_path: str, out_pattern: str, fps: int = 1
) -> list[str]:
    return [
        ffmpeg,
        "-y",
        "-i", input_path,
        "-vf", f"fps={fps}",
        out_pattern,
    ]


def build_export_cmd(
    ffmpeg: str, input_path: str, start: float, length: float, output_path: str
) -> list[str]:
    return [
        ffmpeg,
        "-y",
        "-i", input_path,
        "-ss", str(start),
        "-t", str(length),
        "-c:v", "libx264",
        "-c:a", "aac",
        output_path,
    ]
