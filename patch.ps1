#Requires -Version 5.1
<#
.SYNOPSIS
  Claude Desktop RTL Patch — Windows
  Gives Claude Desktop correct RTL support for Persian / Arabic / Hebrew.

.DESCRIPTION
  Based on the original Windows patch by shraga100:
    https://github.com/shraga100/claude-desktop-rtl-patch
  Payload replaced with a CSS-first, unicode-bidi: plaintext implementation
  that correctly handles mixed-direction text without DOM mutation.

.PARAMETER DryRun
  Print what would be done without making any changes.

.PARAMETER Command
  install | restore | status | menu (default: menu)

.EXAMPLE
  .\patch.ps1
  .\patch.ps1 -Command install
  .\patch.ps1 -DryRun -Command install
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('install','restore','status','menu')]
    [string]$Command = 'menu'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Colours ───────────────────────────────────────────────────────────────────
function Write-Step   { Write-Host "`n► $args" -ForegroundColor Magenta }
function Write-Log    { Write-Host "  [*] $args" -ForegroundColor Cyan }
function Write-OK     { Write-Host "  [+] $args" -ForegroundColor Green }
function Write-Warn   { Write-Host "  [!] $args" -ForegroundColor Yellow }
function Write-Fail   { Write-Host "  [x] $args" -ForegroundColor Red; exit 1 }

$PATCH_MARKER  = 'CLAUDE RTL PATCH v2 START'
$BACKUP_DIR    = Join-Path $env:APPDATA 'claude-rtl-patch\backup'
$PAYLOAD_JS    = Join-Path $PSScriptRoot 'payload\rtl.js'

# Payload embedded so the script works as a single downloaded file.
# If payload\rtl.js exists beside the script, that file takes precedence (dev override).
$EMBEDDED_PAYLOAD = @'
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
    'p, li,',
    'h1, h2, h3, h4, h5, h6,',
    'blockquote, td, th, dl, dt, dd {',
    '  unicode-bidi: plaintext;',
    '  text-align: start;',
    '}',
    'ul, ol {',
    '  padding-inline-start: 1.5em;',
    '  text-align: start;',
    '}',
    '[contenteditable="true"],',
    '.ProseMirror {',
    '  unicode-bidi: plaintext;',
    '  text-align: start;',
    '}',
    'nav a span, nav li span, nav button span,',
    'aside a span, aside li span, aside button span {',
    '  unicode-bidi: plaintext;',
    '  text-align: start;',
    '}',
    'pre, code, kbd, samp,',
    '.code-block__code {',
    '  direction: ltr !important;',
    '  unicode-bidi: isolate !important;',
    '  text-align: left !important;',
    '}',
  ].join('\n');

  var _usedWebFrame = false;
  try {
    if (typeof require !== 'undefined') {
      var _elec = require('electron');
      if (_elec && _elec.webFrame && typeof _elec.webFrame.insertCSS === 'function') {
        _elec.webFrame.insertCSS(CSS, { cssOrigin: 'author' });
        _usedWebFrame = true;
      }
    }
  } catch (_err) {}

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
      _timer = setTimeout(function () { _timer = null; _inject(); }, 100);
    }
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', _inject);
    } else {
      _inject();
    }
    var _root = document.documentElement || document.head;
    if (_root) {
      new MutationObserver(function () {
        if (!document.getElementById(STYLE_ID)) { _scheduleInject(); }
      }).observe(_root, { childList: true, subtree: true });
    }
  }
})();
// --- CLAUDE RTL PATCH v2 END ---
'@

