# Claude Desktop RTL Patch

> **Headline test** — after patching, this line must render RTL with Latin runs staying LTR:
>
> `سلام، من امروز با React و Next.js یک feature جدید روی پورت 3000 بالا آوردم.`

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-12%2B-blue)](patch.sh)
[![Windows](https://img.shields.io/badge/Windows-10%2B-blue)](patch.ps1)
[![ShellCheck](https://github.com/aarjang/claude-desktop-rtl-patch/actions/workflows/lint.yml/badge.svg)](https://github.com/aarjang/claude-desktop-rtl-patch/actions/workflows/lint.yml)

Gives Claude Desktop correct **right-to-left (RTL) support** for Persian, Arabic, and Hebrew — on both macOS and Windows. The key improvement over previous patches is **correct mixed-direction text**: a sentence like the one above has an RTL base direction while the Latin words (`React`, `Next.js`, `feature`) and the number (`3000`) stay in their natural left-to-right order within the RTL flow, and punctuation lands on the correct side. No "scrambling."

---

## How it works

The patch swaps Claude Desktop's bundled `app.asar` archive with a version that appends a small JavaScript payload to the preload script (`.vite/build/mainView.js`). The preload runs inside the Claude Desktop webview and injects CSS into the [claude.ai](https://claude.ai) page before any content loads.

**CSS strategy — `unicode-bidi: plaintext` (no DOM mutation):**
- `unicode-bidi: plaintext` applied to prose elements (`p`, `li`, `h1`–`h6`, `blockquote`, etc.) lets the browser's native [Unicode Bidi Algorithm](https://unicode.org/reports/tr9/) determine each paragraph's direction from its first strong character. Persian/Arabic text auto-detects as RTL; English stays LTR — without any JavaScript reading or writing direction on elements.
- The ProseMirror composer flips direction per paragraph live as you type — no input listener required.
- Code blocks (`pre`, `code`, `.code-block__code`) are pinned to `direction: ltr; unicode-bidi: isolate` so they are never disturbed by surrounding RTL content.
- Sidebar / chat-history titles use `unicode-bidi: plaintext; text-align: start` only — no padding or overflow changes — so truncation with ellipsis works correctly on both sides.

**Install machinery (per OS):**
- Extract `app.asar` → inject payload → repack → update the `ElectronAsarIntegrity` SHA-256 hash in all affected `Info.plist` files (macOS) or inside `claude.exe` (Windows) → install via Finder / ACL bypass → ad-hoc re-sign (macOS only).
- Always rebuilds from a pristine backup (created on first run, never overwritten) → fully idempotent.

---

## Requirements

| | macOS | Windows |
|---|---|---|
| **OS** | macOS 12 Monterey or later | Windows 10 or later |
| **Node.js** | 18 LTS or later | 18 LTS or later |
| **asar** | installed automatically via `npx` | installed automatically via `npx` |
| **Other** | Xcode Command Line Tools (`codesign`) | PowerShell 5.1+ (ships with Windows) |

Install Node.js from <https://nodejs.org>.

---

## macOS

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/aarjang/claude-desktop-rtl-patch/main/patch.sh -o patch.sh && bash patch.sh
```

### Manual

```bash
git clone https://github.com/aarjang/claude-desktop-rtl-patch.git
cd claude-desktop-rtl-patch
chmod +x patch.sh
./patch.sh
```

Select **1 — Install** from the menu. The script will:
1. Find Claude Desktop (checks `/Applications/Claude.app`, `~/Applications/Claude.app`, and Spotlight).
2. Quit the running app.
3. Save a pristine backup of `app.asar` to `~/Library/Application Support/claude-rtl-patch/backup/`.
4. Build the patched asar from the backup, install it via Finder (bypasses macOS ACL), and update integrity hashes in all `Info.plist` files.
5. Re-sign the app bundle ad-hoc with `codesign -s -`.

**Dry run** (no changes written):
```bash
./patch.sh --dry-run
```

**Status check:**
```bash
./patch.sh status
```

---

## Windows

### One-liner (PowerShell — run as Administrator)

```powershell
irm https://raw.githubusercontent.com/aarjang/claude-desktop-rtl-patch/main/patch.ps1 -OutFile patch.ps1; .\patch.ps1
```

### Manual

```powershell
git clone https://github.com/aarjang/claude-desktop-rtl-patch.git
cd claude-desktop-rtl-patch
.\patch.ps1
```

Select **1 — Install** from the menu. The script will:
1. Find Claude Desktop by checking `%LOCALAPPDATA%\AnthropicClaude`, `%LOCALAPPDATA%\Programs\Claude`, `%PROGRAMFILES%`, and Windows uninstall registry keys.
2. Stop the running app.
3. Save a pristine backup to `%APPDATA%\claude-rtl-patch\backup\`.
4. Build the patched asar, take ownership of the file via `takeown`/`icacls`, and install it.
5. Update the integrity hash inside `claude.exe`.

**Dry run:**
```powershell
.\patch.ps1 -DryRun
```

---

## Restore

### macOS

```bash
./patch.sh restore
```

### Windows

```powershell
.\patch.ps1 -Command restore
```

If the backup is missing (e.g., you deleted it), reinstall Claude Desktop from <https://claude.ai/download>.

---

## After a Claude Desktop update

The patch must be re-applied after every update because Claude Desktop replaces `app.asar`.  
Run `./patch.sh status` (macOS) or `.\patch.ps1 -Command status` (Windows) to check.

---

## Disclaimer

This is an **unofficial modification** of Claude Desktop. It may violate [Anthropic's Terms of Service](https://www.anthropic.com/legal/consumer-terms). Use it at your own risk. It is provided as-is with no warranty. The maintainers are not affiliated with Anthropic.

- Ad-hoc code signing on macOS is expected to produce a `codesign -v` warning — this is normal.
- The patch must be re-applied after each Claude Desktop update.
- `unicode-bidi: plaintext` is supported by the Chromium engine Electron uses; the minimal JS surface is intentional to reduce breakage risk on future builds.
- **Cowork tab:** The patch re-signs the app with `com.apple.security.virtualization` so the Cowork Linux VM continues to work. If Cowork shows "Reinstall" after patching, re-run `./patch.sh install` — the VM bundle will restore itself from cache on next launch.

---

## Credits

- [shraga100/claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch) — original Windows patch, install machinery.
- [toboly/claude-desktop-rtl-patch-mac](https://github.com/toboly/claude-desktop-rtl-patch-mac) — macOS port of the above.

This repository is a derivative work: the install scripts are rewritten and hardened; the RTL payload is replaced with a CSS-first implementation that fixes mixed-direction text, sidebar title clipping, and app-path detection.

MIT License — see [LICENSE](LICENSE).
