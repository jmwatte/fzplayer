# fzmp - MetaBrowser.ps1
# Metadata browsing and cache management (genre/artist/album/year)

function Get-FzmpMetadataCachePath {
    param([hashtable]$Config)

    if ($Config.MetadataCachePath) {
        return $Config.MetadataCachePath
    }
    return (Join-Path (Join-Path $env:APPDATA "fzmp") "metadata-cache.csv")
}

function Get-FzmpTagValue {
    param(
        [hashtable]$TagMap,
        [string]$Key,
        [string]$Fallback = ""
    )

    if (-not $TagMap) { return $Fallback }
    foreach ($k in $TagMap.Keys) {
        if ($k -eq $Key) {
            $v = $TagMap[$k]
            if ($null -ne $v -and "$v".Trim()) {
                return "$v".Trim()
            }
            break
        }
    }
    return $Fallback
}

function Normalize-FzmpYear {
    param(
        [string]$YearValue,
        [string]$UnknownLabel
    )

    if (-not $YearValue) { return $UnknownLabel }
    if ($YearValue -match '(\d{4})') {
        return $Matches[1]
    }
    return $UnknownLabel
}

# In-process cache to avoid reparsing large metadata CSV on every Ctrl-G.
$script:FzmpMetadataMemo = @{
    Path = ""
    LastWriteUtc = [datetime]::MinValue
    Records = @()
}

$script:FzmpMetadataWarmup = @{
    Worker = $null
    Handle = $null
    Path = ""
    LastWriteUtc = [datetime]::MinValue
}

function Convert-FzmpMetadataRows {
    param(
        [array]$Rows,
        [string]$UnknownLabel
    )

    if (-not $Rows -or $Rows.Count -eq 0) { return @() }

    $cols = $Rows[0].PSObject.Properties.Name
    if ((-not ($cols -contains "Name")) -and (-not ($cols -contains "Filename"))) {
        return @($Rows)
    }

    # Everything export format — normalize to Path/Genre/Artist/Album/Year/Title.
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        $dir = $row.Path
        $name = $row.Name
        $filename = $row.Filename

        if ($filename -and $filename.Trim()) {
            $fullPath = $filename.Trim()
            if ((-not $name) -or (-not $name.Trim())) {
                $name = Split-Path -Leaf $fullPath
            }
            if ((-not $dir) -or (-not $dir.Trim())) {
                $dir = Split-Path -Parent $fullPath
            }
        }
        else {
            $fullPath = if ($dir -and $name) { Join-Path $dir $name } else { "" }
        }

        if (-not $fullPath) { continue }

        $artist = if ($row.'Artist' -and $row.'Artist'.Trim()) { $row.'Artist'.Trim() }
                  elseif ($row.'Album Artist' -and $row.'Album Artist'.Trim()) { $row.'Album Artist'.Trim() }
                  else { $UnknownLabel }

        $album = if ($row.Album -and $row.Album.Trim()) { $row.Album.Trim() }
                 else { Split-Path -Leaf $dir }

        $genre = if ($row.Genre -and $row.Genre.Trim()) { $row.Genre.Trim() } else { $UnknownLabel }
        $year = if ($row.Year -and $row.Year.Trim()) { $row.Year.Trim() } else { $UnknownLabel }
        $title = if ($row.Title -and $row.Title.Trim()) { $row.Title.Trim() }
                 elseif ($name) { [System.IO.Path]::GetFileNameWithoutExtension($name) }
                 else { $UnknownLabel }

        $out.Add([pscustomobject]@{
            Path = $fullPath
            Genre = $genre
            Artist = $artist
            Album = $album
            Year = $year
            Title = $title
        }) | Out-Null
    }

    return @($out)
}

