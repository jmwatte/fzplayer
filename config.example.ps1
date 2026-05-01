# fzmp - Example Configuration
# Copy this file to: $env:APPDATA\fzmp\config.ps1
# All paths should be absolute. Tools in PATH can use just the executable name.

@{
    # Root directory of your music library
    MusicRoot       = "H:\music"

    # Preview pane position: "top" or "left"
    PreviewPosition = "top"

    # Default preview content: "art" (album art) or "tags" (file metadata)
    PreviewMode     = "art"

    # Tool paths — use full paths if not in PATH
    ChafaPath       = "C:\Users\jmw\AppData\Local\Microsoft\WinGet\Links\Chafa.exe"
    MpvPath         = "C:\Program Files\MPV Player\mpv.exe"
    FfprobePath     = "C:\Users\jmw\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1-full_build\bin\ffprobe.exe"
    FfmpegPath      = "C:\Users\jmw\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-8.1-full_build\bin\ffmpeg.exe"
    FdPath          = "C:\Users\jmw\AppData\Local\Microsoft\WinGet\Packages\sharkdp.fd_Microsoft.Winget.Source_8wekyb3d8bbwe\fd-v10.4.2-x86_64-pc-windows-msvc\fd.exe"
    FzfPath         = "fzf"       # fzf is typically in PATH

    # Named pipe name for mpv IPC (no need to change unless running multiple instances)
    PipeName        = "fzmp"

    # Album art filenames to look for in folders (checked in order)
    ArtFilenames    = @("folder.jpg", "folder.png", "cover.jpg", "cover.png", "front.jpg", "front.png")

    # Audio file extensions to include when browsing
    AudioExtensions = @("mp3", "flac", "ogg", "wav", "m4a", "opus", "wma", "aac", "ape", "wv", "mka")
}
