#!/usr/bin/env bash
# =============================================================================
# Claude Desktop RTL Patch — macOS
# Gives Claude Desktop correct RTL support for Persian / Arabic / Hebrew,
# including proper mixed-direction text (LTR words embedded in RTL paragraphs).
#
# Based on the Windows patch by shraga100:
#   https://github.com/shraga100/claude-desktop-rtl-patch
# and its macOS port by toboly:
#   https://github.com/toboly/claude-desktop-rtl-patch-mac
# (Payload replaced; install machinery extended and hardened.)
#
# MIT License — see LICENSE
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "  ${CYAN}[*]${NC} $1"; }
success() { echo -e "  ${GREEN}[+]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $1"; }
step()    { echo -e "\n${MAGENTA}${BOLD}► $1${NC}"; }
die()     { echo -e "\n  ${RED}[✗]${NC} $1" >&2; exit 1; }
info()    { echo -e "  ${BOLD}$1${NC}"; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=true; shift; }

PAYLOAD_JS="$(cd "$(dirname "$0")" && pwd)/payload/rtl.js"
BACKUP_DIR="$HOME/Library/Application Support/claude-rtl-patch/backup"
PATCHED_ASAR="/private/var/tmp/app.asar.patched.$$"
TMP_EXTRACT="/tmp/claude_rtl_extract_$$"
PATCH_MARKER="CLAUDE RTL PATCH v2 START"

# ── Phase 0: Locate the app robustly (BUG 2 fix) ─────────────────────────────
locate_claude() {
  local candidates=(
    "/Applications/Claude.app"
    "$HOME/Applications/Claude.app"
  )

  # Spotlight search
  local spotlight
  spotlight=$(mdfind "kMDItemCFBundleIdentifier == 'com.anthropic.claudefordesktop'" 2>/dev/null | head -1)
  [[ -n "$spotlight" ]] && candidates+=("$spotlight")

  for path in "${candidates[@]}"; do
    if [[ -d "$path" && -f "$path/Contents/Resources/app.asar" ]]; then
      echo "$path"
      return 0
    fi
  done

  echo ""
  echo -e "  ${RED}[✗]${NC} Claude Desktop not found. Checked:" >&2
  for path in "${candidates[@]}"; do
    echo -e "       • $path" >&2
  done
  echo -e "  Install Claude Desktop from https://claude.ai/download" >&2
  return 1
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites…"
  command -v node    >/dev/null 2>&1 || die "Node.js required — install from https://nodejs.org"
  command -v npx     >/dev/null 2>&1 || die "npx not found — reinstall Node.js"
  command -v python3 >/dev/null 2>&1 || die "python3 required (ships with macOS)"
  command -v codesign>/dev/null 2>&1 || die "codesign not found — install Xcode Command Line Tools"
  npx --yes asar --version >/dev/null 2>&1 || die "asar unavailable — run: npm install -g asar"
  [[ -f "$PAYLOAD_JS" ]] || die "Payload missing: $PAYLOAD_JS"
  success "All prerequisites satisfied."
}

# ── Quit Claude ───────────────────────────────────────────────────────────────
quit_claude() {
  step "Quitting Claude Desktop…"
  osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
  sleep 1
  pkill -x "Claude" 2>/dev/null || true
  sleep 1
  success "Claude stopped."
}

# ── Finder copy — bypasses com.apple.macl ACL that blocks even sudo cp ───────
finder_copy() {
  local src="$1" dst_dir="$2" final_name="$3"
  osascript <<APPLE 2>/dev/null
tell application "Finder"
  try
    set ex to (POSIX file "${dst_dir}${final_name}") as alias
    delete ex
  end try
  set newf to duplicate (POSIX file "${src}") to ((POSIX file "${dst_dir}") as alias)
  set name of newf to "${final_name}"
end tell
APPLE
}