function Start-FzmpMetadataWarmup {
    param([hashtable]$Config)

    $cachePath = Get-FzmpMetadataCachePath -Config $Config
    $item = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
    if (-not $item) { return }

    if ($script:FzmpMetadataMemo.Path -eq $cachePath -and
        $script:FzmpMetadataMemo.LastWriteUtc -eq $item.LastWriteTimeUtc -and
        $script:FzmpMetadataMemo.Records -and $script:FzmpMetadataMemo.Records.Count -gt 0) {
        return
    }

    if ($script:FzmpMetadataWarmup.Handle -and -not $script:FzmpMetadataWarmup.Handle.IsCompleted) {
        return
    }

    if ($script:FzmpMetadataWarmup.Worker) {
        try { $script:FzmpMetadataWarmup.Worker.Dispose() } catch {}
        $script:FzmpMetadataWarmup.Worker = $null
        $script:FzmpMetadataWarmup.Handle = $null
    }

    $unknown = if ($Config.MetadataUnknownLabel) { $Config.MetadataUnknownLabel } else { "Unknown" }

    $worker = [powershell]::Create()
    $scriptBlock = {
        param($Path, $UnknownLabel)

        $rows = @(Import-Csv -Path $Path -Encoding UTF8)
        if (-not $rows -or $rows.Count -eq 0) { return @() }

        $cols = $rows[0].PSObject.Properties.Name
        if ((-not ($cols -contains "Name")) -and (-not ($cols -contains "Filename"))) {
            return @($rows)
        }

        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            $dir = $row.Path
            $name = $row.Name
            $filename = $row.Filename

            if ($filename -and $filename.Trim()) {
                $fullPath = $filename.Trim()
                if ((-not $name) -or (-not $name.Trim())) { $name = Split-Path -Leaf $fullPath }
                if ((-not $dir) -or (-not $dir.Trim())) { $dir = Split-Path -Parent $fullPath }
            }
            else {
                $fullPath = if ($dir -and $name) { Join-Path $dir $name } else { "" }
            }
            if (-not $fullPath) { continue }

            $artist = if ($row.'Artist' -and $row.'Artist'.Trim()) { $row.'Artist'.Trim() }
                      elseif ($row.'Album Artist' -and $row.'Album Artist'.Trim()) { $row.'Album Artist'.Trim() }
                      else { $UnknownLabel }
            $album = if ($row.Album -and $row.Album.Trim()) { $row.Album.Trim() } else { Split-Path -Leaf $dir }
            $genre = if ($row.Genre -and $row.Genre.Trim()) { $row.Genre.Trim() } else { $UnknownLabel }
            $year = if ($row.Year -and $row.Year.Trim()) { $row.Year.Trim() } else { $UnknownLabel }
            $title = if ($row.Title -and $row.Title.Trim()) { $row.Title.Trim() }
                     elseif ($name) { [System.IO.Path]::GetFileNameWithoutExtension($name) }
                     else { $UnknownLabel }

            $out.Add([pscustomobject]@{
                Path = $fullPath
                Genre = $genre
                Artist = $artist
                Album = $album
                Year = $year
                Title = $title
            }) | Out-Null
        }

        return @($out)
    }

    $null = $worker.AddScript($scriptBlock).AddArgument($cachePath).AddArgument($unknown)
    $handle = $worker.BeginInvoke()

    $script:FzmpMetadataWarmup.Worker = $worker
    $script:FzmpMetadataWarmup.Handle = $handle
    $script:FzmpMetadataWarmup.Path = $cachePath
    $script:FzmpMetadataWarmup.LastWriteUtc = $item.LastWriteTimeUtc
}

function Complete-FzmpMetadataWarmup {
    param([hashtable]$Config)

    if (-not $script:FzmpMetadataWarmup.Handle -or -not $script:FzmpMetadataWarmup.Worker) {
        return
    }
    if (-not $script:FzmpMetadataWarmup.Handle.IsCompleted) {
        return
    }

    try {
        $result = @($script:FzmpMetadataWarmup.Worker.EndInvoke($script:FzmpMetadataWarmup.Handle))

        $script:FzmpMetadataMemo.Path = $script:FzmpMetadataWarmup.Path
        $script:FzmpMetadataMemo.LastWriteUtc = $script:FzmpMetadataWarmup.LastWriteUtc
        $script:FzmpMetadataMemo.Records = $result
    }
    catch {
        # Ignore warm-up failures; synchronous load path remains available.
    }
    finally {
        try { $script:FzmpMetadataWarmup.Worker.Dispose() } catch {}
        $script:FzmpMetadataWarmup.Worker = $null
        $script:FzmpMetadataWarmup.Handle = $null
        $script:FzmpMetadataWarmup.Path = ""
        $script:FzmpMetadataWarmup.LastWriteUtc = [datetime]::MinValue
    }
}

