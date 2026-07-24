#!/usr/bin/env bash
#
# save-insta-media.sh
#
# cmux 브라우저(WKWebView)에 "현재 로드되어 보이는" Instagram 이미지 및 영상을
# 페이지 자신의 인증 세션으로 in-page fetch 하여 그대로 저장한다.
# (save-insta-images.sh 의 이미지 수집 로직 + 영상 수집/다운로드를 결합한 버전)
#
# 우회 전략: 별도 HTTP 클라이언트를 쓰지 않고, 사용자가 이미 로그인한
# 실제 브라우저 안에서 fetch() 를 실행한다. 요청의 쿠키/Referer/Origin/
# TLS 지문이 전부 정상 브라우저와 동일하므로 봇 탐지를 최대한 우회한다.
#
# 영상 소스 특이사항: Instagram 은 종종 MSE(MediaSource) 로 스트리밍하는데,
# 이 경우 <video>.currentSrc 는 blob: URL 이라 fetch 로 원본 바이트를 받을 수
# 없다. 이때는 페이지에 내장된 JSON(video_url)에서 실제 CDN 서명 URL을 찾아
# 대신 사용한다. 또한 영상은 이미지보다 훨씬 크므로, 자동화 브릿지(cmux eval)
# 왕복 payload 크기 제한을 피하기 위해 HTTP Range 요청으로 청크 단위로 받아
# 이어붙인다.
#
# 사용법:
#   ./save-insta-media.sh https://www.instagram.com/<user_or_reel_or_post>/  # 새 탭을 띄워 천천히 수집
#   ./save-insta-media.sh                                                   # 이미 열린 instagram 탭에서 수집
#   SURFACE=surface:2 ./save-insta-media.sh                                 # 특정 surface 지정
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
CHUNK_BYTES="${CHUNK_BYTES:-4000000}"     # 영상 Range 요청 청크 크기 (약 4MB)

if command -v ffmpeg >/dev/null 2>&1; then
  HAVE_FFMPEG=1
else
  HAVE_FFMPEG=0
fi

# ---------------------------------------------------------------------------
# 재사용할 페이지 컨텍스트 JS 스니펫들 (heredoc 로 정의 — bash 이스케이프 없이
# JS 를 그대로 쓸 수 있고, 변수로 재사용 가능하다)
# ---------------------------------------------------------------------------

# 현재 페이지에서 비디오(+가능하면 오디오) URL 을 찾는다.
# 반환 형식: "STEM|VIDEO_URL|AUDIO_URL" (STEM 은 항상 비어 있음 — 호출부에서
# URL 로부터 유추하거나, 알고 있는 shortcode 로 직접 대체해서 쓴다).
# <video>.currentSrc 가 http 직접 URL이면 그대로 쓰고, blob:(MSE 스트리밍)이면
# 페이지에 내장된 video_dash_manifest(DASH MPD XML)를 파싱해 비디오/오디오
# AdaptationSet 을 각각 찾는다. manifest 가 없으면 video_versions 의 단일
# URL(오디오 없음)로 폴백한다.
IFS= read -r -d '' VIDEO_JS <<'JSEOF' || true
(()=>{
  const out=[];
  document.querySelectorAll('video').forEach(v=>{
    const u=v.currentSrc||v.src||'';
    if(u.startsWith('http')) out.push('|'+u+'|');
  });
  if(out.length===0){
    for(const sc of document.querySelectorAll('script[type="application/json"]')){
      const t=sc.textContent||'';
      if(!t.includes('video_versions')) continue;
      let videoUrl='', audioUrl='';
      const m=t.match(/"video_dash_manifest":"((?:[^"\\]|\\.)*)"/);
      if(m){
        try{
          const xml=JSON.parse('"'+m[1]+'"');
          const doc=new DOMParser().parseFromString(xml,'text/xml');
          const sets=[...doc.getElementsByTagName('AdaptationSet')];
          const pickBest=(set)=>{
            const reps=[...set.getElementsByTagName('Representation')];
            reps.sort((a,b)=>(+b.getAttribute('bandwidth')||0)-(+a.getAttribute('bandwidth')||0));
            const rep=reps[0];
            if(!rep) return '';
            const base=rep.getElementsByTagName('BaseURL')[0];
            return base?base.textContent:'';
          };
          const vSet=sets.find(s=>s.getAttribute('contentType')==='video');
          const aSet=sets.find(s=>s.getAttribute('contentType')==='audio');
          if(vSet) videoUrl=pickBest(vSet);
          if(aSet) audioUrl=pickBest(aSet);
        }catch(e){}
      }
      if(!videoUrl){
        const vm=t.match(/"url":"(https:[^"]+?\.mp4[^"]*)"/);
        if(vm) videoUrl=JSON.parse('"'+vm[1]+'"');
      }
      if(videoUrl){ out.push('|'+videoUrl+'|'+audioUrl); break; }
    }
  }
  return out.join('\n');
})()
JSEOF

