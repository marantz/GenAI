# mymuse — Z-Image-Turbo LoRA 데이터셋 빌더

`source/<model>/<person>/` 에 모아둔 원본 사진을 **ai-toolkit(ostris) 규격의 LoRA 학습 데이터셋**과
**Z-Image-Turbo 학습용 YAML config** 로 한 번에 변환하는 CLI 도구다.

얼굴 감지 → 얼굴 중심 크롭/리사이즈 → 캡션 생성 → 데이터셋 저장 → config 생성까지 자동화하며,
이미 처리된 이미지는 건너뛰는 **증분(incremental)** 방식으로 동작한다.

---

## 1. 디렉토리 구조

```
mymuse/
├── prepare_dataset.py          # CLI 진입점 (파이프라인 오케스트레이션)
├── modules/
│   ├── scanner.py              # 신규 이미지 스캔 + stem 정규화 (증분 처리)
│   ├── face_processor.py       # 얼굴 감지 + 얼굴 중심 크롭/리사이즈
│   ├── captioner.py            # 캡션 문자열 생성 (trigger + class word)
│   ├── dataset_builder.py      # image.jpg + image.txt 쌍 저장
│   └── config_generator.py     # ai-toolkit diffusion_trainer YAML 생성
├── requirements.txt
├── source/                     # [입력] 원본 사진
│   └── <model>/<person>/*.png
└── lora/                       # [출력] 데이터셋 + config
    └── <model>/<person>/
        ├── dataset/            # image.jpg + image.txt (ai-toolkit 규격)
        └── <config_name>.yaml  # 학습 config
```

입력과 출력은 `<model>/<person>` 경로로 1:1 대응한다.
예) `source/Z-Image-Turbo/sara/` → `lora/Z-Image-Turbo/sara/dataset/`

현재 저장소에는 `Z-Image-Turbo/sara` 한 세트가 들어 있다 (원본 143장 → 데이터셋 143장).

---

## 2. 전체 처리 과정

```
source/<model>/<person>/*.png
        │
        ▼  ① ImageScanner.scan_new()
   신규 이미지만 선별 (이미 dataset/ 에 있는 stem 은 건너뜀)
        │
        ▼  ② FaceProcessor.process()
   얼굴 감지 → 가장 큰 얼굴 선택 → 최소 크기 필터 → 얼굴 중심 정사각 크롭
        │
        ▼  ③ FaceProcessor._resize_square()
   target_resolution(기본 1024) 정사각 LANCZOS 리사이즈
        │
        ▼  ④ build_caption()
   "<trigger>, <class word>"  (예: "sara, a woman")
        │
        ▼  ⑤ DatasetBuilder.save()
   lora/<model>/<person>/dataset/<stem>.jpg (JPEG q95) + <stem>.txt
        │
        ▼  ⑥ build_config() + save_config()
   lora/<model>/<person>/<config_name>.yaml (ai-toolkit 학습 config)
```

### 단계별 상세

| 단계 | 모듈 | 처리 내용 |
|---|---|---|
| ① 스캔 | `scanner.py` | 지원 포맷(`.jpg/.jpeg/.png`) 수집. 파일명을 `sanitize_stem()`(소문자화 + 비영숫자 → `_`)으로 정규화하고, 같은 stem 이 이미 `dataset/` 에 있으면 제외 → **재실행 시 신규 사진만 처리** |
| ② 얼굴 감지 | `face_processor.py` | InsightFace `buffalo_l`(CPU) 로 감지, 미설치 시 OpenCV Haar Cascade 로 자동 대체. 다중 얼굴이면 **가장 큰 얼굴(주 피사체)** 선택. `min_face_size`(기본 64px) 미만이면 제외 |
| ③ 크롭/리사이즈 | `face_processor.py` | 얼굴 bbox 중심으로 `face_crop_padding`(기본 1.8배) 정사각 크롭, 하단은 1.3배 여유를 줘 상반신 포함. 이후 `target_resolution` 정사각 리사이즈 |
| ④ 캡션 | `captioner.py` | ai-toolkit 권장대로 단순 캡션 `"<trigger>, <class word>"` 생성. 모델이 일관된 얼굴 특징을 스스로 학습하도록 의도 |
| ⑤ 저장 | `dataset_builder.py` | `<stem>.jpg`(RGB, JPEG quality=95) + 동일 이름 `<stem>.txt` 쌍으로 저장 |
| ⑥ config | `config_generator.py` | `diffusion_trainer` 규격 YAML 생성. config 는 신규 이미지 유무와 무관하게 **매 실행마다 갱신** |

> 신규 이미지가 없으면 ②~⑤ 는 건너뛰고 ⑥ config 만 다시 생성한다.

---

## 3. 생성되는 학습 Config

`config_generator.py` 는 Z-Image-Turbo 얼굴 LoRA 에 맞춰 튜닝된 ai-toolkit `diffusion_trainer` config 를 생성한다. 주요 기본값:

