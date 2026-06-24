from modules.captioner import build_caption


def test_build_caption_starts_with_trigger_word():
    caption = build_caption("quahand sara")
    assert caption.startswith("quahand sara, ")


def test_build_caption_exact_format():
    assert build_caption("quahand sara") == (
        "quahand sara, photo of a person, natural lighting, sharp focus on face, portrait"
    )
