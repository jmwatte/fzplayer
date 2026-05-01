# Test-Sixel.ps1 — Run in Windows Terminal to diagnose sixel preview issues
# Usage: pwsh -NoProfile -File tests\Test-Sixel.ps1

$searchDir = "H:\music\"
$previewScript = Join-Path $PSScriptRoot "..\lib\Preview.ps1"

# Find an artist folder with multiple album covers
$artistDir = $null
$artFiles = @()
foreach ($d in (Get-ChildItem $searchDir -Directory | Select-Object -First 30)) {
    $found = @()
    foreach ($sub in (Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue)) {
        foreach ($name in @("cover.jpg","folder.jpg","front.jpg","cover.png","folder.png")) {
            $p = Join-Path $sub.FullName $name
            if (Test-Path $p) { $found += $p; break }
        }
    }
    if ($found.Count -ge 3) { $artistDir = $d.FullName; $artFiles = $found; break }
}

# Find a folder with apostrophe
$apostropheDir = Get-ChildItem $searchDir -Directory -Recurse -Depth 2 |
    Where-Object { $_.Name -match "'" } | Select-Object -First 1
#$apostropheDir = Get-ChildItem "H:\music\Monolake\" | where { $_.Name -match "\(" } | Select-Object -First 1
Write-Host "Artist dir:     $artistDir ($($artFiles.Count) album covers)" -ForegroundColor Cyan
Write-Host "Apostrophe dir: $($apostropheDir.FullName)" -ForegroundColor Cyan
Write-Host "Press ESC to advance each test`n"

# ── Test 1: chafa --grid auto with multiple images (direct, no fzf) ──
Write-Host "=== Test 1: chafa --grid auto direct (no fzf) ===" -ForegroundColor Yellow
if ($artFiles.Count -ge 2) {
    $testFiles = $artFiles | Select-Object -First 4
    chafa -f sixel --size 60x17 --grid auto @testFiles
    Write-Host ""
    Read-Host "Did you see multiple images in a grid?"
} else { Write-Host "SKIP: not enough art files" }

# ── Test 2: chafa multiple sequential (direct, no fzf) ──
Write-Host "`n=== Test 2: chafa sequential (no fzf) ===" -ForegroundColor Yellow
if ($artFiles.Count -ge 2) {
    foreach ($f in ($artFiles | Select-Object -First 4)) {
        chafa -f sixel --size 15x5 $f
        Write-Host ""
    }
    Read-Host "Did you see multiple images stacked?"
} else { Write-Host "SKIP: not enough art files" }

# ── Test 3: --height 99% + --with-shell pwsh + apostrophe folder ──
Write-Host "`n=== Test 3: --with-shell pwsh + apostrophe name ===" -ForegroundColor Yellow
if ($apostropheDir) {
    $env:FZMP_PREVIEW_BASE = ""
    $apoName = $apostropheDir.Name
    Write-Output $apoName | fzf --height 99% --with-shell "pwsh -NoProfile -Command" `
        --preview "& '$previewScript' -Path '$($apostropheDir.FullName)' -Mode art" `
        --preview-window "up,50%"
} else { Write-Host "SKIP: no apostrophe folder found" }

# ── Test 4: --height 99% + NO --with-shell (cmd.exe) + apostrophe folder ──
Write-Host "`n=== Test 4: NO --with-shell (cmd.exe) + apostrophe name ===" -ForegroundColor Yellow
if ($apostropheDir) {
    $env:FZMP_PREVIEW_BASE = ""
    $apoName = $apostropheDir.Name
    Write-Output $apoName | fzf --height 99% `
        --preview "pwsh -NoProfile -File `"$previewScript`" -Path `"$($apostropheDir.FullName)`" -Mode art" `
    --preview-window "up,50%"
} else { Write-Host "SKIP: no apostrophe folder found" }

# ── Test 5: --height 99% + NO --with-shell + artist grid ──
Write-Host "`n=== Test 5: NO --with-shell + artist grid ===" -ForegroundColor Yellow
if ($artistDir) {
    $env:FZMP_PREVIEW_BASE = ""
    $artistName = Split-Path -Leaf $artistDir
    Write-Output $artistName | fzf --height 99% `
        --preview "pwsh -NoProfile -File `"$previewScript`" -Path `"$artistDir`" -Mode art" `
        --preview-window "up,50%"
} else { Write-Host "SKIP: no multi-album artist found" }

# ── Test 6: --height 99% + --with-shell pwsh + artist grid ──
Write-Host "`n=== Test 6: --with-shell pwsh + artist grid ===" -ForegroundColor Yellow
if ($artistDir) {
    $env:FZMP_PREVIEW_BASE = ""
    Write-Output "test" | fzf --height 99% --with-shell "pwsh -NoProfile -Command" `
        --preview "& '$previewScript' -Path '$artistDir' -Mode art" `
        --preview-window "up,50%"
} else { Write-Host "SKIP: no multi-album artist found" }

Write-Host "`nResults: which tests showed images?" -ForegroundColor Cyan
Write-Host "  1: chafa grid direct    2: chafa sequential direct"
Write-Host "  3: with-shell+apostrophe  4: cmd.exe+apostrophe"
Write-Host "  5: cmd.exe+grid    6: with-shell+grid"
