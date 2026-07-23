"""enhance.py 순수 함수 단위 테스트 (stdlib unittest만 사용, pytest 불필요).

실행:
    python3 -m unittest discover -s tests -v
"""

import argparse
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import enhance  # noqa: E402


class SanitizeTextTest(unittest.TestCase):
    def test_smart_quotes_to_ascii(self):
        self.assertEqual(enhance.sanitize_text("‘hi’ “there”"), "'hi' \"there\"")

    def test_ellipsis_expanded(self):
        self.assertEqual(enhance.sanitize_text("wait… what"), "wait... what")

    def test_em_dash_becomes_comma(self):
        self.assertEqual(enhance.sanitize_text("raw — sensual"), "raw, sensual")

    def test_accented_characters_stripped_to_base(self):
        self.assertEqual(enhance.sanitize_text("café naïve"), "cafe naive")

    def test_multiple_spaces_collapsed(self):
        self.assertEqual(enhance.sanitize_text("a    b"), "a b")

    def test_remaining_non_ascii_dropped(self):
        # 비-ASCII(한자 등)는 제거되고 남는 공백은 단일 공백으로 정리된다.
        self.assertEqual(enhance.sanitize_text("hello 日本 world"), "hello world")


class ParseRangeTest(unittest.TestCase):
    def test_single_number(self):
        self.assertEqual(enhance.parse_range("5", 10), range(4, 5))

    def test_range_with_bounds(self):
        self.assertEqual(enhance.parse_range("3-7", 10), range(2, 7))

    def test_open_start(self):
        self.assertEqual(enhance.parse_range("-4", 10), range(0, 4))

    def test_open_end(self):
        self.assertEqual(enhance.parse_range("8-", 10), range(7, 10))

    def test_clamped_to_line_count(self):
        self.assertEqual(enhance.parse_range("1-100", 5), range(0, 5))

    def test_clamped_lower_bound(self):
        self.assertEqual(enhance.parse_range("0-3", 10), range(0, 3))


class ResolveConfigTest(unittest.TestCase):
    def _args(self, **overrides):
        base = dict(
            config="/no/such/config.json",
            base_url=None,
            api_key=None,
            model=None,
            temperature=None,
        )
        base.update(overrides)
        return argparse.Namespace(**base)

    def test_defaults_when_nothing_set(self):
        env_keep = {k: os.environ.pop(k, None) for k in ("OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENAI_MODEL")}
        try:
            cfg = enhance.resolve_config(self._args())
            self.assertEqual(cfg["base_url"], "https://api.openai.com/v1")
            self.assertEqual(cfg["model"], "gpt-4o-mini")
            self.assertEqual(cfg["temperature"], 0.7)
        finally:
            for k, v in env_keep.items():
                if v is not None:
                    os.environ[k] = v

    def test_cli_args_take_priority_over_config_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"model": "from-config", "base_url": "https://from-config/v1"}, f)
            path = f.name
        try:
            args = self._args(config=path, model="from-cli")
            cfg = enhance.resolve_config(args)
            self.assertEqual(cfg["model"], "from-cli")
            self.assertEqual(cfg["base_url"], "https://from-config/v1")
        finally:
            os.unlink(path)

    def test_config_file_used_when_no_cli_arg(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"model": "from-config", "temperature": 0.2}, f)
            path = f.name
        try:
            cfg = enhance.resolve_config(self._args(config=path))
            self.assertEqual(cfg["model"], "from-config")
            self.assertEqual(cfg["temperature"], 0.2)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
