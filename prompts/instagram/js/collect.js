/*
 * collect.js — Instagram 페이지에서 이미지를 수집하는 순수/DOM 로직 모음.
 *
 * 이 파일은 두 가지 방식으로 실행된다:
 *   1) 브라우저(cmux `browser eval`) 안: 파일 전체를 문자열로 읽어 eval 페이로드
 *      앞부분에 이어붙인 뒤, 뒤에 IIFE(즉시실행함수)를 붙여 특정 함수를 호출한다.
 *      브라우저에는 `module`이 없으므로 하단의 UMD 블록은 조용히 건너뛴다.
 *   2) Node.js 테스트 안: `require('./collect.js')` 로 순수 함수들을 가져와
 *      DOM 없이(또는 아래 fake-dom 유틸로) 검증한다.
 *
 * 순수 함수(문자열/배열만 다룸)와 DOM 의존 함수를 분리해 두어,
 * 순수 함수는 실제 Node에서, DOM 함수는 최소 fake-dom으로 각각 테스트한다.
 */

// ---------------------------------------------------------------------------
// 순수 함수 (DOM 불필요)
// ---------------------------------------------------------------------------

/**
 * srcset 문자열에서 가장 해상도가 높은 URL을 고른다.
 * "url1 150w, url2 640w, url3 1080w" -> url3
 * 밀도 기술자("1x, 2x")도 지원한다. 파싱 불가/빈 값이면 null.
 */
function pickBestFromSrcset(srcset) {
  if (!srcset || typeof srcset !== "string") return null;
  let best = null;
  let bestScore = -1;
  for (const part of srcset.split(",")) {
    const seg = part.trim();
    if (!seg) continue;
    const bits = seg.split(/\s+/);
    if (bits.length < 1) continue;
    const url = bits[0];
    const descriptor = bits[1] || "";
    let score = 0;
    const wMatch = descriptor.match(/^(\d+(?:\.\d+)?)w$/);
    const xMatch = descriptor.match(/^(\d+(?:\.\d+)?)x$/);
    if (wMatch) score = parseFloat(wMatch[1]);
    else if (xMatch) score = parseFloat(xMatch[1]) * 1000; // density를 폭과 같은 축으로 취급(대략치)
    else score = 0;
    if (url && score >= bestScore) {
      bestScore = score;
      best = url;
    }
  }
  return best;
}

/**
 * srcset 문자열에서 'w' 폭 기술자 중 최댓값(px)을 반환한다.
 * 폭 기술자가 하나도 없으면(밀도 기술자만 있거나 비어있으면) null.
 */
function maxSrcsetWidth(srcset) {
  if (!srcset || typeof srcset !== "string") return null;
  let max = null;
  for (const part of srcset.split(",")) {
    const bits = part.trim().split(/\s+/);
    const m = (bits[1] || "").match(/^(\d+(?:\.\d+)?)w$/);
    if (m) {
      const w = parseFloat(m[1]);
      if (max === null || w > max) max = w;
    }
  }
  return max;
}

/**
 * <img> 요소(또는 {srcset, currentSrc, src} 형태의 평범한 객체)에서
 * 가장 좋은(고해상도) 이미지 URL을 고른다.
 * 우선순위: srcset 최고해상도 > currentSrc(브라우저가 실제 로드한 것) > src 속성.
 */
function bestImageUrl(imgLike) {
  if (!imgLike) return null;
  const fromSrcset = pickBestFromSrcset(imgLike.srcset || null);
  if (fromSrcset) return fromSrcset;
  if (imgLike.currentSrc) return imgLike.currentSrc;
  if (imgLike.src) return imgLike.src;
  return null;
}

/**
 * Instagram permalink href를 분류한다.
 * "/p/<code>/", "/reel/<code>/", "/tv/<code>/" 형태와, Instagram이 그리드에서
 * 쓰는 사용자명 접두 형태 "/<username>/p/<code>/" 등도 유효한 게시물로 인정.
 * 프로필/스토리/탐색 등 다른 링크는 null.
 */
function classifyHref(href) {
  if (!href || typeof href !== "string") return null;
  let path = href;
  // 절대 URL이면 경로만 추출
  const m = path.match(/^https?:\/\/[^/]+(\/.*)$/);
  if (m) path = m[1];
  path = path.split("?")[0].split("#")[0];
  const pm = path.match(/^\/(?:[^/]+\/)?(p|reel|tv)\/([^/]+)\/?$/);
  if (!pm) return null;
  return { type: pm[1], shortcode: pm[2] };
}

/**
 * href를 절대 URL 퍼머링크로 정규화한다("/p/<code>/" -> "https://www.instagram.com/p/<code>/").
 */
function normalizePermalink(href, origin) {
  const info = classifyHref(href);
  if (!info) return null;
  const base = origin || "https://www.instagram.com";
  return `${base}/${info.type}/${info.shortcode}/`;
}

/**
 * URL 문자열 배열을 순서를 유지하며 중복 제거한다.
 */
function dedupe(urls) {
  const seen = new Set();
  const out = [];
  for (const u of urls) {
    if (!u || seen.has(u)) continue;
    seen.add(u);
    out.push(u);
  }
  return out;
}

// ---------------------------------------------------------------------------
// DOM 의존 함수 (실제 브라우저 또는 fake-dom에서 실행)
// ---------------------------------------------------------------------------

