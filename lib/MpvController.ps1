# fzmp - MpvController.ps1
# Manages mpv process lifecycle and IPC communication via Windows named pipe
# IMPORTANT: Uses raw byte writes with LF (\n) line endings — mpv rejects \r\n.

$script:MpvProcess = $null

function Start-Mpv {
    [CmdletBinding()]
    param([hashtable]$Config)

    $mpvExe = $Config.MpvPath

    # Kill any existing mpv with our pipe
    Stop-Mpv -Config $Config -ErrorAction SilentlyContinue

    $argList = @(
        "--idle=yes"
        "--no-terminal"
        "--input-ipc-server=\\.\pipe\$($Config.PipeName)"
        "--no-video"
        "--really-quiet"
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $mpvExe
    $psi.Arguments = $argList -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $script:MpvProcess = [System.Diagnostics.Process]::Start($psi)

    # Wait for pipe to become available
    $pipeReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $testPipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", $Config.PipeName, [System.IO.Pipes.PipeDirection]::InOut)
            $testPipe.Connect(100)
            $testPipe.Dispose()
            $pipeReady = $true
            break
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }

    if (-not $pipeReady) {
        Write-Warning "mpv pipe did not become available within 3 seconds"
    }
}

function Stop-Mpv {
    [CmdletBinding()]
    param([hashtable]$Config)

    # Send quit (fire-and-forget)
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", $Config.PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(500)
        $cmd = '{"command":["quit"]}' + "`n"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($cmd)
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
        $pipe.Dispose()
    }
    catch { }

    # Give mpv a moment to exit gracefully
    if ($script:MpvProcess -and -not $script:MpvProcess.HasExited) {
        $script:MpvProcess.WaitForExit(1000) | Out-Null
    }
    if ($script:MpvProcess -and -not $script:MpvProcess.HasExited) {
        $script:MpvProcess.Kill()
        $script:MpvProcess.WaitForExit(1000) | Out-Null
    }
    $script:MpvProcess = $null
}

function Send-MpvCommand {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [array]$Command
    )

    $json = (@{ command = $Command } | ConvertTo-Json -Compress) + "`n"
    $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $buf = [byte[]]::new(65536)

    $pipe = $null
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", $Config.PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(2000)
        $pipe.Write($sendBytes, 0, $sendBytes.Length)
        $pipe.Flush()

        # Read until we find a command response (has "error" field), skipping events
        $accumulated = ""
        $deadline = [DateTime]::UtcNow.AddMilliseconds(3000)
        while ([DateTime]::UtcNow -lt $deadline) {
            $n = $pipe.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $accumulated += [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)

            foreach ($line in ($accumulated -split "`n")) {
                $line = $line.Trim()
                if (-not $line) { continue }
                $parsed = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($parsed -and $null -ne $parsed.error) {
                    return $parsed
                }
            }
        }
    }
    catch {
        Write-Warning "mpv IPC error: $_"
    }
    finally {
        try { if ($pipe) { $pipe.Dispose() } } catch { }
    }

    return $null
}

function Invoke-MpvPlay {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [string]$FilePath
    )
    $normalizedPath = $FilePath -replace '\\', '/'
    Send-MpvCommand -Config $Config -Command @("loadfile", $normalizedPath, "replace") | Out-Null
}

function Add-MpvQueue {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [string]$FilePath
    )
    $normalizedPath = $FilePath -replace '\\', '/'
    Send-MpvCommand -Config $Config -Command @("loadfile", $normalizedPath, "append-play") | Out-Null
}

function Invoke-MpvNext {
    [CmdletBinding()]
    param([hashtable]$Config)
    Send-MpvCommand -Config $Config -Command @("playlist-next") | Out-Null
}

function Invoke-MpvPrev {
    [CmdletBinding()]
    param([hashtable]$Config)
    Send-MpvCommand -Config $Config -Command @("playlist-prev") | Out-Null
}

function Invoke-MpvPause {
    [CmdletBinding()]
    param([hashtable]$Config)
    Send-MpvCommand -Config $Config -Command @("cycle", "pause") | Out-Null
}

function Get-MpvNowPlaying {
    [CmdletBinding()]
    param([hashtable]$Config)

    $result = @{
        Title    = ""
        Artist   = ""
        Album    = ""
        Path     = ""
        Duration = ""
        Position = ""
        Paused   = $false
    }

    try {
        $resp = Send-MpvCommand -Config $Config -Command @("get_property", "media-title")
        if ($resp -and $resp.error -eq "success") { $result.Title = $resp.data }

        $resp = Send-MpvCommand -Config $Config -Command @("get_property", "metadata/by-key/artist")
        if ($resp -and $resp.error -eq "success") { $result.Artist = $resp.data }

        $resp = Send-MpvCommand -Config $Config -Command @("get_property", "metadata/by-key/album")
        if ($resp -and $resp.error -eq "success") { $result.Album = $resp.data }

        $resp = Send-MpvCommand -Config $Config -Command @("get_property", "path")
        if ($resp -and $resp.error -eq "success") { $result.Path = $resp.data }

        $resp = Send-MpvCommand -Config $Config -Command @("get_property", "duration")
        if ($resp -and $resp.error -eq "success" -and $resp.data) {
            $ts = [TimeSpan]::FromSeconds([math]::Floor($resp.data))
            $result.Duration = "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
        }

        $resp = Send-MpvCommand -Config $Config -Command @("get_property", "time-pos")
        if ($resp -and $resp.error -eq "success" -and $resp.data) {
            $ts = [TimeSpan]::FromSeconds([math]::Floor($resp.data))
            $result.Position = "{0}:{1:D2}" -f [int]$ts.TotalMinutes, $ts.Seconds
        }

        $resp = Send-MpvCommand -Config $Config -Command @("get_property", "pause")
        if ($resp -and $resp.error -eq "success") { $result.Paused = $resp.data }
    }
    catch { }

    return $result
}

function Get-MpvPlaylist {
    [CmdletBinding()]
    param([hashtable]$Config)

    $resp = Send-MpvCommand -Config $Config -Command @("get_property", "playlist")
    if ($resp -and $resp.error -eq "success") {
        return $resp.data
    }
    return @()
}

function Remove-MpvPlaylistItem {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [int]$Index
    )
    Send-MpvCommand -Config $Config -Command @("playlist-remove", $Index) | Out-Null
}

function Set-MpvPlaylistPos {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [int]$Index
    )
    Send-MpvCommand -Config $Config -Command @("set_property", "playlist-pos", $Index) | Out-Null
}
