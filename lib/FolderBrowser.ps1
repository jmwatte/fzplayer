# fzmp - FolderBrowser.ps1
# Folder-browsing fzf session: lists subdirectories, drill-down navigation

function Get-NowPlayingHeader {
    param([hashtable]$Config)

    # If mpv hasn't been started yet, no point querying
    if (-not $script:MpvStarted) {
        return "No track playing"
    }

    # Quick check: see if the named pipe exists before attempting slow IPC
    if (-not (Test-Path "\\.\pipe\$($Config.PipeName)")) {
        return "No track playing"
    }

    # Send all three property requests in a single pipe connection to avoid
    # race conditions and the overhead of three separate connect/disconnect cycles.
    $pipe = $null
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", $Config.PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(1000)

        $cmds  = '{"command":["get_property","media-title"],"request_id":1}' + "`n"
        $cmds += '{"command":["get_property","metadata/by-key/artist"],"request_id":2}' + "`n"
        $cmds += '{"command":["get_property","pause"],"request_id":3}' + "`n"
        $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($cmds)
        $pipe.Write($sendBytes, 0, $sendBytes.Length)
        $pipe.Flush()

        $responses = @{}
        $buf = [byte[]]::new(65536)
        $accumulated = ""
        $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)

        while ($responses.Count -lt 3 -and [DateTime]::UtcNow -lt $deadline) {
            $n = $pipe.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $accumulated += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            foreach ($line in ($accumulated -split "`n")) {
                $line = $line.Trim()
                if (-not $line) { continue }
                $parsed = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($parsed -and $null -ne $parsed.request_id) {
                    $responses[$parsed.request_id] = $parsed
                }
            }
        }

        $titleResp = $responses[1]
        if (-not $titleResp -or $titleResp.error -ne "success" -or -not $titleResp.data) {
            return "No track playing"
        }

        $title  = $titleResp.data
        $artist = if ($responses[2] -and $responses[2].error -eq "success") { $responses[2].data } else { "" }
        $paused = if ($responses[3] -and $responses[3].error -eq "success") { $responses[3].data } else { $false }

        $status  = if ($paused) { "||" } else { ">" }
        $display = if ($artist) { "$artist - $title" } else { $title }
        return "$status $display"
    }
    catch { }
    finally {
        try { if ($pipe) { $pipe.Dispose() } } catch { }
    }
    return "No track playing"
}

