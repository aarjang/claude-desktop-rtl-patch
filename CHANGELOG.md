# Changelog

## Phase 0 — Real-build inspection (2026-06-16)

Findings from inspecting the real Claude Desktop v1.12603.1 on macOS:

| Property | Value |
|---|---|
| App path | `/Applications/Claude.app` |
| Bundle ID | `com.anthropic.claudefordesktop` |
| ASAR path | `Contents/Resources/app.asar` (35 MB) |
| Preload | `.vite/build/mainView.js` (189 KB) |
| Renderer entry | `.vite/renderer/main_window/assets/MainWindowPage-C5zZqnr3.js` |
| Main bundle | `.vite/renderer/main_window/assets/main-BTageDXi.js` |
| Hash mechanism | SHA-256 of ASAR header bytes at offset 16 (size from offset 12) |
| Hash key in plists | `ElectronAsarIntegrity > Resources/app.asar > hash` |
| Plists containing hash | `Contents/Info.plist`, `Electron Framework.framework/.../Info.plist`, all four `Claude Helper*.app/Contents/Info.plist` |
| CSS injection method | `webFrame.insertCSS(css, {cssOrigin:'author'})` in the preload (Electron API, persists through SPA navigation) |
| App UI source | Loaded from **claude.ai** (not local bundles) — the Electron window is a webview wrapper |

**Key selectors discovered:**

| Element | Selector |
|---|---|
| Composer / editor | `[data-testid="chat-input"]`, `.ProseMirror`, `[contenteditable="true"]` |
| Code blocks | `pre`, `.code-block__code` |
| Inline code | `code` |
| Sidebar title | `nav a span`, `nav li span`, `nav button span`, `aside a span` |

**BUG 1 root cause (sidebar clipping):**  
The old payload called `el.style.direction = 'rtl'` + explicit `padding-left: 0; padding-right: Xpx` on generic `div/span/button/a` elements. On Tailwind `truncate` elements (`overflow:hidden; text-overflow:ellipsis; white-space:nowrap`), the padding swap pushed text past the container border. Fix: CSS-only `unicode-bidi: plaintext; text-align: start` with NO padding or overflow changes.

**BUG 2 root cause (path detection):**  
Old script hardcoded `/Applications/Claude.app`. Fix: check three locations + `mdfind` Spotlight search; print all checked paths on failure.

---

## v2.1 — Cowork re-sign fix (2026-06-16)

**Root cause:** `codesign -s - -f --deep` on the outer bundle in v2 replaced the full bundle
signature and stripped all entitlements from every nested binary — including the entitlement
needed for Cowork's Linux VM.

**Investigation:**
- Cowork is not a simple in-process feature: it runs a full Linux VM via Apple's
  Virtualization.framework (`swift_addon.node`, the `@ant/claude-swift` native module).
- `swift_addon.node` contains an explicit runtime check: if `com.apple.security.virtualization`
  is absent from the calling process, it returns `entitlement_missing` — which triggers
  VM bundle deletion and the "Reinstall" prompt in the UI.
- After v2's ad-hoc re-sign, the Cowork VM started (`Linux VM started successfully`) but
  failed at `guest_vsock_connect` with `VZErrorDomain Code=1` — the kernel-level vsock
  requires the virtualization entitlement at the process level.

**Fix (resign_app rewrite):**
1. Removed `--deep` from the outer bundle `codesign` call. Instead, sign inside-out:
   dylibs + `.node` addons → each framework (with its own `--deep`) → each helper `.app`
   → Contents/Helpers executables → outer bundle (no `--deep`).
2. Added `com.apple.security.virtualization` to the outer bundle's entitlements plist.
3. Preserved `--options runtime` on all `.node` files (the originals had the hardened-runtime
   flag; dropping it would break JIT/library loading rules for those binaries).

**Result:** Cowork VM starts fully after patching:
`guest_vsock_connect → CONNECTED → SDK installed → API reachability: REACHABLE`

---

## v2 — CSS-first rewrite

- **Payload replaced**: `payload/rtl.js` — pure CSS via `unicode-bidi: plaintext`, no `dir` writes, no DOM mutation, no hand-rolled Unicode detection.
- **BUG 1 fixed**: sidebar title spans get only `unicode-bidi: plaintext; text-align: start`; overflow/padding untouched.
- **BUG 2 fixed**: multi-location detection with clear diagnostic on failure.
- **Idempotent**: always rebuilds from pristine backup, never from currently-installed (potentially already-patched) asar.
- **Restore**: reliable restore from pristine backup with hash reversal and re-sign.
- **Status command**: reports patched/not-patched, version drift since backup.
- **Dry-run flag**: `--dry-run` / `-DryRun`.
- **Windows**: PowerShell script with registry-based detection, `takeown`/`icacls` ACL bypass, hash patch inside `claude.exe`.
- **CI**: ShellCheck + PSScriptAnalyzer lint workflow.
