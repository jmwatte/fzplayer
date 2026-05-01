# fzmp - MpvAction.ps1
# Lightweight script for fzf execute-silent binds to control mpv
# Usage: pwsh -NoProfile -File MpvAction.ps1 <action> <pipeName>
# Actions: pause, next, prev

param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Action,

    [Parameter(Mandatory, Position = 1)]
    [string]$PipeName
)

function Send-Ipc {
    param([string]$PipeName, [array]$Command)

    $json = (@{ command = $Command } | ConvertTo-Json -Compress) + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $pipe = $null
    try {
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(500)
        $pipe.Write($bytes, 0, $bytes.Length)
        $pipe.Flush()
    }
    catch { }
    finally {
        if ($pipe) { try { $pipe.Dispose() } catch { } }
    }
}

switch ($Action) {
    "pause" { Send-Ipc -PipeName $PipeName -Command @("cycle", "pause") }
    "next"  { Send-Ipc -PipeName $PipeName -Command @("playlist-next") }
    "prev"  { Send-Ipc -PipeName $PipeName -Command @("playlist-prev") }
}
