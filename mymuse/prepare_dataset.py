#!/usr/bin/env python3
"""CLI entry point: builds an ai-toolkit dataset + YAML config for one source/<model>/<person>/ pair."""

import argparse
from pathlib import Path

from modules.captioner import build_caption
from modules.config_generator import build_config, save_config
from modules.dataset_builder import DatasetBuilder
from modules.face_processor import FaceProcessor
from modules.scanner import ImageScanner

REPO_ROOT = Path(__file__).resolve().parent


def build_paths(repo_root: Path, model: str, person: str, trigger_word: str | None = None) -> dict:
    person_dir = repo_root / "lora" / model / person
    lora_name = f"{person}_zimage_lora"
    return {
        "source_dir": repo_root / "source" / model / person,
        "person_dir": person_dir,
        "dataset_dir": person_dir / "dataset",
        "config_path": person_dir / f"{lora_name}.yaml",
        "lora_name": lora_name,
        "trigger_word": trigger_word or f"quahand {person}",
    }


def parse_args():
    parser = argparse.ArgumentParser(
        description="source/<model>/<person>/ 의 원본 사진을 ai-toolkit LoRA 데이터셋으로 증분 변환한다"
    )
    parser.add_argument("--model", "-m", required=True, help="source/<model>/ 디렉토리 이름 (예: Z-Image-Turbo)")
    parser.add_argument("--person", "-p", required=True, help="source/<model>/<person>/ 디렉토리 이름 (예: sara)")
    parser.add_argument("--trigger-word", default=None, help="기본값: 'quahand <person>'")
    parser.add_argument("--lora-rank", type=int, default=64)
    parser.add_argument("--steps", type=int, default=4000)
    parser.add_argument("--target-resolution", type=int, default=1024)
    parser.add_argument("--min-face-size", type=int, default=64)
    parser.add_argument("--face-crop-padding", type=float, default=1.8)
    parser.add_argument("--no-face-filter", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    paths = build_paths(REPO_ROOT, args.model, args.person, args.trigger_word)

    scanner = ImageScanner(paths["source_dir"], paths["dataset_dir"])
    new_entries = scanner.scan_new()
    print(f"신규 이미지: {len(new_entries)}장")

    if new_entries:
        face_proc = FaceProcessor(
            min_face_size=args.min_face_size,
            crop_padding=args.face_crop_padding,
            target_resolution=args.target_resolution,
            face_filter=not args.no_face_filter,
        )
        processed, skipped = face_proc.process(new_entries)
        print(f"얼굴 감지 통과: {len(processed)}장 / 제외: {skipped}장")

        caption = build_caption(paths["trigger_word"])
        for img in processed:
            img.caption = caption

        builder = DatasetBuilder(paths["dataset_dir"])
        saved, failed = builder.save(processed)
        print(f"저장 완료: {saved}장 / 실패: {failed}장")
    else:
        print("신규 이미지가 없습니다. 기존 데이터셋을 그대로 둡니다.")

    cfg = build_config(
        lora_name=paths["lora_name"],
        trigger_word=paths["trigger_word"],
        dataset_dir=paths["dataset_dir"],
        lora_rank=args.lora_rank,
        steps=args.steps,
        target_resolution=args.target_resolution,
    )
    save_config(paths["config_path"], cfg)
    print(f"Config 갱신: {paths['config_path']}")


if __name__ == "__main__":
    main()