# ── Phase 0: Locate the app robustly (BUG 2 fix) ─────────────────────────────
function Find-ClaudeApp {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude'),
        (Join-Path $env:PROGRAMFILES 'Claude'),
        (Join-Path ${env:PROGRAMFILES(X86)} 'Claude' -ErrorAction SilentlyContinue)
    )

    # Registry uninstall keys
    $regPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($reg in $regPaths) {
        try {
            Get-ItemProperty $reg -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Claude*' } |
                ForEach-Object {
                    if ($_.InstallLocation) { $candidates += $_.InstallLocation }
                }
        } catch {}
    }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (-not $path) { continue }
        $asar = Join-Path $path 'resources\app.asar'
        if (Test-Path $asar) { return $path }
    }

    Write-Host "`n  [x] Claude Desktop not found. Checked:" -ForegroundColor Red
    $candidates | Select-Object -Unique | ForEach-Object { Write-Host "       • $_" -ForegroundColor Red }
    Write-Host "  Install from https://claude.ai/download" -ForegroundColor Red
    exit 1
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
function Test-Prerequisites {
    Write-Step "Checking prerequisites..."
    try { node --version | Out-Null } catch { Write-Fail "Node.js required — install from https://nodejs.org" }
    try { npx --version | Out-Null } catch { Write-Fail "npx not found — reinstall Node.js" }
    try { npx --yes asar --version | Out-Null } catch { Write-Fail "asar unavailable — run: npm install -g asar" }
    Write-OK "All prerequisites satisfied."
}

# ── Quit Claude ───────────────────────────────────────────────────────────────
function Stop-Claude {
    Write-Step "Stopping Claude Desktop..."
    Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-OK "Claude stopped."
}

# ── Compute ASAR header SHA-256 ───────────────────────────────────────────────
function Get-AsarHash([string]$Path) {
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $size   = [System.BitConverter]::ToUInt32($bytes, 12)
    $header = [System.Text.Encoding]::UTF8.GetString($bytes, 16, [int]$size)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash   = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($header))
    return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ── Patch the ASAR hash inside claude.exe (Windows-specific) ─────────────────
function Update-ExeHash([string]$exe, [string]$oldHash, [string]$newHash) {
    if (-not (Test-Path $exe)) { return }
    $content = [System.IO.File]::ReadAllText($exe, [System.Text.Encoding]::Latin1)
    if ($content.IndexOf($oldHash) -lt 0) { Write-Warn "Hash not found in $exe — skipping."; return }
    $patched = $content.Replace($oldHash, $newHash)
    [System.IO.File]::WriteAllText($exe, $patched, [System.Text.Encoding]::Latin1)
    Write-Log "Updated hash in: $(Split-Path -Leaf $exe)"
}

# ── Take ownership and fix ACLs on a file ────────────────────────────────────
function Set-FileOwnership([string]$Path) {
    takeown /F $Path /A 2>$null | Out-Null
    icacls $Path /grant "Administrators:F" 2>$null | Out-Null
}

# ── Build patched ASAR from pristine backup ───────────────────────────────────
function Build-PatchedAsar([string]$pristineAsar, [string]$outAsar) {
    $tmp = Join-Path $env:TEMP "claude_rtl_$([System.Diagnostics.Process]::GetCurrentProcess().Id)"

    Write-Step "Phase 1: Extracting pristine ASAR..."
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    npx --yes asar extract $pristineAsar $tmp | Out-Null

    Write-Step "Phase 2: Locating injection targets..."
    $preload = Join-Path $tmp '.vite\build\mainView.js'
    if (-not (Test-Path $preload)) { Write-Fail "Preload not found: $preload" }

    $renderer = Get-ChildItem (Join-Path $tmp '.vite\renderer\main_window') -Filter 'MainWindowPage-*.js' -ErrorAction SilentlyContinue | Select-Object -First 1

    Write-Step "Phase 3: Injecting RTL payload..."
    $payload = if (Test-Path $PAYLOAD_JS) { Get-Content $PAYLOAD_JS -Raw } else { $EMBEDDED_PAYLOAD }
    $injected = 0

    foreach ($target in @($preload) + @($renderer.FullName | Where-Object { $_ })) {
        if (-not $target -or -not (Test-Path $target)) { continue }
        $existing = Get-Content $target -Raw
        if ($existing -match [regex]::Escape($PATCH_MARKER)) {
            Write-Log "Already patched: $(Split-Path -Leaf $target) (skipping)"
            continue
        }
        "$existing`n$payload" | Set-Content $target -Encoding UTF8 -NoNewline
        Write-OK "Injected into: $(Split-Path -Leaf $target)"
        $injected++
    }
    if ($injected -eq 0) { Write-Warn "No new files injected (already patched?)." }

    Write-Step "Phase 4: Repacking ASAR..."
    npx --yes asar pack $tmp $outAsar --unpack '{*.node,spawn-helper}' 2>$null | Out-Null
    Remove-Item -Recurse -Force $tmp
    $size = [math]::Round((Get-Item $outAsar).Length / 1MB, 1)
    Write-OK "Repacked → $outAsar ($size MB)"
}

