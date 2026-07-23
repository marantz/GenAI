// tests/collect.test.js — collect.js 단위 테스트. 외부 의존성 없이 node:test로 실행.
// 실행: node --test tests/

const test = require("node:test");
const assert = require("node:assert/strict");
const {
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
} = require("../js/collect.js");
const { FakeElement, makeDocument } = require("./fake-dom.js");

test("pickBestFromSrcset: w 기술자 중 최대값을 고른다", () => {
  const srcset = "https://a 150w, https://b 640w, https://c 1080w, https://d 320w";
  assert.equal(pickBestFromSrcset(srcset), "https://c");
});

test("pickBestFromSrcset: 순서가 뒤섞여도 최대값을 고른다", () => {
  const srcset = "https://big 1080w, https://small 150w";
  assert.equal(pickBestFromSrcset(srcset), "https://big");
});

test("pickBestFromSrcset: x(밀도) 기술자도 처리한다", () => {
  const srcset = "https://a 1x, https://b 2x";
  assert.equal(pickBestFromSrcset(srcset), "https://b");
});

test("pickBestFromSrcset: 빈/잘못된 입력은 null", () => {
  assert.equal(pickBestFromSrcset(""), null);
  assert.equal(pickBestFromSrcset(null), null);
  assert.equal(pickBestFromSrcset(undefined), null);
});

test("maxSrcsetWidth: w 기술자 중 최댓값(px)을 반환", () => {
  assert.equal(maxSrcsetWidth("https://a 150w, https://b 640w"), 640);
});

test("maxSrcsetWidth: w 기술자가 없으면 null (판단 불가)", () => {
  assert.equal(maxSrcsetWidth("https://a 1x, https://b 2x"), null);
  assert.equal(maxSrcsetWidth(""), null);
  assert.equal(maxSrcsetWidth(null), null);
});

test("bestImageUrl: srcset > currentSrc > src 우선순위", () => {
  assert.equal(
    bestImageUrl({ srcset: "https://hi 1080w", currentSrc: "https://cur", src: "https://s" }),
    "https://hi"
  );
  assert.equal(bestImageUrl({ srcset: null, currentSrc: "https://cur", src: "https://s" }), "https://cur");
  assert.equal(bestImageUrl({ srcset: null, currentSrc: null, src: "https://s" }), "https://s");
  assert.equal(bestImageUrl(null), null);
  assert.equal(bestImageUrl({}), null);
});

test("classifyHref: /p/, /reel/, /tv/ 만 게시물로 인정", () => {
  assert.deepEqual(classifyHref("/p/ABC123/"), { type: "p", shortcode: "ABC123" });
  assert.deepEqual(classifyHref("/reel/XYZ/"), { type: "reel", shortcode: "XYZ" });
  assert.deepEqual(classifyHref("/tv/QQQ/"), { type: "tv", shortcode: "QQQ" });
  assert.deepEqual(
    classifyHref("https://www.instagram.com/p/ABC123/?img_index=2"),
    { type: "p", shortcode: "ABC123" }
  );
});

test("classifyHref: 사용자명 접두 형태(/<username>/p/<code>/)도 인정", () => {
  assert.deepEqual(classifyHref("/vividartistry2023/p/DbA5HTGExrf/"), {
    type: "p",
    shortcode: "DbA5HTGExrf",
  });
  assert.deepEqual(classifyHref("/someuser/reel/XYZ/"), { type: "reel", shortcode: "XYZ" });
});

test("classifyHref: 프로필/탐색 등 다른 링크는 null", () => {
  assert.equal(classifyHref("/someuser/"), null);
  assert.equal(classifyHref("/explore/tags/travel/"), null);
  assert.equal(classifyHref(""), null);
  assert.equal(classifyHref(null), null);
});

test("normalizePermalink: 절대 URL로 정규화", () => {
  assert.equal(normalizePermalink("/p/ABC123/"), "https://www.instagram.com/p/ABC123/");
  assert.equal(normalizePermalink("/notapost/"), null);
});

test("dedupe: 순서를 유지하며 중복 제거, falsy 무시", () => {
  assert.deepEqual(dedupe(["a", "b", "a", null, "c", "", "b"]), ["a", "b", "c"]);
});

// ---------------------------------------------------------------------------
// DOM 의존 함수 (fake-dom 사용)
// ---------------------------------------------------------------------------

function anchorWithImg(href, srcset) {
  const img = new FakeElement("img", { srcset, alt: "Photo" });
  return new FakeElement("a", { href }, [img]);
}

