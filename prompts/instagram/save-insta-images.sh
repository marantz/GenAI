#!/usr/bin/env bash
#
# save-insta-images.sh
#
# cmux 브라우저(WKWebView)에 "현재 로드되어 보이는" Instagram 이미지를
# 페이지 자신의 인증 세션으로 in-page fetch 하여 그대로 저장한다.
#
# 우회 전략: 별도 HTTP 클라이언트를 쓰지 않고, 사용자가 이미 로그인한
# 실제 브라우저 안에서 fetch() 를 실행한다. 요청의 쿠키/Referer/Origin/
# TLS 지문이 전부 정상 브라우저와 동일하므로 봇 탐지를 최대한 우회한다.
#
# 사용법:
#   ./save-insta-images.sh https://www.instagram.com/<user>/   # 새 탭을 띄워 천천히 수집
#   ./save-insta-images.sh                                     # 이미 열린 instagram 탭에서 수집
#   SURFACE=surface:2 ./save-insta-images.sh                   # 특정 surface 지정
#
set -uo pipefail

CMUX="/Applications/cmux.app/Contents/Resources/bin/cmux"
URL="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_BASE="${OUT_BASE:-$SCRIPT_DIR/users}"   # 기본값: <스크립트 위치>/users (repo 동기화 제외 대상)
SURFACE="${SURFACE:-}"

# 사람과 유사한 속도로 "천천히" 수집하기 위한 파라미터
SCROLL_STEP_PX="${SCROLL_STEP_PX:-400}"   # 한 번에 스크롤할 양 (작을수록 가상화로 인한 누락↓)
SCROLL_ROUNDS="${SCROLL_ROUNDS:-}"        # 비우면 프로필의 게시물 수로 자동 산출
MIN_IMG_WIDTH="${MIN_IMG_WIDTH:-150}"     # 이 폭 미만의 아이콘류는 무시
DL_DELAY_MIN="${DL_DELAY_MIN:-1}"         # 이미지 사이 최소 지연(초)
DL_DELAY_MAX="${DL_DELAY_MAX:-3}"         # 이미지 사이 최대 지연(초)

log() { printf '\033[36m[insta]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[insta]\033[0m %s\n' "$*" >&2; }

jitter() {
  # DL_DELAY_MIN ~ DL_DELAY_MAX 사이 난수 초만큼 sleep (사람처럼 천천히)
  local lo="$1" hi="$2" span
  span=$(( hi - lo + 1 ))
  (( span < 1 )) && span=1
  sleep "$(( lo + RANDOM % span ))"
}

# ---------------------------------------------------------------------------
# 1) 대상 surface 결정 (URL 주면 새 탭, 아니면 열린 instagram 탭 탐색)
# ---------------------------------------------------------------------------
if [ -n "$URL" ]; then
  log "브라우저 탭을 띄웁니다: $URL"
  open_json="$("$CMUX" --json browser open "$URL" 2>&1)"
  # 새로 생성된 브라우저 surface 는 "surface_ref" 키 (source_surface_ref 와 혼동 금지)
  SURFACE="$(printf '%s' "$open_json" | grep -oE '"surface_ref"[^"]*"surface:[0-9]+"' | grep -oE 'surface:[0-9]+' | head -1)"
  if [ -z "$SURFACE" ]; then
    err "surface 를 찾지 못했습니다. cmux 응답: $open_json"
    exit 1
  fi
  log "surface=$SURFACE 에서 로딩 대기..."
  "$CMUX" browser "$SURFACE" wait --load-state complete --timeout-ms 20000 >/dev/null 2>&1
  sleep 3
elif [ -z "$SURFACE" ]; then
  log "열려 있는 instagram 탭을 찾는 중..."
  for n in 1 2 3 4 5 6 7 8 9 10; do
    u="$("$CMUX" browser "surface:$n" get url 2>/dev/null)"
    case "$u" in
      *instagram.com*) SURFACE="surface:$n"; break ;;
    esac
  done
  if [ -z "$SURFACE" ]; then
    err "열린 instagram 탭이 없습니다. 프로필 URL 을 인자로 넘겨주세요."
    exit 1
  fi
fi

