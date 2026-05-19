# fzmp - Terminal Audio Player
# Main entry point: parse args, load config, start mpv, run browser loop

[CmdletBinding()]
param(
    [string]$MusicRoot,
    [ValidateSet("top", "left")]
    [string]$PreviewPosition,
    [ValidateSet("art", "tags")]
    [string]$PreviewMode,
    [string]$Recent
)

$ErrorActionPreference = 'Continue'

# Determine script root
$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$libDir = Join-Path $scriptRoot "lib"

# Source all library modules
. (Join-Path $libDir "Config.ps1")
. (Join-Path $libDir "MpvController.ps1")
. (Join-Path $libDir "FolderBrowser.ps1")
. (Join-Path $libDir "TrackBrowser.ps1")
. (Join-Path $libDir "Search.ps1")
. (Join-Path $libDir "MetaBrowser.ps1")
. (Join-Path $libDir "Queue.ps1")

# Load config with CLI overrides
$config = Get-FzmpConfig `
    -MusicRoot $MusicRoot `
    -PreviewPosition $PreviewPosition `
    -PreviewMode $PreviewMode `
    -Recent $Recent

# Validate dependencies
$errors = Test-FzmpDependencies -Config $config
if ($errors.Count -gt 0) {
    Write-Host "`n  fzmp: dependency check failed`n" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "    - $err" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Config file: $(Get-FzmpConfigPath)" -ForegroundColor Gray
    Write-Host "  Create it from config.example.ps1 with your tool paths." -ForegroundColor Gray
    Write-Host ""
    exit 1
}

if ($config.MetadataEnabled) {
    Start-FzmpMetadataWarmup -Config $config
}