function Get-FzmpMetadataRecords {
    param([hashtable]$Config)

    $cachePath = Get-FzmpMetadataCachePath -Config $Config
    if (-not (Test-Path $cachePath)) {
        return @()
    }

    Complete-FzmpMetadataWarmup -Config $Config

    $unknown = if ($Config.MetadataUnknownLabel) { $Config.MetadataUnknownLabel } else { "Unknown" }

    $item = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
    if ($item -and
        $script:FzmpMetadataMemo.Path -eq $cachePath -and
        $script:FzmpMetadataMemo.LastWriteUtc -eq $item.LastWriteTimeUtc -and
        $script:FzmpMetadataMemo.Records -and $script:FzmpMetadataMemo.Records.Count -gt 0) {
        return @($script:FzmpMetadataMemo.Records)
    }

    try {
        $rows = @(Import-Csv -Path $cachePath -Encoding UTF8)
        if (-not $rows) { return @() }

        $result = Convert-FzmpMetadataRows -Rows $rows -UnknownLabel $unknown
        if ($item) {
            $script:FzmpMetadataMemo.Path = $cachePath
            $script:FzmpMetadataMemo.LastWriteUtc = $item.LastWriteTimeUtc
            $script:FzmpMetadataMemo.Records = $result
        }
        return $result
    }
    catch {
        return @()
    }
}

function Update-FzmpMetadataCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [switch]$Force
    )

    $unknown = if ($Config.MetadataUnknownLabel) { $Config.MetadataUnknownLabel } else { "Unknown" }
    $cachePath = Get-FzmpMetadataCachePath -Config $Config
    $cacheDir = Split-Path -Parent $cachePath
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    if (-not (Test-Path $cachePath)) {
        Write-Host "Metadata cache not found: $cachePath" -ForegroundColor Yellow
        Write-Host "Please export your music library metadata from Everything:"
        Write-Host ""
        Write-Host "  1. Open Everything search window"
        Write-Host "  2. Search: audio:"
        Write-Host "  3. Menu > Export > CSV..."
        Write-Host "  4. Save to: $cachePath"
        Write-Host ""
        return $null
    }

    # Read Everything-exported CSV and map columns to our format
    $rawRows = @(Import-Csv -Path $cachePath -Encoding UTF8)
    if (-not $rawRows) {
        return $cachePath
    }

    $rows = @()
    foreach ($r in $rawRows) {
        $path = $r.Path
        if (-not $path) { continue }

        # Everything CSV may have quoted empty strings; normalize to Unknown
        $genre = if ($r.Genre -and $r.Genre.Trim()) { $r.Genre.Trim() } else { $unknown }
        $artist = if ($r.Artist -and $r.Artist.Trim()) { $r.Artist.Trim() } else { $r."Album Artist" }
        $artist = if ($artist -and $artist.Trim()) { $artist.Trim() } else { $unknown }
        $album = if ($r.Album -and $r.Album.Trim()) { $r.Album.Trim() } else { $unknown }
        $year = if ($r.Year -and $r.Year.Trim()) { $r.Year.Trim() } else { $unknown }
        $title = if ($r.Title -and $r.Title.Trim()) { $r.Title.Trim() } else { Split-Path -Leaf $path }

        $rows += [pscustomobject]@{
            Path = $path
            Genre = $genre
            Artist = $artist
            Album = $album
            Year = $year
            Title = $title
        }
    }

    # Write normalized cache
    $rows | Export-Csv -Path $cachePath -NoTypeInformation -Encoding UTF8
    return $cachePath
}

