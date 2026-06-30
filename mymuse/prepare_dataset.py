#!/usr/bin/env python3
"""CLI entry point: builds an ai-toolkit dataset + YAML config for one source/<model>/<person>/ pair."""

import argparse
from pathlib import Path

from modules.captioner import build_caption
from modules.config_generator import (
    DEFAULT_AITK_DATASETS,
    DEFAULT_AITK_OUTPUT,
    build_config,
    save_config,
)
from modules.dataset_builder import DatasetBuilder
from modules.face_processor import FaceProcessor
from modules.scanner import ImageScanner

REPO_ROOT = Path(__file__).resolve().parent


def build_paths(
    repo_root: Path,
    model: str,
    person: str,
    *,
    trigger_word: str | None = None,
    config_name: str | None = None,
    class_word: str = "a woman",
    aitk_output: str = DEFAULT_AITK_OUTPUT,
    aitk_datasets: str = DEFAULT_AITK_DATASETS,
) -> dict:
    person_dir = repo_root / "lora" / model / person
    cfg_name = config_name or f"qh_{person}_v_0_0_1"
    trigger = trigger_word or person
    return {
        "source_dir": repo_root / "source" / model / person,
        "person_dir": person_dir,
        # Local build target (where this Mac writes image/caption pairs).
        "dataset_dir": person_dir / "dataset",
        "config_path": person_dir / f"{cfg_name}.yaml",
        "config_name": cfg_name,
        "trigger_word": trigger,
        "caption": build_caption(trigger, class_word),
        # Training-side paths, consumed by AI-Toolkit on the Windows box.
        "training_folder": aitk_output,
        "dataset_folder_path": f"{aitk_datasets}/{person}",
    }


def parse_args():
    parser = argparse.ArgumentParser(
        description="source/<model>/<person>/ 의 원본 사진을 ai-toolkit LoRA 데이터셋으로 증분 변환한다"
    )
    parser.add_argument("--model", "-m", required=True, help="source/<model>/ 디렉토리 이름 (예: Z-Image-Turbo)")
    parser.add_argument("--person", "-p", required=True, help="source/<model>/<person>/ 디렉토리 이름 (예: sara)")
    parser.add_argument("--trigger-word", default=None, help="기본값: '<person>'")
    parser.add_argument("--config-name", default=None, help="config.name / 출력 yaml 파일명 (기본값: 'qh_<person>_v_0_0_1')")
    parser.add_argument("--class-word", default="a woman", help="캡션 클래스 단어 (기본값: 'a woman')")
    parser.add_argument("--lora-rank", type=int, default=64, help="network.linear / linear_alpha")
    parser.add_argument("--conv-rank", type=int, default=None, help="network.conv / conv_alpha (기본값: lora-rank // 2)")
    parser.add_argument("--steps", type=int, default=2000)
    parser.add_argument("--num-repeats", type=int, default=3, help="dataset num_repeats")
    parser.add_argument("--lr", type=float, default=0.0001)
    parser.add_argument("--no-flip-x", action="store_true", help="좌우 반전 augmentation 비활성화 (기본: 활성화)")
    parser.add_argument("--target-resolution", type=int, default=1024)
    parser.add_argument("--aitk-output", default=DEFAULT_AITK_OUTPUT, help="AI-Toolkit training_folder 경로")
    parser.add_argument("--aitk-datasets", default=DEFAULT_AITK_DATASETS, help="AI-Toolkit datasets 베이스 경로 (folder_path = <base>/<person>)")
    parser.add_argument("--min-face-size", type=int, default=64)
    parser.add_argument("--face-crop-padding", type=float, default=1.8)
    parser.add_argument("--no-face-filter", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    paths = build_paths(
        REPO_ROOT,
        args.model,
        args.person,
        trigger_word=args.trigger_word,
        config_name=args.config_name,
        class_word=args.class_word,
        aitk_output=args.aitk_output,
        aitk_datasets=args.aitk_datasets,
    )
    conv_rank = args.conv_rank if args.conv_rank is not None else args.lora_rank // 2

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

        for img in processed:
            img.caption = paths["caption"]

        builder = DatasetBuilder(paths["dataset_dir"])
        saved, failed = builder.save(processed)
        print(f"저장 완료: {saved}장 / 실패: {failed}장")
    else:
        print("신규 이미지가 없습니다. 기존 데이터셋을 그대로 둡니다.")

    cfg = build_config(
        config_name=paths["config_name"],
        trigger_word=paths["trigger_word"],
        caption=paths["caption"],
        dataset_folder_path=paths["dataset_folder_path"],
        training_folder=paths["training_folder"],
        lora_rank=args.lora_rank,
        conv_rank=conv_rank,
        steps=args.steps,
        target_resolution=args.target_resolution,
        num_repeats=args.num_repeats,
        flip_x=not args.no_flip_x,
        lr=args.lr,
    )
    save_config(paths["config_path"], cfg)
    print(f"Config 갱신: {paths['config_path']}")


if __name__ == "__main__":
    main()