test("collectGridItems: 게시물 링크만 골라 커버 이미지를 뽑는다", () => {
  const doc = makeDocument([
    anchorWithImg("/p/AAA/", "https://a-small 320w, https://a-big 1080w"),
    anchorWithImg("/reel/BBB/", "https://b-small 320w, https://b-big 750w"),
    new FakeElement("a", { href: "/someprofile/" }, [
      new FakeElement("img", { srcset: "https://ignored 1080w" }),
    ]),
  ]);
  const items = collectGridItems(doc, "https://www.instagram.com", 0);
  assert.equal(items.length, 2);
  assert.deepEqual(items[0], {
    permalink: "https://www.instagram.com/p/AAA/",
    type: "p",
    coverUrl: "https://a-big",
  });
  assert.deepEqual(items[1], {
    permalink: "https://www.instagram.com/reel/BBB/",
    type: "reel",
    coverUrl: "https://b-big",
  });
});

test("collectGridItems: minWidth 미달 항목은 제외하지만 판단 불가(정보 없음)면 포함한다", () => {
  const doc = makeDocument([
    anchorWithImg("/p/SMALL/", "https://tiny 100w"),
    anchorWithImg("/p/BIG/", "https://big-small 100w, https://big-big 1080w"),
    new FakeElement("a", { href: "/p/NOSRCSET/" }, [new FakeElement("img", { alt: "Photo" })]),
  ]);
  const items = collectGridItems(doc, "https://www.instagram.com", 150);
  const permalinks = items.map((it) => it.permalink);
  assert.ok(!permalinks.includes("https://www.instagram.com/p/SMALL/"));
  assert.ok(permalinks.includes("https://www.instagram.com/p/BIG/"));
  assert.ok(permalinks.includes("https://www.instagram.com/p/NOSRCSET/"));
});

test("collectPostImages: 캐러셀의 모든 사진 슬라이드를 모으고 프로필 아바타는 배제", () => {
  const article = new FakeElement("article", {}, [
    new FakeElement("img", { alt: "Profile picture of someuser", srcset: "https://avatar 150w" }),
    new FakeElement("img", { alt: "Photo by someuser", srcset: "https://slide1-small 320w, https://slide1-big 1080w" }),
    new FakeElement("img", { alt: "Photo by someuser", srcset: "https://slide2-small 320w, https://slide2-big 1080w" }),
  ]);
  const doc = makeDocument([article]);
  const urls = collectPostImages(doc);
  assert.deepEqual(urls, ["https://slide1-big", "https://slide2-big"]);
});

test("collectPostImages: alt 텍스트로 안 걸러지는 댓글 작성자 아바타도 minWidth로 배제한다", () => {
  const article = new FakeElement("article", {}, [
    new FakeElement("img", { alt: "someuser", srcset: "https://commenter-avatar 150w" }),
    new FakeElement("img", { alt: "Photo by someuser", srcset: "https://slide1-small 320w, https://slide1-big 1080w" }),
  ]);
  const doc = makeDocument([article]);
  const urls = collectPostImages(doc, 200);
  assert.deepEqual(urls, ["https://slide1-big"]);
});

test("isVideoOnlyPost: 비디오만 있고 사진이 없으면 true", () => {
  const article = new FakeElement("article", {}, [new FakeElement("video", {})]);
  const doc = makeDocument([article]);
  assert.equal(isVideoOnlyPost(doc), true);
});

test("isVideoOnlyPost: 비디오+사진(믹스 캐러셀)이면 false", () => {
  const article = new FakeElement("article", {}, [
    new FakeElement("video", {}),
    new FakeElement("img", { alt: "Photo by someuser", srcset: "https://slide 1080w" }),
  ]);
  const doc = makeDocument([article]);
  assert.equal(isVideoOnlyPost(doc), false);
});

test("findNextButton: aria-label=Next 을 가진 클릭 가능한 조상을 반환", () => {
  const svg = new FakeElement("svg", { "aria-label": "Next" });
  const btn = new FakeElement("button", {}, [svg]);
  const article = new FakeElement("article", {}, [btn]);
  const doc = makeDocument([article]);
  const found = findNextButton(doc);
  assert.equal(found, btn);
});

test("findNextButton: 버튼이 없으면 null", () => {
  const article = new FakeElement("article", {}, [new FakeElement("img", {})]);
  const doc = makeDocument([article]);
  assert.equal(findNextButton(doc), null);
});

test("findNextButton: article 밖(추천 게시물 등)의 Next 버튼은 무시한다", () => {
  const article = new FakeElement("article", {}, [new FakeElement("img", {})]);
  const outsideSvg = new FakeElement("svg", { "aria-label": "Next" });
  const outsideBtn = new FakeElement("button", {}, [outsideSvg]);
  const suggestedSection = new FakeElement("section", {}, [outsideBtn]);
  const doc = makeDocument([article, suggestedSection]);
  assert.equal(findNextButton(doc), null);
});