function Get-FzmpGroupCounts {
    param(
        [array]$Records,
        [string]$Field,
        [string]$UnknownLabel
    )

    $groups = @{}
    foreach ($r in $Records) {
        $v = "$($r.$Field)"
        if (-not $v.Trim()) { $v = $UnknownLabel }
        if (-not $groups.ContainsKey($v)) {
            $groups[$v] = 0
        }
        $groups[$v] += 1
    }

    $result = foreach ($k in $groups.Keys) {
        [pscustomobject]@{ Value = $k; Count = $groups[$k] }
    }
    return @($result | Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Value'; Descending = $false })
}

function Invoke-FzmpMetadataFzf {
    param(
        [string[]]$InputLines,
        [string]$Prompt,
        [string]$Header,
        [hashtable]$Config,
        [string]$Expect,
        [string]$PreviewCmd = "",
        [string]$PreviewPos = "up,50%"
    )

    if (-not $InputLines -or $InputLines.Count -eq 0) {
        return $null
    }

    $fzfArgs = @(
        "--height=99%"
        "--ansi"
        "--layout=reverse"
        "--header=$Header"
        "--header-first"
        "--prompt=$Prompt"
        "--expect=$Expect"
        "--delimiter=\t"
        "--with-nth=1"
    )

    if ($PreviewCmd) {
        $fzfArgs += "--preview=$PreviewCmd"
        $fzfArgs += "--preview-window=$PreviewPos"
    }
    else {
        $fzfArgs += "--no-preview"
    }

    $raw = ($InputLines -join "`n") | & $Config.FzfPath @fzfArgs
    if (-not $raw) { return $null }

    $parts = $raw -split "`n"
    $key = if ($parts.Count -gt 0) { $parts[0].Trim() } else { "" }
    $line = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    $cols = $line -split "`t"

    return [pscustomobject]@{
        Key = $key
        Display = if ($cols.Count -gt 0) { $cols[0] } else { "" }
        Value = if ($cols.Count -gt 1) { $cols[1] } else { "" }
        Extra = if ($cols.Count -gt 2) { $cols[2] } else { "" }
    }
}

# Get tracks via es.exe using tag filters (fast), falling back to cache filter.
# $filters is a hashtable like @{ Genre = "Jazz"; Artist = "Miles Davis" }
function Get-FzmpTracksForFilters {
    param(
        [hashtable]$Config,
        [hashtable]$Filters,
        [array]$AllRecords
    )

    $esPath = $Config.EsPath
    $esAvailable = $false
    if ($esPath) {
        if ([System.IO.Path]::IsPathRooted($esPath)) {
            $esAvailable = Test-Path $esPath
        } else {
            $esAvailable = [bool](Get-Command $esPath -ErrorAction SilentlyContinue)
        }
    }

    if ($esAvailable -and $Filters.Count -gt 0) {
        # Build Everything search query using tag filter syntax
        $queryParts = @()
        foreach ($key in $Filters.Keys) {
            $val = $Filters[$key]
            $esKey = $key.ToLower()   # genre, artist, album, year
            if ($esKey -eq "year") { $esKey = "year" }
            if ($val -ne $Config.MetadataUnknownLabel) {
                $queryParts += "${esKey}:`"$val`""
            }
        }
        $queryParts += "`"$($Config.MusicRoot)\`""
        $queryParts += "audio:"

        $esArgs = @("-p") + $queryParts
        $paths = & $esPath @esArgs 2>$null | Where-Object { $_ }
        if ($paths) {
            return @($paths | ForEach-Object { $_.Trim() })
        }
    }

    # Fallback: filter CSV records in memory
    $filtered = $AllRecords
    foreach ($key in $Filters.Keys) {
        $val = $Filters[$key]
        $filtered = @($filtered | Where-Object { "$($_.$key)" -eq $val })
    }
    return @($filtered | ForEach-Object { $_.Path })
}

# Show a single facet-value picker using cached records.
# Returns @{ Action; Value } or @{ Action = "back|quit|..." }
function Invoke-FzmpFacetPicker {
    param(
        [array]$Records,
        [string]$Field,
        [string]$Prompt,
        [string]$Header,
        [hashtable]$Config,
        [string]$UnknownLabel,
        [string]$PreviewScript = "",
        [string]$PreviewPos = "up,50%"
    )

    $values = Get-FzmpGroupCounts -Records $Records -Field $Field -UnknownLabel $UnknownLabel
    $previewCmd = ""
    $lines = @()

    if (($Field -eq "Album") -and $PreviewScript) {
        # Build album -> representative folder path map for album-art preview.
        $albumPreview = @{}
        foreach ($r in $Records) {
            $albumName = "$($r.Album)"
            if (-not $albumName.Trim()) { $albumName = $UnknownLabel }
            if (-not $albumPreview.ContainsKey($albumName)) {
                $dir = Split-Path -Parent $r.Path
                $albumPreview[$albumName] = if ($dir) { $dir } else { $Config.MusicRoot }
            }
        }

        foreach ($v in $values) {
            $p = if ($albumPreview.ContainsKey($v.Value)) { $albumPreview[$v.Value] } else { $Config.MusicRoot }
            $lines += "{0} ({1})`t{0}`t{2}" -f $v.Value, $v.Count, $p
        }

        # Third column carries preview directory path.
        $previewCmd = "pwsh -NoProfile -File `"$PreviewScript`" -Path {3} -Mode art"
    }
    else {
        foreach ($v in $values) {
            $lines += "{0} ({1})`t{0}" -f $v.Value, $v.Count
        }
    }

    $res = Invoke-FzmpMetadataFzf -InputLines $lines -Prompt $Prompt -Header $Header `
        -Config $Config -Expect "ctrl-g,ctrl-o,ctrl-q,ctrl-r,ctrl-s,ctrl-v,enter" `
        -PreviewCmd $previewCmd -PreviewPos $PreviewPos
    if (-not $res) { return @{ Action = "back" } }

    switch ($res.Key) {
        "ctrl-q" { return @{ Action = "quit" } }
        "ctrl-v" { return @{ Action = "queue-view" } }
        "ctrl-r" { return @{ Action = "set-recent" } }
        "ctrl-s" { return @{ Action = "search" } }
        "ctrl-o" {
            if ($res.Extra) { return @{ Action = "open-explorer"; Path = $res.Extra } }
            return @{ Action = "back" }
        }
        "ctrl-g" { return @{ Action = "back" } }   # Ctrl-G again = back to facet root
    }

    $val = $res.Value
    if (-not $val) { return @{ Action = "back" } }
    return @{ Action = "selected"; Value = $val }
}

function Show-MetadataBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$StatusMessage = ""
    )

    $unknown = if ($Config.MetadataUnknownLabel) { $Config.MetadataUnknownLabel } else { "Unknown" }
    $headerBase = Get-NowPlayingHeader -Config $Config
    $recentLabel = if ($Config.Recent) { " [Recent: $($Config.Recent)]" } else { "" }
    $previewScript = Join-Path $PSScriptRoot "Preview.ps1"
    $mpvActionScript = Join-Path $PSScriptRoot "MpvAction.ps1"
    $previewPos = if ($Config.PreviewPosition -eq "left") { "left,50%" } else { "up,50%" }
    $previewMode = $Config.PreviewMode

    $records = Get-FzmpMetadataRecords -Config $Config
    if (-not $records -or $records.Count -eq 0) {
        $items = @("Build metadata cache`tbuild", "Back`tback")
        $res = Invoke-FzmpMetadataFzf -InputLines $items -Prompt "Meta> " `
            -Header "$headerBase$recentLabel`n[Metadata] Cache not found$(if ($StatusMessage) { "`n$StatusMessage" })" `
            -Config $Config -Expect "ctrl-q,enter"
        if (-not $res) { return @{ Action = "back" } }
        if ($res.Key -eq "ctrl-q") { return @{ Action = "quit" } }
        if ($res.Value -eq "build") { return @{ Action = "build-meta-cache" } }
        return @{ Action = "back" }
    }

    # State for the drill path
    $stage      = 0   # 0=facet root, 1=facet value, 2=sub-facet value, 3=album, 4=tracks
    $rootFacet  = $null
    $rootValue  = $null
    $nextFacet  = $null
    $nextValue  = $null
    $albumValue = $null
    $narrowed   = $null
    $narrowed2  = $null

    while ($true) {
        switch ($stage) {

            # ── Stage 0: choose root facet ───────────────────────────────────
            0 {
                $facetItems = @(
                    "Genre`tGenre",
                    "Artist`tArtist",
                    "Album`tAlbum",
                    "Year`tYear",
                    "All Tracks`tTracks"
                )
                $hdr = "$headerBase$recentLabel`n[Metadata] Choose category  Ctrl-Q=Quit$(if ($StatusMessage) { "`n$StatusMessage" })"
                $res = Invoke-FzmpMetadataFzf -InputLines $facetItems -Prompt "Meta> " `
                    -Header $hdr -Config $Config -Expect "ctrl-g,ctrl-q,ctrl-r,ctrl-s,ctrl-v,enter"

                if (-not $res -or $res.Key -eq "ctrl-g") { return @{ Action = "back" } }
                switch ($res.Key) {
                    "ctrl-q" { return @{ Action = "quit" } }
                    "ctrl-v" { return @{ Action = "queue-view" } }
                    "ctrl-r" { return @{ Action = "set-recent" } }
                    "ctrl-s" { return @{ Action = "search" } }
                }
                $rootFacet = $res.Value
                if (-not $rootFacet) { return @{ Action = "back" } }

                if ($rootFacet -eq "Tracks") {
                    $trackPaths = @($records | ForEach-Object { $_.Path })
                    $trackHeader = "$headerBase$recentLabel`n[All Tracks: $($trackPaths.Count)]"
                    $r = Show-FzmpTrackList -TrackPaths $trackPaths -Header $trackHeader -Config $Config `
                        -PreviewScript $previewScript -MpvActionScript $mpvActionScript `
                        -PreviewMode $previewMode -PreviewPos $previewPos
                    if ($r.Action -eq "back") { continue }   # Esc from track list → back to stage 0
                    return $r
                }

                $nextFacet = switch ($rootFacet) {
                    "Genre"  { "Artist" }
                    "Artist" { "Album" }
                    "Year"   { "Artist" }
                    "Album"  { $null }
                    default  { $null }
                }
                $stage = 1
            }

            # ── Stage 1: choose value for root facet (e.g. "Jazz") ───────────
            1 {
                $hdr = "$headerBase$recentLabel`n[Metadata › $rootFacet]  Esc=Back"
                $res = Invoke-FzmpFacetPicker -Records $records -Field $rootFacet `
                    -Prompt "Meta: $rootFacet> " -Header $hdr -Config $Config -UnknownLabel $unknown `
                    -PreviewScript $previewScript -PreviewPos $previewPos

                if ($res.Action -eq "selected") {
                    $rootValue = $res.Value
                    $narrowed  = @($records | Where-Object { "$($_.$rootFacet)" -eq $rootValue })
                    # If no sub-facet, jump straight to tracks
                    $stage = if ($nextFacet) { 2 } else { 4 }
                } elseif ($res.Action -in "quit","queue-view","set-recent","search") {
                    return $res
                } else {
                    # Esc → back to stage 0
                    $stage = 0
                }
            }

            # ── Stage 2: choose sub-facet value (e.g. Artist under Genre) ────
            2 {
                $hdr = "$headerBase$recentLabel`n[Metadata › $rootFacet=$rootValue › $nextFacet]  Esc=Back"
                $res = Invoke-FzmpFacetPicker -Records $narrowed -Field $nextFacet `
                    -Prompt "Meta: $nextFacet> " -Header $hdr -Config $Config -UnknownLabel $unknown `
                    -PreviewScript $previewScript -PreviewPos $previewPos

                if ($res.Action -eq "selected") {
                    $nextValue = $res.Value
                    # Genre→Artist→Album needs a third level; others go to tracks
                    if ($rootFacet -eq "Genre" -and $nextFacet -eq "Artist") {
                        $narrowed2 = @($narrowed | Where-Object { "$($_.Artist)" -eq $nextValue })
                        $stage = 3
                    } else {
                        $stage = 4
                    }
                } elseif ($res.Action -in "quit","queue-view","set-recent","search") {
                    return $res
                } else {
                    # Esc → back to stage 1
                    $stage = 1
                }
            }

            # ── Stage 3: choose Album (Genre→Artist→Album path only) ─────────
            3 {
                $hdr = "$headerBase$recentLabel`n[Metadata › $rootFacet=$rootValue › Artist=$nextValue › Album]  Esc=Back"
                $res = Invoke-FzmpFacetPicker -Records $narrowed2 -Field "Album" `
                    -Prompt "Meta: Album> " -Header $hdr -Config $Config -UnknownLabel $unknown `
                    -PreviewScript $previewScript -PreviewPos $previewPos

                if ($res.Action -eq "selected") {
                    $albumValue = $res.Value
                    $stage = 4
                } elseif ($res.Action -in "quit","queue-view","set-recent","search") {
                    return $res
                } else {
                    # Esc → back to stage 2
                    $stage = 2
                }
            }

            # ── Stage 4: show track list ──────────────────────────────────────
            4 {
                # Build filter map from accumulated selections
                $filters = @{ $rootFacet = $rootValue }
                if ($nextValue)  { $filters[$nextFacet] = $nextValue }
                if ($albumValue) { $filters["Album"]    = $albumValue }

                $trackPaths = Get-FzmpTracksForFilters -Config $Config -Filters $filters -AllRecords $records

                if (-not $trackPaths -or $trackPaths.Count -eq 0) {
                    $StatusMessage = "No tracks found"
                    $stage = if ($albumValue) { 3 } elseif ($nextValue) { 2 } else { 1 }
                    continue
                }

                $breadcrumb = ($filters.Keys | ForEach-Object { "$_=$($filters[$_])" }) -join " › "
                $trackHeader = "$headerBase$recentLabel`n[Metadata › $breadcrumb — $($trackPaths.Count) tracks]"

                $r = Show-FzmpTrackList -TrackPaths $trackPaths -Header $trackHeader -Config $Config `
                    -PreviewScript $previewScript -MpvActionScript $mpvActionScript `
                    -PreviewMode $previewMode -PreviewPos $previewPos

                if ($r.Action -eq "back") {
                    # Esc from track list → go back one stage
                    $stage = if ($albumValue) { 3 } elseif ($nextValue) { 2 } else { 1 }
                    $albumValue = $null   # clear deepest selection so stage 3 reruns picker
                } else {
                    return $r
                }
            }
        }
    }
}

