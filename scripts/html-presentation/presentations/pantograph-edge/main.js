// pantograph-edge presentation — vanilla JS, no build step, file:// safe.
(function () {
  'use strict';

  var state = {
    sections: [],
    activeIndex: 0,
    reducedMotion: window.matchMedia('(prefers-reduced-motion: reduce)').matches,
  };

  function $all(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  // ---------- nav dots + progress bar ----------

  function buildNav() {
    state.sections = $all('section.slide');
    var nav = document.getElementById('dot-nav');
    state.sections.forEach(function (sec, i) {
      var label = sec.getAttribute('aria-label') || sec.id;
      var btn = document.createElement('button');
      btn.setAttribute('data-label', label);
      btn.setAttribute('aria-label', label + ' 섹션으로 이동');
      btn.addEventListener('click', function () {
        sec.scrollIntoView({ behavior: state.reducedMotion ? 'auto' : 'smooth' });
      });
      nav.appendChild(btn);
    });
  }

  function updateProgress() {
    var doc = document.documentElement;
    var scrollTop = doc.scrollTop || document.body.scrollTop;
    var height = doc.scrollHeight - doc.clientHeight;
    var pct = height > 0 ? (scrollTop / height) * 100 : 0;
    document.getElementById('progress-bar').style.width = pct + '%';
  }

  function updateActiveDot() {
    var mid = window.innerHeight / 2;
    var best = 0, bestDist = Infinity;
    state.sections.forEach(function (sec, i) {
      var rect = sec.getBoundingClientRect();
      var dist = Math.abs(rect.top + rect.height / 2 - mid);
      if (dist < bestDist) { bestDist = dist; best = i; }
    });
    state.activeIndex = best;
    $all('#dot-nav button').forEach(function (btn, i) {
      btn.classList.toggle('active', i === best);
    });
  }

  function onScroll() {
    updateProgress();
    updateActiveDot();
  }

  // ---------- reveal-on-scroll ----------

  function setupReveal() {
    if (!('IntersectionObserver' in window)) {
      $all('.reveal, .stage').forEach(function (el) { el.classList.add('in-view'); });
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('in-view');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15, rootMargin: '0px 0px -8% 0px' });
    $all('.reveal, .stage').forEach(function (el) { io.observe(el); });
  }

  // ---------- pipeline flow-line (SVG connecting stage boxes) ----------

  function drawFlowLine() {
    var track = document.getElementById('pipeline-track');
    var svg = document.getElementById('flow-line');
    if (!track || !svg) return;
    var stages = $all('.stage', track);
    if (!stages.length) return;

    var trackRect = track.getBoundingClientRect();
    var isStacked = window.getComputedStyle(track).gridTemplateColumns.split(' ').length === 1;
    var points = stages.map(function (stage) {
      var r = stage.getBoundingClientRect();
      var x = isStacked ? r.left - trackRect.left + 20 : r.left - trackRect.left + r.width / 2;
      var y = isStacked ? r.top - trackRect.top + r.height / 2 : r.top - trackRect.top + 18;
      return { x: x, y: y };
    });

    svg.setAttribute('viewBox', '0 0 ' + trackRect.width + ' ' + trackRect.height);
    var d = 'M ' + points.map(function (p) { return p.x + ' ' + p.y; }).join(' L ');
    svg.innerHTML = '<path d="' + d + '"></path>';
  }

  // ---------- source tree file preview ----------

  function setupTree() {
    var preview = document.getElementById('file-preview');
    if (!preview) return;
    $all('.tree .file').forEach(function (fileEl) {
      fileEl.addEventListener('click', function () {
        $all('.tree .file.active').forEach(function (f) { f.classList.remove('active'); });
        fileEl.classList.add('active');
        var name = fileEl.textContent.trim();
        var desc = fileEl.getAttribute('data-desc') || '설명이 없습니다.';
        var evidence = fileEl.getAttribute('data-evidence') || '';
        preview.innerHTML =
          '<h4>' + escapeHtml(name) + '</h4>' +
          '<p>' + escapeHtml(desc) + '</p>' +
          (evidence ? '<div class="evidence-line">근거: ' + escapeHtml(evidence) + '</div>' : '');
      });
    });
  }

  function escapeHtml(str) {
    var div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
  }

  // ---------- keyboard navigation (up/down/PageUp/PageDown jump sections) ----------

  function setupKeyboardNav() {
    window.addEventListener('keydown', function (e) {
      if (e.altKey || e.metaKey || e.ctrlKey) return;

      var tag = (document.activeElement && document.activeElement.tagName) || '';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'VIDEO') return;
      if (document.activeElement && document.activeElement.closest('video')) return;

      if (e.key === 'ArrowDown' || e.key === 'PageDown' || e.key === 'ArrowRight') {
        e.preventDefault();
        jumpTo(state.activeIndex + 1);
      } else if (e.key === 'ArrowUp' || e.key === 'PageUp' || e.key === 'ArrowLeft') {
        e.preventDefault();
        jumpTo(state.activeIndex - 1);
      }
    });
  }

  function jumpTo(index) {
    if (index < 0 || index >= state.sections.length) return;
    state.activeIndex = index;
    state.sections[index].scrollIntoView({ behavior: state.reducedMotion ? 'auto' : 'smooth' });
  }

  // ---------- init ----------

  function init() {
    buildNav();
    setupReveal();
    setupTree();
    setupKeyboardNav();
    drawFlowLine();

    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', debounce(drawFlowLine, 150));
    onScroll();
  }

  function debounce(fn, ms) {
    var t;
    return function () {
      clearTimeout(t);
      t = setTimeout(fn, ms);
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
