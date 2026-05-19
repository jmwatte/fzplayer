# fzmp - Preview.ps1
# Standalone script invoked by fzf --preview to show album art or file tags
# Usage: pwsh -NoProfile -File Preview.ps1 -Path <file_or_folder> -Mode <art|tags|embedded> -ConfigPath <path>

param(
    [Parameter(Mandatory)]
    [string]$Path,

    [ValidateSet("art", "tags", "embedded")]
    [string]$Mode = "art",

    [string]$ConfigPath = ""
)

# Close any dangling sixel DCS immediately.
# This must run before any other output or heavy work when fzf rapidly kills/restarts previews.
[Console]::Out.Write("$([char]0x1B)\")

# Resolve full path from env var if Path is relative
$basePath = $env:FZMP_PREVIEW_BASE
if ($Path -eq "..") {
    Write-Output "  (parent folder)"
    exit 0
}
if ($basePath -and -not [System.IO.Path]::IsPathRooted($Path)) {
    $Path = Join-Path $basePath $Path
}

# Load config
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $scriptDir "Config.ps1")

if ($ConfigPath -and (Test-Path $ConfigPath)) {
    $config = & $ConfigPath
    foreach ($key in ([hashtable]$script:DefaultConfig).Keys) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = $script:DefaultConfig[$key]
        }
    }
}
else {
    $config = Get-FzmpConfig
}

$chafaExe   = $config.ChafaPath
$ffprobeExe = $config.FfprobePath
$ffmpegExe  = $config.FfmpegPath
$artNames   = $config.ArtFilenames

# Resolve path - if it's a directory, find first audio file for tags, use folder for art
$targetPath = $Path
$targetDir  = $null

if (Test-Path $Path -PathType Container) {
    $targetDir = $Path
    # For tags mode on a folder, find first audio file
    $extensions = $config.AudioExtensions
    $firstFile = Get-ChildItem -Path $Path -File | Where-Object {
        $_.Extension -replace '^\.' -in $extensions
    } | Select-Object -First 1
    if ($firstFile) {
        $targetPath = $firstFile.FullName
    }
    else {
        if ($Mode -eq "tags") {
            Write-Output "No audio files in this folder"
            exit 0
        }
    }
}
else {
    $targetDir = Split-Path -Parent $Path
}