# =============================================================================
# INSTALL
# =============================================================================
function Invoke-Install {
    Write-Step "Locating Claude Desktop..."
    $claudeDir = Find-ClaudeApp
    $resources  = Join-Path $claudeDir 'resources'
    $asarPath   = Join-Path $resources 'app.asar'
    $exePath    = Join-Path $claudeDir 'Claude.exe'
    Write-OK "Found: $claudeDir"

    Test-Prerequisites
    Stop-Claude

    # Backup
    Write-Step "Phase 0: Backup check..."
    $backupAsar = Join-Path $BACKUP_DIR 'app.asar'
    $backupVer  = Join-Path $BACKUP_DIR 'version.txt'

    if (-not (Test-Path $backupAsar)) {
        New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null
        Write-Log "Creating pristine backup..."
        if ($DryRun) {
            Write-Warn "[dry-run] Would copy $asarPath → $backupAsar"
        } else {
            Copy-Item $asarPath $backupAsar
            $ver = (Get-Item $exePath).VersionInfo.FileVersion
            $ver | Set-Content $backupVer
            Write-OK "Pristine backup saved (v$ver)."
        }
    } else {
        $bv = Get-Content $backupVer -ErrorAction SilentlyContinue
        Write-Log "Existing backup found (v$bv) — keeping pristine."
    }

    if ($DryRun) {
        Write-Warn "[dry-run] Would build and install patched ASAR. Exiting without changes."
        return
    }

    $outAsar = Join-Path $env:TEMP "app.asar.patched.$([System.Diagnostics.Process]::GetCurrentProcess().Id)"

    Build-PatchedAsar $backupAsar $outAsar

    Write-Step "Phase 5: Computing integrity hashes..."
    $oldHash = Get-AsarHash $backupAsar
    $newHash = Get-AsarHash $outAsar
    Write-Log "Old hash: $oldHash"
    Write-Log "New hash: $newHash"

    Write-Step "Phase 6: Installing patched ASAR..."
    Set-FileOwnership $asarPath
    Copy-Item -Force $outAsar $asarPath
    Remove-Item -Force $outAsar
    Write-OK "Installed patched app.asar."

    Write-Step "Phase 7: Updating integrity hash in claude.exe..."
    Update-ExeHash $exePath $oldHash $newHash

    Write-Host ""
    Write-Host "  ✓ RTL patch installed successfully!" -ForegroundColor Green
    Write-Host "  Launch Claude Desktop and test with:"
    Write-Host "  سلام، من امروز با React و Next.js یک feature جدید روی پورت 3000 بالا آوردم." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Note: Re-run after each Claude Desktop update." -ForegroundColor Yellow
}

