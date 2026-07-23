#!/usr/bin/env bash
#
# save-insta-images.sh
#
# cmux 브라우저(WKWebView)에 이미 로그인된 Instagram 세션을 그대로 이용해
# 페이지 자신의 인증 컨텍스트에서 이미지를 in-page fetch 하여 저장한다.
#
# 우회 전략: 별도 HTTP 클라이언트를 쓰지 않고, 사용자가 이미 로그인한
# 실제 브라우저 안에서 fetch() 를 실행한다. 쿠키/Referer/Origin/TLS 지문이
# 전부 정상 브라우저와 동일하므로 봇 탐지를 최대한 우회한다.
#
# 이 스크립트는 두 단계로 이미지를 모은다:
#   1) 프로필 그리드를 스크롤하며 각 게시물의 "커버" 이미지 + 퍼머링크를 수집
#   2) (EXPAND_POSTS=1, 기본값) 각 게시물 퍼머링크를 열어 캐러셀의 "모든" 슬라이드를
#      끝까지 넘겨 수집한다 — 그리드 썸네일만으로는 캐러셀의 2번째 사진부터는
#      영원히 빠지기(누락되기) 때문.
#
# 사용법:
#   ./save-insta-images.sh https://www.instagram.com/<user>/   # 새 탭을 띄워 천천히 수집
#   ./save-insta-images.sh                                     # 이미 열린 instagram 탭에서 수집
#   SURFACE=surface:2 ./save-insta-images.sh                   # 특정 surface 지정
#   ./save-insta-images.sh --selftest                          # 라이브 브라우저 없이 설정/스크립트 점검
#
set -uo pipefail

CMUX="/Applications/cmux.app/Contents/Resources/bin/cmux"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECT_JS="$SCRIPT_DIR/js/collect.js"