# Shared track-list fzf screen used by metadata browser final stage.
function Show-FzmpTrackList {
    param(
        [string[]]$TrackPaths,
        [string]$Header,
        [hashtable]$Config,
        [string]$PreviewScript,
        [string]$MpvActionScript,
        [string]$PreviewMode,
        [string]$PreviewPos
    )

    # Display: "Artist - Title  [Album]" tab full path — fzf shows col1, uses col2 for preview
    $trackLines = foreach ($p in $TrackPaths) {
        $leaf = Split-Path -Leaf $p
        "$leaf`t$p"
    }

    $previewCmd = "pwsh -NoProfile -File `"$PreviewScript`" -Path {2} -Mode $PreviewMode"

    $fzfArgs = @(
        "--height=99%"
        "--ansi"
        "--layout=reverse"
        "--multi"
        "--header=$Header`n  Enter=Play  Tab=Select  Ctrl-A=Queue selection  Ctrl-O=Open in Explorer  Esc=Back  Ctrl-Q=Quit"
        "--header-first"
        "--prompt=MetaTracks> "
        "--expect=ctrl-a,ctrl-g,ctrl-o,ctrl-q,ctrl-r,ctrl-s,ctrl-v,enter"
        "--delimiter=`t"
        "--with-nth=1"
        "--preview=$previewCmd"
        "--preview-window=$PreviewPos"
        "--bind=ctrl-space:execute-silent(pwsh -NoProfile -File `"$MpvActionScript`" pause `"$($Config.PipeName)`")"
        "--bind=alt-n:execute-silent(pwsh -NoProfile -File `"$MpvActionScript`" next `"$($Config.PipeName)`")"
        "--bind=alt-p:execute-silent(pwsh -NoProfile -File `"$MpvActionScript`" prev `"$($Config.PipeName)`")"
    )

    $raw = ($trackLines -join "`n") | & $Config.FzfPath @fzfArgs
    if (-not $raw) { return @{ Action = "back" } }

    $parts = $raw -split "`n"
    $key = $parts[0].Trim()
    $selections = @($parts[1..($parts.Count - 1)] | Where-Object { $_.Trim() })
    $firstCols = ($selections | Select-Object -First 1) -split "`t", 2
    $firstPath = if ($firstCols.Count -gt 1) { $firstCols[1].Trim() } else { "" }

    switch ($key) {
        "enter" {
            if ($selections.Count -gt 1) {
                $files = $selections | ForEach-Object { ($_ -split "`t", 2)[1].Trim() }
                return @{ Action = "queue-selected"; Files = $files }
            }
            if ($firstPath) { return @{ Action = "play"; File = $firstPath } }
            return @{ Action = "back" }
        }
        "ctrl-a" {
            $files = $selections | ForEach-Object { ($_ -split "`t", 2)[1].Trim() }
            if (-not $files) { $files = @($TrackPaths) }
            return @{ Action = "queue-selected"; Files = $files }
        }
        "ctrl-o" {
            if ($firstPath) {
                return @{ Action = "open-explorer"; Path = (Split-Path -Parent $firstPath); File = $firstPath }
            }
            return @{ Action = "back" }
        }
        "ctrl-q" { return @{ Action = "quit" } }
        "ctrl-v" { return @{ Action = "queue-view" } }
        "ctrl-r" { return @{ Action = "set-recent" } }
        "ctrl-s" { return @{ Action = "search" } }
        "ctrl-g" { return @{ Action = "back" } }
        default {
            if ($firstPath) { return @{ Action = "play"; File = $firstPath } }
            return @{ Action = "back" }
        }
    }
}
