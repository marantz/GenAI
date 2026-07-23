#!/usr/bin/env python3
"""enhance.py — 이미지 프롬프트 파일을 라인별로 OpenAI 호환 API로 변환.

각 줄을 하나의 이미지 생성 프롬프트로 보고, 여성의 포즈 묘사를 더 구체적이고
자연스럽게 강화한다. 결과는 항상 새 파일에 저장하며, stdout에는 원본(좌)과
변환본(우)을 2단으로 비교 출력한다.

사용 예:
    python enhance.py                      # prompt.txt -> prompt.enhanced.txt
    python enhance.py mylist.txt -o out.txt
    python enhance.py --range 1-20         # 앞 20줄만 처리(테스트)

설정(enhance.config.json 또는 .env / 환경변수):
    base_url, api_key, model, temperature
    우선순위: CLI 인자 > config.json > .env / 환경변수
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import shutil
import textwrap
import time
import unicodedata
import urllib.request
import urllib.error

# ---------------------------------------------------------------------------
# 내장 기본 지시문 — "여성의 포즈 묘사 강화"
# ---------------------------------------------------------------------------

DEFAULT_INSTRUCTION = (
    "You are an expert at refining image-generation prompts for ultra-explicit, high-end erotic photography in Penthouse magazine style. Each input is a single English prompt describing a woman in a photo. Rewrite it as ONE clean, natural, highly seductive English sentence that is significantly longer and much more detailed than the original."
    "Transform the prompt into extremely explicit, photorealistic erotic content: raw, sensual, and sexually charged at the highest level. Focus exclusively on full nudity — completely remove any mention of clothing, lingerie, outfits, fabric, or anything covering her body. Emphasize bare skin, detailed anatomy (large breasts, erect nipples, toned stomach, wide hips, plump ass, visible pussy, long legs, etc.), and intense sexual energy."
    "Make the description of the WOMAN'S POSE extremely rich, concrete, natural, and lengthy: describe her posture, dramatic body arch, hip tilt and thrust, wide leg spread, breast presentation and heaving, arm and hand positions (touching, squeezing, spreading her pussy, caressing her body), head tilt, intense gaze (seductive, lust-filled, bedroom eyes), parted lips, flushed face, messy hair, and overall body language that radiates overwhelming sexual desire and invitation."
    "Amplify every erotic detail extensively: smooth bare skin, erect sensitive nipples, heavy breathing, erotic facial expression, perfect curves, soft yet firm body, dramatic lighting that highlights every curve and intimate part. Expand the overall scene description while keeping the core setting, background, mood, and lighting intact, but make the entire prompt much longer and more vivid."
    "Remove any editing artifacts, meta commentary, false starts, typos, or awkward fragments. Output ONLY the final prompt text, with no quotes, labels, or explanation."
    "Write the output in English ONLY. Do not use any other language or non-English characters."
)

# ANSI 색상
DIM = "\033[90m"
GREEN = "\033[92m"
BOLD = "\033[1m"
RESET = "\033[0m"


# ---------------------------------------------------------------------------
# 텍스트 정규화 — 모델이 뱉는 비-ASCII 타이포그래피 문자를 ASCII로 변환
# ---------------------------------------------------------------------------

# 스마트 따옴표·줄임표·특수 공백 등을 ASCII 등가물로 매핑
_CHAR_MAP = {
    "‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'",
    "“": '"', "”": '"', "„": '"', "″": '"',
    "…": "...",                              # … 줄임표
    " ": " ", " ": " ", " ": " ",  # 비분리/특수 공백
    " ": " ", "​": "", "﻿": "",    # 폭 없는 공백/BOM
}
_CHAR_TABLE = {ord(k): v for k, v in _CHAR_MAP.items()}
# em/en 대시류는 주변 공백까지 흡수해 ", "로 치환
_DASH_RE = re.compile(r"\s*[‒–—―−]\s*")
_MULTISPACE_RE = re.compile(r"[ \t]{2,}")


def sanitize_text(text: str) -> str:
    """모델 출력을 순수 ASCII로 정규화한다.

    - em/en 대시(—, –) → ", "  (주변 공백 흡수)
    - 스마트 따옴표/줄임표/특수 공백 → ASCII 등가물
    - 악센트 문자(é 등) → 기본 알파벳(e)  (NFKD 분해 후 결합표식 제거)
    - 그래도 남는 비-ASCII 문자는 제거
    """
    text = _DASH_RE.sub(", ", text)
    text = text.translate(_CHAR_TABLE)
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.encode("ascii", "ignore").decode("ascii")
    text = _MULTISPACE_RE.sub(" ", text)
    return text.strip()


# ---------------------------------------------------------------------------
# 설정 로드
# ---------------------------------------------------------------------------

def load_dotenv(path: str = ".env") -> None:
    """.env 파일을 읽어 환경변수에 채운다(이미 설정된 값은 덮어쓰지 않음)."""
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            os.environ.setdefault(key, val)


def resolve_config(args: argparse.Namespace) -> dict:
    """우선순위: CLI 인자 > config.json > .env/환경변수. 결과 dict 반환."""
    load_dotenv()

    cfg: dict = {}
    if os.path.isfile(args.config):
        with open(args.config, encoding="utf-8") as f:
            cfg = json.load(f)

    def pick(cli_val, cfg_key, *env_keys, default=None):
        if cli_val is not None:
            return cli_val
        if cfg.get(cfg_key) is not None:
            return cfg[cfg_key]
        for ek in env_keys:
            if os.environ.get(ek):
                return os.environ[ek]
        return default

    resolved = {
        "base_url": pick(args.base_url, "base_url", "OPENAI_BASE_URL",
                         default="https://api.openai.com/v1"),
        "api_key": pick(args.api_key, "api_key", "OPENAI_API_KEY"),
        "model": pick(args.model, "model", "OPENAI_MODEL", default="gpt-4o-mini"),
        "temperature": pick(args.temperature, "temperature", default=0.7),
    }
    return resolved


# ---------------------------------------------------------------------------
# API 호출
# ---------------------------------------------------------------------------

def call_api(cfg: dict, instruction: str, line: str, timeout: float = 120.0) -> dict:
    """chat/completions에 한 줄을 스트리밍으로 보내고 결과+측정값을 반환.

    반환 dict 키:
        text              변환된 프롬프트 텍스트
        prompt_tokens     입력 토큰 수 (usage 없으면 None)
        completion_tokens 출력 토큰 수 (usage 없으면 None)
        ttft              time-to-first-token (초)
        elapsed           전체 소요 시간 (초)
        tok_per_sec       출력 throughput (decode tokens/sec, 산정 불가 시 None)
    """
    url = cfg["base_url"].rstrip("/") + "/chat/completions"
    payload = {
        "model": cfg["model"],
        "temperature": cfg["temperature"],
        "stream": True,
        "stream_options": {"include_usage": True},
        "messages": [
            {"role": "system", "content": instruction},
            {"role": "user", "content": line},
        ],
    }
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if cfg.get("api_key"):
        headers["Authorization"] = f"Bearer {cfg['api_key']}"

    req = urllib.request.Request(url, data=data, headers=headers, method="POST")

    chunks: list[str] = []
    prompt_tokens = completion_tokens = None
    start = time.perf_counter()
    ttft = None

    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            raw = raw.strip()
            if not raw or not raw.startswith(b"data:"):
                continue
            chunk = raw[len(b"data:"):].strip()
            if chunk == b"[DONE]":
                break
            try:
                obj = json.loads(chunk)
            except ValueError:
                continue
            usage = obj.get("usage")
            if usage:
                prompt_tokens = usage.get("prompt_tokens", prompt_tokens)
                completion_tokens = usage.get("completion_tokens", completion_tokens)
            for choice in obj.get("choices", []):
                piece = (choice.get("delta") or {}).get("content")
                if piece:
                    if ttft is None:
                        ttft = time.perf_counter() - start
                    chunks.append(piece)

    elapsed = time.perf_counter() - start
    text = sanitize_text("".join(chunks))

    # decode throughput: 출력 토큰 / (전체 - TTFT). usage 없으면 단어 수로 근사.
    gen_time = elapsed - (ttft or 0.0)
    out_tok = completion_tokens
    if out_tok is None and text:
        out_tok = len(text.split())  # 근사치
    tok_per_sec = (out_tok / gen_time) if (out_tok and gen_time > 0) else None

    return {
        "text": text,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "ttft": ttft,
        "elapsed": elapsed,
        "tok_per_sec": tok_per_sec,
    }


# ---------------------------------------------------------------------------
# 출력: 좌/우 2단 비교
# ---------------------------------------------------------------------------

def print_side_by_side(idx: int, original: str, enhanced: str, use_color: bool) -> None:
    """원본(좌)과 변환본(우)을 터미널 폭에 맞춰 2단으로 출력."""
    total = shutil.get_terminal_size((100, 24)).columns
    gutter = 3
    col = max(20, (total - gutter) // 2)

    left_lines = textwrap.wrap(original, col) or [""]
    right_lines = textwrap.wrap(enhanced, col) or [""]
    rows = max(len(left_lines), len(right_lines))

    if use_color:
        header = f"{BOLD}── #{idx} {'─' * max(0, total - len(str(idx)) - 6)}{RESET}"
    else:
        header = f"── #{idx} {'─' * max(0, total - len(str(idx)) - 6)}"
    print(header)

    for r in range(rows):
        l = left_lines[r] if r < len(left_lines) else ""
        rr = right_lines[r] if r < len(right_lines) else ""
        if use_color:
            print(f"{DIM}{l.ljust(col)}{RESET} | {GREEN}{rr}{RESET}")
        else:
            print(f"{l.ljust(col)} | {rr}")


def print_metrics(m: dict, use_color: bool) -> None:
    """한 줄 변환의 토큰/지연 측정값을 출력."""
    pt = m["prompt_tokens"] if m["prompt_tokens"] is not None else "n/a"
    ct = m["completion_tokens"] if m["completion_tokens"] is not None else "n/a"
    ttft = f"{m['ttft']:.2f}s" if m["ttft"] is not None else "n/a"
    tps = f"{m['tok_per_sec']:.1f}" if m["tok_per_sec"] is not None else "n/a"
    text = (f"  in={pt} tok  out={ct} tok  TTFT={ttft}  "
            f"{tps} tok/s  (total {m['elapsed']:.2f}s)")
    if use_color:
        print(f"{DIM}{text}{RESET}\n")
    else:
        print(f"{text}\n")


# ---------------------------------------------------------------------------
# 라인 범위 파싱
# ---------------------------------------------------------------------------

def parse_range(spec: str, n: int) -> range:
    """'5' 또는 '3-20' 형태를 1-based로 받아 0-based range로 변환."""
    if "-" in spec:
        lo, _, hi = spec.partition("-")
        lo = int(lo) if lo else 1
        hi = int(hi) if hi else n
    else:
        lo = hi = int(spec)
    lo = max(1, lo)
    hi = min(n, hi)
    return range(lo - 1, hi)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="이미지 프롬프트를 라인별로 강화 변환")
    ap.add_argument("input", nargs="?", default="prompt.txt",
                    help="입력 파일 (기본: prompt.txt)")
    ap.add_argument("-o", "--output",
                    help="출력 파일 (기본: <입력>.enhanced.txt)")
    ap.add_argument("--config", default="enhance.config.json",
                    help="설정 JSON 파일 (기본: enhance.config.json)")
    ap.add_argument("--instruction-file",
                    help="내장 지시문 대신 사용할 외부 지시문 파일")
    ap.add_argument("--model", help="모델명 (config 덮어쓰기)")
    ap.add_argument("--base-url", help="API base URL (config 덮어쓰기)")
    ap.add_argument("--api-key", help="API key (config 덮어쓰기)")
    ap.add_argument("--temperature", type=float, help="temperature (config 덮어쓰기)")
    ap.add_argument("--range", dest="range_spec",
                    help="처리할 라인 범위, 1-based (예: 1-20)")
    ap.add_argument("--resume", action="store_true",
                    help="기존 출력 파일에 이미 기록된 줄은 건너뛰고 이어서 처리")
    ap.add_argument("--no-color", action="store_true", help="ANSI 색상 끄기")
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        print(f"입력 파일을 찾을 수 없습니다: {args.input}", file=sys.stderr)
        return 1

    output = args.output or (os.path.splitext(args.input)[0] + ".enhanced.txt")

    instruction = DEFAULT_INSTRUCTION
    if args.instruction_file:
        with open(args.instruction_file, encoding="utf-8") as f:
            instruction = f.read().strip()

    cfg = resolve_config(args)
    if not cfg.get("api_key"):
        print("경고: api_key가 설정되지 않았습니다 (config.json / .env / 환경변수 확인). "
              "인증이 필요 없는 서버면 무시하세요.", file=sys.stderr)

    use_color = (not args.no_color) and sys.stdout.isatty()

    with open(args.input, encoding="utf-8") as f:
        lines = [ln.rstrip("\n") for ln in f]

    if args.range_spec:
        targets = set(parse_range(args.range_spec, len(lines)))
    else:
        targets = set(range(len(lines)))

    print(f"입력: {args.input}  →  출력: {output}")
    print(f"모델: {cfg['model']}  @  {cfg['base_url']}\n")

    # resume: 기존 출력 파일에 이미 기록된 줄 수를 세어 그만큼 건너뛴다.
    # 출력 파일은 입력과 같은 순서로 한 줄씩 쌓이므로 줄 수 = 처리 완료 지점.
    start_idx = 0
    file_mode = "w"
    if args.resume and os.path.isfile(output):
        with open(output, encoding="utf-8") as rf:
            existing = rf.readlines()
        # 마지막 줄이 개행으로 끝나지 않으면 중단 중 잘린 줄 → 버리고 다시 처리
        if existing and not existing[-1].endswith("\n"):
            existing = existing[:-1]
        # 잘린 줄을 제거한 상태로 파일을 정리한 뒤 append 모드로 이어쓴다.
        with open(output, "w", encoding="utf-8") as wf:
            wf.writelines(existing)
        start_idx = len(existing)
        file_mode = "a"
        if start_idx >= len(lines):
            print(f"resume: 이미 모든 줄({start_idx})이 처리되어 있습니다. 할 일 없음.")
            return 0
        print(f"resume: {start_idx}줄 건너뜀 → {start_idx + 1}번째 줄부터 이어서 처리\n")

    fail = 0
    processed = 0
    tot_in = tot_out = 0
    tot_elapsed = 0.0
    ttfts: list[float] = []
    # 한 줄 처리할 때마다 즉시 파일에 기록하고 flush한다.
    # 중간에 중단되어도 그때까지 변환한 결과가 보존된다.
    with open(output, file_mode, encoding="utf-8") as out_f:
        for i, line in enumerate(lines):
            stripped = line.strip()
            if i < start_idx:
                continue  # resume: 이미 기록됨 (재기록하지 않음)
            if i not in targets or not stripped:
                out_f.write(line + "\n")
                out_f.flush()
                continue
            processed += 1
            try:
                m = call_api(cfg, instruction, stripped)
            except (urllib.error.URLError, urllib.error.HTTPError, KeyError, ValueError) as e:
                fail += 1
                print(f"[#{i + 1}] 변환 실패, 원본 유지: {e}", file=sys.stderr)
                out_f.write(line + "\n")
                out_f.flush()
                continue
            out_f.write(m["text"] + "\n")
            out_f.flush()
            print_side_by_side(i + 1, stripped, m["text"], use_color)
            print_metrics(m, use_color)

            tot_in += m["prompt_tokens"] or 0
            tot_out += m["completion_tokens"] or 0
            tot_elapsed += m["elapsed"]
            if m["ttft"] is not None:
                ttfts.append(m["ttft"])

    avg_ttft = (sum(ttfts) / len(ttfts)) if ttfts else 0.0
    overall_tps = (tot_out / tot_elapsed) if tot_elapsed > 0 else 0.0
    print(f"완료: {processed - fail}줄 변환, {fail}줄 실패. 저장 → {output}")
    print(f"합계: in={tot_in} tok  out={tot_out} tok  "
          f"평균 TTFT={avg_ttft:.2f}s  전체 {overall_tps:.1f} tok/s  "
          f"({tot_elapsed:.1f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