function Show-AlbumArt {
    param([string]$Directory)

    $cols = $env:FZF_PREVIEW_COLUMNS
    $rows = $env:FZF_PREVIEW_LINES
    $c = if ($cols) { [int]$cols } else { 60 }
    $r = if ($rows) { [int]$rows } else { 17 }
    $size = "${c}x${r}"

    # Search for art files directly in this folder
    $artFile = $null
    foreach ($name in $artNames) {
        $candidate = Join-Path $Directory $name
        if (Test-Path $candidate) {
            $artFile = $candidate
            break
        }
    }

    if ($artFile) {
        # Single album art
        & $chafaExe -f sixel --size $size $artFile
        Write-Host ""
        return
    }

    # No direct art — check subfolders (artist folder with album subdirs)
    $subArt = @()
    $subDirs = Get-ChildItem -Path $Directory -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($sub in $subDirs) {
        foreach ($name in $artNames) {
            $candidate = Join-Path $sub.FullName $name
            if (Test-Path $candidate) {
                $subArt += $candidate
                break
            }
        }
    }

    if ($subArt.Count -eq 1) {
        # Single album in subfolder — render directly
        & $chafaExe -f sixel --size $size $subArt[0]
        Write-Host ""
        return
    }

    if ($subArt.Count -gt 1) {
        # Multiple albums — create a SQUARE montage via ffmpeg
        $tempDir = Join-Path $env:TEMP "fzmp"
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
        $dirHash = (Split-Path -Leaf $Directory).GetHashCode()
        $montageFile = Join-Path $tempDir "montage_${dirHash}.jpg"

        if (-not (Test-Path $montageFile)) {
            $count = [math]::Min($subArt.Count, 12)
            $limitedArt = $subArt | Select-Object -First $count
            
            if ($count -le 4) { $gridCols = 2 }
            elseif ($count -le 9) { $gridCols = 3 }
            else { $gridCols = 4 }
            $gridRowCount = $gridCols

            $thumbPx = 200

            # Build ffmpeg filter
            $inputs = @()
            $filterParts = @()
            for ($i = 0; $i -lt $limitedArt.Count; $i++) {
                $inputs += "-i"
                $inputs += "`"$($limitedArt[$i])`""
                $filterParts += "[$i]scale=${thumbPx}:${thumbPx}:force_original_aspect_ratio=decrease,pad=${thumbPx}:${thumbPx}:(ow-iw)/2:(oh-ih)/2[t$i]"
            }

            # Pad incomplete last row with black
            $gridRowCount = [math]::Ceiling($count / $gridCols)
            $totalCells = $gridCols * $gridRowCount
            for ($i = $count; $i -lt $totalCells; $i++) {
                $filterParts += "color=black:s=${thumbPx}x${thumbPx}:d=1[t$i]"
            }

            # hstack each row, then vstack all rows
            $rowLabels = @()
            for ($row = 0; $row -lt $gridRowCount; $row++) {
                $cells = @()
                for ($col = 0; $col -lt $gridCols; $col++) {
                    $cells += "[t$($row * $gridCols + $col)]"
                }
                if ($gridCols -gt 1) {
                    $filterParts += "$($cells -join '')hstack=inputs=${gridCols}[row$row]"
                } else {
                    $filterParts += "$($cells[0])copy[row$row]"
                }
                $rowLabels += "[row$row]"
            }

            if ($gridRowCount -gt 1) {
                $filterParts += "$($rowLabels -join '')vstack=inputs=${gridRowCount}"
            } else {
                $filterParts[$filterParts.Count - 1] = $filterParts[$filterParts.Count - 1] -replace '\[row0\]$', ''
            }

            $filter = $filterParts -join ';'
            $ffmpegArgs = "-y $($inputs -join ' ') -filter_complex `"$filter`" `"$montageFile`""

            # Use Start-Process to fully isolate ffmpeg I/O from the sixel stream
            Start-Process -FilePath $ffmpegExe -ArgumentList $ffmpegArgs `
                -NoNewWindow -Wait `
                -RedirectStandardOutput (Join-Path $tempDir "ffmpeg_out.txt") `
                -RedirectStandardError (Join-Path $tempDir "ffmpeg_err.txt") | Out-Null
        }

        if ((Test-Path $montageFile) -and (Get-Item $montageFile).Length -gt 0) {
            & $chafaExe -f sixel --size $size $montageFile
            Write-Host ""
        } else {
            # Fallback: show first cover
            & $chafaExe -f sixel --size $size $subArt[0]
            Write-Host ""
        }
        return
    }

    Write-Output ""
    Write-Output "  No album art found in folder"
    Write-Output ""
    Write-Output "  Looked for: $($artNames -join ', ')"
    Write-Output "  Press Ctrl-E to check embedded art"
}

function Show-EmbeddedArt {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Output "  No file selected for embedded art"
        return
    }

    $tempDir = Join-Path $env:TEMP "fzmp"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    $tempFile = Join-Path $tempDir "cover_$(Get-Random).jpg"

    try {
        # Extract embedded cover art via ffmpeg
        Start-Process -FilePath $ffmpegExe -ArgumentList @(
            "-i", "`"$FilePath`"",
            "-an", "-vcodec", "copy",
            "-y", "`"$tempFile`""
        ) -NoNewWindow -Wait -RedirectStandardError (Join-Path $tempDir "ffmpeg_err.txt") | Out-Null

        if ((Test-Path $tempFile) -and (Get-Item $tempFile).Length -gt 0) {
            $cols = $env:FZF_PREVIEW_COLUMNS
            $lines = $env:FZF_PREVIEW_LINES
            $size = if ($cols -and $lines) { "${cols}x${lines}" } else { "60x17" }
            & $chafaExe -f sixel --size $size $tempFile
            Write-Host ""
        }
        else {
            Write-Output ""
            Write-Output "  No embedded cover art found in this file"
        }
    }
    catch {
        Write-Output "  Error extracting embedded art: $_"
    }
    finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Show-Tags {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Output "  No audio file to show tags for"
        return
    }

    try {
        $jsonOutput = & $ffprobeExe -v quiet -print_format json -show_format -show_streams $FilePath 2>$null
        $data = $jsonOutput | ConvertFrom-Json

        $format = $data.format
        $tags = $format.tags

        # Build display
        $lines = @()
        $lines += ""

        if ($tags) {
            $tagMap = @{}
            # Normalize tag keys to lowercase for case-insensitive lookup
            foreach ($prop in $tags.PSObject.Properties) {
                $tagMap[$prop.Name.ToLower()] = $prop.Value
            }

            $displayFields = @(
                @{ Label = "  Title";   Key = "title" }
                @{ Label = "  Artist";  Key = "artist" }
                @{ Label = "  Album";   Key = "album" }
                @{ Label = "  Year";    Key = "date" }
                @{ Label = "  Genre";   Key = "genre" }
                @{ Label = "  Track";   Key = "track" }
            )

            foreach ($field in $displayFields) {
                $val = $tagMap[$field.Key]
                if ($val) {
                    $lines += "{0,-12} {1}" -f "$($field.Label):", $val
                }
            }
        }

        $lines += ""

        # Technical info
        if ($format.duration) {
            $dur = [TimeSpan]::FromSeconds([math]::Floor([double]$format.duration))
            $lines += "  Duration:  {0}:{1:D2}" -f [int]$dur.TotalMinutes, $dur.Seconds
        }
        if ($format.bit_rate) {
            $kbps = [math]::Round([long]$format.bit_rate / 1000)
            $lines += "  Bitrate:   ${kbps} kbps"
        }
        if ($format.format_long_name) {
            $lines += "  Format:    $($format.format_long_name)"
        }
        if ($format.size) {
            $mb = [math]::Round([long]$format.size / 1MB, 1)
            $lines += "  Size:      ${mb} MB"
        }

        # Stream info (sample rate, channels)
        $audioStream = $data.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1
        if ($audioStream) {
            if ($audioStream.sample_rate) {
                $khz = [math]::Round([int]$audioStream.sample_rate / 1000, 1)
                $lines += "  Sample:    ${khz} kHz"
            }
            if ($audioStream.channels) {
                $ch = switch ([int]$audioStream.channels) {
                    1 { "Mono" }
                    2 { "Stereo" }
                    default { "$($audioStream.channels) channels" }
                }
                $lines += "  Channels:  $ch"
            }
            if ($audioStream.bits_per_raw_sample) {
                $lines += "  Bit depth: $($audioStream.bits_per_raw_sample) bit"
            }
        }

        $lines += ""
        $lines += "  File: $(Split-Path -Leaf $FilePath)"

        $lines | ForEach-Object { Write-Output $_ }
    }
    catch {
        Write-Output "  Error reading tags: $_"
    }
}

# Main dispatch
switch ($Mode) {
    "art"      { Show-AlbumArt -Directory $targetDir }
    "tags"     { Show-Tags -FilePath $targetPath }
    "embedded" { Show-EmbeddedArt -FilePath $targetPath }
}
