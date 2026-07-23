/*
 * fake-dom.js — collect.js의 DOM 의존 함수를 실제 브라우저 없이 테스트하기 위한
 * 아주 작은 querySelector(All) 구현. jsdom 등 외부 의존성을 두지 않기 위해 직접 작성했다.
 *
 * collect.js가 실제로 사용하는 셀렉터 형태만 지원한다:
 *   - 태그명 ("img", "video", "article")
 *   - 속성 존재/등치/부분일치 ([href], [role="button"], [href*="/p/"])
 *   - 쉼표로 나열된 여러 셀렉터의 합집합
 * 프로덕션 코드(collect.js)는 실제 브라우저(cmux eval)에서 실행되어 진짜
 * querySelectorAll을 쓰므로, 여기서는 테스트에 필요한 최소 부분집합만 구현한다.
 */

class FakeElement {
  constructor(tagName, attrs = {}, children = []) {
    this.tagName = tagName.toUpperCase();
    this._attrs = attrs;
    this.children = [];
    this.parentElement = null;
    for (const c of children) this.appendChild(c);
    if ("currentSrc" in attrs) this.currentSrc = attrs.currentSrc;
    if ("src" in attrs) this.src = attrs.src;
  }

  appendChild(child) {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  getAttribute(name) {
    return name in this._attrs ? this._attrs[name] : null;
  }

  _descendants() {
    const out = [];
    for (const c of this.children) {
      out.push(c);
      out.push(...c._descendants());
    }
    return out;
  }

  querySelectorAll(selector) {
    const branches = selector.split(",").map((s) => s.trim());
    const pool = this._descendants();
    return pool.filter((el) => branches.some((b) => matchesSimple(el, b)));
  }

  querySelector(selector) {
    const all = this.querySelectorAll(selector);
    return all.length ? all[0] : null;
  }
}

function matchesSimple(el, simpleSelector) {
  const m = simpleSelector.match(/^([a-zA-Z0-9]*)((?:\[[^\]]+\])*)$/);
  if (!m) throw new Error(`fake-dom: 지원하지 않는 셀렉터: ${simpleSelector}`);
  const [, tag, attrsPart] = m;
  if (tag && el.tagName !== tag.toUpperCase()) return false;
  const attrRe = /\[([a-zA-Z0-9-]+)(?:([*^$]?=)"?([^"\]]*)"?)?\]/g;
  let am;
  while ((am = attrRe.exec(attrsPart))) {
    const [, name, op, val] = am;
    const actual = el.getAttribute(name);
    if (op === undefined) {
      if (actual === null) return false;
    } else if (actual === null) {
      return false;
    } else if (op === "=") {
      if (actual !== val) return false;
    } else if (op === "*=") {
      if (!actual.includes(val)) return false;
    } else if (op === "^=") {
      if (!actual.startsWith(val)) return false;
    } else if (op === "$=") {
      if (!actual.endsWith(val)) return false;
    }
  }
  return true;
}

/** 최소 document-like 루트: querySelector(All)만 몸통(root children)에 위임. */
function makeDocument(rootChildren) {
  const root = new FakeElement("DOCUMENT-ROOT", {}, rootChildren);
  return root;
}

module.exports = { FakeElement, makeDocument };
