"""Build and persist the ai-toolkit YAML training config for a Z-Image-Turbo face LoRA.

Mirrors a hand-tuned ai-toolkit (diffusion_trainer) config: LoKr/conv network,
bf16, qfloat8 quantization, zimage:turbo arch and the v2 training adapter.
The training-side paths default to the Windows AI-Toolkit install where training runs.
"""

from pathlib import Path

import yaml

# Defaults point at the Windows AI-Toolkit install where training actually runs.
DEFAULT_AITK_OUTPUT = r"E:\TrainAI\AI-Toolkit\output"
DEFAULT_AITK_DATASETS = r"E:\TrainAI\AI-Toolkit\datasets"
DEFAULT_SQLITE_DB_PATH = "./aitk_db.db"


def build_config(
    *,
    config_name: str,
    trigger_word: str,
    caption: str,
    dataset_folder_path: str,
    training_folder: str = DEFAULT_AITK_OUTPUT,
    sqlite_db_path: str = DEFAULT_SQLITE_DB_PATH,
    lora_rank: int = 64,
    conv_rank: int = 32,
    steps: int = 2000,
    target_resolution: int = 1024,
    num_repeats: int = 3,
    flip_x: bool = True,
    lr: float = 0.0001,
) -> dict:
    return {
        "job": "extension",
        "config": {
            "name": config_name,
            "process": [{
                "type": "diffusion_trainer",
                "training_folder": training_folder,
                "sqlite_db_path": sqlite_db_path,
                "device": "cuda",
                "trigger_word": trigger_word,
                "performance_log_every": 10,
                "network": {
                    "type": "lora",
                    "linear": lora_rank,
                    "linear_alpha": lora_rank,
                    "conv": conv_rank,
                    "conv_alpha": conv_rank,
                    "lokr_full_rank": True,
                    "lokr_factor": -1,
                    "network_kwargs": {
                        "ignore_if_contains": [],
                    },
                },
                "save": {
                    "dtype": "bf16",
                    "save_every": 200,
                    "max_step_saves_to_keep": 4,
                    "save_format": "diffusers",
                    "push_to_hub": False,
                },
                "datasets": [{
                    "folder_path": dataset_folder_path,
                    "mask_path": None,
                    "mask_min_value": 0.1,
                    "default_caption": caption,
                    "caption_ext": "txt",
                    "caption_dropout_rate": 0.05,
                    "cache_latents_to_disk": False,
                    "is_reg": False,
                    "network_weight": 1,
                    "resolution": [512, 768, target_resolution],
                    "controls": [],
                    "shrink_video_to_frames": True,
                    "num_frames": 1,
                    "flip_x": flip_x,
                    "flip_y": False,
                    "num_repeats": num_repeats,
                }],
                "train": {
                    "batch_size": 1,
                    "bypass_guidance_embedding": False,
                    "steps": steps,
                    "gradient_accumulation": 1,
                    "train_unet": True,
                    "train_text_encoder": False,
                    "gradient_checkpointing": True,
                    "noise_scheduler": "flowmatch",
                    "optimizer": "adamw8bit",
                    "timestep_type": "weighted",
                    "content_or_style": "content",
                    "optimizer_params": {
                        "weight_decay": 0.0001,
                    },
                    "unload_text_encoder": False,
                    "cache_text_embeddings": False,
                    "lr": lr,
                    "ema_config": {
                        "use_ema": False,
                        "ema_decay": 0.99,
                    },
                    "skip_first_sample": False,
                    "force_first_sample": False,
                    "disable_sampling": False,
                    "dtype": "bf16",
                    "diff_output_preservation": False,
                    "diff_output_preservation_multiplier": 1,
                    "diff_output_preservation_class": "person",
                    "switch_boundary_every": 1,
                    "loss_type": "mse",
                },
                "logging": {
                    "log_every": 1,
                    "use_ui_logger": True,
                },
                "model": {
                    "name_or_path": "Tongyi-MAI/Z-Image-Turbo",
                    "quantize": True,
                    "qtype": "qfloat8",
                    "quantize_te": True,
                    "qtype_te": "qfloat8",
                    "arch": "zimage:turbo",
                    "low_vram": False,
                    "model_kwargs": {},
                    "compile": False,
                    "layer_offloading": False,
                    "layer_offloading_text_encoder_percent": 1,
                    "layer_offloading_transformer_percent": 1,
                    "assistant_lora_path": (
                        "ostris/zimage_turbo_training_adapter/"
                        "zimage_turbo_training_adapter_v2.safetensors"
                    ),
                },
                "sample": {
                    "sampler": "flowmatch",
                    "sample_every": 200,
                    "width": target_resolution,
                    "height": target_resolution,
                    "samples": [
                        {"prompt": f"{trigger_word}, portrait photo, close-up face, looking at viewer, natural lighting"},
                        {"prompt": f"{caption}, headshot, detailed face, soft lighting"},
                        {"prompt": f"{trigger_word}, face focus, upper body, sharp focus"},
                    ],
                    "neg": "",
                    "seed": 42,
                    "walk_seed": True,
                    "guidance_scale": 1,
                    "sample_steps": 8,
                    "num_frames": 1,
                    "fps": 1,
                },
            }],
        },
        "meta": {
            "name": config_name,
            "version": "1.0",
        },
    }


def save_config(output_path: Path, cfg: dict) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        yaml.dump(cfg, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
