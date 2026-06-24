from pathlib import Path

from prepare_dataset import build_paths


def test_build_paths_maps_source_to_lora_dataset_and_config():
    paths = build_paths(Path("/repo"), "Z-Image-Turbo", "sara")

    assert paths["source_dir"] == Path("/repo/source/Z-Image-Turbo/sara")
    assert paths["dataset_dir"] == Path("/repo/lora/Z-Image-Turbo/sara/dataset")
    assert paths["config_path"] == Path("/repo/lora/Z-Image-Turbo/sara/sara_zimage_lora.yaml")
    assert paths["lora_name"] == "sara_zimage_lora"
    assert paths["trigger_word"] == "quahand sara"