# ── Compute ASAR header SHA-256 (matches ElectronAsarIntegrity plist key) ─────
asar_hash() {
  python3 - "$1" <<'PY'
import sys, struct, hashlib
with open(sys.argv[1], "rb") as f:
    f.seek(12)
    size = struct.unpack("<I", f.read(4))[0]
    data = f.read(size)
print(hashlib.sha256(data.decode("utf-8").encode("utf-8")).hexdigest())
PY
}

# ── Read the current ElectronAsarIntegrity hash from a plist ─────────────────
# The hash is the only 64-char lowercase hex string in these plists.
plist_hash() {
  grep -oE '[0-9a-f]{64}' "$1" 2>/dev/null | head -1
}

# ── Update ElectronAsarIntegrity hash in one plist ───────────────────────────
# Reads old_hash from the plist itself — robust regardless of prior install state.
update_plist_hash() {
  local plist="$1" new="$2"
  [[ -f "$plist" ]] || return 0
  local old; old=$(plist_hash "$plist")
  [[ -n "$old" && "$old" != "$new" ]] || { log "Hash unchanged in: $(basename "$(dirname "$plist")")"; return 0; }

  local tmp; tmp=$(mktemp /tmp/claude_plist_XXXXXX)
  sed "s/$old/$new/g" "$plist" > "$tmp"
  local dst_dir; dst_dir="$(dirname "$plist")/"
  local fname;   fname="$(basename "$plist")"
  finder_copy "$tmp" "$dst_dir" "$fname"
  rm -f "$tmp"
  log "Updated hash in: $(dirname "$plist" | sed "s|/Applications/Claude.app/||")"
}

# ── Ad-hoc re-sign (inside-out, Cowork-safe) ─────────────────────────────────
# Cowork runs a Linux VM via Apple's Virtualization.framework. The Swift native
# module (swift_addon.node) explicitly checks for com.apple.security.virtualization
# on the host process and refuses to start the VM if it is missing. We must add
# this entitlement to the main bundle; the kernel honours it even in ad-hoc sigs.
#
# Signing order: dylibs → .node addons → frameworks → helper .apps →
#   Contents/Helpers executables → outer bundle (no --deep on the outer bundle
#   so we control the entitlements and don't re-overwrite inner components).
resign_app() {
  local app="$1"
  step "Re-signing ad-hoc (inside-out, Cowork-safe)…"

  # Write entitlements plist — only what Cowork needs
  local ent
  ent=$(mktemp /tmp/claude_vz_ent_XXXXXX.plist)
  cat > "$ent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.virtualization</key>
  <true/>
</dict>
</plist>
PLIST

  # 1. Innermost: dylibs and .node native addons
  #    --options runtime preserves the hardened-runtime flag the originals carried
  find "$app/Contents" \( -name "*.dylib" -o -name "*.node" \) | while read -r f; do
    codesign -s - -f --options runtime "$f" 2>/dev/null || true
  done

  # 2. Each framework — use --deep on each individual framework (not on the whole app)
  find "$app/Contents/Frameworks" -maxdepth 1 -name "*.framework" | while read -r fw; do
    codesign -s - -f --deep "$fw" 2>/dev/null || true
  done

  # 3. Each helper .app bundle
  find "$app/Contents/Frameworks" -maxdepth 1 -name "*.app" | while read -r helper; do
    codesign -s - -f --deep "$helper" 2>/dev/null || true
  done

  # 4. Standalone Mach-O executables in Contents/Helpers/
  while IFS= read -r f; do
    if file "$f" 2>/dev/null | grep -q 'Mach-O'; then
      codesign -s - -f "$f" 2>/dev/null || true
    fi
  done < <(find "$app/Contents/Helpers" -type f 2>/dev/null)

  # 5. Outer bundle — no --deep (inner components already signed above)
  #    The VZ entitlement goes here so the Claude process can use Virtualization.framework
  codesign -s - -f --entitlements "$ent" "$app" 2>/dev/null || true

  rm -f "$ent"
  success "Re-signed ad-hoc with com.apple.security.virtualization. (A codesign -v warning is normal.)"
}