- **network**: LoRA `linear/linear_alpha = 64`, `conv/conv_alpha = 32` (얼굴 ID·디테일 강화), LoKr full-rank
- **train**: `steps = 2000`, `lr = 0.0001`, `optimizer = adamw8bit`, `timestep_type = weighted`, `content_or_style = content`, `dtype = bf16`
- **model**: `arch = zimage:turbo`, `qfloat8` 양자화(+ text encoder), `assistant_lora_path = zimage_turbo_training_adapter_v2`
- **dataset**: `resolution = [512, 768, 1024]`, `num_repeats = 3`, `flip_x = true`, `caption_dropout_rate = 0.05`
- **sample**: 200 step 마다 trigger word 포함 검증 프롬프트 3종 샘플링

### 학습 경로(중요)

데이터셋 빌드는 이 Mac 에서 하지만 **학습은 Windows AI-Toolkit 환경**에서 돌리는 것을 전제로,
config 안의 경로는 기본적으로 Windows 경로를 가리킨다.

| config 키 | 기본값 | 의미 |
|---|---|---|
| `training_folder` | `E:\TrainAI\AI-Toolkit\output` | 학습 결과 출력 폴더 |
| `datasets[].folder_path` | `E:\TrainAI\AI-Toolkit\datasets/<person>` | 학습기가 읽을 데이터셋 경로 |

> 빌드된 `dataset/` 폴더를 Windows AI-Toolkit 의 `datasets/<person>/` 로 복사하면 config 가 그대로 동작한다.
> 경로가 다르면 `--aitk-output` / `--aitk-datasets` 로 덮어쓴다.

---

## 4. 설치

```bash
pip install -r requirements.txt
```

`requirements.txt`: `torch`, `opencv-python`, `Pillow`, `pyyaml`, `rich`, `tqdm`, `onnxruntime`, `insightface`

> `insightface` / `onnxruntime` 가 없으면 얼굴 감지는 OpenCV Haar Cascade 로 자동 대체된다(정밀도는 낮음).
> 얼굴 감지는 **CPU** 로 동작하므로 GPU 가 없어도 데이터셋 빌드가 가능하다.

---

## 5. 실행 방법

### 기본 실행

```bash
python prepare_dataset.py --model Z-Image-Turbo --person sara
```

- 입력: `source/Z-Image-Turbo/sara/`
- 출력: `lora/Z-Image-Turbo/sara/dataset/` + `lora/Z-Image-Turbo/sara/qh_sara_v_0_0_1.yaml`
- trigger word 기본값: `sara` (= person 이름), 캡션: `"sara, a woman"`

### config 이름/버전 지정

```bash
python prepare_dataset.py -m Z-Image-Turbo -p sara --config-name qh_sara_v_0_0_2
```

→ `lora/Z-Image-Turbo/sara/qh_sara_v_0_0_2.yaml` 생성 (`config.name` / `meta.name` 도 동일).

### 자주 쓰는 옵션 조합

```bash
python prepare_dataset.py -m Z-Image-Turbo -p sara \
  --trigger-word "sara" \
  --class-word "a woman" \
  --lora-rank 64 \
  --steps 2000 \
  --num-repeats 3 \
  --aitk-datasets "E:\\TrainAI\\AI-Toolkit\\datasets"
```

### 전체 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--model`, `-m` | (필수) | `source/<model>/` 디렉토리 이름 |
| `--person`, `-p` | (필수) | `source/<model>/<person>/` 디렉토리 이름 |
| `--trigger-word` | `<person>` | LoRA trigger word |
| `--config-name` | `qh_<person>_v_0_0_1` | config.name 및 출력 yaml 파일명 |
| `--class-word` | `a woman` | 캡션 클래스 단어 (`"<trigger>, <class>"`) |
| `--lora-rank` | `64` | network.linear / linear_alpha |
| `--conv-rank` | `lora-rank // 2` | network.conv / conv_alpha |
| `--steps` | `2000` | 학습 스텝 수 |
| `--num-repeats` | `3` | dataset num_repeats |
| `--lr` | `0.0001` | 학습률 |
| `--no-flip-x` | (off) | 좌우 반전 augmentation 비활성화 |
| `--target-resolution` | `1024` | 출력 이미지 해상도 |
| `--aitk-output` | `E:\TrainAI\AI-Toolkit\output` | config 의 training_folder |
| `--aitk-datasets` | `E:\TrainAI\AI-Toolkit\datasets` | config 의 datasets 베이스 경로 |
| `--min-face-size` | `64` | 최소 얼굴 크기(px), 미만이면 제외 |
| `--face-crop-padding` | `1.8` | 얼굴 크롭 패딩 배율 |
| `--no-face-filter` | (off) | 얼굴 감지 필터 비활성화(전체 이미지 리사이즈만) |

---

## 6. 새 인물 추가 워크플로

```bash
# 1) 원본 사진을 source/<model>/<person>/ 에 넣는다
mkdir -p source/Z-Image-Turbo/jane
cp ~/photos/jane/*.png source/Z-Image-Turbo/jane/

# 2) 데이터셋 + config 생성
python prepare_dataset.py -m Z-Image-Turbo -p jane --config-name qh_jane_v_0_0_1

# 3) lora/Z-Image-Turbo/jane/dataset/ 를 Windows AI-Toolkit 의 datasets/jane/ 로 복사
# 4) qh_jane_v_0_0_1.yaml 로 ai-toolkit 학습 실행
```

사진을 더 추가한 뒤 같은 명령을 다시 실행하면 **신규 사진만** 추가 처리되고 config 가 갱신된다.
