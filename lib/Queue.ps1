# fzmp - Queue.ps1
# Queue display and management via fzf

function Show-QueueBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$StatusMessage = ""
    )

    $fzfExe = $Config.FzfPath
    $mpvActionScript = Join-Path $PSScriptRoot "MpvAction.ps1"

    # Get playlist from mpv
    $playlist = Get-MpvPlaylist -Config $Config

    if (-not $playlist -or $playlist.Count -eq 0) {
        return @{ Action = "back"; StatusMessage = "Queue is empty" }
    }

    # Format playlist entries with index and current marker
    $lines = @()
    $currentIdx = -1
    for ($i = 0; $i -lt $playlist.Count; $i++) {
        $entry = $playlist[$i]
        $filename = if ($entry.filename) { Split-Path -Leaf $entry.filename } else { "Unknown" }
        $marker = ""
        if ($entry.current -eq $true -or $entry.current -eq "yes") {
            $marker = " >>>"
            $currentIdx = $i
        }
        $lines += "{0,3}. {1}{2}" -f ($i + 1), $filename, $marker
    }

    $header = Get-NowPlayingHeader -Config $Config
    $fzfInput = $lines -join "`n"

    $fzfArgs = @(
        "--height=99%"
        "--ansi"
        "--layout=reverse"
        "--multi"
        "--header=$header`n[Queue: $($playlist.Count) tracks]$(if ($StatusMessage) { "`n$StatusMessage" })`nTab=Select  Enter=Jump  Ctrl-D=Remove  Esc=Back  Ctrl-Q=Quit"
        "--header-first"
        "--prompt=Queue> "
        "--no-preview"
        "--bind=ctrl-space:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" pause `"$($Config.PipeName)`")"
        "--bind=alt-n:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" next `"$($Config.PipeName)`")"
        "--bind=alt-p:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" prev `"$($Config.PipeName)`")"
        "--expect=ctrl-d,enter,esc,ctrl-q"
    )

    # Pre-select current track
    if ($currentIdx -ge 0) {
        # fzf uses 1-based positioning with --scroll-off or we can use default position
    }

    $result = $fzfInput | & $fzfExe @fzfArgs

    if (-not $result) {
        return @{ Action = "back" }
    }

    $resultLines = $result -split "`n"
    $key = $resultLines[0].Trim()
    # All lines after the key are selected items (multi-select)
    $selections = @($resultLines[1..($resultLines.Count - 1)] | Where-Object { $_.Trim() })
    # For single-action commands, use the first selection
    $selection = if ($selections.Count -gt 0) { $selections[0].Trim() } else { "" }

    # Extract index from a single selection line (format: "  1. filename.mp3")
    $idx = -1
    if ($selection -match '^\s*(\d+)\.') {
        $idx = [int]$Matches[1] - 1
    }

    switch ($key) {
        "enter" {
            if ($idx -ge 0) {
                Set-MpvPlaylistPos -Config $Config -Index $idx
            }
            return @{ Action = "jump"; Index = $idx }
        }
        "ctrl-d" {
            # Collect all selected indices, remove in descending order to avoid index shifting
            $indices = @()
            foreach ($sel in $selections) {
                if ($sel.Trim() -match '^\s*(\d+)\.') {
                    $indices += [int]$Matches[1] - 1
                }
            }
            $indices = $indices | Sort-Object -Descending
            foreach ($i in $indices) {
                Remove-MpvPlaylistItem -Config $Config -Index $i
            }
            $removed = $indices.Count
            $msg = if ($removed -eq 1) { "Removed 1 track" } else { "Removed $removed tracks" }
            return @{ Action = "remove"; StatusMessage = $msg }
        }
        "esc" {
            return @{ Action = "back" }
        }
        "ctrl-q" {
            return @{ Action = "quit" }
        }
        default {
            return @{ Action = "back" }
        }
    }
}
