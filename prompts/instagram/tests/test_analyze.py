"""analyze.py 순수 함수 단위 테스트 (stdlib unittest만 사용, pytest 불필요).

실행:
    python3 -m unittest discover -s tests -v
"""

import os
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# analyze.py는 openai/Pillow에 의존하지만, 여기서 테스트하는 함수들은 순수 로직이라
# 두 패키지를 굳이 설치하지 않아도 되게 최소 스텁을 주입해 임포트만 성립시킨다.
if "openai" not in sys.modules:
    openai_stub = types.ModuleType("openai")
    openai_stub.OpenAI = object
    sys.modules["openai"] = openai_stub
if "PIL" not in sys.modules:
    pil_stub = types.ModuleType("PIL")
    pil_image_stub = types.ModuleType("PIL.Image")
    pil_stub.Image = pil_image_stub
    sys.modules["PIL"] = pil_stub
    sys.modules["PIL.Image"] = pil_image_stub

import analyze  # noqa: E402


class OneLineTest(unittest.TestCase):
    def test_collapses_crlf_and_repeated_whitespace(self):
        self.assertEqual(analyze.one_line("a\r\nb   c\n\nd"), "a b c d")

    def test_strips_leading_trailing_whitespace(self):
        self.assertEqual(analyze.one_line("  hello world  "), "hello world")

    def test_empty_string(self):
        self.assertEqual(analyze.one_line(""), "")


class IsFemaleResponseTest(unittest.TestCase):
    def test_not_female_marker_is_excluded(self):
        self.assertFalse(analyze.is_female_response("NOT_FEMALE"))
        self.assertFalse(analyze.is_female_response("  not_female  "))

    def test_normal_description_is_female(self):
        self.assertTrue(analyze.is_female_response("배경은 해변이고, 원피스를 입고 서 있다."))

    def test_case_insensitive(self):
        self.assertFalse(analyze.is_female_response("Not_Female"))


class BuildPromptsTest(unittest.TestCase):
    def test_default_focus_returns_pair(self):
        system, user = analyze.build_prompts("default")
        self.assertIn(analyze.NOT_FEMALE, system)
        self.assertIn(analyze.NOT_FEMALE, user)

    def test_clothing_focus_differs_from_default(self):
        s_default, u_default = analyze.build_prompts("default")
        s_clothing, u_clothing = analyze.build_prompts("clothing")
        self.assertNotEqual(s_default, s_clothing)
        self.assertNotEqual(u_default, u_clothing)

    def test_unknown_focus_raises(self):
        with self.assertRaises(KeyError):
            analyze.build_prompts("nope")


class LoadProcessedTest(unittest.TestCase):
    def test_missing_file_returns_empty_set(self):
        self.assertEqual(analyze.load_processed("/no/such/file.txt"), set())

    def test_reads_lines_as_set(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("user1/a.jpg\nuser1/b.jpg\n\nuser2/c.jpg\n")
            path = f.name
        try:
            self.assertEqual(
                analyze.load_processed(path),
                {"user1/a.jpg", "user1/b.jpg", "user2/c.jpg"},
            )
        finally:
            os.unlink(path)


class IterImagesTest(unittest.TestCase):
    def test_yields_supported_extensions_only_and_skips_dotdirs(self):
        with tempfile.TemporaryDirectory() as root:
            user_dir = os.path.join(root, "alice")
            os.makedirs(user_dir)
            for name in ("a.jpg", "b.PNG", "c.webp", "d.avif", "notes.txt"):
                open(os.path.join(user_dir, name), "w").close()
            hidden_dir = os.path.join(root, ".cache")
            os.makedirs(hidden_dir)
            open(os.path.join(hidden_dir, "e.jpg"), "w").close()

            found = sorted(name for _, name, _ in analyze.iter_images(root))
            self.assertEqual(found, ["a.jpg", "b.PNG", "c.webp", "d.avif"])

    def test_yields_user_and_full_path(self):
        with tempfile.TemporaryDirectory() as root:
            user_dir = os.path.join(root, "bob")
            os.makedirs(user_dir)
            open(os.path.join(user_dir, "x.jpg"), "w").close()

            [(user, name, path)] = list(analyze.iter_images(root))
            self.assertEqual(user, "bob")
            self.assertEqual(name, "x.jpg")
            self.assertEqual(path, os.path.join(user_dir, "x.jpg"))


if __name__ == "__main__":
    unittest.main()