# ── Build the patched ASAR ────────────────────────────────────────────────────
# Extracts from the PRISTINE BACKUP so JS is always clean (never double-patched).
# The companion app.asar.unpacked/ (native modules) is symlinked from the
# installed location so that asar extract can resolve unpacked file references.
# This makes the repack deterministic → the hash is stable across re-runs.
build_patched_asar() {
  local backup_asar="$1"
  local installed_resources="$2"   # path to Contents/Resources/ (has .unpacked sibling)

  step "Phase 1: Extracting pristine ASAR (from backup)…"
  rm -rf "$TMP_EXTRACT"
  local stage; stage=$(mktemp -d)
  cp "$backup_asar" "$stage/app.asar"
  # Symlink the installed .unpacked dir so asar extract finds native modules.
  ln -sf "$installed_resources/app.asar.unpacked" "$stage/app.asar.unpacked"
  npx --yes asar extract "$stage/app.asar" "$TMP_EXTRACT"
  rm -rf "$stage"

  step "Phase 2: Locating injection targets…"
  local preload="$TMP_EXTRACT/.vite/build/mainView.js"
  [[ -f "$preload" ]] || die "Preload not found: $preload"

  local renderer
  renderer=$(find "$TMP_EXTRACT/.vite/renderer/main_window" -name "MainWindowPage-*.js" 2>/dev/null | head -1)
  [[ -n "$renderer" ]] || warn "MainWindowPage-*.js not found — injecting preload only."

  step "Phase 3: Injecting RTL payload…"
  local injected=0
  for target in "$preload" ${renderer:+"$renderer"}; do
    [[ -f "$target" ]] || continue
    if grep -q "$PATCH_MARKER" "$target" 2>/dev/null; then
      log "Already patched: $(basename "$target") (skipping)"
      continue
    fi
    local tmp; tmp=$(mktemp)
    cat "$target" "$PAYLOAD_JS" > "$tmp"
    mv "$tmp" "$target"
    success "Injected into: $(basename "$target")"
    ((injected++)) || true
  done
  [[ $injected -gt 0 ]] || warn "No new files injected (already patched?)."

  step "Phase 4: Repacking ASAR…"
  npx --yes asar pack "$TMP_EXTRACT" "$PATCHED_ASAR" --unpack "{*.node,spawn-helper}" 2>/dev/null
  rm -rf "$TMP_EXTRACT"
  success "Repacked → $PATCHED_ASAR ($(du -sh "$PATCHED_ASAR" | cut -f1))"
}

