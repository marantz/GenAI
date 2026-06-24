"""Build the fixed 'simple' caption used for Z-Image-Turbo face LoRA training."""


def build_caption(trigger_word: str) -> str:
    return f"{trigger_word}, photo of a person, natural lighting, sharp focus on face, portrait"
