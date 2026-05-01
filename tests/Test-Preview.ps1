# fzmp - Test-Preview.ps1
# Test fixture to validate preview functionality before making changes.
# Run: pwsh -NoProfile -File tests\Test-Preview.ps1

param(
    [string]$MusicRoot = "H:\music",
    [string]$TestArtist = "10cc",
    [string]$TestAlbum = "2007 - Sheet Music",
    [string]$TestTrack = "01 - The Wall Street Shuffle.mp3"
)

$ErrorActionPreference = "Stop"
$script:passed = 0
$script:failed = 0
$script:skipped = 0

$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"
$previewScript = Join-Path $libDir "Preview.ps1"
$configScript = Join-Path $libDir "Config.ps1"

# Load config for tool paths
. $configScript
$config = Get-FzmpConfig

$artistDir  = Join-Path $MusicRoot $TestArtist
$albumDir   = Join-Path $artistDir $TestAlbum
$trackFile  = Join-Path $albumDir $TestTrack

function Write-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail = "")
    if ($Pass) {
        $script:passed++
        Write-Host "  PASS  " -ForegroundColor Green -NoNewline
    } else {
        $script:failed++
        Write-Host "  FAIL  " -ForegroundColor Red -NoNewline
    }
    Write-Host $Name -NoNewline
    if ($Detail) { Write-Host " ($Detail)" -ForegroundColor DarkGray } else { Write-Host }
}

function Write-Skip {
    param([string]$Name, [string]$Reason)
    $script:skipped++
    Write-Host "  SKIP  " -ForegroundColor Yellow -NoNewline
    Write-Host "$Name ($Reason)"
}

# ── Section 1: Tool availability ──
Write-Host "`n=== Tool Availability ===" -ForegroundColor Cyan

$chafaExe = $config.ChafaPath
$ffprobeExe = $config.FfprobePath
$ffmpegExe = $config.FfmpegPath
$fdExe = $config.FdPath
$fzfExe = $config.FzfPath

foreach ($tool in @(
    @{ Name = "chafa";   Path = $chafaExe }
    @{ Name = "ffprobe"; Path = $ffprobeExe }
    @{ Name = "ffmpeg";  Path = $ffmpegExe }
    @{ Name = "fd";      Path = $fdExe }
    @{ Name = "fzf";     Path = $fzfExe }
)) {
    $cmd = Get-Command $tool.Path -ErrorAction SilentlyContinue
    Write-Result "$($tool.Name) found" ($null -ne $cmd) $(if ($cmd) { $cmd.Source } else { "not in PATH" })
}

# ── Section 2: Test data existence ──
Write-Host "`n=== Test Data ===" -ForegroundColor Cyan

Write-Result "Artist dir exists" (Test-Path $artistDir) $artistDir
Write-Result "Album dir exists"  (Test-Path $albumDir) $albumDir
Write-Result "Track file exists" (Test-Path $trackFile) $trackFile

# Find art file in album dir
$artFile = $null
foreach ($name in $config.ArtFilenames) {
    $candidate = Join-Path $albumDir $name
    if (Test-Path $candidate) { $artFile = $candidate; break }
}
Write-Result "Album art file found" ($null -ne $artFile) $(if ($artFile) { Split-Path -Leaf $artFile } else { "none" })

# ── Section 3: Chafa rendering ──
Write-Host "`n=== Chafa Rendering ===" -ForegroundColor Cyan

if ($artFile) {
    # Test sixel output produces data
    $sixelOut = & $chafaExe -f sixel --size 20x10 $artFile 2>&1
    $hasSixel = $sixelOut -and ($sixelOut | Out-String).Length -gt 50
    Write-Result "chafa -f sixel produces output" $hasSixel "output length: $(($sixelOut | Out-String).Length)"

    # Test that sixel starts with ESC sequence
    $rawStr = $sixelOut | Out-String
    $startsEsc = $rawStr.Length -gt 0 -and ($rawStr[0] -eq [char]0x1B -or $rawStr.Contains([char]0x1B))
    Write-Result "sixel output contains ESC sequences" $startsEsc
} else {
    Write-Skip "chafa sixel test" "no art file"
    Write-Skip "sixel ESC test" "no art file"
}

# ── Section 4: Preview script direct invocation ──
Write-Host "`n=== Preview Script (direct) ===" -ForegroundColor Cyan

# Art mode with absolute path
$env:FZF_PREVIEW_COLUMNS = "40"
$env:FZF_PREVIEW_LINES = "12"
$env:FZMP_PREVIEW_BASE = ""

try {
    $out = & pwsh -NoProfile -File $previewScript -Path $albumDir -Mode art 2>&1 | Out-String
    $hasOutput = $out.Length -gt 50
    Write-Result "Preview art mode (absolute path)" $hasOutput "output: $($out.Length) chars"
} catch {
    Write-Result "Preview art mode (absolute path)" $false $_.Exception.Message
}

