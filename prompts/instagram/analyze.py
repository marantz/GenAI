#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
하위 사용자 폴더의 인스타 이미지를 vLLM(OpenAI 호환) VLM으로 분석한다.
여성 사진만 골라, 얼굴 생김새를 제외한 배경 묘사 + 몸매/의상 + 찍힌 포즈를
자연스러운 한국어 '한 줄' 설명으로 instagram.txt 에 누적한다.

- lists.txt: 처리된 '사용자/이미지명' 을 기록(여성/비여성 모두). 재실행 시 미처리만 처리.
- instagram.txt: 여성 사진의 설명만 한 줄씩 append. CR/LF/연속공백은 단일 공백으로 축약.
"""

import argparse
import base64
import io
import os
import re
import sys

from openai import OpenAI
from PIL import Image

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
NOT_FEMALE = "NOT_FEMALE"

# 주 피사체 판별 + 얼굴 제외 규칙은 모든 focus 모드 공통.
SYSTEM_BASE = (
    "당신은 사진을 분석하는 한국어 어시스턴트입니다. "
    "사진의 주 피사체가 여성이 아니라면(남성, 풍경, 제품, 동물, 사람 없음 등) "
    f"다른 말 없이 정확히 '{NOT_FEMALE}' 한 단어만 출력하세요. "
    "주 피사체가 여성이라면, 얼굴 생김새(이목구비)는 묘사하지 마세요. "
)

# focus 모드별 묘사 지침.
SYSTEM_FOCUS = {
    "default": (
        "배경, 여성의 몸매, 의상, 그리고 사진에서 취하고 있는 포즈를 "
        "자연스러운 한국어 한 문단으로 묘사하세요. 줄바꿈 없이 작성하세요."
    ),
    "clothing": (
        "착용한 의상을 패션 카탈로그 수준으로 아주 자세히 묘사하세요. "
        "보이는 각 아이템(상의, 하의, 아우터, 원피스, 신발, 가방, 모자, 액세서리 등)별로 "
        "색상(메인 컬러와 포인트 컬러), 소재·재질감(면, 린넨, 니트, 데님, 가죽, 실크, 시폰, 트위드 등), "
        "실루엣과 핏(오버핏·슬림·박시 등), 기장, 패턴·프린트, "
        "그리고 디자인 디테일(의상에 원래 잡혀 있는 주름·플리츠·셔링·드레이프, 절개선, 자수, 단추, 지퍼, "
        "카라 형태, 소매·넥라인 형태, 밑단 처리 등)을 구체적으로 포함하세요. "
        "배경과 포즈는 한두 마디로만 간략히 언급하세요. "
        "자연스러운 한국어 한 문단으로, 줄바꿈 없이 작성하세요."
    ),
}

USER_FOCUS = {
    "default": (
        "이 사진을 분석하세요. 여성이 아니면 "
        f"'{NOT_FEMALE}' 만 출력하고, 여성이면 얼굴 생김새를 제외한 "
        "배경 묘사와 몸매·의상, 그리고 찍힌 포즈를 한국어로 묘사하세요."
    ),
    "clothing": (
        "이 사진을 분석하세요. 여성이 아니면 "
        f"'{NOT_FEMALE}' 만 출력하고, 여성이면 얼굴 생김새를 제외한 채 "
        "착용한 의상을 색상·소재·실루엣·패턴·디자인 디테일(주름·플리츠 등 포함)까지 "
        "패션 카탈로그처럼 아주 자세히 한국어로 묘사하세요."
    ),
}


def build_prompts(focus):
    """focus 모드에 맞는 (system, user) 프롬프트 쌍을 반환."""
    return SYSTEM_BASE + SYSTEM_FOCUS[focus], USER_FOCUS[focus]


def encode_image(path, max_size):
    """이미지를 열어 긴 변 <= max_size 로 리사이즈하고 JPEG base64 data URI 로 반환."""
    with Image.open(path) as im:
        im = im.convert("RGB")
        im.thumbnail((max_size, max_size))
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=90)
    b64 = base64.b64encode(buf.getvalue()).decode("ascii")
    return f"data:image/jpeg;base64,{b64}"


def one_line(text):
    """CR/LF 및 연속 공백을 단일 공백으로 축약한 한 줄 문자열."""
    return re.sub(r"\s+", " ", text).strip()


def load_processed(lists_path):
    if not os.path.exists(lists_path):
        return set()
    with open(lists_path, "r", encoding="utf-8") as f:
        return {line.strip() for line in f if line.strip()}


def iter_images(root):
    """root 하위 사용자 폴더의 이미지를 (사용자, 파일명, 전체경로) 로 yield."""
    for user in sorted(os.listdir(root)):
        user_dir = os.path.join(root, user)
        if not os.path.isdir(user_dir) or user.startswith("."):
            continue
        for name in sorted(os.listdir(user_dir)):
            if os.path.splitext(name)[1].lower() in IMAGE_EXTS:
                yield user, name, os.path.join(user_dir, name)


def analyze_one(client, model, data_uri, system_prompt, user_prompt, max_tokens=512):
    resp = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_prompt},
                    {"type": "image_url", "image_url": {"url": data_uri}},
                ],
            },
        ],
        temperature=0.4,
        max_tokens=max_tokens,
    )
    return resp.choices[0].message.content or ""


def main():
    ap = argparse.ArgumentParser(description="인스타 이미지 VLM 분석 → instagram.txt")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "users"),
                    help="사용자 폴더들이 있는 루트 (기본: <스크립트 위치>/users)")
    ap.add_argument("--base-url", default=os.environ.get("VLM_BASE_URL", "http://192.168.11.126:8000/v1"))
    ap.add_argument("--model", default=os.environ.get("VLM_MODEL", "nvidia/diffusiongemma-26B-A4B-it-NVFP4"))
    ap.add_argument("--api-key", default=os.environ.get("VLM_API_KEY", "EMPTY"))
    ap.add_argument("--max-size", type=int, default=1024, help="이미지 긴 변 최대 픽셀")
    ap.add_argument("--focus", choices=sorted(SYSTEM_FOCUS), default="default",
                    help="묘사 초점. default: 배경·몸매·의상·포즈, "
                         "clothing: 의상을 색상·소재·실루엣·패턴·디테일(주름/플리츠 등)까지 상세 묘사")
    ap.add_argument("--max-tokens", type=int, default=512,
                    help="응답 최대 토큰 (clothing 상세 묘사 시 늘리는 것을 권장)")
    ap.add_argument("--lists", default=None, help="처리 목록 파일 (기본: <root>/lists.txt)")
    ap.add_argument("--output", default=None, help="설명 출력 파일 (기본: <root>/instagram.txt)")
    args = ap.parse_args()

    system_prompt, user_prompt = build_prompts(args.focus)

    root = os.path.abspath(args.root)
    # lists/output 은 이미지(users/)와 분리해 스크립트 디렉토리에 둔다.
    script_dir = os.path.dirname(os.path.abspath(__file__))
    lists_path = args.lists or os.path.join(script_dir, "lists.txt")
    output_path = args.output or os.path.join(script_dir, "instagram.txt")

    client = OpenAI(base_url=args.base_url, api_key=args.api_key)
    processed = load_processed(lists_path)

    images = [t for t in iter_images(root) if f"{t[0]}/{t[1]}" not in processed]
    total = len(images)
    print(f"총 {total} 개 미처리 이미지 (이미 처리됨: {len(processed)}) | focus={args.focus}")
    if total == 0:
        return

    done = 0
    for user, name, path in images:
        key = f"{user}/{name}"
        done += 1
        prefix = f"[{done}/{total}] {key}"
        try:
            data_uri = encode_image(path, args.max_size)
            raw = analyze_one(client, args.model, data_uri,
                              system_prompt, user_prompt, args.max_tokens)
        except Exception as e:  # noqa: BLE001 - 실패 시 lists 미기록 → 다음 실행 재시도
            print(f"{prefix} -> ERROR: {e}", file=sys.stderr)
            continue

        text = raw.strip()
        is_female = NOT_FEMALE not in text.upper()

        if is_female:
            line = one_line(text)
            if line:
                with open(output_path, "a", encoding="utf-8") as fo:
                    fo.write(line + "\n")
                    fo.flush()
                    os.fsync(fo.fileno())
            print(f"{prefix} -> female")
        else:
            print(f"{prefix} -> skip (non-female)")

        # 성공 처리분만 기록 (여성/비여성 공통)
        with open(lists_path, "a", encoding="utf-8") as fl:
            fl.write(key + "\n")
            fl.flush()
            os.fsync(fl.fileno())

    print("완료.")


if __name__ == "__main__":
    main()