# Cleanup on exit
$cleanupBlock = {
    Stop-Mpv -Config $config -ErrorAction SilentlyContinue
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupBlock | Out-Null

# mpv starts lazily on first play
$script:MpvStarted = $false

function Ensure-MpvRunning {
    if (-not $script:MpvStarted) {
        Start-Mpv -Config $config
        $script:MpvStarted = $true
    }
}

function Open-InExplorer {
    param(
        [string]$Path,
        [string]$File
    )

    if ($File -and (Test-Path -LiteralPath $File)) {
        Start-Process explorer.exe -ArgumentList "/select,`"$File`""
        return
    }

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Start-Process explorer.exe -ArgumentList "`"$Path`""
    }
}

function Get-RecentInput {
    param([string]$FzfPath)
    # Use a minimal fzf session so nothing is printed to the scrollback
    $fzfResult = $null | & $FzfPath `
        "--disabled" `
        "--print-query" `
        "--height=4" `
        "--no-preview" `
        "--no-info" `
        "--layout=reverse" `
        "--prompt=Recent: " `
        "--header=Time range (e.g. 1h, 2d, 1w)  Enter=set  Esc=cancel  empty=clear" `
        "--header-first"
    if ($LASTEXITCODE -eq 130) {
        # Esc — no change
        return @{ Changed = $false }
    }
    $val = if ($fzfResult) { $fzfResult.Trim() } else { "" }
    return @{ Changed = $true; Value = if ($val) { $val } else { $null } }
}

try {
    $currentPath = $config.MusicRoot
    $mode = "folders"       # "folders", "tracks", "search", "metadata", "queue"
    $previousMode = "folders"
    $returnPath = $config.MusicRoot
    $folderQuery = ""
    $statusMessage = ""
    $queryStack = [System.Collections.Generic.Stack[string]]::new()

    Write-Host "  fzmp - Terminal Audio Player" -ForegroundColor Cyan
    Write-Host "  Music: $($config.MusicRoot)" -ForegroundColor DarkGray
    Write-Host "  F1 or ? for keyboard shortcuts" -ForegroundColor DarkGray
    Write-Host ""

    $running = $true
    while ($running) {
        switch ($mode) {
            "folders" {
                $result = Show-FolderBrowser -Path $currentPath -Config $config -Query $folderQuery -StatusMessage $statusMessage
                $statusMessage = ""

                switch ($result.Action) {
                    "drill" {
                        # Push current query for when user comes back to this level
                        $queryStack.Push($result.Query)
                        $folderQuery = ""
                        $currentPath = $result.Path
                    }
                    "tracks" {
                        # No subfolders — go directly to tracks
                        $mode = "tracks"
                    }
                    "up" {
                        # Pop query from parent level
                        $folderQuery = if ($queryStack.Count -gt 0) { $queryStack.Pop() } else { "" }
                        $currentPath = $result.Path
                    }
                    "set-recent" {
                        $r = Get-RecentInput -FzfPath $config.FzfPath
                        if ($r.Changed) { $config.Recent = $r.Value }
                    }
                    "queue-folder" {
                        $folderQuery = $result.Query
                        Ensure-MpvRunning
                        # Queue all tracks in the folder (recursive into subfolders)
                        $extArgs = @()
                        foreach ($ext in $config.AudioExtensions) {
                            $extArgs += "-e"
                            $extArgs += $ext
                        }
                        $fdArgs = @("--type", "f", "--base-directory", $result.Path) + $extArgs
                        $tracks = & $config.FdPath @fdArgs 2>$null | Sort-Object
                        if ($tracks) {
                            foreach ($track in $tracks) {
                                $fullPath = Join-Path $result.Path $track
                                Add-MpvQueue -Config $config -FilePath $fullPath
                            }
                            $statusMessage = "Queued $($tracks.Count) tracks from $(Split-Path -Leaf $result.Path)"
                        }
                    }
                    "search" {
                        $previousMode = "folders"
                        $returnPath = $currentPath
                        $mode = "search"
                    }
                    "metadata" {
                        $previousMode = "folders"
                        $returnPath = $currentPath
                        $mode = "metadata"
                    }
                    "queue-view" {
                        $previousMode = "folders"
                        $returnPath = $currentPath
                        $mode = "queue"
                    }
                    "quit" {
                        $running = $false
                    }
                    "exit" {
                        $running = $false
                    }
                }

                # If we drilled into a folder, check if it has subfolders
                # If not, switch to track mode automatically
                if ($mode -eq "folders" -and $result.Action -eq "drill") {
                    $subCheck = & $config.FdPath --type d --max-depth 1 --base-directory $currentPath 2>$null
                    if (-not $subCheck) {
                        $mode = "tracks"
                    }
                }
            }

            "tracks" {
                $result = Show-TrackBrowser -Path $currentPath -Config $config -StatusMessage $statusMessage
                $statusMessage = ""

                switch ($result.Action) {
                    "play" {
                        Ensure-MpvRunning
                        Invoke-MpvPlay -Config $config -FilePath $result.File
                    }
                    "queue" {
                        Ensure-MpvRunning
                        Add-MpvQueue -Config $config -FilePath $result.File
                        $statusMessage = "Queued: $(Split-Path -Leaf $result.File)"
                    }
                    "queue-all" {
                        Ensure-MpvRunning
                        $extArgs = @()
                        foreach ($ext in $config.AudioExtensions) {
                            $extArgs += "-e"
                            $extArgs += $ext
                        }
                        $fdArgs = @("--type", "f", "--max-depth", "1", "--base-directory", $currentPath) + $extArgs
                        if ($config.Recent) {
                            $fdArgs += "--changed-within"
                            $fdArgs += $config.Recent
                        }
                        $allTracks = & $config.FdPath @fdArgs 2>$null | Sort-Object
                        if ($allTracks) {
                            foreach ($track in $allTracks) {
                                $fullPath = Join-Path $currentPath $track
                                Add-MpvQueue -Config $config -FilePath $fullPath
                            }
                            $statusMessage = "Queued $($allTracks.Count) tracks from $(Split-Path -Leaf $currentPath)"
                        }
                    }
                    "queue-selected" {
                        Ensure-MpvRunning
                        foreach ($f in $result.Files) {
                            Add-MpvQueue -Config $config -FilePath $f
                        }
                        $n = $result.Files.Count
                        $statusMessage = if ($n -eq 1) { "Queued: $(Split-Path -Leaf $result.Files[0])" } else { "Queued $n tracks" }
                    }
                    "search" {
                        $previousMode = "tracks"
                        $returnPath = $currentPath
                        $mode = "search"
                    }
                    "metadata" {
                        $previousMode = "tracks"
                        $returnPath = $currentPath
                        $mode = "metadata"
                    }
                    "queue-view" {
                        $previousMode = "tracks"
                        $returnPath = $currentPath
                        $mode = "queue"
                    }
                    "open-explorer" {
                        Open-InExplorer -Path $result.Path -File $result.File
                        $statusMessage = if ($result.File) { "Opened in Explorer: $(Split-Path -Leaf $result.File)" } else { "Opened in Explorer: $(Split-Path -Leaf $result.Path)" }
                    }
                    "quit" {
                        $running = $false
                    }
                    "back" {
                        $mode = "folders"
                        $folderQuery = if ($queryStack.Count -gt 0) { $queryStack.Pop() } else { "" }
                        $parentDir = Split-Path -Parent $currentPath
                        if ($parentDir -and $parentDir -ne $currentPath) {
                            $currentPath = $parentDir
                        }
                        $statusMessage = $result.StatusMessage
                    }
                    "set-recent" {
                        $r = Get-RecentInput -FzfPath $config.FzfPath
                        if ($r.Changed) { $config.Recent = $r.Value }
                    }
                }
            }

            "search" {
                $result = Show-SearchBrowser -RootPath $config.MusicRoot -Config $config

                switch ($result.Action) {
                    "play" {
                        Ensure-MpvRunning
                        Invoke-MpvPlay -Config $config -FilePath $result.File
                    }
                    "queue" {
                        Ensure-MpvRunning
                        Add-MpvQueue -Config $config -FilePath $result.File
                        $statusMessage = "Queued: $(Split-Path -Leaf $result.File)"
                    }
                    "queue-view" {
                        $previousMode = "search"
                        $mode = "queue"
                    }
                    "metadata" {
                        $previousMode = "search"
                        $mode = "metadata"
                    }
                    "open-explorer" {
                        Open-InExplorer -Path $result.Path -File $result.File
                        $statusMessage = if ($result.File) { "Opened in Explorer: $(Split-Path -Leaf $result.File)" } else { "Opened in Explorer: $(Split-Path -Leaf $result.Path)" }
                    }
                    "quit" {
                        $running = $false
                    }
                    "back" {
                        $mode = $previousMode
                        $currentPath = $returnPath
                        $statusMessage = $result.StatusMessage
                    }
                    "set-recent" {
                        $r = Get-RecentInput -FzfPath $config.FzfPath
                        if ($r.Changed) { $config.Recent = $r.Value }
                    }
                }
            }

            "metadata" {
                if (-not $config.MetadataEnabled) {
                    $mode = $previousMode
                    $statusMessage = "Metadata mode is disabled in config"
                    continue
                }

                $result = Show-MetadataBrowser -Config $config -StatusMessage $statusMessage
                $statusMessage = ""

                switch ($result.Action) {
                    "play" {
                        Ensure-MpvRunning
                        Invoke-MpvPlay -Config $config -FilePath $result.File
                    }
                    "queue" {
                        Ensure-MpvRunning
                        Add-MpvQueue -Config $config -FilePath $result.File
                        $statusMessage = "Queued: $(Split-Path -Leaf $result.File)"
                    }
                    "queue-selected" {
                        Ensure-MpvRunning
                        foreach ($f in $result.Files) {
                            Add-MpvQueue -Config $config -FilePath $f
                        }
                        $n = $result.Files.Count
                        $statusMessage = if ($n -eq 1) { "Queued: $(Split-Path -Leaf $result.Files[0])" } else { "Queued $n tracks" }
                    }
                    "build-meta-cache" {
                        Write-Host "`n  Building metadata cache (first run may take a long time)..." -ForegroundColor DarkGray
                        $cachePath = Update-FzmpMetadataCache -Config $config -Force
                        $statusMessage = "Metadata cache updated: $cachePath"
                    }
                    "search" {
                        $previousMode = "metadata"
                        $mode = "search"
                    }
                    "queue-view" {
                        $previousMode = "metadata"
                        $mode = "queue"
                    }
                    "open-explorer" {
                        Open-InExplorer -Path $result.Path -File $result.File
                        $statusMessage = if ($result.File) { "Opened in Explorer: $(Split-Path -Leaf $result.File)" } else { "Opened in Explorer: $(Split-Path -Leaf $result.Path)" }
                    }
                    "quit" {
                        $running = $false
                    }
                    "back" {
                        $mode = $previousMode
                        $currentPath = $returnPath
                        $statusMessage = $result.StatusMessage
                    }
                    "set-recent" {
                        $r = Get-RecentInput -FzfPath $config.FzfPath
                        if ($r.Changed) { $config.Recent = $r.Value }
                    }
                }
            }

            "queue" {
                $result = Show-QueueBrowser -Config $config -StatusMessage $statusMessage
                $statusMessage = ""

                switch ($result.Action) {
                    "jump" {
                        # Stay in queue view after jumping
                    }
                    "remove" {
                        # Stay in queue view after removing — it will refresh
                        # StatusMessage (e.g. "Removed 3 tracks") shown in next queue header
                        $statusMessage = $result.StatusMessage
                    }
                    "back" {
                        $mode = $previousMode
                        $currentPath = $returnPath
                        $statusMessage = $result.StatusMessage
                    }
                    "quit" {
                        $running = $false
                    }
                }
            }
        }
    }
}
finally {
    if ($script:MpvStarted) {
        Write-Host "`n  Stopping mpv..." -ForegroundColor DarkGray
        Stop-Mpv -Config $config -ErrorAction SilentlyContinue
    }
    Write-Host "  Bye!" -ForegroundColor Cyan
}
