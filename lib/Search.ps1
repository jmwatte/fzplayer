# fzmp - Search.ps1
# Recursive search across all tracks in the music library

function Show-SearchBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [hashtable]$Config
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

    # Build extension filter args for fd
    $extArgs = @()
    foreach ($ext in $Config.AudioExtensions) {
        $extArgs += "-e"
        $extArgs += $ext
    }

    # Recursive search — show paths relative to music root
    $fdArgs = @("--type", "f", "--base-directory", $RootPath) + $extArgs
    if ($Config.Recent) {
        $fdArgs += "--changed-within"
        $fdArgs += $Config.Recent
    }
    $tracks = & $fdExe @fdArgs 2>$null

    if (-not $tracks -or $tracks.Count -eq 0) {
        return @{ Action = "back"; RootPath = $RootPath; StatusMessage = "No audio files found" }
    }

    $fzfInput = $tracks -join "`n"

    # Set env var for preview base path (avoids quoting issues with cmd.exe)
    $env:FZMP_PREVIEW_BASE = $RootPath

    # Preview uses full path: env var base + relative selection
    $previewCmd = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode $previewMode"
    $previewCmdAlt = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode $previewModeAlt"
    $previewCmdEmbedded = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode embedded"

    $fzfArgs = @(
        "--height=99%"
        "--ansi"
        "--layout=reverse"
        "--header=$header$recentLabel`n[Search: $RootPath]"
        "--header-first"
        "--prompt=Search> "
        "--preview=$previewCmd"
        "--preview-window=$previewPos"
        "--bind=ctrl-t:change-preview($previewCmdAlt)+change-prompt(Preview toggled> )"
        "--bind=alt-/:change-preview-window($previewPosAlt|$previewPos)"
        "--bind=ctrl-e:change-preview($previewCmdEmbedded)"
        "--bind=ctrl-space:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" pause `"$($Config.PipeName)`")"
        "--bind=alt-n:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" next `"$($Config.PipeName)`")"
        "--bind=alt-p:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" prev `"$($Config.PipeName)`")"
        "--bind=f1:preview(type `"$(Join-Path $PSScriptRoot 'help-search.txt')`")"
        "--bind=?:preview(type `"$(Join-Path $PSScriptRoot 'help-search.txt')`")"
        "--expect=ctrl-a,ctrl-g,ctrl-o,ctrl-q,ctrl-v,ctrl-r,enter"
    )

    $result = $fzfInput | & $fzfExe @fzfArgs

    if (-not $result) {
        return @{ Action = "back"; RootPath = $RootPath }
    }

    $lines = $result -split "`n"
    $key = $lines[0].Trim()
    $selection = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }
    $selectedFile = if ($selection) { Join-Path $RootPath $selection } else { "" }

    switch ($key) {
        "enter" {
            if ($selectedFile) {
                return @{ Action = "play"; RootPath = $RootPath; File = $selectedFile }
            }
            return @{ Action = "back"; RootPath = $RootPath }
        }
        "ctrl-a" {
            if ($selectedFile) {
                return @{ Action = "queue"; RootPath = $RootPath; File = $selectedFile }
            }
            return @{ Action = "noop"; RootPath = $RootPath }
        }
        "ctrl-o" {
            if ($selectedFile) {
                return @{ Action = "open-explorer"; RootPath = $RootPath; Path = (Split-Path -Parent $selectedFile); File = $selectedFile }
            }
            return @{ Action = "back"; RootPath = $RootPath }
        }
        "ctrl-q" {
            return @{ Action = "quit"; RootPath = $RootPath }
        }
        "ctrl-g" {
            return @{ Action = "metadata"; RootPath = $RootPath }
        }
        "ctrl-v" {
            return @{ Action = "queue-view"; RootPath = $RootPath }
        }
        "ctrl-r" {
            return @{ Action = "set-recent"; RootPath = $RootPath }
        }
        default {
            if ($selectedFile) {
                return @{ Action = "play"; RootPath = $RootPath; File = $selectedFile }
            }
            return @{ Action = "back"; RootPath = $RootPath }
        }
    }
}