# =============================================================================
# INSTALL
# =============================================================================
cmd_install() {
  local CLAUDE_APP RESOURCES ASAR_PATH

  step "Locating Claude Desktop…"
  CLAUDE_APP=$(locate_claude) || exit 1
  RESOURCES="$CLAUDE_APP/Contents/Resources"
  ASAR_PATH="$RESOURCES/app.asar"
  success "Found: $CLAUDE_APP"
  log "Version: $(defaults read "$CLAUDE_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"

  check_prerequisites
  quit_claude

  # ── Backup (first run only — never overwrite pristine backup) ──────────────
  step "Phase 0: Backup check…"
  local BACKUP_ASAR="$BACKUP_DIR/app.asar"
  local BACKUP_VER="$BACKUP_DIR/version.txt"

  if [[ ! -f "$BACKUP_ASAR" ]]; then
    mkdir -p "$BACKUP_DIR"
    log "Creating pristine backup…"
    if $DRY_RUN; then
      warn "[dry-run] Would copy $ASAR_PATH → $BACKUP_ASAR"
    else
      cp "$ASAR_PATH" "$BACKUP_ASAR"
      defaults read "$CLAUDE_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null \
        > "$BACKUP_VER" || echo "unknown" > "$BACKUP_VER"
      success "Pristine backup saved ($(cat "$BACKUP_VER" | tr -d '\n'))."
    fi
  else
    log "Existing backup found (v$(cat "$BACKUP_VER" 2>/dev/null || echo ?)) — keeping pristine."
  fi

  if $DRY_RUN; then
    warn "[dry-run] Would build patched ASAR from installed copy and install it."
    warn "[dry-run] Exiting without changes."
    exit 0
  fi

  # ── Build patched ASAR from pristine backup → deterministic, always clean ────
  build_patched_asar "$BACKUP_ASAR" "$RESOURCES"

  # ── Compute new hash ───────────────────────────────────────────────────────
  step "Phase 5: Computing integrity hashes…"
  local new_hash; new_hash=$(asar_hash "$PATCHED_ASAR")
  log "New hash: $new_hash"

  # ── Install patched ASAR via Finder (bypasses com.apple.macl) ─────────────
  step "Phase 6: Installing patched ASAR via Finder…"
  finder_copy "$PATCHED_ASAR" "$RESOURCES/" "app.asar"
  rm -f "$PATCHED_ASAR"
  success "Installed patched app.asar."

  # ── Update ElectronAsarIntegrity in all affected plists ───────────────────
  # update_plist_hash reads old hash from each plist — robust after any prior state.
  step "Phase 7: Updating integrity hashes in Info.plist files…"
  local plists=(
    "$CLAUDE_APP/Contents/Info.plist"
    "$CLAUDE_APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"
  )
  # Enumerate helpers dynamically
  while IFS= read -r helper; do
    [[ -f "$helper/Contents/Info.plist" ]] && plists+=("$helper/Contents/Info.plist")
  done < <(find "$CLAUDE_APP/Contents/Frameworks" -maxdepth 1 -name "*.app" 2>/dev/null)

  for plist in "${plists[@]}"; do
    update_plist_hash "$plist" "$new_hash"
  done
  success "Integrity hashes updated."

  # ── Ad-hoc re-sign ─────────────────────────────────────────────────────────
  resign_app "$CLAUDE_APP"

  echo ""
  echo -e "${GREEN}${BOLD}✓ RTL patch installed successfully!${NC}"
  echo -e "  Launch Claude Desktop and test with:"
  echo -e "  ${BOLD}سلام، من امروز با React و Next.js یک feature جدید روی پورت 3000 بالا آوردم.${NC}"
  echo -e "  The paragraph should be RTL-based; Latin words should stay LTR within the flow."
  echo ""
  echo -e "  ${YELLOW}Note:${NC} Re-run this script after each Claude Desktop update."
}

# =============================================================================
# RESTORE
# =============================================================================
cmd_restore() {
  local CLAUDE_APP RESOURCES ASAR_PATH

  step "Locating Claude Desktop…"
  CLAUDE_APP=$(locate_claude) || exit 1
  RESOURCES="$CLAUDE_APP/Contents/Resources"
  ASAR_PATH="$RESOURCES/app.asar"
  success "Found: $CLAUDE_APP"

  local BACKUP_ASAR="$BACKUP_DIR/app.asar"
  local BACKUP_VER="$BACKUP_DIR/version.txt"

  if [[ ! -f "$BACKUP_ASAR" ]]; then
    die "No backup found at $BACKUP_ASAR.\nPlease reinstall Claude Desktop from https://claude.ai/download"
  fi

  log "Backup version: $(cat "$BACKUP_VER" 2>/dev/null || echo unknown)"
  quit_claude

  if $DRY_RUN; then
    warn "[dry-run] Would restore $BACKUP_ASAR → $ASAR_PATH and re-sign."
    exit 0
  fi

  step "Restoring pristine ASAR…"
  local pristine_hash; pristine_hash=$(asar_hash "$BACKUP_ASAR")
  finder_copy "$BACKUP_ASAR" "$RESOURCES/" "app.asar"

  step "Restoring integrity hashes…"
  # update_plist_hash reads old hash from the plist itself — works from any prior state.
  local plists=(
    "$CLAUDE_APP/Contents/Info.plist"
    "$CLAUDE_APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"
  )
  while IFS= read -r helper; do
    [[ -f "$helper/Contents/Info.plist" ]] && plists+=("$helper/Contents/Info.plist")
  done < <(find "$CLAUDE_APP/Contents/Frameworks" -maxdepth 1 -name "*.app" 2>/dev/null)

  for plist in "${plists[@]}"; do
    update_plist_hash "$plist" "$pristine_hash"
  done

  resign_app "$CLAUDE_APP"

  echo ""
  echo -e "${GREEN}${BOLD}✓ Claude Desktop restored to stock.${NC}"
  echo -e "  You can delete the backup at: $BACKUP_DIR"
}

