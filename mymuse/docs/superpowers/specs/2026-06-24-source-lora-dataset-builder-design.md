# source → lora 데이터셋 빌더 설계

날짜: 2026-06-24

## 1. 배경

`CLAUDE.md`는 ai-toolkit(ostris) 규격에 맞는 Z-Image-Turbo 얼굴 LoRA 데이터셋 준비 툴을 설계했다(대화형 + CLI 모드, 얼굴 감지/크롭/캡션/YAML 자동화). 실제 운영 구조는 다음과 같이 고정되어 있다:

- `source/<model>/<person>/` 에 원본 사진만 존재 (예: `source/Z-Image-Turbo/sara/`)
- `lora/<model>/<person>/` 에 ai-toolkit 학습용 데이터셋 + YAML config를 생성/갱신해야 함
- 사진이 추가되면 기존 데이터셋을 건드리지 않고 신규분만 증분 처리
- `source/`, `lora/`는 git에 커밋되지 않아야 함
- 학습 자체는 CUDA + ai-toolkit이 설치된 별도 서버에서 수행 (이 Mac은 전처리만)

CLAUDE.md 원안과의 차이점은 디렉토리 구조가 고정되어 있어 대화형 디렉토리 탐색이 불필요하고, 이 Mac(M1, CUDA 없음)에서는 InsightFace를 CPU로, 캡션은 Florence-2 대신 `simple` 고정 방식을 쓴다는 점이다.

## 2. 디렉토리 구조

```
prepare_dataset.py          ← CLI 진입점
modules/
├── __init__.py
├── scanner.py               ← source 스캔 + 증분 diff (이미 처리된 stem 스킵)
├── face_processor.py        ← InsightFace(CPU) 얼굴 감지, 폴백 OpenCV Haar Cascade, 크롭/리사이즈
├── captioner.py              ← simple 캡션 고정 생성
├── dataset_builder.py        ← jpg/txt 페어 저장 (원본 파일명 sanitize한 stem 유지)
└── config_generator.py       ← ai-toolkit YAML 생성/갱신
requirements.txt
.gitignore                    ← /source/ , /lora/ 추가
```

## 3. 실행 방법

```bash
python prepare_dataset.py --model Z-Image-Turbo --person sara
```

필수 인자: `--model`, `--person`
선택 오버라이드: `--lora-rank`(기본 64), `--steps`(기본 4000), `--target-resolution`(기본 1024), `--min-face-size`(기본 64), `--face-crop-padding`(기본 1.8), `--no-face-filter`, `--trigger-word`(기본값 override)

경로 매핑:
- 입력: `source/<model>/<person>/`
- 데이터셋 출력: `lora/<model>/<person>/dataset/` (jpg+txt 페어)
- YAML 출력: `lora/<model>/<person>/<person>_zimage_lora.yaml` (dataset 디렉토리의 상위, 즉 `lora/<model>/<person>/` 바로 아래)
- trigger word 기본값: `quahand <person>` (예: `quahand sara`)

## 4. 증분 처리 로직

1. `source/<model>/<person>/` 의 모든 `jpg/jpeg/png` 파일을 스캔
2. 각 원본 파일명을 sanitize하여 stem 생성: 소문자화, 공백/특수문자를 `_`로 치환 (예: `2026-06-14 184017 ZIT_0001.png` → `2026-06-14_184017_zit_0001`)
3. `dataset/<stem>.jpg` + `dataset/<stem>.txt` 가 이미 존재하면 **스킵** (재처리하지 않음 — 수동으로 캡션을 고친 경우를 보존)
4. 존재하지 않는 신규 이미지만 얼굴 감지 → 크롭/리사이즈 → 캡션 생성 → 저장
5. YAML config는 신규 이미지 유무와 무관하게 **매 실행마다 재생성**하여 최신 옵션을 반영

원본 파일이 삭제되었을 때 데이터셋에서 대응 항목을 자동 삭제하는 기능은 범위에서 제외한다(추가만 지원).

## 5. 얼굴 감지

- 1차: InsightFace `buffalo_l`, `providers=["CPUExecutionProvider"]` (CUDA 없음, CPU 전용)
- `insightface` 미설치 시 OpenCV Haar Cascade로 자동 폴백 (이미 CLAUDE.md에 구현된 로직 재사용)
- 얼굴 없음 → 제외, 다중 얼굴 → 가장 큰 얼굴(주 피사체) 자동 선택, 최소 크기(`min_face_size`) 미만 제외
- 크롭: 얼굴 bbox 기준 padding 1.8배, 하단 1.3배 추가 (상반신 포함), 정사각형 보정 후 `target_resolution`으로 리사이즈

## 6. 캡션

- `simple` 고정 (Florence-2 경로는 CUDA 전용이라 이 Mac에서 제외): `"{trigger_word}, photo of a person, natural lighting, sharp focus on face, portrait"`

## 7. YAML Config

CLAUDE.md 4.9절의 Z-Image-Turbo 전용 설정을 재사용:
- `network.linear` / `linear_alpha`: lora_rank (기본 64)
- `save.dtype`: float16
- `train.optimizer`: adamw8bit, `timestep_type`: sigmoid, `noise_scheduler`: flowmatch
- `model.name_or_path`: `Tongyi-MAI/Z-Image-Turbo`, `arch`: zimage
- `model.assistant_lora_path`: `ostris/zimage_turbo_training_adapter/zimage_turbo_training_adapterV2.safetensors`
- `datasets[0].folder_path`: 이 Mac의 **로컬 절대경로**를 그대로 기록 (예: `/Users/.../lora/Z-Image-Turbo/sara/dataset`). 학습 서버에 업로드 시 사용자가 직접 경로를 수정한다 — 도구가 원격 경로를 추정하지 않는다.
- `sample.prompts`: trigger_word를 사용한 3개 샘플 프롬프트

## 8. .gitignore

루트 `.gitignore`에 다음 추가:
```
/source/
/lora/
```

## 9. requirements.txt

기존 CLAUDE.md 안의 목록에서 이 환경(M1 Mac, CUDA 없음)에 맞게 조정:
- `torch`, `opencv-python`, `Pillow`, `pyyaml`, `rich`, `tqdm` — 이미 설치됨, 명시
- `onnxruntime` (CPU, `-gpu` 아님) — 이미 설치됨, 명시
- `insightface` — 신규 추가 필요
- Florence-2 관련 `transformers`/`accelerate`는 simple 캡션만 쓰므로 제외

## 10. 테스트 전략

- `dataset_builder`/`scanner`의 증분 스킵 로직: 동일 stem이 이미 존재할 때 재처리하지 않는지 단위 테스트
- sanitize 함수: 공백/특수문자 입력에 대한 stem 변환 케이스 테스트
- `config_generator`: 동일 입력에 대해 YAML이 기대한 키 구조로 생성되는지 테스트
- 얼굴 감지/크롭은 실제 InsightFace 모델 가중치 다운로드가 필요해 단위 테스트에서는 모킹하거나 통합 테스트로 별도 분리