# =============================================================================
# RESTORE
# =============================================================================
function Invoke-Restore {
    Write-Step "Locating Claude Desktop..."
    $claudeDir = Find-ClaudeApp
    $resources  = Join-Path $claudeDir 'resources'
    $asarPath   = Join-Path $resources 'app.asar'
    $exePath    = Join-Path $claudeDir 'Claude.exe'

    $backupAsar = Join-Path $BACKUP_DIR 'app.asar'
    $backupVer  = Join-Path $BACKUP_DIR 'version.txt'

    if (-not (Test-Path $backupAsar)) {
        Write-Fail "No backup found at $backupAsar.`nPlease reinstall Claude Desktop from https://claude.ai/download"
    }

    $bv = Get-Content $backupVer -ErrorAction SilentlyContinue
    Write-Log "Backup version: $bv"
    Stop-Claude

    if ($DryRun) {
        Write-Warn "[dry-run] Would restore $backupAsar → $asarPath."
        return
    }

    $oldHash = Get-AsarHash $asarPath
    $newHash = Get-AsarHash $backupAsar

    Write-Step "Restoring pristine ASAR..."
    Set-FileOwnership $asarPath
    Copy-Item -Force $backupAsar $asarPath
    Write-OK "Restored app.asar."

    Write-Step "Restoring integrity hash in claude.exe..."
    Update-ExeHash $exePath $oldHash $newHash

    Write-Host ""
    Write-Host "  ✓ Claude Desktop restored to stock." -ForegroundColor Green
    Write-Host "  You can delete the backup at: $BACKUP_DIR"
}

# =============================================================================
# STATUS
# =============================================================================
function Invoke-Status {
    Write-Step "Locating Claude Desktop..."
    $claudeDir = Find-ClaudeApp
    $asarPath  = Join-Path $claudeDir 'resources\app.asar'
    $exePath   = Join-Path $claudeDir 'Claude.exe'
    $backupAsar = Join-Path $BACKUP_DIR 'app.asar'
    $backupVer  = Join-Path $BACKUP_DIR 'version.txt'

    $installedVer = (Get-Item $exePath -ErrorAction SilentlyContinue).VersionInfo.FileVersion

    Write-Host ""
    Write-Host "  Claude Desktop: $claudeDir" -ForegroundColor White
    Write-Host "  Installed version: $installedVer" -ForegroundColor White

    if (Test-Path $backupAsar) {
        $bv = Get-Content $backupVer -ErrorAction SilentlyContinue
        Write-Host "  Backup: $BACKUP_DIR (v$bv)" -ForegroundColor White

        $tmp = Join-Path $env:TEMP "claude_rtl_status_$([System.Diagnostics.Process]::GetCurrentProcess().Id)"
        npx --yes asar extract $asarPath $tmp 2>$null | Out-Null
        $preload = Join-Path $tmp '.vite\build\mainView.js'
        $patched = (Get-Content $preload -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($PATCH_MARKER)
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

        if ($patched) {
            Write-Host "  Patch status: ACTIVE" -ForegroundColor Green
            if ($installedVer -ne $bv) {
                Write-Host "  [!] App was updated (v$bv → v$installedVer) — re-apply recommended." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Patch status: NOT APPLIED" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No backup found — patch has not been installed." -ForegroundColor Yellow
    }
    Write-Host ""
}

# =============================================================================
# MENU
# =============================================================================
function Show-Menu {
    Write-Host ""
    Write-Host "Claude Desktop RTL Patch — Windows" -ForegroundColor Cyan
    Write-Host "Correct Persian / Arabic / Hebrew support (CSS-first, unicode-bidi: plaintext)"
    Write-Host ""
    if ($DryRun) { Write-Host "  [dry-run mode] No changes will be written." -ForegroundColor Yellow; Write-Host "" }
    Write-Host "  1) Install / re-apply patch"
    Write-Host "  2) Restore stock Claude Desktop"
    Write-Host "  3) Status"
    Write-Host "  4) Exit"
    Write-Host ""
    $choice = Read-Host "  Choice [1-4]"
    switch ($choice) {
        '1' { Invoke-Install }
        '2' { Invoke-Restore }
        '3' { Invoke-Status }
        '4' { Write-Host "Bye."; exit 0 }
        default { Write-Host "Invalid choice."; exit 1 }
    }
}

# ── Entry ─────────────────────────────────────────────────────────────────────
switch ($Command) {
    'install' { Invoke-Install }
    'restore' { Invoke-Restore }
    'status'  { Invoke-Status }
    'menu'    { Show-Menu }
}