PAGE_URL="$("$CMUX" browser "$SURFACE" get url 2>/dev/null)"
log "대상: $SURFACE  ($PAGE_URL)"

# 사용자명으로 저장 폴더 결정
USER_NAME="$(printf '%s' "$PAGE_URL" | sed -E 's#https?://[^/]*instagram\.com/##; s#/.*##; s/[?#].*//')"
[ -z "$USER_NAME" ] && USER_NAME="page"
OUT_DIR="$OUT_BASE/${USER_NAME}"   # 현재 디렉터리 아래 프로필명 폴더
mkdir -p "$OUT_DIR"
log "저장 위치: $OUT_DIR"

# ---------------------------------------------------------------------------
# 2) 게시물 수를 읽어 스크롤 횟수 결정 (SCROLL_ROUNDS 지정 시 그 값을 우선)
# ---------------------------------------------------------------------------
POST_COUNT="$("$CMUX" browser "$SURFACE" eval \
  "(()=>{const md=document.querySelector('meta[property=\"og:description\"],meta[name=\"description\"]');if(!md)return '';const c=md.content.replace(/,/g,'');const m=c.match(/([0-9]+)\\s*posts/i)||c.match(/게시물\\s*([0-9]+)/);return m?m[1]:'';})()" \
  2>/dev/null | tr -dc '0-9')"

if [ -n "$SCROLL_ROUNDS" ]; then
  log "스크롤 횟수: ${SCROLL_ROUNDS}회 (사용자 지정)"
elif [ -n "$POST_COUNT" ] && [ "$POST_COUNT" -gt 0 ]; then
  # 그리드 높이 추정 ≈ 게시물수 × 120px(한 줄 3개, 행높이≈360px ÷ 3).
  # 바닥까지 필요한 스크롤 ≈ 추정높이 / 스텝. 여유분 20회 + 로딩 지연 대비.
  SCROLL_ROUNDS=$(( POST_COUNT * 120 / SCROLL_STEP_PX + 20 ))
  [ "$SCROLL_ROUNDS" -lt 30 ] && SCROLL_ROUNDS=30
  [ "$SCROLL_ROUNDS" -gt 800 ] && SCROLL_ROUNDS=800   # 폭주 방지 상한
  log "게시물 ${POST_COUNT}개 감지 → 스크롤 횟수 ${SCROLL_ROUNDS}회로 설정 (스텝 ${SCROLL_STEP_PX}px)"
else
  SCROLL_ROUNDS=60
  log "게시물 수를 읽지 못해 기본 ${SCROLL_ROUNDS}회로 스크롤합니다"
fi

# ---------------------------------------------------------------------------
# 3) 천천히 스크롤하며 이미지 URL 을 "누적" 수집
#    (Instagram 그리드는 가상화되어 화면 밖 <img> 가 DOM 에서 제거되므로,
#     끝에서 한 번만 모으면 마지막 화면분만 잡힌다. 매 라운드마다 누적한다.)
# ---------------------------------------------------------------------------
URLS_FILE="$(mktemp)"
trap 'rm -f "$URLS_FILE"' EXIT

collect_into() {
  "$CMUX" browser "$SURFACE" eval \
    "(()=>{const s=new Set();document.querySelectorAll('img').forEach(i=>{const u=i.currentSrc||i.src||'';if(u.startsWith('http')&&i.naturalWidth>=${MIN_IMG_WIDTH})s.add(u);});return [...s].join('\n');})()" \
    2>/dev/null >> "$URLS_FILE"
}
uniq_count() { sort -u "$URLS_FILE" | grep -c . ; }