log() { printf '\033[36m[insta]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[insta]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[insta]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 0) --selftest: 라이브 Instagram 탭 없이 점검 가능한 부분만 검증하고 종료
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  ok=1
  [ -x "$CMUX" ] && log "cmux 실행 파일 확인: $CMUX" || { err "cmux 실행 파일을 찾을 수 없습니다: $CMUX"; ok=0; }
  if [ -f "$COLLECT_JS" ]; then
    if command -v node >/dev/null 2>&1; then
      if node --check "$COLLECT_JS" >/dev/null 2>&1; then
        log "js/collect.js 문법 검사 통과"
      else
        err "js/collect.js 문법 오류"; ok=0
      fi
    else
      warn "node 를 찾을 수 없어 js/collect.js 문법 검사를 건너뜁니다"
    fi
  else
    err "js/collect.js 가 없습니다: $COLLECT_JS"; ok=0
  fi
  log "설정: SCROLL_STEP_PX=${SCROLL_STEP_PX:-400} MIN_IMG_WIDTH=${MIN_IMG_WIDTH:-150} " \
      "EXPAND_POSTS=${EXPAND_POSTS:-1} INCLUDE_REELS=${INCLUDE_REELS:-0} " \
      "FETCH_RETRIES=${FETCH_RETRIES:-3} MIN_BYTES=${MIN_BYTES:-2000}"
  [ "$ok" = 1 ] && { log "selftest OK"; exit 0; } || { err "selftest 실패"; exit 1; }
fi

URL="${1:-}"
OUT_BASE="${OUT_BASE:-$SCRIPT_DIR/users}"   # 기본값: <스크립트 위치>/users (repo 동기화 제외 대상)
SURFACE="${SURFACE:-}"

# 사람과 유사한 속도로 "천천히" 수집하기 위한 파라미터
SCROLL_STEP_PX="${SCROLL_STEP_PX:-400}"     # 한 번에 스크롤할 양 (작을수록 가상화로 인한 누락↓)
SCROLL_ROUNDS="${SCROLL_ROUNDS:-}"          # 비우면 프로필의 게시물 수로 자동 산출
MIN_IMG_WIDTH="${MIN_IMG_WIDTH:-150}"       # 이 폭(px, srcset 기술자 기준) 미만 아이콘류는 무시
DL_DELAY_MIN="${DL_DELAY_MIN:-1}"           # 이미지 사이 최소 지연(초)
DL_DELAY_MAX="${DL_DELAY_MAX:-3}"           # 이미지 사이 최대 지연(초)

# 캐러셀 전체 수집 관련 파라미터
EXPAND_POSTS="${EXPAND_POSTS:-1}"           # 1이면 각 게시물을 열어 캐러셀 전체 슬라이드 수집
INCLUDE_REELS="${INCLUDE_REELS:-0}"         # 1이면 릴스(/reel/)도 게시물 열기 대상에 포함
MAX_POSTS="${MAX_POSTS:-0}"                 # 0=무제한. 테스트 시 적은 값으로 제한 가능
MAX_CAROUSEL_SLIDES="${MAX_CAROUSEL_SLIDES:-20}"  # 캐러셀당 최대 "다음" 클릭 횟수(무한루프 방지)
POST_DELAY_MIN="${POST_DELAY_MIN:-2}"       # 게시물 사이 최소 지연(초)
POST_DELAY_MAX="${POST_DELAY_MAX:-4}"       # 게시물 사이 최대 지연(초)
POST_WAIT_TIMEOUT_MS="${POST_WAIT_TIMEOUT_MS:-8000}"

# 다운로드 견고성 파라미터
FETCH_RETRIES="${FETCH_RETRIES:-3}"         # 이미지 1장당 재시도 횟수
FETCH_RETRY_BASE_SEC="${FETCH_RETRY_BASE_SEC:-2}"  # 재시도 대기(초, 회차마다 배가)
MIN_BYTES="${MIN_BYTES:-2000}"              # 이보다 작으면 차단/placeholder 응답으로 간주해 재시도
CONSEC_FAIL_BREAK="${CONSEC_FAIL_BREAK:-6}" # 연속 실패가 이 값 이상이면 서킷브레이커 휴식
CONSEC_FAIL_SLEEP="${CONSEC_FAIL_SLEEP:-30}" # 서킷브레이커 휴식 시간(초)

if [ ! -f "$COLLECT_JS" ]; then
  err "js/collect.js 를 찾을 수 없습니다: $COLLECT_JS"
  exit 1
fi
JS_LIB="$(cat "$COLLECT_JS")"

jitter() {
  # lo ~ hi 사이 난수 초만큼 sleep (사람처럼 천천히)
  local lo="$1" hi="$2" span
  span=$(( hi - lo + 1 ))
  (( span < 1 )) && span=1
  sleep "$(( lo + RANDOM % span ))"
}

# 페이지에서 collect.js 를 로드한 뒤 이어붙인 드라이버 코드를 실행한다.
evaljs() {
  "$CMUX" browser "$SURFACE" eval "$JS_LIB
$1"
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
  for n in $(seq 1 20); do
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
OUT_DIR="$OUT_BASE/${USER_NAME}"
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
  SCROLL_ROUNDS=$(( POST_COUNT * 120 / SCROLL_STEP_PX + 20 ))
  [ "$SCROLL_ROUNDS" -lt 30 ] && SCROLL_ROUNDS=30
  [ "$SCROLL_ROUNDS" -gt 800 ] && SCROLL_ROUNDS=800   # 폭주 방지 상한
  log "게시물 ${POST_COUNT}개 감지 → 스크롤 횟수 ${SCROLL_ROUNDS}회로 설정 (스텝 ${SCROLL_STEP_PX}px)"
else
  SCROLL_ROUNDS=60
  log "게시물 수를 읽지 못해 기본 ${SCROLL_ROUNDS}회로 스크롤합니다"
fi

# ---------------------------------------------------------------------------
# 3) 천천히 스크롤하며 게시물(퍼머링크+커버이미지)을 "누적" 수집
#    (Instagram 그리드는 가상화되어 화면 밖 <img> 가 DOM 에서 제거되므로,
#     끝에서 한 번만 모으면 마지막 화면분만 잡힌다. 매 라운드마다 누적한다.
#     naturalWidth(로드완료) 에 의존하지 않고 srcset 속성만 보므로,
#     아직 로딩 중인 이미지도 URL 자체는 놓치지 않는다.)
# ---------------------------------------------------------------------------
ITEMS_FILE="$(mktemp)"     # "permalink<TAB>type<TAB>coverUrl" 누적 (탭 구분, 중복 포함)
trap 'rm -f "$ITEMS_FILE" "${URLS_FILE:-}" "${PERMALINKS_FILE:-}"' EXIT

collect_grid_into() {
  evaljs "(()=>{const items=collectGridItems(document, location.origin, ${MIN_IMG_WIDTH});return items.map(it=>[it.permalink||'',it.type||'',it.coverUrl||''].join('\t')).join('\n');})()" \
    2>/dev/null >> "$ITEMS_FILE"
}
uniq_permalink_count() { awk -F'\t' '{print $1}' "$ITEMS_FILE" | sort -u | grep -c . ; }

log "천천히 스크롤하며 게시물을 누적 수집합니다 (최대 ${SCROLL_ROUNDS}회)..."
"$CMUX" browser "$SURFACE" eval "window.scrollTo(0,0);" >/dev/null 2>&1   # 맨 위부터 시작
sleep 1
collect_grid_into                 # 초기 화면 수집
prev_uniq="$(uniq_permalink_count)"; [ -z "$prev_uniq" ] && prev_uniq=0
nogrow=0
for r in $(seq 1 "$SCROLL_ROUNDS"); do
  # 스크롤 후 페이지 끝 도달 여부 반환
  pos="$("$CMUX" browser "$SURFACE" eval \
    "(()=>{window.scrollBy(0,${SCROLL_STEP_PX});return ((window.innerHeight+window.scrollY)>=(document.body.scrollHeight-200))?'BOTTOM':'MORE';})()" \
    2>/dev/null | tr -dc 'A-Z')"
  jitter 1 2
  collect_grid_into
  cur_uniq="$(uniq_permalink_count)"; [ -z "$cur_uniq" ] && cur_uniq=0
  log "  스크롤 $r/${SCROLL_ROUNDS} · 누적 게시물 ${cur_uniq}개 (${pos:-?})"
  if [ "$cur_uniq" -le "$prev_uniq" ]; then
    nogrow=$(( nogrow + 1 ))
    # 새 게시물이 더 안 늘면 종료 (무한스크롤 로딩 지연 대비 5회 인내)
    [ "$nogrow" -ge 5 ] && { log "더 이상 새 게시물이 없습니다. 스크롤 종료."; break; }
  else
    nogrow=0
  fi
  prev_uniq="$cur_uniq"
done

# permalink 기준 중복 제거(마지막에 본 커버 URL 유지)
sort -t $'\t' -k1,1 -u "$ITEMS_FILE" -o "$ITEMS_FILE"
grid_total="$(grep -c . "$ITEMS_FILE" || true)"
log "그리드 수집 완료 — 게시물 ${grid_total}개."

# ---------------------------------------------------------------------------
# 4) 커버 이미지 URL을 다운로드 목록에 우선 반영
# ---------------------------------------------------------------------------
URLS_FILE="$(mktemp)"
awk -F'\t' '$3!=""{print $3}' "$ITEMS_FILE" >> "$URLS_FILE"

# ---------------------------------------------------------------------------
# 5) (EXPAND_POSTS=1) 각 게시물을 열어 캐러셀의 모든 슬라이드를 수집
#    그리드 썸네일은 게시물의 "첫 장"만 보여주므로, 캐러셀(다중 사진) 게시물의
#    2번째 사진부터는 이 단계 없이는 영구적으로 누락된다.
# ---------------------------------------------------------------------------
if [ "$EXPAND_POSTS" = "1" ]; then
  PERMALINKS_FILE="$(mktemp)"
  if [ "$INCLUDE_REELS" = "1" ]; then
    awk -F'\t' '$1!=""{print $1}' "$ITEMS_FILE" >> "$PERMALINKS_FILE"
  else
    awk -F'\t' '$1!="" && $2!="reel"{print $1}' "$ITEMS_FILE" >> "$PERMALINKS_FILE"
  fi
  post_total="$(grep -c . "$PERMALINKS_FILE" || true)"
  if [ "$MAX_POSTS" != "0" ] && [ "$post_total" -gt "$MAX_POSTS" ]; then
    log "MAX_POSTS=${MAX_POSTS} 지정 → 앞에서부터 ${MAX_POSTS}개 게시물만 확장합니다"
    head -n "$MAX_POSTS" "$PERMALINKS_FILE" > "${PERMALINKS_FILE}.tmp" && mv "${PERMALINKS_FILE}.tmp" "$PERMALINKS_FILE"
    post_total="$MAX_POSTS"
  fi
  log "게시물 ${post_total}개를 열어 캐러셀 전체 이미지를 확장 수집합니다..."

  pidx=0
  while IFS= read -r permalink; do
    [ -z "$permalink" ] && continue
    pidx=$(( pidx + 1 ))

    if ! "$CMUX" browser "$SURFACE" goto "$permalink" >/dev/null 2>&1; then
      warn "  [$pidx/$post_total] 이동 실패, 건너뜀: $permalink"
      continue
    fi
    "$CMUX" browser "$SURFACE" wait --load-state complete --timeout-ms "$POST_WAIT_TIMEOUT_MS" >/dev/null 2>&1
    "$CMUX" browser "$SURFACE" wait --selector 'article img, article video' --timeout-ms "$POST_WAIT_TIMEOUT_MS" >/dev/null 2>&1

    video_only="$(evaljs "(()=>isVideoOnlyPost(document, ${MIN_IMG_WIDTH})?'YES':'NO')()" 2>/dev/null | tr -dc 'A-Z')"
    if [ "$video_only" = "YES" ]; then
      log "  [$pidx/$post_total] 비디오 전용 게시물, 사진 없음: $permalink"
    else
      slide=0
      while :; do
        slide=$(( slide + 1 ))
        evaljs "(()=>collectPostImages(document, ${MIN_IMG_WIDTH}).join('\n'))()" 2>/dev/null >> "$URLS_FILE"
        [ "$slide" -ge "$MAX_CAROUSEL_SLIDES" ] && break
        has_next="$(evaljs "(()=>findNextButton(document)?'YES':'NO')()" 2>/dev/null | tr -dc 'A-Z')"
        [ "$has_next" != "YES" ] && break
        # article 스코프로 클릭 대상을 좁혀 페이지 하단의 다른 캐러셀(추천 게시물 등)의
        # 동일한 aria-label="Next" 버튼을 잘못 클릭하지 않도록 한다.
        "$CMUX" browser "$SURFACE" click 'article [aria-label="Next"]' >/dev/null 2>&1
        jitter 1 2
      done
      log "  [$pidx/$post_total] 슬라이드 ${slide}장 확인: $permalink"
    fi

    jitter "$POST_DELAY_MIN" "$POST_DELAY_MAX"
  done < "$PERMALINKS_FILE"

  log "캐러셀 확장 완료. 프로필 페이지로 복귀합니다."
  "$CMUX" browser "$SURFACE" goto "$PAGE_URL" >/dev/null 2>&1
  "$CMUX" browser "$SURFACE" wait --load-state complete --timeout-ms 15000 >/dev/null 2>&1
else
  log "EXPAND_POSTS=0 → 캐러셀 확장을 건너뜁니다 (그리드 커버 이미지만 수집)."
fi

# ---------------------------------------------------------------------------
# 6) 누적 URL 중복 제거
# ---------------------------------------------------------------------------
sort -u "$URLS_FILE" -o "$URLS_FILE"
total="$(grep -c . "$URLS_FILE" || true)"
log "수집 완료 — 고유 이미지 ${total}장. 다운로드를 시작합니다."

# ---------------------------------------------------------------------------
# 7) 페이지 컨텍스트 fetch -> base64 -> 파일 저장 (천천히, 순차, 재시도 포함)
# ---------------------------------------------------------------------------
fetch_one() {
  # $1=url. "mime|base64" 또는 "ERR:..." 를 stdout 으로 반환.
  "$CMUX" browser "$SURFACE" eval \
    "(async()=>{try{const r=await fetch(\"$1\",{headers:{Accept:'image/jpeg,image/png,image/webp,image/*;q=0.9,*/*;q=0.5'}});if(!r.ok)return 'ERR:HTTP'+r.status;const b=await r.blob();const a=new Uint8Array(await b.arrayBuffer());if(a.length<1)return 'ERR:EMPTY';let s='';const C=0x8000;for(let i=0;i<a.length;i+=C){s+=String.fromCharCode.apply(null,a.subarray(i,i+C));}return (b.type||'image/jpeg')+'|'+btoa(s);}catch(e){return 'ERR:'+e.message;}})()" \
    2>/dev/null
}

ok=0; fail=0; skip=0; idx=0; consec_fail=0
while IFS= read -r url; do
  [ -z "$url" ] && continue
  idx=$(( idx + 1 ))

  # 파일명 베이스: CDN 경로 basename 에서 확장자 제거 (확장자는 실제 MIME 으로 결정)
  base="${url%%\?*}"
  stem="$(basename "$base")"
  stem="${stem%.*}"

  attempt=0
  resp=""
  while [ "$attempt" -lt "$FETCH_RETRIES" ]; do
    attempt=$(( attempt + 1 ))
    resp="$(fetch_one "$url")"
    case "$resp" in
      ERR:*|"")
        warn "  [$idx/$total] 시도 $attempt/${FETCH_RETRIES} 실패($resp): $stem"
        sleep "$(( FETCH_RETRY_BASE_SEC * attempt ))"
        continue
        ;;
    esac
    mime="${resp%%|*}"
    b64="${resp#*|}"
    byte_est=$(( ${#b64} * 3 / 4 ))
    if [ "$byte_est" -lt "$MIN_BYTES" ]; then
      warn "  [$idx/$total] 시도 $attempt/${FETCH_RETRIES} 응답 너무 작음(${byte_est}B, 차단 의심): $stem"
      resp="ERR:TOOSMALL"
      sleep "$(( FETCH_RETRY_BASE_SEC * attempt ))"
      continue
    fi
    break
  done

  case "$resp" in
    ERR:*|"")
      fail=$(( fail + 1 ))
      consec_fail=$(( consec_fail + 1 ))
      err "  [$idx/$total] 최종 실패($resp): $stem"
      if [ "$consec_fail" -ge "$CONSEC_FAIL_BREAK" ]; then
        warn "연속 실패 ${consec_fail}회 → 차단 의심, ${CONSEC_FAIL_SLEEP}초 휴식 후 재개"
        sleep "$CONSEC_FAIL_SLEEP"
        consec_fail=0
      fi
      continue
      ;;
  esac
  consec_fail=0

  mime="${resp%%|*}"
  b64="${resp#*|}"
  case "$mime" in
    image/png)  ext=png ;;
    image/webp) ext=webp ;;
    image/gif)  ext=gif ;;
    image/avif) ext=avif ;;
    image/heic|image/heif) ext=heic ;;
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