function Show-FolderBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string]$Query = "",

        [string]$StatusMessage = ""
    )

    $fdExe      = $Config.FdPath
    $fzfExe     = $Config.FzfPath
    $libDir     = Join-Path $PSScriptRoot ""
    $previewScript = Join-Path $libDir "Preview.ps1"

    # Determine preview window position
    $previewPos = if ($Config.PreviewPosition -eq "left") { "left,50%" } else { "up,50%" }
    $previewPosAlt = if ($Config.PreviewPosition -eq "left") { "up,50%" } else { "left,50%" }

    # Determine initial preview mode
    $previewMode = $Config.PreviewMode
    $previewModeAlt = if ($previewMode -eq "art") { "tags" } else { "art" }

    # Now playing header
    $header = Get-NowPlayingHeader -Config $Config
    $recentLabel = if ($Config.Recent) { " [Recent: $($Config.Recent)]" } else { "" }

    # Build folder list: ".." + subdirectories
    $folders = @()
    $parentDir = Split-Path -Parent $Path
    if ($parentDir -and $parentDir -ne $Path) {
        $folders += ".."
    }

    $fdArgs = @("--type", "d", "--max-depth", "1", "--base-directory", $Path)
    if ($Config.Recent) {
        $fdArgs += "--changed-within"
        $fdArgs += $Config.Recent
    }
    $subDirs = & $fdExe @fdArgs 2>$null | Sort-Object
    if ($subDirs) {
        $folders += $subDirs | ForEach-Object { $_.TrimEnd('\', '/') }
    }

    if ($folders.Count -eq 0) {
        # No subfolders — signal to go to track browser
        return @{ Action = "tracks"; Path = $Path }
    }

    $fzfInput = $folders -join "`n"

    # Set env var for preview base path (avoids quoting issues with cmd.exe)
    $env:FZMP_PREVIEW_BASE = $Path

    # Build fzf preview command — {} is the selected item (cmd.exe double-quotes it)
    $previewCmd = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode $previewMode"
    $previewCmdAlt = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode $previewModeAlt"
    $previewCmdEmbedded = "pwsh -NoProfile -File `"$previewScript`" -Path {} -Mode embedded"

    # Action scripts for mpv control
    $mpvActionScript = Join-Path $libDir "MpvAction.ps1"

    # Help file path for preview overlay
    $helpFile = Join-Path $libDir "help-folders.txt"

    # Build fzf arguments
    $fzfArgs = @(
        "--height=99%"
        "--ansi"
        "--layout=reverse"
        "--header=$header$recentLabel$(if ($StatusMessage) { "`n$StatusMessage" })"
        "--header-first"
        "--prompt=Folders> "
        "--print-query"
        $(if ($Query) { "--query=$Query" })
        "--preview=$previewCmd"
        "--preview-window=$previewPos"
        "--bind=ctrl-t:change-preview($previewCmdAlt)+change-prompt(Preview toggled> )"
        "--bind=alt-/:change-preview-window($previewPosAlt|$previewPos)"
        "--bind=ctrl-e:change-preview($previewCmdEmbedded)"
        "--bind=ctrl-space:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" pause `"$($Config.PipeName)`")"
        "--bind=alt-n:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" next `"$($Config.PipeName)`")"
        "--bind=alt-p:execute-silent(pwsh -NoProfile -File `"$mpvActionScript`" prev `"$($Config.PipeName)`")"
        "--bind=f1:preview(type `"$helpFile`")"
        "--bind=?:preview(type `"$helpFile`")"
        "--expect=ctrl-a,ctrl-s,ctrl-q,ctrl-v,ctrl-r,enter"
    )

    $result = $fzfInput | & $fzfExe @fzfArgs

    if (-not $result) {
        # ESC or Ctrl-C — go up; at root, stay in place
        $parentDir2 = Split-Path -Parent $Path
        if ($parentDir2 -and $parentDir2 -ne $Path -and $Path -ne $Config.MusicRoot) {
            return @{ Action = "up"; Path = $parentDir2 }
        }
        return @{ Action = "noop"; Path = $Path }
    }

    # --print-query adds query as first line: query, key, selection
    $lines = $result -split "`n"
    $lastQuery = $lines[0].Trim()
    $key = if ($lines.Count -gt 1) { $lines[1].Trim() } else { "" }
    $selection = if ($lines.Count -gt 2) { $lines[2].Trim() } else { "" }

    switch ($key) {
        "enter" {
            if ($selection -eq "..") {
                return @{ Action = "up"; Path = $parentDir; Query = $lastQuery }
            }
            $selectedPath = Join-Path $Path $selection
            if (Test-Path $selectedPath -PathType Container) {
                return @{ Action = "drill"; Path = $selectedPath; Query = $lastQuery }
            }
            return @{ Action = "noop"; Path = $Path; Query = $lastQuery }
        }
        "ctrl-a" {
            # Queue all tracks in selected folder
            $targetFolder = if ($selection -and $selection -ne "..") {
                Join-Path $Path $selection
            } else { $Path }
            return @{ Action = "queue-folder"; Path = $targetFolder; Query = $lastQuery }
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
            return @{ Action = "set-recent"; Path = $Path; Query = $lastQuery }
        }
        default {
            # No key match or empty — treat as enter if there's a selection
            if ($selection -eq "..") {
                return @{ Action = "up"; Path = $parentDir; Query = $lastQuery }
            }
            if ($selection) {
                $selectedPath = Join-Path $Path $selection
                return @{ Action = "drill"; Path = $selectedPath; Query = $lastQuery }
            }
            return @{ Action = "noop"; Path = $Path; Query = $lastQuery }
        }
    }
}