log "천천히 스크롤하며 이미지를 누적 수집합니다 (최대 ${SCROLL_ROUNDS}회)..."
"$CMUX" browser "$SURFACE" eval "window.scrollTo(0,0);" >/dev/null 2>&1   # 맨 위부터 시작
sleep 1
collect_into                      # 초기 화면 수집
prev_uniq="$(uniq_count)"; [ -z "$prev_uniq" ] && prev_uniq=0
nogrow=0
for r in $(seq 1 "$SCROLL_ROUNDS"); do
  # 스크롤 후 페이지 끝 도달 여부 반환
  pos="$("$CMUX" browser "$SURFACE" eval \
    "(()=>{window.scrollBy(0,${SCROLL_STEP_PX});return ((window.innerHeight+window.scrollY)>=(document.body.scrollHeight-200))?'BOTTOM':'MORE';})()" \
    2>/dev/null | tr -dc 'A-Z')"
  jitter 1 2
  collect_into
  cur_uniq="$(uniq_count)"; [ -z "$cur_uniq" ] && cur_uniq=0
  log "  스크롤 $r/${SCROLL_ROUNDS} · 누적 ${cur_uniq}장 (${pos:-?})"
  if [ "$cur_uniq" -le "$prev_uniq" ]; then
    nogrow=$(( nogrow + 1 ))
    # 새 이미지가 더 안 늘면 종료 (무한스크롤 로딩 지연 대비 5회 인내)
    [ "$nogrow" -ge 5 ] && { log "더 이상 새 이미지가 없습니다. 스크롤 종료."; break; }
  else
    nogrow=0
  fi
  prev_uniq="$cur_uniq"
done

# ---------------------------------------------------------------------------
# 4) 누적 URL 중복 제거
# ---------------------------------------------------------------------------
sort -u "$URLS_FILE" -o "$URLS_FILE"
total="$(grep -c . "$URLS_FILE" || true)"
log "수집 완료 — 고유 이미지 ${total}장. 다운로드를 시작합니다."

# ---------------------------------------------------------------------------
# 5) 페이지 컨텍스트 fetch -> base64 -> 파일 저장 (천천히, 순차)
# ---------------------------------------------------------------------------
ok=0; fail=0; skip=0; idx=0
while IFS= read -r url; do
  [ -z "$url" ] && continue
  idx=$(( idx + 1 ))

  # 파일명 베이스: CDN 경로 basename 에서 확장자 제거 (확장자는 실제 MIME 으로 결정)
  base="${url%%\?*}"
  stem="$(basename "$base")"
  stem="${stem%.*}"

  # 페이지 자신의 세션으로 fetch -> "mime|base64" 반환 (base64 에는 '|' 가 없음)
  resp="$("$CMUX" browser "$SURFACE" eval \
    "(async()=>{try{const r=await fetch(\"$url\");if(!r.ok)return 'ERR:HTTP'+r.status;const b=await r.blob();const a=new Uint8Array(await b.arrayBuffer());let s='';const C=0x8000;for(let i=0;i<a.length;i+=C){s+=String.fromCharCode.apply(null,a.subarray(i,i+C));}return (b.type||'image/jpeg')+'|'+btoa(s);}catch(e){return 'ERR:'+e.message;}})()" \
    2>/dev/null)"

  case "$resp" in
    ERR:*|"" )
      fail=$(( fail + 1 ))
      err "  [$idx/$total] 실패($resp): $stem"
      continue
      ;;
  esac

  mime="${resp%%|*}"
  b64="${resp#*|}"
  case "$mime" in
    image/png)  ext=png ;;
    image/webp) ext=webp ;;
    image/gif)  ext=gif ;;
    *)          ext=jpg ;;
  esac
  dest="$OUT_DIR/${stem}.${ext}"

  if [ -s "$dest" ]; then
    skip=$(( skip + 1 ))
    log "  [$idx/$total] 이미 있음, 건너뜀: ${stem}.${ext}"
    continue
  fi

  fname="${stem}.${ext}"
  if printf '%s' "$b64" | base64 -d > "$dest" 2>/dev/null && [ -s "$dest" ]; then
    ok=$(( ok + 1 ))
    sz="$(wc -c < "$dest" | tr -d ' ')"
    log "  [$idx/$total] 저장 ✓ $fname (${sz} bytes)"
  else
    rm -f "$dest"
    fail=$(( fail + 1 ))
    err "  [$idx/$total] 디코드 실패: $fname"
  fi

  jitter "$DL_DELAY_MIN" "$DL_DELAY_MAX"
done < "$URLS_FILE"

log "완료 — 저장 $ok · 건너뜀 $skip · 실패 $fail"
log "폴더: $OUT_DIR"
