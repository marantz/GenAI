"""Build the fixed 'simple' caption used for Z-Image-Turbo face LoRA training.

ai-toolkit recommends keeping captions minimal so the model learns consistent
facial features on its own: just the trigger word plus a class word.
"""


def build_caption(trigger_word: str, class_word: str = "a woman") -> str:
    return f"{trigger_word}, {class_word}"
