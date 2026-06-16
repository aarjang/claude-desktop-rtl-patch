// --- CLAUDE RTL PATCH v2 START ---
// CSS-first RTL support: unicode-bidi: plaintext lets the browser's Unicode Bidi
// Algorithm determine paragraph direction from the first strong character.
// No dir-attribute writes, no element.style.direction mutation, no hand-rolled
// Unicode range detection. Mixed-direction text (e.g. Persian + Latin + numbers)
// renders correctly because the UBA handles it natively.
;(function () {
  'use strict';
  if (typeof document === 'undefined' && typeof require === 'undefined') return;

  var STYLE_ID = 'claude-rtl-patch-v2';

  var CSS = [
    // ── Prose content ──────────────────────────────────────────────────────────
    // unicode-bidi: plaintext → base direction is set per paragraph by the UBA
    // (first strong character rule P2/P3). text-align: start follows that direction.
    // Safe for LTR paragraphs — they are unaffected when first char is LTR.
    'p, li,',
    'h1, h2, h3, h4, h5, h6,',
    'blockquote, td, th, dl, dt, dd {',
    '  unicode-bidi: plaintext;',
    '  text-align: start;',
    '}',

    // ── Lists ──────────────────────────────────────────────────────────────────
    // padding-inline-start is logical — flips with content direction automatically.
    // Never touch padding-left / padding-right directly.
    'ul, ol {',
    '  padding-inline-start: 1.5em;',
    '  text-align: start;',
    '}',

    // ── Composer (ProseMirror contenteditable) ─────────────────────────────────
    // Flips direction per paragraph live as the user types — no input listener needed.
    '[contenteditable="true"],',
    '.ProseMirror {',
    '  unicode-bidi: plaintext;',
    '  text-align: start;',
    '}',

    // ── Sidebar / conversation history titles (BUG 1 fix) ─────────────────────
    // unicode-bidi: plaintext is content-driven: LTR titles stay LTR, RTL auto-detects.
    // NO explicit direction, padding, or overflow properties — the Tailwind "truncate"
    // class (overflow:hidden; text-overflow:ellipsis; white-space:nowrap) is preserved.
    // The ellipsis lands on the correct side because the UBA sets the inline direction.
    'nav a span, nav li span, nav button span,',
    'aside a span, aside li span, aside button span {',
    '  unicode-bidi: plaintext;',
    '  text-align: start;',
    '}',

    // ── Code regions — always LTR ──────────────────────────────────────────────
    // unicode-bidi: isolate stops code from disturbing surrounding RTL flow.
    // direction: ltr + text-align: left are safe hard overrides for code only.
    'pre, code, kbd, samp,',
    '.code-block__code {',
    '  direction: ltr !important;',
    '  unicode-bidi: isolate !important;',
    '  text-align: left !important;',
    '}',
  ].join('\n');

  // ── Primary injection: Electron webFrame.insertCSS (preload context) ─────────
  // This is the most robust method in the preload: CSS is managed by Electron,
  // survives SPA route changes, and cannot be removed by DOM manipulation.
  var _usedWebFrame = false;
  try {
    if (typeof require !== 'undefined') {
      var _elec = require('electron');
      if (_elec && _elec.webFrame && typeof _elec.webFrame.insertCSS === 'function') {
        _elec.webFrame.insertCSS(CSS, { cssOrigin: 'author' });
        _usedWebFrame = true;
      }
    }
  } catch (_err) {
    // Not in preload context — fall through to DOM injection below.
  }

  // ── Fallback injection: <style> tag + presence-guard observer ─────────────────
  // Used when webFrame is not available (page-script context).
  // The observer re-injects the tag only if it is removed — it never reads or
  // writes element direction.
  if (!_usedWebFrame && typeof document !== 'undefined') {
    var _timer = null;

    function _inject() {
      if (document.getElementById(STYLE_ID)) return;
      var s = document.createElement('style');
      s.id = STYLE_ID;
      s.textContent = CSS;
      (document.head || document.documentElement).appendChild(s);
    }

    function _scheduleInject() {
      if (_timer) return;
      _timer = setTimeout(function () {
        _timer = null;
        _inject();
      }, 100);
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', _inject);
    } else {
      _inject();
    }

    // Guard: watch document.head for the style tag being removed.
    var _root = document.documentElement || document.head;
    if (_root) {
      new MutationObserver(function () {
        if (!document.getElementById(STYLE_ID)) {
          _scheduleInject();
        }
      }).observe(_root, { childList: true, subtree: true });
    }
  }
})();
// --- CLAUDE RTL PATCH v2 END ---
