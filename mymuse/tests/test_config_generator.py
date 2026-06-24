from pathlib import Path

from modules.config_generator import build_config, save_config


def test_build_config_sets_trigger_word_and_rank():
    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("/tmp/dataset"),
        lora_rank=32,
        steps=3000,
        target_resolution=512,
    )
    process = cfg["config"]["process"][0]
    assert process["trigger_word"] == "quahand sara"
    assert process["network"]["linear"] == 32
    assert process["network"]["linear_alpha"] == 32
    assert process["train"]["steps"] == 3000
    assert process["sample"]["width"] == 512


def test_build_config_dataset_folder_path_is_absolute_string():
    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("relative/dataset"),
    )
    folder_path = cfg["config"]["process"][0]["datasets"][0]["folder_path"]
    assert Path(folder_path).is_absolute()


def test_build_config_uses_zimage_turbo_model_settings():
    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("/tmp/dataset"),
    )
    process = cfg["config"]["process"][0]
    model = process["model"]

    # Model architecture
    assert model["name_or_path"] == "Tongyi-MAI/Z-Image-Turbo"
    assert model["arch"] == "zimage"
    assert model["assistant_lora_path"] == (
        "ostris/zimage_turbo_training_adapter/"
        "zimage_turbo_training_adapterV2.safetensors"
    )

    # Training critical settings
    assert process["train"]["optimizer"] == "adamw8bit"
    assert process["train"]["timestep_type"] == "sigmoid"
    assert process["train"]["noise_scheduler"] == "flowmatch"

    # Data type precision
    assert process["save"]["dtype"] == "float16"


def test_save_config_writes_readable_yaml(tmp_path):
    import yaml

    cfg = build_config(
        lora_name="sara_zimage_lora",
        trigger_word="quahand sara",
        dataset_dir=Path("/tmp/dataset"),
    )
    out_path = tmp_path / "sara_zimage_lora.yaml"
    save_config(out_path, cfg)

    loaded = yaml.safe_load(out_path.read_text(encoding="utf-8"))
    assert loaded["config"]["name"] == "sara_zimage_lora"
