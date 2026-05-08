# fzmp - TrackBrowser.ps1
# Track-browsing fzf session: lists audio files in a folder

function Show-TrackBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$StatusMessage = ""
    )

    $fdExe      = $Config.FdPath
    $fzfExe     = $Config.FzfPath
    $libDir     = Join-Path $PSScriptRoot ""
    $previewScript = Join-Path $libDir "Preview.ps1"
    $mpvActionScript = Join-Path $libDir "MpvAction.ps1"

    # Determine preview window position
    $previewPos = if ($Config.PreviewPosition -eq "left") { "left,50%" } else { "up,50%" }
    $previewPosAlt = if ($Config.PreviewPosition -eq "left") { "up,50%" } else { "left,50%" }

    # Determine initial preview mode
    $previewMode = $Config.PreviewMode
    $previewModeAlt = if ($previewMode -eq "art") { "tags" } else { "art" }

    # Now playing header
    $header = Get-NowPlayingHeader -Config $Config
    $recentLabel = if ($Config.Recent) { " [Recent: $($Config.Recent)]" } else { "" }
    $folderName = Split-Path -Leaf $Path

    # Build track list using fd
    $extArgs = @()
    foreach ($ext in $Config.AudioExtensions) {
        $extArgs += "-e"
        $extArgs += $ext
    }

    $fdArgs = @("--type", "f", "--max-depth", "1", "--base-directory", $Path) + $extArgs
    if ($Config.Recent) {
        $fdArgs += "--changed-within"
        $fdArgs += $Config.Recent
    }
    $tracks = & $fdExe @fdArgs 2>$null | Sort-Object

    if (-not $tracks -or $tracks.Count -eq 0) {
        return @{ Action = "back"; Path = $Path; StatusMessage = "No audio files in: $(Split-Path -Leaf $Path)" }
    }

    $fzfInput = $tracks -join "`n"

    # Set env var for preview base path (avoids quoting issues with cmd.exe)
    $env:FZMP_PREVIEW_BASE = $Path

    # Build fzf preview commands — {} is the selected item (cmd.exe double-quotes it)
    $previewCmd = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode $previewMode"
    $previewCmdAlt = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode $previewModeAlt"
    $previewCmdEmbedded = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode embedded"

    $fzfArgs = @(
        "--height=99%"
        "--ansi"
        "--layout=reverse"
        "--multi"
        "--header=$header$recentLabel`n[$folderName]$(if ($StatusMessage) { "`n$StatusMessage" })"
        "--header-first"
        "--prompt=Tracks> "
        "--preview=$previewCmd"
        "--preview-window=$previewPos"
        "--bind=ctrl-t:change-preview($previewCmdAlt)+change-prompt(Preview toggled> )"
        "--bind=alt-/:change-preview-window($previewPosAlt|$previewPos)"
        "--bind=ctrl-e:change-preview($previewCmdEmbedded)"
        "--bind=ctrl-space:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" pause `"$($Config.PipeName)`")"
        "--bind=alt-n:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" next `"$($Config.PipeName)`")"
        "--bind=alt-p:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" prev `"$($Config.PipeName)`")"
        "--bind=f1:preview(type `"$(Join-Path $libDir 'help-tracks.txt')`")"
        "--bind=?:preview(type `"$(Join-Path $libDir 'help-tracks.txt')`")"
        "--expect=ctrl-a,ctrl-s,ctrl-q,ctrl-v,ctrl-r,enter"
    )

    $result = $fzfInput | & $fzfExe @fzfArgs

    if (-not $result) {
        # ESC or Ctrl-C — go back to folder browser
        return @{ Action = "back"; Path = $Path }
    }

    $lines = $result -split "`n"
    $key = $lines[0].Trim()
    # All lines after the key are selected items
    $selections = @($lines[1..($lines.Count - 1)] | Where-Object { $_.Trim() })
    $selection = if ($selections.Count -gt 0) { $selections[0].Trim() } else { "" }
    $selectedFile = if ($selection) { Join-Path $Path $selection } else { "" }

    switch ($key) {
        "enter" {
            if ($selections.Count -gt 1) {
                # Multiple items tab-selected — queue them all
                $files = $selections | ForEach-Object { Join-Path $Path $_.Trim() }
                return @{ Action = "queue-selected"; Path = $Path; Files = $files }
            }
            if ($selectedFile) {
                return @{ Action = "play"; Path = $Path; File = $selectedFile }
            }
            return @{ Action = "back"; Path = $Path }
        }
        "ctrl-a" {
            return @{ Action = "queue-all"; Path = $Path }
        }
        "ctrl-s" {
            return @{ Action = "search"; Path = $Path }
        }
        "ctrl-q" {
            return @{ Action = "quit"; Path = $Path }
        }
        "ctrl-v" {
            return @{ Action = "queue-view"; Path = $Path }
        }
        "ctrl-r" {
            return @{ Action = "set-recent"; Path = $Path }
        }
        default {
            if ($selectedFile) {
                return @{ Action = "play"; Path = $Path; File = $selectedFile }
            }
            return @{ Action = "back"; Path = $Path }
        }
    }
}