/**
 * 그리드(프로필) 페이지에서 게시물 링크 + 커버 이미지를 수집한다.
 * naturalWidth(로드 완료 여부)에 의존하지 않고 srcset 속성만으로 판단하므로,
 * 이미지가 아직 로딩 중이거나 가상화로 언로드되기 직전이어도 URL을 놓치지 않는다.
 *
 * minWidth(px)를 지정하면, srcset에 폭 기술자가 있는데 그 최댓값이 minWidth 미만인
 * 항목은 제외한다(아이콘류 안전망). srcset에 폭 기술자가 없으면(판단 불가) 포함한다 —
 * "판단 불가 시 누락시키지 않는다"가 이 도구의 기본 원칙이기 때문이다.
 *
 * 반환: [{ permalink, type, coverUrl }]
 */
function collectGridItems(doc, origin, minWidth) {
  const out = [];
  const anchors = doc.querySelectorAll(
    'a[href*="/p/"], a[href*="/reel/"], a[href*="/tv/"]'
  );
  for (const a of anchors) {
    const info = classifyHref(a.getAttribute("href"));
    if (!info) continue;
    const permalink = normalizePermalink(a.getAttribute("href"), origin);
    const img = a.querySelector ? a.querySelector("img") : null;
    const srcset = img
      ? (img.getAttribute ? img.getAttribute("srcset") : img.srcset)
      : null;
    if (minWidth) {
      const w = maxSrcsetWidth(srcset);
      if (w !== null && w < minWidth) continue;
    }
    const coverUrl = img
      ? bestImageUrl({
          srcset,
          currentSrc: img.currentSrc,
          src: img.getAttribute ? img.getAttribute("src") : img.src,
        })
      : null;
    out.push({ permalink, type: info.type, coverUrl });
  }
  return out;
}

/**
 * 게시물 상세 페이지에서 현재 DOM에 마운트된 모든 슬라이드의 이미지를 수집한다.
 * (캐러셀은 다음 버튼을 눌러야 다음 슬라이드가 추가로 마운트되므로,
 *  호출자가 findNextButton()으로 클릭을 반복하며 매 라운드 이 함수를 다시 호출해야 한다.)
 *
 * article 안에는 댓글 작성자들의 프로필 아바타 <img>도 함께 들어있는데, alt 텍스트가
 * 항상 "profile picture" 패턴을 따르지는 않으므로(로캘/마크업에 따라 다름) alt만으로는
 * 걸러지지 않는 아바타가 새어 들어올 수 있다. 그리드 수집(collectGridItems)과 동일하게
 * srcset 최대 폭이 minWidth 미만이면 제외해 아바타류를 이중으로 배제한다.
 */
function collectPostImages(doc, minWidth) {
  const scope = doc.querySelector('article') || doc;
  const imgs = scope.querySelectorAll("img");
  const urls = [];
  for (const img of imgs) {
    const srcset = img.getAttribute ? img.getAttribute("srcset") : img.srcset;
    const src = img.getAttribute ? img.getAttribute("src") : img.src;
    // 프로필 아바타·좋아요 아이콘 등은 alt 텍스트 패턴으로 배제(사진 슬라이드는 보통 "Photo by" 류 alt를 가짐)
    const alt = (img.getAttribute ? img.getAttribute("alt") : img.alt) || "";
    if (/profile picture/i.test(alt)) continue;
    if (minWidth) {
      const w = maxSrcsetWidth(srcset);
      if (w !== null && w < minWidth) continue;
    }
    const url = bestImageUrl({ srcset, currentSrc: img.currentSrc, src });
    if (url) urls.push(url);
  }
  return dedupe(urls);
}

/**
 * 게시물이 비디오 전용(캐러셀에 사진이 하나도 없는 릴스/동영상)인지 판정한다.
 */
function isVideoOnlyPost(doc, minWidth) {
  const scope = doc.querySelector('article') || doc;
  const hasVideo = !!scope.querySelector("video");
  const hasPhotoImg = collectPostImages(doc, minWidth).length > 0;
  return hasVideo && !hasPhotoImg;
}

/**
 * 캐러셀의 "다음" 버튼을 찾는다. 클릭 가능한 조상(button/[role=button])까지 올라간다.
 * 반드시 게시물 본문(article) 안에서만 찾는다 — 페이지 하단의 "추천 게시물" 등
 * 다른 캐러셀에도 동일한 aria-label="Next" 버튼이 있을 수 있어, 스코프를 벗어나면
 * 엉뚱한 캐러셀을 클릭해 수집이 뒤섞일 위험이 있다.
 * 없으면 null.
 */
function findNextButton(doc) {
  const scope = doc.querySelector('article') || doc;
  const candidates = scope.querySelectorAll('[aria-label="Next"]');
  for (const el of candidates) {
    let node = el;
    for (let i = 0; i < 4 && node; i++) {
      const role = node.getAttribute ? node.getAttribute("role") : null;
      if (node.tagName === "BUTTON" || role === "button") return node;
      node = node.parentElement || null;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// UMD 내보내기 (Node 테스트 전용, 브라우저 eval에서는 `module`이 없어 건너뜀)
// ---------------------------------------------------------------------------

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    pickBestFromSrcset,
    maxSrcsetWidth,
    bestImageUrl,
    classifyHref,
    normalizePermalink,
    dedupe,
    collectGridItems,
    collectPostImages,
    isVideoOnlyPost,
    findNextButton,
  };
}
