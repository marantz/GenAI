"""Build and persist the ai-toolkit YAML training config for a Z-Image-Turbo face LoRA."""

from pathlib import Path

import yaml


def build_config(
    *,
    lora_name: str,
    trigger_word: str,
    dataset_dir: Path,
    lora_rank: int = 64,
    steps: int = 4000,
    target_resolution: int = 1024,
) -> dict:
    return {
        "job": "extension",
        "config": {
            "name": lora_name,
            "process": [{
                "type": "sd_trainer",
                "training_folder": "output",
                "device": "cuda:0",
                "trigger_word": trigger_word,
                "network": {
                    "type": "lora",
                    "linear": lora_rank,
                    "linear_alpha": lora_rank,
                },
                "save": {
                    "dtype": "float16",
                    "save_every": 250,
                    "max_step_saves_to_keep": 6,
                },
                "datasets": [{
                    "folder_path": str(dataset_dir.resolve()),
                    "caption_ext": "txt",
                    "caption_dropout_rate": 0.05,
                    "cache_latents_to_disk": True,
                    "resolution": [512, 768, target_resolution],
                }],
                "train": {
                    "batch_size": 1,
                    "steps": steps,
                    "gradient_accumulation_steps": 1,
                    "train_unet": True,
                    "train_text_encoder": False,
                    "gradient_checkpointing": True,
                    "noise_scheduler": "flowmatch",
                    "optimizer": "adamw8bit",
                    "lr": 0.0002,
                    "weight_decay": 0.0001,
                    "timestep_type": "sigmoid",
                },
                "model": {
                    "name_or_path": "Tongyi-MAI/Z-Image-Turbo",
                    "arch": "zimage",
                    "assistant_lora_path": (
                        "ostris/zimage_turbo_training_adapter/"
                        "zimage_turbo_training_adapterV2.safetensors"
                    ),
                    "quantize": True,
                },
                "sample": {
                    "sampler": "flowmatch",
                    "sample_every": 250,
                    "width": target_resolution,
                    "height": target_resolution,
                    "prompts": [
                        f"{trigger_word}, portrait photo, natural lighting, sharp focus",
                        f"{trigger_word}, outdoor photo, casual wear, smiling",
                        f"{trigger_word}, close-up face, studio lighting",
                    ],
                    "seed": 42,
                    "guidance_scale": 1,
                    "sample_steps": 8,
                },
            }],
        },
        "meta": {
            "name": "[name]",
            "version": "1.0",
        },
    }


def save_config(output_path: Path, cfg: dict) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        yaml.dump(cfg, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