# Art mode with relative path + FZMP_PREVIEW_BASE
$env:FZMP_PREVIEW_BASE = $artistDir
try {
    $out = & pwsh -NoProfile -File $previewScript -Path $TestAlbum -Mode art 2>&1 | Out-String
    $hasOutput = $out.Length -gt 50
    Write-Result "Preview art mode (relative path via FZMP_PREVIEW_BASE)" $hasOutput "output: $($out.Length) chars"
} catch {
    Write-Result "Preview art mode (relative path)" $false $_.Exception.Message
}

# Tags mode
$env:FZMP_PREVIEW_BASE = $albumDir
try {
    $out = & pwsh -NoProfile -File $previewScript -Path $TestTrack -Mode tags 2>&1 | Out-String
    $hasTags = $out -match '(Title|Artist|Album|Duration)'
    Write-Result "Preview tags mode" $hasTags "contains tag info"
} catch {
    Write-Result "Preview tags mode" $false $_.Exception.Message
}

# Embedded art mode
try {
    $out = & pwsh -NoProfile -File $previewScript -Path $TestTrack -Mode embedded 2>&1 | Out-String
    # Either produces art or says "No embedded cover art"
    $validOutput = $out.Length -gt 10
    Write-Result "Preview embedded mode runs" $validOutput
} catch {
    Write-Result "Preview embedded mode" $false $_.Exception.Message
}

# ── Section 5: Preview via cmd.exe (simulates fzf) ──
Write-Host "`n=== Preview via cmd.exe (fzf simulation) ===" -ForegroundColor Cyan

$env:FZMP_PREVIEW_BASE = $artistDir
$env:FZF_PREVIEW_COLUMNS = "40"
$env:FZF_PREVIEW_LINES = "12"

try {
    $out = cmd /c "pwsh -NoProfile -File `"$previewScript`" -Path `"$TestAlbum`" -Mode art" 2>&1 | Out-String
    $hasOutput = $out.Length -gt 50
    Write-Result "cmd.exe preview art (relative path)" $hasOutput "output: $($out.Length) chars"
} catch {
    Write-Result "cmd.exe preview art" $false $_.Exception.Message
}

$env:FZMP_PREVIEW_BASE = $albumDir
try {
    $out = cmd /c "pwsh -NoProfile -File `"$previewScript`" -Path `"$TestTrack`" -Mode tags" 2>&1 | Out-String
    $hasTags = $out -match '(Title|Artist|Album|Duration)'
    Write-Result "cmd.exe preview tags" $hasTags
} catch {
    Write-Result "cmd.exe preview tags" $false $_.Exception.Message
}

# ── Section 6: fzf preview window live test ──
Write-Host "`n=== fzf Preview Window (sixel render) ===" -ForegroundColor Cyan

if ($artFile) {
    $env:FZMP_PREVIEW_BASE = $artistDir
    try {
        # Use --select-1 --exit-0 with a single item to auto-accept
        $fzfOut = $TestAlbum | & $fzfExe --preview "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode art" --preview-window "up,50%" --select-1 --exit-0 2>&1
        Write-Result "fzf with preview runs without error" ($LASTEXITCODE -eq 0 -or $null -ne $fzfOut) "exit: $LASTEXITCODE"
    } catch {
        Write-Result "fzf with preview" $false $_.Exception.Message
    }
} else {
    Write-Skip "fzf preview window test" "no art file"
}

# ── Section 7: fd output format ──
Write-Host "`n=== fd Output Format ===" -ForegroundColor Cyan

$fdOut = & $fdExe --type d --max-depth 1 --base-directory $artistDir 2>$null
if ($fdOut) {
    $firstItem = ($fdOut | Select-Object -First 1)
    $hasSep = $firstItem.EndsWith('\') -or $firstItem.EndsWith('/')
    Write-Result "fd dir output has trailing separator" $hasSep "raw: '$firstItem'"
    $trimmed = $firstItem.TrimEnd('\', '/')
    Write-Result "TrimEnd removes separator" (-not ($trimmed.EndsWith('\') -or $trimmed.EndsWith('/'))) "trimmed: '$trimmed'"
} else {
    Write-Skip "fd output format" "no fd output"
}

# ── Summary ──
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed:  $script:passed" -ForegroundColor Green
Write-Host "  Failed:  $script:failed" -ForegroundColor $(if ($script:failed -gt 0) { "Red" } else { "Green" })
Write-Host "  Skipped: $script:skipped" -ForegroundColor Yellow
Write-Host

# Clean up env vars
Remove-Item Env:\FZMP_PREVIEW_BASE -ErrorAction SilentlyContinue
Remove-Item Env:\FZF_PREVIEW_COLUMNS -ErrorAction SilentlyContinue
Remove-Item Env:\FZF_PREVIEW_LINES -ErrorAction SilentlyContinue

exit $script:failed