# 프로필 릴스 그리드(/<user>/reels/)에서 각 릴스 permalink 의 shortcode 를 모은다.
IFS= read -r -d '' REEL_LINKS_JS <<'JSEOF' || true
(()=>{
  const s=new Set();
  document.querySelectorAll('a[href*="/reel/"]').forEach(a=>{
    const href=a.getAttribute('href')||'';
    const m=href.match(/\/reel\/([A-Za-z0-9_-]+)\//);
    if(m) s.add(m[1]);
  });
  return [...s].join('\n');
})()
JSEOF

log() { printf '\033[36m[insta]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[31m[insta]\033[0m %s\n' "$*" >&2; }

jitter() {
  local lo="$1" hi="$2" span
  span=$(( hi - lo + 1 ))
  (( span < 1 )) && span=1
  sleep "$(( lo + RANDOM % span ))"
}

# 큰 파일(영상/오디오)을 HTTP Range 로 청크씩 받아 이어붙인다.
# 참고: Range 요청(GET)의 Content-Range 헤더는 크로스오리진 CDN 응답에서 CORS 로
# 노출되지 않아 JS 에서 읽을 수 없다. 반면 Content-Length 는 CORS 세이프리스트에
# 포함되어 있으므로, 전체 크기 확인은 Range 없는 HEAD 요청으로 한다.
download_ranged() {
  local url="$1" dest_file="$2" total_len offset end resp head_resp pct attempt

  # cmux eval 호출이 연속으로 몰리면 간헐적으로 빈 응답이 오는 경우가 있어 재시도한다.
  attempt=0
  head_resp=""
  while [ "$attempt" -lt 3 ]; do
    head_resp="$("$CMUX" browser "$SURFACE" eval \
      "(async()=>{try{const r=await fetch(\"$url\",{method:'HEAD'});return r.headers.get('content-length')||'';}catch(e){return 'ERR:'+e.message;}})()" \
      2>/dev/null)"
    case "$head_resp" in
      ERR:*|"") attempt=$(( attempt + 1 )); sleep 1 ;;
      *) break ;;
    esac
  done
  case "$head_resp" in
    ERR:*|"")
      err "    헤더 조회 실패: $head_resp"
      return 1
      ;;
  esac
  total_len="$(printf '%s' "$head_resp" | tr -dc '0-9')"
  if [ -z "$total_len" ] || [ "$total_len" -le 0 ]; then
    err "    전체 크기(Content-Length)를 확인하지 못했습니다"
    return 1
  fi

  : > "$dest_file"
  offset=0
  while [ "$offset" -lt "$total_len" ]; do
    end=$(( offset + CHUNK_BYTES - 1 ))
    [ "$end" -ge "$total_len" ] && end=$(( total_len - 1 ))

    attempt=0
    resp=""
    while [ "$attempt" -lt 3 ]; do
      resp="$("$CMUX" browser "$SURFACE" eval \
        "(async()=>{try{const r=await fetch(\"$url\",{headers:{Range:'bytes=${offset}-${end}'}});if(!r.ok&&r.status!==206)return 'ERR:HTTP'+r.status;const b=await r.blob();const a=new Uint8Array(await b.arrayBuffer());let s='';const C=0x8000;for(let i=0;i<a.length;i+=C){s+=String.fromCharCode.apply(null,a.subarray(i,i+C));}return btoa(s);}catch(e){return 'ERR:'+e.message;}})()" \
        2>/dev/null)"
      case "$resp" in
        ERR:*|"") attempt=$(( attempt + 1 )); sleep 1 ;;
        *) break ;;
      esac
    done

    case "$resp" in
      ERR:*|"")
        err "    청크 실패 (bytes ${offset}-${end}): $resp"
        return 1
        ;;
    esac

    if ! printf '%s' "$resp" | base64 -d >> "$dest_file" 2>/dev/null; then
      err "    청크 디코드 실패 (bytes ${offset}-${end})"
      return 1
    fi

    pct=$(( (end + 1) * 100 / total_len ))
    log "    받는 중... $((end + 1))/${total_len} bytes (${pct}%)"
    offset=$(( end + 1 ))
  done

  [ -s "$dest_file" ]
}

# 비디오(+선택적 오디오) URL 을 받아 "$OUT_DIR/$stem.mp4" 로 저장한다.
# 오디오가 있고 ffmpeg 이 있으면 muxing, 아니면 비디오만 저장.
# $vid_ok/$vid_fail/$vid_skip 전역 카운터를 갱신한다.
save_video() {
  local stem="$1" vurl="$2" aurl="$3" label="${4:-$stem}"
  local dest video_tmp audio_tmp muxed sz tag

  dest="$OUT_DIR/${stem}.mp4"
  if [ -s "$dest" ]; then
    vid_skip=$(( vid_skip + 1 ))
    log "  [$label] 이미 있음, 건너뜀: ${stem}.mp4"
    return 0
  fi

  video_tmp="$OUT_DIR/.${stem}.video.tmp"
  audio_tmp="$OUT_DIR/.${stem}.audio.tmp"
  rm -f "$video_tmp" "$audio_tmp"

  log "  [$label] 비디오 다운로드 중... (${CHUNK_BYTES} bytes 단위)"
  if ! download_ranged "$vurl" "$video_tmp"; then
    rm -f "$video_tmp"
    vid_fail=$(( vid_fail + 1 ))
    err "  [$label] 비디오 다운로드 실패"
    return 1
  fi

  muxed=0
  if [ -n "$aurl" ]; then
    if [ "$HAVE_FFMPEG" -eq 1 ]; then
      log "  [$label] 오디오 트랙 다운로드 중..."
      if download_ranged "$aurl" "$audio_tmp"; then
        if ffmpeg -y -loglevel error -i "$video_tmp" -i "$audio_tmp" -c copy "$dest" 2>/dev/null && [ -s "$dest" ]; then
          muxed=1
        else
          err "  [$label] muxing 실패, 비디오만 저장합니다"
        fi
      else
        err "  [$label] 오디오 다운로드 실패, 비디오만 저장합니다"
      fi
      rm -f "$audio_tmp"
    else
      log "  [$label] ffmpeg 없음, 오디오 없이 저장합니다"
    fi
  fi

  [ "$muxed" -eq 0 ] && mv "$video_tmp" "$dest"
  rm -f "$video_tmp"

  if [ -s "$dest" ]; then
    vid_ok=$(( vid_ok + 1 ))
    sz="$(wc -c < "$dest" | tr -d ' ')"
    tag=""; [ "$muxed" -eq 1 ] && tag=" (오디오 포함)"
    log "  [$label] 저장 ✓ ${stem}.mp4${tag} (${sz} bytes)"
    return 0
  else
    vid_fail=$(( vid_fail + 1 ))
    err "  [$label] 저장 실패: ${stem}"
    return 1
  fi
}

# 프로필 릴스 탭(https://www.instagram.com/<user>/reels/)에서 릴스 permalink
# shortcode 를 전부 스크롤 수집한 뒤, 하나씩 그 URL 로 이동(navigate)해서
# 영상(+가능하면 오디오)만 순차적으로 받는다. 이미지는 다루지 않는다.
# 이미 받은 파일(<code>.mp4)은 이동조차 하지 않고 건너뛴다.
run_bulk_reels_mode() {
  local codes_file total idx code label dest tries line vurl aurl rest
  local prev cur nogrow r scroll_rounds

  log "프로필 릴스 탭 감지 — 전체 릴스 영상을 하나씩 받습니다."

  codes_file="$(mktemp)"

  "$CMUX" browser "$SURFACE" eval "window.scrollTo(0,0);" >/dev/null 2>&1
  sleep 1
  "$CMUX" browser "$SURFACE" eval "$REEL_LINKS_JS" 2>/dev/null >> "$codes_file"
  prev="$(sort -u "$codes_file" | grep -c . || true)"; [ -z "$prev" ] && prev=0
  nogrow=0
  scroll_rounds="${SCROLL_ROUNDS:-300}"
  for r in $(seq 1 "$scroll_rounds"); do
    "$CMUX" browser "$SURFACE" eval "window.scrollBy(0,${SCROLL_STEP_PX});" >/dev/null 2>&1
    jitter 1 2
    "$CMUX" browser "$SURFACE" eval "$REEL_LINKS_JS" 2>/dev/null >> "$codes_file"
    cur="$(sort -u "$codes_file" | grep -c . || true)"; [ -z "$cur" ] && cur=0
    log "  스크롤 $r/${scroll_rounds} · 릴스 ${cur}개 발견"
    if [ "$cur" -le "$prev" ]; then
      nogrow=$(( nogrow + 1 ))
      [ "$nogrow" -ge 5 ] && { log "더 이상 새 릴스가 없습니다. 스크롤 종료."; break; }
    else
      nogrow=0
    fi
    prev="$cur"
  done

  sort -u "$codes_file" -o "$codes_file"
  total="$(grep -c . "$codes_file" || true)"
  log "릴스 ${total}개 발견. 영상을 하나씩 받습니다."

  vid_ok=0; vid_fail=0; vid_skip=0
  idx=0
  while IFS= read -r code; do
    [ -z "$code" ] && continue
    idx=$(( idx + 1 ))
    label="릴스 $idx/$total $code"

    dest="$OUT_DIR/${code}.mp4"
    if [ -s "$dest" ]; then
      vid_skip=$(( vid_skip + 1 ))
      log "  [$label] 이미 있음, 건너뜀"
      continue
    fi

    log "  [$label] 이동 중..."
    "$CMUX" browser "$SURFACE" navigate "https://www.instagram.com/reel/${code}/" >/dev/null 2>&1
    "$CMUX" browser "$SURFACE" wait --load-state complete --timeout-ms 20000 >/dev/null 2>&1
    sleep 2

    line=""
    tries=0
    while [ "$tries" -lt 10 ]; do
      line="$("$CMUX" browser "$SURFACE" eval "$VIDEO_JS" 2>/dev/null)"
      [ -n "$line" ] && [ "$line" != "|" ] && break
      sleep 1
      tries=$(( tries + 1 ))
    done

    if [ -z "$line" ] || [ "$line" = "|" ]; then
      vid_fail=$(( vid_fail + 1 ))
      err "  [$label] 영상 소스를 찾지 못했습니다"
      jitter "$DL_DELAY_MIN" "$DL_DELAY_MAX"
      continue
    fi

    # line 형식: "STEM|VIDEO_URL|AUDIO_URL" (STEM 은 항상 비어 있음) — 첫 필드를 버린다.
    rest="${line#*|}"
    vurl="${rest%%|*}"
    aurl="${rest#*|}"
    [ "$aurl" = "$rest" ] && aurl=""

    save_video "$code" "$vurl" "$aurl" "$label"
    jitter "$DL_DELAY_MIN" "$DL_DELAY_MAX"
  done < "$codes_file"

  rm -f "$codes_file"
  log "완료 — 영상: 저장 $vid_ok · 건너뜀 $vid_skip · 실패 $vid_fail"
  log "폴더: $OUT_DIR"
}

# ---------------------------------------------------------------------------
# 1) 대상 surface 결정 (URL 주면 새 탭, 아니면 열린 instagram 탭 탐색)
# ---------------------------------------------------------------------------
if [ -n "$URL" ]; then
  log "브라우저 탭을 띄웁니다: $URL"
  open_json="$("$CMUX" --json browser open "$URL" 2>&1)"
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
    err "열린 instagram 탭이 없습니다. 프로필/게시물 URL 을 인자로 넘겨주세요."
    exit 1
  fi
fi

PAGE_URL="$("$CMUX" browser "$SURFACE" get url 2>/dev/null)"
log "대상: $SURFACE  ($PAGE_URL)"

# 사용자명으로 저장 폴더 결정
USER_NAME="$(printf '%s' "$PAGE_URL" | sed -E 's#https?://[^/]*instagram\.com/##; s#/.*##; s/[?#].*//')"
case "$USER_NAME" in
  reel|reels|p|tv|stories|""|explore|direct)
    # /reel/<code>/ 등은 경로에 사용자명이 없으므로 페이지에서 조회한다.
    # 1) video_versions/image_versions2 근처의 username (가장 정확 — 소프트 네비게이션에도 갱신됨)
    # 2) og:description 메타 태그의 "- username on ..." 패턴 (새로 로드된 탭에서만 신뢰 가능 —
    #    Instagram 이 클라이언트 사이드로 페이지를 이동하면 메타 태그는 갱신되지 않는다)
    USER_NAME="$("$CMUX" browser "$SURFACE" eval \
      "(()=>{const scripts=[...document.querySelectorAll('script[type=\"application/json\"]')];const pick=(pred)=>{for(const sc of scripts){const t=sc.textContent||'';if(!pred(t))continue;const m=t.match(/\"username\":\"([^\"]+)\"/);if(m)return m[1];}return '';};const fromJson=pick(t=>t.includes('video_versions'))||pick(t=>t.includes('image_versions2'));if(fromJson)return fromJson;const md=document.querySelector('meta[property=\"og:description\"]');if(md){const m=md.content.match(/- ([A-Za-z0-9_.]+) on /);if(m)return m[1];}return '';})()" \
      2>/dev/null)"
    ;;
esac
[ -z "$USER_NAME" ] && USER_NAME="page"
OUT_DIR="$OUT_BASE/${USER_NAME}"   # 현재 디렉터리 아래 프로필명 폴더
mkdir -p "$OUT_DIR"
log "저장 위치: $OUT_DIR"

# 게시물/릴스 페이지라면 shortcode 를 영상 파일명 대체용으로 확보해 둔다
SHORTCODE="$(printf '%s' "$PAGE_URL" | grep -oE '/(reel|reels|p|tv)/[A-Za-z0-9_-]+' | grep -oE '[A-Za-z0-9_-]+$' | head -1)"

# ---------------------------------------------------------------------------
# 프로필 릴스 탭(https://www.instagram.com/<user>/reels/) 이면 전체 릴스
# 영상을 하나씩 순회하며 받는 별도 모드로 진입한다 (이미지는 다루지 않음).
# ---------------------------------------------------------------------------
case "$PAGE_URL" in
  https://*instagram.com/*/reels|https://*instagram.com/*/reels/|https://*instagram.com/*/reels\?*|https://*instagram.com/*/reels\#*)
    run_bulk_reels_mode
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 2) 게시물 수를 읽어 스크롤 횟수 결정 (SCROLL_ROUNDS 지정 시 그 값을 우선)
# ---------------------------------------------------------------------------
POST_COUNT="$("$CMUX" browser "$SURFACE" eval \
  "(()=>{const md=document.querySelector('meta[property=\"og:description\"],meta[name=\"description\"]');if(!md)return '';const c=md.content.replace(/,/g,'');const m=c.match(/([0-9]+)\\s*posts/i)||c.match(/게시물\\s*([0-9]+)/);return m?m[1]:'';})()" \
  2>/dev/null | tr -dc '0-9')"

if [ -n "$SCROLL_ROUNDS" ]; then
  log "스크롤 횟수: ${SCROLL_ROUNDS}회 (사용자 지정)"
elif [ -n "$POST_COUNT" ] && [ "$POST_COUNT" -gt 0 ]; then
  SCROLL_ROUNDS=$(( POST_COUNT * 120 / SCROLL_STEP_PX + 20 ))
  [ "$SCROLL_ROUNDS" -lt 30 ] && SCROLL_ROUNDS=30
  [ "$SCROLL_ROUNDS" -gt 800 ] && SCROLL_ROUNDS=800   # 폭주 방지 상한
  log "게시물 ${POST_COUNT}개 감지 → 스크롤 횟수 ${SCROLL_ROUNDS}회로 설정 (스텝 ${SCROLL_STEP_PX}px)"
else
  SCROLL_ROUNDS=60
  log "게시물 수를 읽지 못해 기본 ${SCROLL_ROUNDS}회로 스크롤합니다"
fi

# ---------------------------------------------------------------------------
# 3) 천천히 스크롤하며 이미지 URL + 영상 URL 을 "누적" 수집
#    (Instagram 그리드는 가상화되어 화면 밖 요소가 DOM 에서 제거되므로,
#     끝에서 한 번만 모으면 마지막 화면분만 잡힌다. 매 라운드마다 누적한다.)
# ---------------------------------------------------------------------------
IMAGES_FILE="$(mktemp)"
VIDEOS_FILE="$(mktemp)"
trap 'rm -f "$IMAGES_FILE" "$VIDEOS_FILE"' EXIT

collect_into() {
  "$CMUX" browser "$SURFACE" eval \
    "(()=>{const s=new Set();document.querySelectorAll('img').forEach(i=>{const u=i.currentSrc||i.src||'';if(u.startsWith('http')&&i.naturalWidth>=${MIN_IMG_WIDTH})s.add(u);});return [...s].join('\n');})()" \
    2>/dev/null >> "$IMAGES_FILE"

  # 각 줄은 "STEM|videoURL|audioURL" 형태 (STEM 은 항상 비어 있음 — 아래
  # 다운로드 루프에서 URL 로부터 유추한다).
  "$CMUX" browser "$SURFACE" eval "$VIDEO_JS" 2>/dev/null >> "$VIDEOS_FILE"
}
uniq_count() { sort -u "$IMAGES_FILE" "$VIDEOS_FILE" | grep -c . ; }

log "천천히 스크롤하며 이미지/영상을 누적 수집합니다 (최대 ${SCROLL_ROUNDS}회)..."
"$CMUX" browser "$SURFACE" eval "window.scrollTo(0,0);" >/dev/null 2>&1   # 맨 위부터 시작
sleep 1
collect_into                      # 초기 화면 수집
prev_uniq="$(uniq_count)"; [ -z "$prev_uniq" ] && prev_uniq=0
nogrow=0
for r in $(seq 1 "$SCROLL_ROUNDS"); do
  pos="$("$CMUX" browser "$SURFACE" eval \
    "(()=>{window.scrollBy(0,${SCROLL_STEP_PX});return ((window.innerHeight+window.scrollY)>=(document.body.scrollHeight-200))?'BOTTOM':'MORE';})()" \
    2>/dev/null | tr -dc 'A-Z')"
  jitter 1 2
  collect_into
  cur_uniq="$(uniq_count)"; [ -z "$cur_uniq" ] && cur_uniq=0
  log "  스크롤 $r/${SCROLL_ROUNDS} · 누적 ${cur_uniq}개 (${pos:-?})"
  if [ "$cur_uniq" -le "$prev_uniq" ]; then
    nogrow=$(( nogrow + 1 ))
    [ "$nogrow" -ge 5 ] && { log "더 이상 새 항목이 없습니다. 스크롤 종료."; break; }
  else
    nogrow=0
  fi
  prev_uniq="$cur_uniq"
done

# ---------------------------------------------------------------------------
# 4) 누적 URL 중복 제거
# ---------------------------------------------------------------------------
sort -u "$IMAGES_FILE" -o "$IMAGES_FILE"
sort -u "$VIDEOS_FILE" -o "$VIDEOS_FILE"
img_total="$(grep -c . "$IMAGES_FILE" || true)"
vid_total="$(grep -c . "$VIDEOS_FILE" || true)"
log "수집 완료 — 이미지 ${img_total}장, 영상 ${vid_total}개. 다운로드를 시작합니다."

# ---------------------------------------------------------------------------
# 5) 이미지 다운로드: 페이지 컨텍스트 fetch -> base64 -> 파일 저장 (천천히, 순차)
# ---------------------------------------------------------------------------
img_ok=0; img_fail=0; img_skip=0; idx=0
while IFS= read -r url; do
  [ -z "$url" ] && continue
  idx=$(( idx + 1 ))

  base="${url%%\?*}"
  stem="$(basename "$base")"
  stem="${stem%.*}"

  resp="$("$CMUX" browser "$SURFACE" eval \
    "(async()=>{try{const r=await fetch(\"$url\");if(!r.ok)return 'ERR:HTTP'+r.status;const b=await r.blob();const a=new Uint8Array(await b.arrayBuffer());let s='';const C=0x8000;for(let i=0;i<a.length;i+=C){s+=String.fromCharCode.apply(null,a.subarray(i,i+C));}return (b.type||'image/jpeg')+'|'+btoa(s);}catch(e){return 'ERR:'+e.message;}})()" \
    2>/dev/null)"

  case "$resp" in
    ERR:*|"" )
      img_fail=$(( img_fail + 1 ))
      err "  [이미지 $idx/$img_total] 실패($resp): $stem"
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
    img_skip=$(( img_skip + 1 ))
    log "  [이미지 $idx/$img_total] 이미 있음, 건너뜀: ${stem}.${ext}"
    continue
  fi

  if printf '%s' "$b64" | base64 -d > "$dest" 2>/dev/null && [ -s "$dest" ]; then
    img_ok=$(( img_ok + 1 ))
    sz="$(wc -c < "$dest" | tr -d ' ')"
    log "  [이미지 $idx/$img_total] 저장 ✓ ${stem}.${ext} (${sz} bytes)"
  else
    rm -f "$dest"
    img_fail=$(( img_fail + 1 ))
    err "  [이미지 $idx/$img_total] 디코드 실패: ${stem}.${ext}"
  fi

  jitter "$DL_DELAY_MIN" "$DL_DELAY_MAX"
done < "$IMAGES_FILE"

# ---------------------------------------------------------------------------
# 6) 영상 다운로드: 용량이 크므로 HTTP Range 로 청크씩 받아 이어붙인다.
#    오디오 트랙이 별도 URL(DASH audio AdaptationSet)로 있으면 함께 받아
#    ffmpeg 로 muxing 한다. 오디오가 없거나 ffmpeg 이 없으면 비디오만 저장한다.
# ---------------------------------------------------------------------------
[ "$HAVE_FFMPEG" -eq 0 ] && [ "$vid_total" -gt 0 ] && \
  log "ffmpeg 를 찾을 수 없어, 오디오 트랙이 있어도 비디오만 저장됩니다 (brew install ffmpeg 권장)"

vid_ok=0; vid_fail=0; vid_skip=0; vidx=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  vidx=$(( vidx + 1 ))
  # 형식: STEM|VIDEO_URL|AUDIO_URL (STEM 비어있으면 URL/전역 SHORTCODE 로 유추)
  stem_field="${line%%|*}"
  rest="${line#*|}"
  vurl="${rest%%|*}"
  aurl="${rest#*|}"
  [ "$aurl" = "$rest" ] && aurl=""

  if [ -n "$stem_field" ]; then
    stem="$stem_field"
  else
    base="${vurl%%\?*}"
    stem="$(basename "$base")"
    stem="${stem%.*}"
    [ -z "$stem" ] && stem="${SHORTCODE:-video_${vidx}}"
    # basename 이 너무 짧거나 확장자 없는 해시뿐이면 shortcode 를 우선 사용
    if [ -n "$SHORTCODE" ] && [ "$vid_total" -le 1 ]; then
      stem="$SHORTCODE"
    fi
  fi

  save_video "$stem" "$vurl" "$aurl" "영상 $vidx/$vid_total"
  jitter "$DL_DELAY_MIN" "$DL_DELAY_MAX"
done < "$VIDEOS_FILE"

log "완료 — 이미지: 저장 $img_ok · 건너뜀 $img_skip · 실패 $img_fail  /  영상: 저장 $vid_ok · 건너뜀 $vid_skip · 실패 $vid_fail"
log "폴더: $OUT_DIR"