# =============================================================================
# STATUS
# =============================================================================
cmd_status() {
  local CLAUDE_APP

  step "Locating Claude Desktop…"
  CLAUDE_APP=$(locate_claude) || exit 1
  local ASAR_PATH="$CLAUDE_APP/Contents/Resources/app.asar"
  local BACKUP_ASAR="$BACKUP_DIR/app.asar"
  local BACKUP_VER="$BACKUP_DIR/version.txt"

  local installed_ver
  installed_ver=$(defaults read "$CLAUDE_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)

  echo ""
  info "Claude Desktop: $CLAUDE_APP"
  info "Installed version: $installed_ver"

  if [[ -f "$BACKUP_ASAR" ]]; then
    local backed_up_ver; backed_up_ver=$(cat "$BACKUP_VER" 2>/dev/null || echo unknown)
    info "Backup: $BACKUP_DIR (v$backed_up_ver)"

    # Check if current asar contains the patch marker
    local tmp_check; tmp_check=$(mktemp -d)
    npx --yes asar extract "$ASAR_PATH" "$tmp_check" >/dev/null 2>&1
    local patched=false
    grep -q "$PATCH_MARKER" "$tmp_check/.vite/build/mainView.js" 2>/dev/null && patched=true
    rm -rf "$tmp_check"

    if $patched; then
      echo -e "  ${GREEN}[+]${NC} Patch status: ${GREEN}ACTIVE${NC}"
      if [[ "$installed_ver" != "$backed_up_ver" ]]; then
        echo -e "  ${YELLOW}[!]${NC} App was updated (v$backed_up_ver → v$installed_ver) — re-apply recommended."
      fi
    else
      echo -e "  ${YELLOW}[!]${NC} Patch status: ${YELLOW}NOT APPLIED${NC}"
    fi
  else
    echo -e "  ${YELLOW}[!]${NC} No backup found — patch has not been installed."
  fi
  echo ""
}

# =============================================================================
# MENU
# =============================================================================
print_banner() {
  echo ""
  echo -e "${BOLD}Claude Desktop RTL Patch${NC} — macOS"
  echo -e "Correct Persian / Arabic / Hebrew support (CSS-first, unicode-bidi: plaintext)"
  echo ""
}

main_menu() {
  print_banner
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run mode]${NC} No changes will be written."
    echo ""
  fi
  echo -e "  1) ${BOLD}Install${NC} / re-apply patch"
  echo -e "  2) ${BOLD}Restore${NC} stock Claude Desktop"
  echo -e "  3) ${BOLD}Status${NC} — check patch state"
  echo -e "  4) Exit"
  echo ""
  read -r -p "  Choice [1-4]: " choice
  case "$choice" in
    1) cmd_install ;;
    2) cmd_restore ;;
    3) cmd_status ;;
    4) echo "Bye." ; exit 0 ;;
    *) echo "Invalid choice." ; exit 1 ;;
  esac
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:-menu}" in
  install)  cmd_install ;;
  restore)  cmd_restore ;;
  status)   cmd_status ;;
  menu|"")  main_menu ;;
  *)        echo "Usage: $0 [--dry-run] [install|restore|status|menu]"; exit 1 ;;
esac
